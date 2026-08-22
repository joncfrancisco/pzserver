#!/usr/bin/env bash
# Backup tiers T1 (local rolling) and T2 (S3), per DESIGN section 11.
#
#   pz-backup.sh <trigger> [label]
#   trigger: scheduled | prestop | prerestore | manual
#
# THE ONE NON-NEGOTIABLE RULE: every backup is preceded by an RCON save. Archiving a
# live world without forcing a save captures a mid-write state, and a mid-write PZ save
# restores as a world that loads and is subtly wrong -- the worst kind of broken.
set -euo pipefail

# `set -a` so everything in the env file is EXPORTED, not just set: the AWS CLI reads
# AWS_DEFAULT_REGION from the environment, and pz-rcon reads PZ_RCON_*. A plain `source`
# would leave them as shell variables that child processes never see.
set -a
# shellcheck source=/dev/null
source /etc/pz/env
set +a

TRIGGER="${1:-manual}"
LABEL="${2:-}"
RCON=/opt/pz/bin/pz-rcon
ZOMBOID="${PZ_DATA}/Zomboid"
LOCAL_DIR="${PZ_DATA}/backups"
KEEP_LOCAL=6
MARKER=/var/lib/pz/last-backup

log() { echo "pz-backup: $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

case "$TRIGGER" in
  scheduled|prestop|prerestore|manual) ;;
  *) die "unknown trigger '$TRIGGER' (scheduled|prestop|prerestore|manual)" ;;
esac

# Labels end up in an S3 key and a filename. Keep them boring.
if [[ -n "$LABEL" ]]; then
  LABEL="$(tr -cd '[:alnum:]-_' <<<"$LABEL" | cut -c1-40)"
fi

install -d -m 0755 "$LOCAL_DIR" /var/lib/pz

# --- Force a save -------------------------------------------------------------------

if systemctl is-active --quiet pzserver.service; then
  log "forcing a save before archiving"
  if "$RCON" save; then
    sleep 10
  else
    # A scheduled backup of a wedged server is worth less than a loud failure: taking it
    # anyway would overwrite the rolling window with mid-write archives.
    if [[ "$TRIGGER" == "scheduled" ]]; then
      die "RCON save failed and this is a scheduled backup -- refusing to archive a possibly mid-write world"
    fi
    log "WARNING: RCON save failed, but trigger=$TRIGGER so archiving anyway"
  fi
else
  log "pzserver is not running; archiving at rest (no save needed)"
fi

# --- Archive ------------------------------------------------------------------------

STAMP="$(date -u +%Y-%m-%dT%H-%M-%SZ)"
NAME="${STAMP}__${TRIGGER}${LABEL:+__${LABEL}}.tar.zst"
ARCHIVE="${LOCAL_DIR}/${NAME}"

# All three of these, always. A restore that covers Saves/ but not Server/*.ini brings
# the world back with the wrong sandbox settings, and db/ is where player accounts and
# the whitelist live. They are only meaningful as a set -- see the restore script, which
# refuses to restore a partial archive.
declare -a PARTS=()
[[ -d "${ZOMBOID}/Saves/Multiplayer/${PZ_SERVER_NAME}" ]] && PARTS+=("Saves/Multiplayer/${PZ_SERVER_NAME}")
[[ -d "${ZOMBOID}/Server" ]] && PARTS+=("Server")
[[ -d "${ZOMBOID}/db" ]] && PARTS+=("db")

(( ${#PARTS[@]} == 3 )) || die "expected Saves/Multiplayer/${PZ_SERVER_NAME}, Server/ and db/ under ${ZOMBOID}; found: ${PARTS[*]:-none}"

log "archiving ${PARTS[*]} -> ${ARCHIVE}"
# zstd -10 rather than xz: comparable ratio at a fraction of the CPU, and this runs on
# the same box that is running the game.
tar --use-compress-program='zstd -10 -T2' \
    -cf "$ARCHIVE" -C "$ZOMBOID" "${PARTS[@]}"

SIZE="$(stat -c %s "$ARCHIVE")"
log "archive is $(numfmt --to=iec "$SIZE")"

# --- T1: local rolling window -------------------------------------------------------

# shellcheck disable=SC2012
ls -1t "${LOCAL_DIR}"/*.tar.zst 2>/dev/null | tail -n +$((KEEP_LOCAL + 1)) | while read -r old; do
  log "pruning local $old"
  rm -f "$old"
done

# --- T2: S3 --------------------------------------------------------------------------

KEY="backups/${PZ_STACK}/${NAME}"
log "uploading s3://${PZ_BACKUP_BUCKET}/${KEY}"
aws s3 cp "$ARCHIVE" "s3://${PZ_BACKUP_BUCKET}/${KEY}" \
  --only-show-errors \
  --metadata "trigger=${TRIGGER},server=${PZ_SERVER_NAME},label=${LABEL:-none}"

date -u +%s >"$MARKER"

aws cloudwatch put-metric-data \
  --namespace PZ \
  --metric-name BackupSizeBytes \
  --dimensions "Stack=${PZ_STACK}" \
  --value "$SIZE" \
  --unit Bytes || log "WARNING: could not publish BackupSizeBytes"

log "done: ${KEY}"
