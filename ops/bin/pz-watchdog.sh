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
MARKER="${STATE}/last-backup"

IDLE_WARN="${PZ_IDLE_WARN_MIN:-25}"
IDLE_TIMEOUT="${PZ_IDLE_TIMEOUT_MIN:-30}"
SESSION_CAP_HOURS="${PZ_SESSION_CAP_HOURS:-12}"

# An unreachable server cannot be counted, but it also must not bill at $0.20/hour all
# night. Treat unreachable as idle only after this many consecutive failures -- long
# enough to ride out a world load or a save pause, short enough to matter.
FAIL_THRESHOLD=10

install -d -m 0755 "$STATE"
log() { echo "pz-watchdog: $*" >&2; }
read_int() { local f="$1"; [[ -r "$f" ]] && cat "$f" || echo 0; }

put_metric() {
  aws cloudwatch put-metric-data \
    --namespace PZ --metric-name "$1" \
    --dimensions "Stack=${PZ_STACK}" \
    --value "$2" --unit "${3:-None}" >/dev/null 2>&1 \
    || log "WARNING: PutMetricData $1 failed"
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
  notify "shutting down" "Reason: ${reason}. Saving and backing up first."

  "$RCON" servermsg "\"Server shutting down: ${reason}\"" >/dev/null 2>&1

  # pz-backup.sh forces its own RCON save; stopping the unit runs ExecStop, which saves
  # again. Belt and braces on the one thing that is unrecoverable.
  /opt/pz/bin/pz-backup.sh prestop "${reason// /-}" || log "WARNING: pre-stop backup failed"
  systemctl stop pzserver.service || log "WARNING: pzserver stop returned non-zero"

  rm -f "$IDLE_FILE" "$WARNED_FILE" "$FAIL_FILE"

  log "stopping instance ${PZ_INSTANCE_ID}"
  aws ec2 stop-instances --instance-ids "$PZ_INSTANCE_ID" >/dev/null \
    || { log "FATAL: could not stop the instance -- it will keep billing"; \
         notify "STOP FAILED" "Could not stop ${PZ_INSTANCE_ID}. It is still billing. Stop it by hand."; }
  exit 0
}

# --- Is the game even supposed to be running? ---------------------------------------

if ! systemctl is-active --quiet pzserver.service; then
  # Deliberately quiet: this is also the state during a restore or a manual maintenance
  # window, and stopping the box out from under an admin mid-restore would be rude.
  put_metric ServerReady 0
  put_metric PlayersOnline 0
  log "pzserver.service is not active; nothing to watch"
  exit 0
fi

# --- Count players -------------------------------------------------------------------

players_out="$("$RCON" players 2>/dev/null)"
rcon_rc=$?

if (( rcon_rc != 0 )); then
  failures=$(( $(read_int "$FAIL_FILE") + 1 ))
  echo "$failures" >"$FAIL_FILE"
  put_metric ServerReady 0
  log "RCON unreachable (${failures}/${FAIL_THRESHOLD} consecutive)"

  if (( failures >= FAIL_THRESHOLD )); then
    notify "server unreachable" \
      "RCON has not answered for ${FAIL_THRESHOLD} consecutive minutes while the instance is running. Saving what we can and stopping to avoid billing a dead server overnight."
    shutdown_sequence "unreachable for ${FAIL_THRESHOLD}m"
  fi
  exit 0
fi

echo 0 >"$FAIL_FILE"
put_metric ServerReady 1

# PZ answers `players` with "Players connected (N):" followed by one -name per line.
count="$(grep -oE '\(([0-9]+)\)' <<<"$players_out" | head -1 | tr -cd '0-9')"
count="${count:-0}"
put_metric PlayersOnline "$count" Count

# Backup freshness, for the stale-backup alarm.
if [[ -r "$MARKER" ]]; then
  age_min=$(( ( $(date -u +%s) - $(cat "$MARKER") ) / 60 ))
  put_metric BackupAgeMinutes "$age_min" Count
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
