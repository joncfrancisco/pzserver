#!/usr/bin/env bash
# Runs every 60 seconds (pz-watchdog.timer). Publishes metrics, enforces the idle
# shutdown and the session cap.
#
# This lives on the GAME SERVER, not in the bot, and that is deliberate (DESIGN 12): it
# has local RCON access, needs no network path to function, and keeps working when the
# bot host is down or the Discord token has expired. The cost guarantee must not depend
# on Discord being healthy.
set -uo pipefail

# `set -a` so everything in the env file is EXPORTED, not just set: the AWS CLI reads
# AWS_DEFAULT_REGION from the environment, and pz-rcon reads PZ_RCON_*. A plain `source`
# would leave them as shell variables that child processes never see.
set -a
# shellcheck source=/dev/null
source /etc/pz/env
set +a

RCON=/opt/pz/bin/pz-rcon
STATE=/var/lib/pz
IDLE_FILE="${STATE}/idle-minutes"
FAIL_FILE="${STATE}/rcon-failures"
WARNED_FILE="${STATE}/idle-warned"
DOWN_FILE="${STATE}/down-minutes"
MARKER="${STATE}/last-backup"

# Set by pz-restore.sh (and by hand, for a maintenance window) to mean "the game is
# supposed to be down; leave the instance alone". Without it, the down counter below
# would stop the box out from under an admin mid-restore.
MAINT_FLAG="${STATE}/maintenance"

IDLE_WARN="${PZ_IDLE_WARN_MIN:-25}"
IDLE_TIMEOUT="${PZ_IDLE_TIMEOUT_MIN:-30}"
SESSION_CAP_HOURS="${PZ_SESSION_CAP_HOURS:-12}"

# An unreachable server cannot be counted, but it also must not bill at $0.20/hour all
# night. Treat unreachable as idle only after this many consecutive failures -- long
# enough to ride out a world load or a save pause, short enough to matter.
FAIL_THRESHOLD=10

# The same reasoning, for the case where the game unit is not running at all.
# pzserver.service has StartLimitBurst=3/900s and OOMPolicy=stop, so three crashes in
# fifteen minutes or one OOM kill leaves the unit `failed` and the INSTANCE RUNNING --
# which is precisely the failure DESIGN section 12 says this system exists to prevent
# ("a crashed server billing at $0.20/hour overnight"). The RCON-unreachable path above
# never sees it, because RCON is only consulted once the unit is active.
DOWN_TIMEOUT="${PZ_DOWN_TIMEOUT_MIN:-15}"

install -d -m 0755 "$STATE"
log() { echo "pz-watchdog: $*" >&2; }
read_int() { local f="$1"; [[ -r "$f" ]] && cat "$f" || echo 0; }

# Metrics are accumulated and published in ONE call at exit rather than one call each.
# Every `aws` invocation is a fresh Python interpreter -- about a second of CPU -- and
# this runs every 60 seconds on the box running the game loop. Batching also gives all
# the metrics in a run the same timestamp, which makes them line up on a graph.
declare -a METRICS=()

queue_metric() {
  METRICS+=("{\"MetricName\":\"$1\",\"Value\":$2,\"Unit\":\"${3:-None}\",\"Dimensions\":[{\"Name\":\"Stack\",\"Value\":\"${PZ_STACK}\"}]}")
}

flush_metrics() {
  (( ${#METRICS[@]} )) || return 0
  local payload
  payload="$(IFS=,; printf '[%s]' "${METRICS[*]}")"
  METRICS=()
  aws cloudwatch put-metric-data --namespace PZ --metric-data "$payload" >/dev/null 2>&1 \
    || log "WARNING: PutMetricData failed"
}

# Every exit path publishes, including the ones inside shutdown_sequence.
trap flush_metrics EXIT

# Is the start path legitimately still in progress? pz-update.service (SteamCMD) and the
# mount both run Before= the game, so there is a window on every boot where the game unit
# is correctly not-yet-active. Counting that window as "down" would have the watchdog
# stop the instance during its own start.
start_in_progress() {
  local unit state
  for unit in opt-pz-data.mount pz-config.service pz-update.service pzserver.service; do
    state="$(systemctl is-active "$unit" 2>/dev/null || true)"
    case "$state" in
      activating|deactivating|reloading) return 0 ;;
    esac
  done
  return 1
}

notify() {
  [[ -n "${PZ_ALERT_TOPIC_ARN:-}" ]] || return 0
  aws sns publish --topic-arn "$PZ_ALERT_TOPIC_ARN" \
    --subject "PZ ${PZ_STACK}: $1" --message "$2" >/dev/null 2>&1 \
    || log "WARNING: SNS publish failed"
}

# Full stop sequence. Every path that ends the session goes through this one function,
# so there is exactly one place where "save, back up, then stop" can be got wrong.
shutdown_sequence() {
  local reason="$1"
  log "initiating shutdown: ${reason}"
  # Publish before the slow part: the backup and the unit stop can take minutes, and a
  # metric stamped after them describes the wrong moment.
  flush_metrics
  notify "shutting down" "Reason: ${reason}. Saving and backing up first."

  "$RCON" servermsg "\"Server shutting down: ${reason}\"" >/dev/null 2>&1

  # pz-backup.sh forces its own RCON save; stopping the unit runs ExecStop, which saves
  # again. Belt and braces on the one thing that is unrecoverable.
  /opt/pz/bin/pz-backup.sh prestop "${reason// /-}" || log "WARNING: pre-stop backup failed"
  systemctl stop pzserver.service || log "WARNING: pzserver stop returned non-zero"

  rm -f "$IDLE_FILE" "$WARNED_FILE" "$FAIL_FILE" "$DOWN_FILE"

  log "stopping instance ${PZ_INSTANCE_ID}"
  aws ec2 stop-instances --instance-ids "$PZ_INSTANCE_ID" >/dev/null \
    || { log "FATAL: could not stop the instance -- it will keep billing"; \
         notify "STOP FAILED" "Could not stop ${PZ_INSTANCE_ID}. It is still billing. Stop it by hand."; }
  exit 0
}

# --- Is the game even supposed to be running? ---------------------------------------

if ! systemctl is-active --quiet pzserver.service; then
  # A restore or a manual maintenance window is the one legitimate reason for the game to
  # be down while the instance is up. It is marked explicitly, and it deliberately
  # publishes NO metrics: both the not-ready alarm and the auto-stop alarm treat missing
  # data as not-breaching, so suppressing the metric is what stops CloudWatch pulling the
  # instance out from under a restore the same way this counter would.
  if [[ -f "$MAINT_FLAG" ]]; then
    rm -f "$DOWN_FILE"
    log "pzserver.service is not active, but ${MAINT_FLAG} exists -- maintenance, leaving the instance up"
    exit 0
  fi

  queue_metric ServerReady 0
  queue_metric PlayersOnline 0 Count

  # Boot, SteamCMD and the mount all happen before the game unit can be active. That is
  # not "down", it is "starting".
  if start_in_progress; then
    log "pzserver.service is not active, but the start path is still running; not counting"
    exit 0
  fi

  down=$(( $(read_int "$DOWN_FILE") + 1 ))
  echo "$down" >"$DOWN_FILE"
  log "pzserver.service is not active (state=$(systemctl is-active pzserver.service 2>/dev/null || true)); down for ${down}m (stop at ${DOWN_TIMEOUT}m)"

  if (( down >= DOWN_TIMEOUT )); then
    notify "game not running" \
      "pzserver.service has not been active for ${DOWN_TIMEOUT} consecutive minutes while the instance is running -- most likely a crash loop past StartLimitBurst, or an OOM stop. Stopping the instance so it does not bill overnight. Touch ${MAINT_FLAG} first if you want the box left up."
    shutdown_sequence "pzserver.service down for ${down}m"
  fi
  exit 0
fi

rm -f "$DOWN_FILE"

# --- Count players -------------------------------------------------------------------

players_out="$("$RCON" players 2>/dev/null)"
rcon_rc=$?

if (( rcon_rc != 0 )); then
  failures=$(( $(read_int "$FAIL_FILE") + 1 ))
  echo "$failures" >"$FAIL_FILE"
  queue_metric ServerReady 0
  log "RCON unreachable (${failures}/${FAIL_THRESHOLD} consecutive)"

  if (( failures >= FAIL_THRESHOLD )); then
    notify "server unreachable" \
      "RCON has not answered for ${FAIL_THRESHOLD} consecutive minutes while the instance is running. Saving what we can and stopping to avoid billing a dead server overnight."
    shutdown_sequence "unreachable for ${FAIL_THRESHOLD}m"
  fi
  exit 0
fi

echo 0 >"$FAIL_FILE"
queue_metric ServerReady 1

# PZ answers `players` with "Players connected (N):" followed by one -name per line.
count="$(grep -oE '\(([0-9]+)\)' <<<"$players_out" | head -1 | tr -cd '0-9')"
count="${count:-0}"
queue_metric PlayersOnline "$count" Count

# Backup freshness, for the stale-backup alarm.
if [[ -r "$MARKER" ]]; then
  age_min=$(( ( $(date -u +%s) - $(cat "$MARKER") ) / 60 ))
  # Clamp to instance uptime. The instance is stopped by default (the whole cost model),
  # so the marker is routinely wall-clock hours old the moment the box boots -- without
  # this, the first datapoint of nearly every session blows past the 90-minute threshold
  # before a scheduled backup has had any chance to run. The alarm's own description says
  # "while the server is running"; this is what makes that true instead of just documented.
  uptime_min=$(( $(cut -d. -f1 /proc/uptime) / 60 ))
  (( age_min > uptime_min )) && age_min=$uptime_min
  # Unit None, not Count: the value is a duration in minutes, and CloudWatch has no
  # "Minutes" unit. Labelling it Count made the console and any future dashboard render
  # it as a quantity of things.
  queue_metric BackupAgeMinutes "$age_min"
fi

# --- Session cap ----------------------------------------------------------------------

# Catches the case the idle counter cannot: a character left idling in a safehouse
# overnight, where the player count never reaches zero.
started_at="$(systemctl show -p ActiveEnterTimestampMonotonic --value pzserver.service)"
if [[ -n "$started_at" && "$started_at" != "0" ]]; then
  now_mono=$(( $(awk '{print $1}' /proc/uptime | tr -d '.') * 10000 ))
  uptime_hours=$(( (now_mono - started_at) / 3600000000 ))
  if (( uptime_hours >= SESSION_CAP_HOURS )); then
    shutdown_sequence "session cap of ${SESSION_CAP_HOURS}h reached"
  fi
fi

# --- Idle counter ---------------------------------------------------------------------

if (( count > 0 )); then
  if [[ -s "$IDLE_FILE" ]]; then
    log "${count} player(s) online; resetting idle counter"
  fi
  rm -f "$IDLE_FILE" "$WARNED_FILE"
  exit 0
fi

idle=$(( $(read_int "$IDLE_FILE") + 1 ))
echo "$idle" >"$IDLE_FILE"
log "0 players; idle for ${idle}m (warn ${IDLE_WARN}m, stop ${IDLE_TIMEOUT}m)"

if (( idle >= IDLE_TIMEOUT )); then
  shutdown_sequence "idle for ${idle}m"
fi

if (( idle >= IDLE_WARN )) && [[ ! -f "$WARNED_FILE" ]]; then
  remaining=$(( IDLE_TIMEOUT - idle ))
  # Broadcast in-game as well as to Discord: anyone who logs in during the window resets
  # the counter simply by being there, so the warning is genuinely actionable.
  "$RCON" servermsg "\"No players for ${idle} minutes -- shutting down in ${remaining}. Log in to keep the server up.\"" >/dev/null 2>&1
  notify "idle warning" "No players for ${idle} minutes. Shutting down in ${remaining} minutes unless someone connects."
  touch "$WARNED_FILE"
fi
