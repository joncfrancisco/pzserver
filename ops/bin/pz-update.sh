#!/usr/bin/env bash
# The one place SteamCMD is invoked. Every update path -- the one on the start path, the
# manual "update now", and the slow validate -- comes through here with different flags,
# so there is exactly one implementation of "which build does this box install".
#
# Run as pzuser (the systemd units set User=), never as root: SteamCMD writes into
# /opt/pz/server, and a root-owned file in there is one the service account cannot
# rewrite on the next update.
#
#   pz-update.sh              boot path. Honours the hold; no validate.
#   pz-update.sh --force      manual update. Ignores the hold.
#   pz-update.sh --validate   implies --force, and re-checksums the whole install.
set -euo pipefail

APP_ID=380870
SERVER_DIR=/opt/pz/server
CONF=/opt/pz/data/version.conf
# The pre-existing emergency brake, kept because DEPLOY.md documents it and because it
# lives on the ROOT volume: it still works when the data volume (and therefore $CONF)
# has not mounted, which is exactly when you least want an automatic update.
LEGACY_HOLD=/opt/pz/skip-update

log() { echo "pz-update: $*" >&2; }

force=0
validate=0
for arg in "$@"; do
  case "$arg" in
    --force) force=1 ;;
    --validate)
      validate=1
      force=1
      ;;
    *)
      log "FATAL: unknown argument ${arg}"
      exit 2
      ;;
  esac
done

# --- Configured branch and hold ---------------------------------------------------------
#
# Parsed, not sourced. $CONF is root-owned on a volume the game itself can write to
# elsewhere; `source`ing it would turn "can write somewhere on the data volume" into
# "can run shell as pzuser at every start" if the ownership were ever got wrong.

conf_get() {
  [[ -r "$CONF" ]] || return 0
  local found
  found="$(sed -n "s/^${1}=\(.*\)$/\1/p" "$CONF")"
  printf '%s\n' "${found##*$'\n'}" # the last match wins, and no pipe to fail under -o pipefail
}

branch="$(conf_get PZ_STEAM_BRANCH)"
hold="$(conf_get PZ_UPDATE_HOLD)"

if [[ -n "$branch" && ! "$branch" =~ ^[A-Za-z0-9._-]{1,32}$ ]]; then
  log "FATAL: ${CONF} names branch '${branch}', which is not a Steam branch name."
  exit 1
fi

if [[ "$force" -ne 1 ]]; then
  if [[ -e "$LEGACY_HOLD" ]]; then
    log "held: ${LEGACY_HOLD} exists -- keeping the build already on disk"
    exit 0
  fi
  if [[ "$hold" == "1" ]]; then
    log "held: PZ_UPDATE_HOLD=1 in ${CONF} -- keeping the build already on disk"
    exit 0
  fi
fi

# Only on the manual paths. On the boot path systemd's `Before=pzserver.service` is the
# ordering guarantee, and asking systemd about a unit whose job is already queued behind
# this one is a question with a confusing answer.
if [[ "$force" -eq 1 ]] && systemctl is-active --quiet pzserver.service; then
  log "FATAL: pzserver.service is running. SteamCMD rewriting files beneath a live JVM is"
  log "       its own kind of corruption. Stop the game first."
  exit 1
fi

# --- The invocation ---------------------------------------------------------------------

# ARGUMENT ORDER IS LOAD-BEARING: +login must come BEFORE +force_install_dir. With
# force_install_dir first, SteamCMD authenticates fine and then rejects the app with
# "ERROR! Failed to install app '380870' (Missing configuration)" -- a message that points
# nowhere near the actual cause. `-beta` and `validate` are arguments to +app_update, so
# they go after the appid and before +quit.
args=(+login anonymous +force_install_dir "$SERVER_DIR" +app_update "$APP_ID")

# `-beta` is passed only when a branch has actually been configured, so an unconfigured
# box issues byte-for-byte the invocation it always did. It is NOT enough to drop the
# flag to leave a beta: Steam remembers the branch in the app manifest's UserConfig, so
# getting back to the default branch means passing `-beta public` EXPLICITLY, which is
# why pz-version.sh writes `public` into $CONF rather than deleting the line.
if [[ -n "$branch" ]]; then
  log "tracking Steam branch '${branch}'"
  args+=(-beta "$branch")
fi

if [[ "$validate" -eq 1 ]]; then
  log "validating: re-checksumming the whole install against the Steam manifest"
  args+=(validate)
fi

args+=(+quit)

exec /usr/games/steamcmd "${args[@]}"
