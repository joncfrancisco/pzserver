#!/usr/bin/env bash
# Restore a world from a T2 (S3) archive. DESIGN section 11.
#
#   pz-restore.sh <s3-key-or-name> [--yes]
#
# This is the most dangerous operation in the system and is written to behave like it.
# Three properties, in order of importance:
#
#   1. It REFUSES to run while PZ is up. A restore under a live server races the game's
#      own writes and produces a world that is neither the backup nor the original.
#   2. It takes a `prerestore` backup of the current state FIRST, unconditionally. Every
#      restore is therefore itself reversible -- including the restore you regret.
#   3. It restores Saves/, Server/ and db/ as a SET, or not at all. A save paired with
#      the wrong sandbox config is a subtly broken world that takes days to diagnose.
set -euo pipefail

# `set -a` so everything in the env file is EXPORTED, not just set: the AWS CLI reads
# AWS_DEFAULT_REGION from the environment, and pz-rcon reads PZ_RCON_*. A plain `source`
# would leave them as shell variables that child processes never see.
set -a
# shellcheck source=/dev/null
source /etc/pz/env
set +a

KEY_ARG="${1:-}"
CONFIRM="${2:-}"
ZOMBOID="${PZ_DATA}/Zomboid"

# The watchdog stops the instance if the game unit is not active for DOWN_TIMEOUT
# minutes -- which a restore looks exactly like. This flag says "the game is down on
# purpose". It is removed on EVERY exit path, successful or not: a leaked flag would
# silently disable the cost guarantee for as long as it sat there.
MAINT_FLAG=/var/lib/pz/maintenance

log() { echo "pz-restore: $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

[[ -n "$KEY_ARG" ]] || die "usage: pz-restore.sh <s3-key-or-archive-name> [--yes]"

# --- Guard 1: the server must be down -----------------------------------------------

if systemctl is-active --quiet pzserver.service; then
  die "pzserver.service is running. Stop it first:
       sudo systemctl stop pzserver.service
       Restoring underneath a live server races its writes and corrupts both copies."
fi

# Accept either a bare archive name or a full key.
if [[ "$KEY_ARG" == backups/* ]]; then
  KEY="$KEY_ARG"
else
  KEY="backups/${PZ_STACK}/${KEY_ARG}"
fi

aws s3api head-object --bucket "$PZ_BACKUP_BUCKET" --key "$KEY" >/dev/null 2>&1 \
  || die "no such backup: s3://${PZ_BACKUP_BUCKET}/${KEY}
       List what is available with:  aws s3 ls s3://${PZ_BACKUP_BUCKET}/backups/${PZ_STACK}/"

# --- Guard 2: confirmation ------------------------------------------------------------

if [[ "$CONFIRM" != "--yes" ]]; then
  current_mtime="never"
  save_dir="${ZOMBOID}/Saves/Multiplayer/${PZ_SERVER_NAME}"
  [[ -d "$save_dir" ]] && current_mtime="$(date -u -d "@$(stat -c %Y "$save_dir")" -Is)"
  cat >&2 <<PROMPT

  RESTORE
    from : s3://${PZ_BACKUP_BUCKET}/${KEY}
    onto : ${PZ_SERVER_NAME}  (last written ${current_mtime})

  Everything that happened in the world after the backup was taken will be gone.
  A prerestore backup of the current state is taken first, so this is reversible.

  Re-run with --yes to proceed.

PROMPT
  exit 1
fi

# --- Claim the maintenance window ------------------------------------------------------

# Only after the guards have passed, so a usage error or a missing archive does not
# briefly suspend the watchdog for nothing.
install -d -m 0755 /var/lib/pz
touch "$MAINT_FLAG"
trap 'rm -f "$MAINT_FLAG"' EXIT
log "claimed the maintenance window (${MAINT_FLAG}); the watchdog will leave the instance up"

# --- Guard 3: snapshot the present before overwriting it -------------------------------

log "taking a prerestore backup of the current world"
/opt/pz/bin/pz-backup.sh prerestore "before-$(basename "$KEY" .tar.zst | cut -c1-20)" \
  || die "prerestore backup failed -- refusing to continue. Nothing has been changed."

# --- Fetch and validate ----------------------------------------------------------------

WORK="$(mktemp -d /var/tmp/pz-restore.XXXXXX)"
# Replaces the trap set above, so it has to clear the flag too -- a second `trap ... EXIT`
# does not stack, it overwrites.
trap 'rm -rf "$WORK"; rm -f "$MAINT_FLAG"' EXIT

log "downloading ${KEY}"
aws s3 cp "s3://${PZ_BACKUP_BUCKET}/${KEY}" "${WORK}/archive.tar.zst" --only-show-errors

log "extracting"
mkdir -p "${WORK}/x"
tar --use-compress-program='zstd -d' -xf "${WORK}/archive.tar.zst" -C "${WORK}/x"

# The reason this check exists: an archive can be silently missing db/ for months and
# nothing notices until the day it is restored and every player account is gone.
for part in "Saves/Multiplayer/${PZ_SERVER_NAME}" "Server" "db"; do
  [[ -e "${WORK}/x/${part}" ]] \
    || die "archive is missing ${part} -- refusing a partial restore.
       Your world has NOT been touched, and the prerestore backup above is intact."
done

# --- Swap ------------------------------------------------------------------------------

STAMP="$(date -u +%Y%m%d-%H%M%S)"
log "moving the current world aside (suffix .pre-restore-${STAMP})"
for part in "Saves/Multiplayer/${PZ_SERVER_NAME}" "Server" "db"; do
  if [[ -e "${ZOMBOID}/${part}" ]]; then
    mv "${ZOMBOID}/${part}" "${ZOMBOID}/${part}.pre-restore-${STAMP}"
  fi
  install -d -o pzuser -g pzuser "$(dirname "${ZOMBOID}/${part}")"
  mv "${WORK}/x/${part}" "${ZOMBOID}/${part}"
done

chown -R pzuser:pzuser "$ZOMBOID"

cat >&2 <<DONE

  Restored ${KEY}.

  The previous world is still on disk as *.pre-restore-${STAMP} under ${ZOMBOID}
  (and in S3 as the prerestore backup). Delete the local copies once you are satisfied:
      sudo rm -rf ${ZOMBOID}/*.pre-restore-${STAMP}

  Start the server:
      sudo systemctl start pzserver.service

DONE
