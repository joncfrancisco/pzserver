#!/usr/bin/env bash
# Provision (or re-provision) the Project Zomboid game server host.
#
# IDEMPOTENT BY DESIGN, and that is the whole point. The same script runs in three
# places:
#   * once from user_data at first boot (DESIGN C6 -- cloud-init never runs again);
#   * on demand over `ssm send-command`, after changing anything under ops/;
#   * at bake time inside a Packer build, when Phase 5 promotes this to a golden AMI.
#
# Being safe to re-run is what makes that promotion cheap. Nothing here may assume a
# clean machine, and nothing here may destroy state.
set -euo pipefail

OPS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PZ_ROOT=/opt/pz
DATA_MNT=/opt/pz/data
DATA_LABEL=pzdata

log() { echo "provision: $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

[[ "$(id -u)" -eq 0 ]] || die "must run as root"

# --- Packages -------------------------------------------------------------------------

export DEBIAN_FRONTEND=noninteractive
log "installing packages"
apt-get update -y

# SteamCMD's EULA prompt blocks an unattended install unless it is pre-answered.
echo steam steam/question select "I AGREE" | debconf-set-selections
echo steam steam/license note '' | debconf-set-selections
add-apt-repository -y multiverse >/dev/null 2>&1 || true
dpkg --add-architecture i386
apt-get update -y

apt-get install -y --no-install-recommends \
  steamcmd \
  lib32gcc-s1 \
  zstd tar curl unzip jq \
  python3 \
  openjdk-17-jre-headless \
  amazon-ssm-agent 2>/dev/null || \
apt-get install -y --no-install-recommends \
  steamcmd lib32gcc-s1 zstd tar curl unzip jq python3 openjdk-17-jre-headless

# PZ ships its own JRE under jre64/, so openjdk above is only a fallback for builds that
# do not. Harmless either way and it saves a debugging session.

# Ubuntu's AWS images carry the SSM agent as a snap. Make sure it is actually running --
# without it there is NO way into this box, because there is no SSH.
if snap list amazon-ssm-agent >/dev/null 2>&1; then
  snap start --enable amazon-ssm-agent >/dev/null 2>&1 || true
elif ! systemctl is-enabled --quiet amazon-ssm-agent 2>/dev/null; then
  log "WARNING: SSM agent not found. This host has no SSH; without SSM there is no shell in."
fi

# --- User ------------------------------------------------------------------------------

if ! id pzuser >/dev/null 2>&1; then
  log "creating pzuser"
  useradd --system --create-home --home-dir /home/pzuser --shell /usr/sbin/nologin pzuser
fi

# --- Data volume -------------------------------------------------------------------------

install -d -m 0755 "$PZ_ROOT" "$PZ_ROOT/bin" "$DATA_MNT" /etc/pz /var/lib/pz

# Find the attached-but-not-root block device. Never assume /dev/nvme1n1: the numbering
# is not guaranteed stable, which is also why everything downstream mounts by label.
root_src="$(findmnt -no SOURCE / | sed 's/p\?[0-9]*$//')"
data_dev=""
while read -r name type; do
  [[ "$type" == "disk" ]] || continue
  [[ "/dev/$name" == "$root_src" ]] && continue
  data_dev="/dev/$name"
done < <(lsblk -dno NAME,TYPE)

if [[ -z "$data_dev" ]]; then
  die "no data volume found. Expected a second block device attached as /dev/sdf.
       Check the aws_volume_attachment applied and the instance was restarted."
fi

existing_label="$(blkid -s LABEL -o value "$data_dev" 2>/dev/null || true)"
existing_type="$(blkid -s TYPE -o value "$data_dev" 2>/dev/null || true)"

if [[ -z "$existing_type" ]]; then
  # Only ever format a device with NO filesystem on it. This single condition is what
  # stands between a re-provision and the deletion of the world.
  log "formatting fresh volume $data_dev as ext4 (label=$DATA_LABEL)"
  mkfs.ext4 -L "$DATA_LABEL" "$data_dev"
elif [[ "$existing_label" != "$DATA_LABEL" ]]; then
  log "labelling existing $existing_type filesystem on $data_dev as $DATA_LABEL"
  e2label "$data_dev" "$DATA_LABEL"
else
  log "data volume $data_dev already formatted and labelled -- leaving it alone"
fi

# --- Ops files ---------------------------------------------------------------------------

log "installing scripts to ${PZ_ROOT}/bin"
install -m 0755 -o root -g root "$OPS_SRC"/bin/* "$PZ_ROOT/bin/"

log "installing systemd units"
install -m 0644 -o root -g root "$OPS_SRC"/systemd/* /etc/systemd/system/
systemctl daemon-reload

# --- Mount, then everything that depends on it --------------------------------------------

systemctl enable --now opt-pz-data.mount
mountpoint -q "$DATA_MNT" || die "$DATA_MNT did not mount; see: systemctl status opt-pz-data.mount"

install -d -o pzuser -g pzuser \
  "$DATA_MNT/Zomboid" \
  "$DATA_MNT/Zomboid/Server" \
  "$DATA_MNT/Zomboid/Saves/Multiplayer" \
  "$DATA_MNT/Zomboid/db" \
  "$DATA_MNT/backups"

# PZ hardcodes ~/Zomboid. Pointing it at the data volume is what keeps the world off the
# disposable root disk. pz-start-server.sh also passes -cachedir explicitly, so this is
# the belt to that pair of braces.
if [[ ! -L /home/pzuser/Zomboid ]]; then
  rm -rf /home/pzuser/Zomboid
  ln -s "$DATA_MNT/Zomboid" /home/pzuser/Zomboid
  chown -h pzuser:pzuser /home/pzuser/Zomboid
fi

install -d -o pzuser -g pzuser "$PZ_ROOT/server"

# --- Config from SSM ---------------------------------------------------------------------

systemctl enable pz-config.service
systemctl restart pz-config.service
[[ -r /etc/pz/env ]] || die "/etc/pz/env was not written; see: journalctl -u pz-config.service"

# --- Game files ---------------------------------------------------------------------------

# Run the updater synchronously on a first provision so that provisioning either produces
# a working server or fails loudly, rather than "succeeding" and leaving an empty
# /opt/pz/server for pzserver.service to fall over on.
if [[ ! -x "$PZ_ROOT/server/start-server.sh" ]]; then
  log "no PZ install yet -- running SteamCMD (this takes several minutes)"
  systemctl start pz-update.service
fi
systemctl enable pz-update.service

# --- CloudWatch agent ----------------------------------------------------------------------

if [[ ! -x /opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl ]]; then
  log "installing the CloudWatch agent"
  tmp="$(mktemp -d)"
  curl -fsSL -o "$tmp/cwagent.deb" \
    "https://amazoncloudwatch-agent.s3.amazonaws.com/ubuntu/amd64/latest/amazon-cloudwatch-agent.deb"
  dpkg -i -E "$tmp/cwagent.deb"
  rm -rf "$tmp"
fi
install -m 0644 "$OPS_SRC/etc/cloudwatch-agent.json" \
  /opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json
/opt/aws/amazon-cloudwatch-agent/bin/amazon-cloudwatch-agent-ctl \
  -a fetch-config -m ec2 -s -c file:/opt/aws/amazon-cloudwatch-agent/etc/amazon-cloudwatch-agent.json

# --- Timers and the server itself ------------------------------------------------------------

systemctl enable --now pz-watchdog.timer pz-backup.timer

# Enabled, not started. `ec2:StartInstances` is all it takes to bring the world up, which
# keeps exactly one failure point in the start path -- and leaves this provisioning run
# free to finish without launching a server nobody asked for.
systemctl enable pzserver.service

log "provisioning complete."
log "  start the world:  sudo systemctl start pzserver.service"
log "  watch it load:    journalctl -u pzserver -f"
