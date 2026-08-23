#!/usr/bin/env bash
# Boot-time sanity checks, run before the JVM starts.
#
# The headline check is the -Xmx assertion. Leaving the heap at the JVM default while
# the box has 16 GiB free is the most common way to kill a PZ server (DESIGN C3), and it
# presents as a mysterious crash hours into a session rather than as a startup error.
# This turns it into a loud, immediate refusal to start.
set -euo pipefail

# `set -a` so everything in the env file is EXPORTED, not just set: the AWS CLI reads
# AWS_DEFAULT_REGION from the environment, and pz-rcon reads PZ_RCON_*. A plain `source`
# would leave them as shell variables that child processes never see.
set -a
# shellcheck source=/dev/null
source /etc/pz/env
set +a

log() { echo "pz-preflight: $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

# --- -Xmx vs physical memory --------------------------------------------------------

mem_total_kb="$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
mem_total_mb=$(( mem_total_kb / 1024 ))

xmx_raw="${PZ_XMX:-}"
[[ -n "$xmx_raw" ]] || die "PZ_XMX is empty; refusing to start on the JVM default heap"

case "${xmx_raw: -1}" in
  g|G) xmx_mb=$(( ${xmx_raw%[gG]} * 1024 )) ;;
  m|M) xmx_mb=$(( ${xmx_raw%[mM]} )) ;;
  *)   die "PZ_XMX='$xmx_raw' is not of the form 12g or 12288m" ;;
esac

limit_mb=$(( mem_total_mb * 75 / 100 ))
if (( xmx_mb > limit_mb )); then
  die "PZ_XMX=${xmx_raw} (${xmx_mb} MiB) exceeds 75% of MemTotal (${mem_total_mb} MiB, limit ${limit_mb} MiB).
       Either shrink game_xmx or move to a larger instance. Starting anyway would let the
       JVM claim memory the kernel needs for page cache and the OS, and the server would
       be killed by the OOM reaper under load rather than failing here."
fi
log "-Xmx${xmx_raw} = ${xmx_mb} MiB of ${mem_total_mb} MiB ($(( xmx_mb * 100 / mem_total_mb ))%) -- OK"

# --- The world is actually mounted --------------------------------------------------

mountpoint -q "$PZ_DATA" || die "$PZ_DATA is not a mount point -- the data volume is missing.
       Starting now would create a fresh world on the root volume and quietly diverge
       from the real one. Check: systemctl status opt-pz-data.mount"

# --- Server .ini --------------------------------------------------------------------

ini_dir="${PZ_DATA}/Zomboid/Server"
ini="${ini_dir}/${PZ_SERVER_NAME}.ini"
install -d -o pzuser -g pzuser "$ini_dir"

if [[ ! -f "$ini" ]]; then
  log "no ${PZ_SERVER_NAME}.ini yet -- writing a minimal one; PZ will fill in its defaults"
  install -m 0640 -o pzuser -g pzuser /dev/null "$ini"
  cat >"$ini" <<INIEOF
DefaultPort=16261
UDPPort=16262
Public=false
PublicName=${PZ_SERVER_NAME}
UPnP=false
RCONPort=27015
RCONPassword=
Open=true
PauseEmpty=true
INIEOF
  chown pzuser:pzuser "$ini"
fi

# Enforce only the keys the infrastructure depends on. Everything else -- MaxPlayers,
# PVP, the sandbox knobs -- belongs to the admin and to `/pz config`, and is left alone.
#
# NOT sed. This is fed the RCON password, and sed would interpret it twice over: a `|` in
# the value is a syntax error, and -- worse, because it is silent -- an `&` in the
# replacement expands to the whole matched text, writing a corrupted password into the
# .ini. RCON auth then fails, the watchdog counts ten consecutive failures, and the box
# stops itself with nothing pointing at the cause.
#
# Latent rather than live today: DEPLOY.md's rotation command generates from
# `openssl rand -base64 24 | tr -d '/+='`, which cannot emit any of those characters. It
# only bites if someone sets the password by hand -- which is exactly the situation where
# a silent corruption is hardest to connect back to its cause.
#
# Same approach pz-start-server.sh already uses for JSON: hand the value to Python as an
# argument, so nothing in it is ever parsed as syntax.
set_ini() {
  local key="$1" value="$2"
  python3 - "$ini" "$key" "$value" <<'PY'
import sys

path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
prefix = key + "="
with open(path, encoding="utf-8", errors="surrogateescape") as fh:
    lines = fh.readlines()

replaced = False
for i, line in enumerate(lines):
    if line.startswith(prefix):
        lines[i] = f"{prefix}{value}\n"
        replaced = True
        break
if not replaced:
    if lines and not lines[-1].endswith("\n"):
        lines[-1] += "\n"
    lines.append(f"{prefix}{value}\n")

with open(path, "w", encoding="utf-8", errors="surrogateescape") as fh:
    fh.writelines(lines)
PY
}

set_ini RCONPort 27015
set_ini RCONPassword "$PZ_RCON_PASSWORD"
set_ini DefaultPort 16261
set_ini UDPPort 16262
# There is no UPnP-capable router in a VPC -- the instance is addressed by an Elastic IP
# and the security group is the only thing gating traffic. PZ prints
# "If the server hangs here, set UPnP=false" while it probes for one, which is a startup
# delay at best and a documented hang at worst. Turn it off.
set_ini UPnP false
chmod 0640 "$ini"
chown pzuser:pzuser "$ini"

log "preflight OK (server=${PZ_SERVER_NAME}, ini=${ini})"
