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

# -cachedir belt-and-braces with the ~/Zomboid symlink provision.sh creates: either one
# alone puts the world on the data volume, and having both means a broken symlink or an
# unexpected launcher change cannot silently write a fresh world onto the root disk.
exec ./start-server.sh \
  -cachedir="${PZ_DATA}/Zomboid" \
  -servername "${PZ_SERVER_NAME}" \
  -adminpassword "${PZ_ADMIN_PASSWORD}"
