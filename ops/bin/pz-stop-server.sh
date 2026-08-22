#!/usr/bin/env bash
# ExecStop for pzserver.service, and the mechanism behind DESIGN G5: a stop ALWAYS saves
# the world first.
#
# Because the instance's shutdown behaviour is ACPI stop, this runs no matter who
# initiated it -- the bot, the idle watchdog, someone clicking Stop in the console, or
# AWS retiring the instance. There is no path that stops this box without passing
# through here.
set -uo pipefail   # deliberately not -e: a failed save must not skip the quit

# `set -a` so everything in the env file is EXPORTED, not just set: the AWS CLI reads
# AWS_DEFAULT_REGION from the environment, and pz-rcon reads PZ_RCON_*. A plain `source`
# would leave them as shell variables that child processes never see.
set -a
# shellcheck source=/dev/null
source /etc/pz/env
set +a

RCON=/opt/pz/bin/pz-rcon
log() { echo "pz-stop: $*" >&2; }

log "saving world before shutdown"
if "$RCON" save; then
  # PZ's `save` returns as soon as the save is queued, not when it has been written.
  # This pause is what makes the difference between a clean world and a mid-write one.
  sleep 10
  log "save complete"
else
  log "WARNING: RCON save failed (rc=$?) -- continuing to quit; PZ also saves on quit"
fi

log "asking PZ to quit"
"$RCON" quit || log "WARNING: RCON quit failed; systemd will SIGTERM after TimeoutStopSec"

# Give the process room to flush. TimeoutStopSec=180 in the unit is the outer bound;
# systemd escalates to SIGKILL after that, which is exactly what we are avoiding.
for _ in $(seq 1 150); do
  pgrep -f 'zombie.network.GameServer' >/dev/null 2>&1 || { log "PZ exited cleanly"; exit 0; }
  sleep 1
done

log "WARNING: PZ still running after 150s; leaving the rest to systemd"
exit 0
