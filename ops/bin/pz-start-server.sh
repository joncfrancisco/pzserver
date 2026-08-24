#!/usr/bin/env bash
# ExecStart for pzserver.service. Runs preflight, forces the heap size, then hands off
# to the stock PZ launcher.
set -euo pipefail

# `set -a` so everything in the env file is EXPORTED, not just set: the AWS CLI reads
# AWS_DEFAULT_REGION from the environment, and pz-rcon reads PZ_RCON_*. A plain `source`
# would leave them as shell variables that child processes never see.
set -a
# shellcheck source=/dev/null
source /etc/pz/env
set +a

/opt/pz/bin/pz-preflight.sh

SERVER_DIR=/opt/pz/server
JSON="${SERVER_DIR}/ProjectZomboid64.json"

# PZ reads its JVM arguments from ProjectZomboid64.json, and a SteamCMD update rewrites
# that file -- so the heap is re-applied here on every start rather than set once at
# provisioning time. Patching the JSON (rather than passing -Xmx on the command line)
# is what actually works across builds: the launcher composes the java invocation from
# this file.
if [[ -f "$JSON" ]]; then
  python3 - "$JSON" "$PZ_XMX" <<'PY'
import json, re, sys

path, xmx = sys.argv[1], sys.argv[2]
with open(path) as fh:
    cfg = json.load(fh)

args = [a for a in cfg.get("vmArgs", []) if not re.match(r"^-Xm[sx]", a)]
args += [f"-Xmx{xmx}", f"-Xms{xmx}"]  # Xms == Xmx: PZ's heap is not going to shrink
cfg["vmArgs"] = args

with open(path, "w") as fh:
    json.dump(cfg, fh, indent=2)
print(f"pz-start: set -Xmx{xmx}/-Xms{xmx} in {path}", file=sys.stderr)
PY
else
  echo "pz-start: WARNING ${JSON} not found; PZ will start on its default heap" >&2
fi

cd "$SERVER_DIR"

# PZ takes the admin password as a command-line flag, and the stock launcher passes it
# straight through to the java process -- where it lands in /proc/<pid>/cmdline, which is
# WORLD-READABLE. `ps aux` on this box printed the live admin password in full. Anything
# that gets as far as an unprivileged local user (a malicious mod, an RCE in the game, a
# second service running as nobody) reads it for free.
#
# Note the value being in /etc/pz/env is NOT the same exposure: /proc/<pid>/environ is
# 0400 and readable only by the process owner and root. The flag is the leak, not the
# variable -- so the fix is to stop passing the flag, not to stop exporting the value.
#
# PZ only needs -adminpassword to SEED the admin account into the server database on the
# first run. Once the account exists it authenticates against the DB and the flag is
# redundant, so paying a permanent world-readable exposure on every start buys nothing.
# Pass it only when there is no database yet, and make re-applying it an explicit,
# deliberate act (below) rather than the default.
admin_args=()
db="${PZ_DATA}/Zomboid/db/${PZ_SERVER_NAME}.db"

if [[ ! -s "$db" ]]; then
  echo "pz-start: no server DB at ${db} -- seeding the admin account on this run" >&2
  admin_args=(-adminpassword "${PZ_ADMIN_PASSWORD}")
elif [[ "${PZ_FORCE_ADMIN_PASSWORD:-0}" == "1" ]]; then
  # The rotation path. DEPLOY.md documents this as a one-shot: set it, start, unset it.
  # Leaving it set would quietly reinstate the exposure on every subsequent boot, which
  # is exactly the state this change exists to get out of.
  echo "pz-start: PZ_FORCE_ADMIN_PASSWORD=1 -- re-applying the admin password this run" >&2
  admin_args=(-adminpassword "${PZ_ADMIN_PASSWORD}")
fi

# -cachedir belt-and-braces with the ~/Zomboid symlink provision.sh creates: either one
# alone puts the world on the data volume, and having both means a broken symlink or an
# unexpected launcher change cannot silently write a fresh world onto the root disk.
#
# "${admin_args[@]}" on an empty array is safe under `set -u` on bash >= 4.4; this box
# runs 5.2.
exec ./start-server.sh \
  -cachedir="${PZ_DATA}/Zomboid" \
  -servername "${PZ_SERVER_NAME}" \
  "${admin_args[@]}"
