#!/usr/bin/env bash
# Which build of Project Zomboid this box runs, and the three things an admin can do
# about it: hold it where it is, move it to another Steam branch, or update it now.
#
# Runs as ROOT, invoked by the `pz-<stack>-version` SSM document with pattern-constrained
# parameters -- so `action` and `branch` arrive as plain argv, never as text interpolated
# into a shell string. Every action prints one JSON object on stdout; that is the bot's
# side of the contract and the reason nothing here prints prose to stdout.
#
#   pz-version.sh status
#   pz-version.sh hold | unhold
#   pz-version.sh branch <name>      records it; does not download anything
#   pz-version.sh update | validate  runs SteamCMD via systemd, as pzuser
set -euo pipefail

APP_ID=380870
SERVER_DIR=/opt/pz/server
DATA_MNT=/opt/pz/data
CONF="${DATA_MNT}/version.conf"
LEGACY_HOLD=/opt/pz/skip-update
ACF="${SERVER_DIR}/steamapps/appmanifest_${APP_ID}.acf"

log() { echo "pz-version: $*" >&2; }
die() {
  log "FATAL: $*"
  exit 1
}

# --- Reading the world's answers ----------------------------------------------------------

# Both of these take one line out of a multi-line match WITHOUT a pipe, and that is not
# style. Under `set -o pipefail`, `sed ... | head -n 1` is a race: head exits after the
# first line, sed gets EPIPE, and the pipeline's status becomes 141 -- so on a file big
# enough for sed to still be writing, this function fails and `set -e` takes the script
# with it, intermittently, on a box with no SSH. Bash parameter expansion has no such edge.

conf_get() {
  [[ -r "$CONF" ]] || return 0
  local found
  found="$(sed -n "s/^${1}=\(.*\)$/\1/p" "$CONF")"
  printf '%s\n' "${found##*$'\n'}" # the LAST match: a later line wins
}

# Steam's app manifest is the only honest answer to "what is actually installed" -- it is
# what SteamCMD itself compares against, and it carries the branch, so a branch that was
# switched by hand shows up here rather than being taken on trust from $CONF.
acf_get() {
  [[ -r "$ACF" ]] || return 0
  local found
  found="$(sed -n "s/^[[:space:]]*\"${1}\"[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$ACF")"
  # The FIRST match: BetaKey appears under both UserConfig and MountedConfig, and
  # UserConfig -- what was asked for -- comes first.
  printf '%s\n' "${found%%$'\n'*}"
}

emit_status() {
  local note="${1:-}"
  local hold=false hold_reason=""

  if [[ -e "$LEGACY_HOLD" ]]; then
    hold=true
    hold_reason="${LEGACY_HOLD} exists"
  elif [[ "$(conf_get PZ_UPDATE_HOLD)" == "1" ]]; then
    hold=true
    hold_reason="PZ_UPDATE_HOLD=1 in ${CONF}"
  fi

  # BetaKey is absent from the manifest on the default branch, which is Steam saying
  # "public" the long way round.
  local installed_branch
  installed_branch="$(acf_get BetaKey)"

  python3 - \
    "$(acf_get buildid)" \
    "${installed_branch:-public}" \
    "$(conf_get PZ_STEAM_BRANCH)" \
    "$(acf_get LastUpdated)" \
    "$hold" "$hold_reason" "$note" <<'PY'
import datetime as dt
import json
import subprocess
import sys

build, installed_branch, configured_branch, updated, hold, reason, note = sys.argv[1:8]

when = ""
if updated.isdigit() and int(updated) > 0:
    # timezone.utc rather than dt.UTC: the box runs 3.12 where both work, but these
    # tools get run by hand on older interpreters when something is wrong, and that is
    # the worst moment for a tool to fail on an alias.
    stamp = dt.datetime.fromtimestamp(int(updated), dt.timezone.utc)
    when = stamp.isoformat().replace("+00:00", "Z")

try:
    running = subprocess.run(
        ["systemctl", "is-active", "--quiet", "pzserver.service"], check=False
    ).returncode == 0
except OSError:
    # `status` is the one action that must never fail: it is what the bot calls to find
    # out why the others might.
    running = False

print(json.dumps({
    "installed_build": build,
    "installed_branch": installed_branch,
    # "" means nothing has ever pinned a branch, which is NOT the same as "public":
    # it is the state in which pz-update.sh passes no -beta flag at all.
    "configured_branch": configured_branch,
    "last_updated": when,
    "hold": hold == "true",
    "hold_reason": reason,
    "server_running": running,
    "note": note,
}))
PY
}

# --- Writing the pin -----------------------------------------------------------------------

write_conf() {
  local branch="$1" hold="$2"

  # Unmounted, this would write the pin to the root volume UNDER the mountpoint, where it
  # is invisible the moment the volume mounts -- a pin that silently is not one.
  mountpoint -q "$DATA_MNT" || die "${DATA_MNT} is not mounted; refusing to write a pin that would vanish"

  local tmp
  tmp="$(mktemp)"
  cat >"$tmp" <<CONFEOF
# Which build of Project Zomboid this world runs on. Written by pz-version.sh; read by
# pz-update.sh on every start.
#
# It lives on the DATA volume, not the root volume, because it is a decision about the
# world rather than about the disposable OS disk: rebuild the instance and the pin -- and
# with it the reason the save still loads -- comes back with the world.
#
# PZ_STEAM_BRANCH  Steam branch to track. Empty means "never pinned": no -beta flag at
#                  all, the stock behaviour. 'public' is an explicit pin to the default
#                  branch, which is how you get back OFF a beta.
# PZ_UPDATE_HOLD   1 pins the build already on disk; pz-update.sh skips the start-path
#                  update entirely. A manual update ignores it.
PZ_STEAM_BRANCH=${branch}
PZ_UPDATE_HOLD=${hold}
CONFEOF
  install -m 0644 -o root -g root "$tmp" "$CONF"
  rm -f "$tmp"
}

# --- Running SteamCMD ------------------------------------------------------------------------
#
# Through systemd rather than by calling pz-update.sh directly, because these units carry
# `User=pzuser`. Invoked from here as root, SteamCMD would leave root-owned files in
# /opt/pz/server that the service account could not rewrite on the next update.

run_unit() {
  local unit="$1"
  if systemctl is-active --quiet pzserver.service; then
    die "the game is running. Stop it first -- SteamCMD rewriting files beneath a live JVM is its own kind of corruption."
  fi
  # `systemctl start` on a Type=oneshot unit blocks until it has finished, so this
  # command's exit status is the update's exit status.
  if ! systemctl start "$unit"; then
    log "$(journalctl -u "$unit" -n 40 --no-pager 2>&1 || true)"
    die "${unit} failed; the journal is above and the previous build is untouched"
  fi
}

# --- Actions -----------------------------------------------------------------------------------

action="${1:-status}"
branch_arg="${2:-}"

case "$action" in
  status)
    emit_status
    ;;

  hold)
    write_conf "$(conf_get PZ_STEAM_BRANCH)" 1
    emit_status "updates held: this box will keep the build it has until the hold is lifted"
    ;;

  unhold)
    write_conf "$(conf_get PZ_STEAM_BRANCH)" 0
    # Clearing the legacy brake too: leaving it would make `unhold` report a hold it just
    # lifted, which is the sort of thing that gets debugged at 1am.
    rm -f "$LEGACY_HOLD"
    emit_status "updates resumed: the next start will update to the branch's latest build"
    ;;

  branch)
    [[ -n "$branch_arg" ]] || die "branch takes a Steam branch name, e.g. public or unstable"
    [[ "$branch_arg" =~ ^[A-Za-z0-9._-]{1,32}$ ]] || die "'${branch_arg}' is not a Steam branch name"
    write_conf "$branch_arg" "$(conf_get PZ_UPDATE_HOLD)"
    emit_status "now tracking '${branch_arg}'; nothing is downloaded until an update runs"
    ;;

  update)
    run_unit pz-update-now.service
    emit_status "updated"
    ;;

  validate)
    run_unit pz-update-validate.service
    emit_status "validated: every file re-checksummed against the Steam manifest"
    ;;

  *)
    die "unknown action '${action}'"
    ;;
esac
