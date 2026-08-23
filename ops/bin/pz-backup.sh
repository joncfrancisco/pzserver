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

# T1 lives on the ROOT volume, not on ${PZ_DATA}. It used to sit inside the data volume,
# which is the volume the daily DLM policy snapshots -- so every snapshot carried six
# entirely new incompressible archives that had nothing to do with the filesystem state it
# was trying to capture, and the six-file window fully rotates every three hours. T3's job
# is "the filesystem is confused"; it should not also be storing backups of itself.
#
# The trade is real: T1 no longer survives an instance rebuild. That is the right call,
# because T1's job is "roll back an hour" and a rebuild is a T2 restore anyway.
LOCAL_DIR=/var/lib/pz/backups
KEEP_LOCAL=6
MARKER=/var/lib/pz/last-backup

# Shared with pz-restore.sh. Two reasons, and the second is the one that bites:
#   * two backups at once would fight over the local rolling window;
#   * the 30-minute timer does NOT short-circuit while the server is down (it logs
#     "archiving at rest" and proceeds), so without this a restore in progress would have
#     scheduled runs uploading half-restored worlds to S3 and aging the good entries out
#     of the six-slot local window.
LOCK=/var/lib/pz/backup.lock

log() { echo "pz-backup: $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

case "$TRIGGER" in
  scheduled|prestop|prerestore|manual) ;;
  *) die "unknown trigger '$TRIGGER' (scheduled|prestop|prerestore|manual)" ;;
esac

# Take the lock on a file descriptor held for the life of the process -- no re-exec, and
# it is released even on a kill.
#
# A scheduled run does not wait: one that queues behind a ten-minute restore and then runs
# against a world mid-swap is worse than one that is skipped, and the next is due in
# thirty minutes anyway. It exits 0, because a skip is a correct outcome and a failed
# systemd unit every half hour during a restore is just noise. prestop and prerestore do
# wait -- those are paths where the caller genuinely needs the archive to exist.
install -d -m 0755 /var/lib/pz
exec 9>"$LOCK"
if [[ "$TRIGGER" == "scheduled" ]]; then
  flock -w 0 9 || { log "another backup or restore holds ${LOCK}; skipping this scheduled run"; exit 0; }
else
  flock -w 900 9 || die "timed out waiting for ${LOCK} after 15 minutes"
fi

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

# --- Keep the RCON password out of the archive ---------------------------------------
#
# pz-preflight.sh writes RCONPassword= into Server/<name>.ini on every start, and Server/
# is one of the three mandatory parts above -- so every archive used to carry the live
# password in cleartext, and DESIGN C7 rates that password as equivalent to full control
# of the server. The consequence that matters is not the archive, it is that ROTATING the
# password does not invalidate the archives still holding the old one, and archives
# outlive rotations.
#
# The archive does not need the value at all: pz-preflight.sh rewrites RCONPassword from
# Parameter Store on every single start, so whatever is in a restored .ini is overwritten
# before it is ever read. It was pure liability.
#
# Server/ is staged through a copy and blanked there. The live .ini is never touched --
# editing it in place would race the running server and, if this script died in between,
# leave the world with no password at all.
STAGE="$(mktemp -d /var/tmp/pz-backup.XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT

cp -a "${ZOMBOID}/Server" "${STAGE}/Server"
scrubbed=0
while IFS= read -r -d '' inifile; do
  if grep -qE '^RCONPassword=.' "$inifile"; then
    # Fixed strings on both sides -- no sed, whose replacement text would interpret & and
    # whose delimiter a password may legitimately contain (see set_ini in pz-preflight.sh).
    python3 - "$inifile" <<'PY'
import sys
path = sys.argv[1]
with open(path, encoding="utf-8", errors="surrogateescape") as fh:
    lines = fh.readlines()
with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
    for line in lines:
        fh.write("RCONPassword=\n" if line.startswith("RCONPassword=") else line)
PY
    scrubbed=$(( scrubbed + 1 ))
  fi
done < <(find "${STAGE}/Server" -type f -name '*.ini' -print0)
log "blanked RCONPassword in ${scrubbed} .ini file(s) in the staged copy"

log "archiving ${PARTS[*]} -> ${ARCHIVE}"
# zstd -10 rather than xz: comparable ratio at a fraction of the CPU, and this runs on
# the same box that is running the game.
#
# Two -C flags: everything except Server/ comes from the live tree, Server/ comes from the
# scrubbed staging copy. Paths inside the archive are identical either way, so pz-restore.sh
# and its partial-archive check are unaffected.
declare -a LIVE_PARTS=()
for part in "${PARTS[@]}"; do
  [[ "$part" == "Server" ]] || LIVE_PARTS+=("$part")
done

tar --use-compress-program='zstd -10 -T2' \
    -cf "$ARCHIVE" \
    -C "$ZOMBOID" "${LIVE_PARTS[@]}" \
    -C "$STAGE" Server

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

# The `keep` tag is what the bucket's lifecycle rules filter on, and it is the only thing
# standing between a scheduled archive and 180-day retention. It has to be a TAG rather
# than the trigger already in the object key, because lifecycle filters match a key
# PREFIX and the trigger sits in the middle of the name -- and re-laying-out the key to
# put it at the front would break pz-restore.sh's parsing and the bot's autocomplete.
case "$TRIGGER" in
  scheduled) KEEP=short ;;   # 21 days; T1 and the DLM snapshot cover the same ground
  *) KEEP=long ;;            # 180 days: prestop, prerestore, manual -- the ones you reach for
esac

log "uploading s3://${PZ_BACKUP_BUCKET}/${KEY} (keep=${KEEP})"
aws s3 cp "$ARCHIVE" "s3://${PZ_BACKUP_BUCKET}/${KEY}" \
  --only-show-errors \
  --tagging "trigger=${TRIGGER}&keep=${KEEP}" \
  --metadata "trigger=${TRIGGER},server=${PZ_SERVER_NAME},label=${LABEL:-none}"

date -u +%s >"$MARKER"

aws cloudwatch put-metric-data \
  --namespace PZ \
  --metric-name BackupSizeBytes \
  --dimensions "Stack=${PZ_STACK}" \
  --value "$SIZE" \
  --unit Bytes || log "WARNING: could not publish BackupSizeBytes"

log "done: ${KEY}"
