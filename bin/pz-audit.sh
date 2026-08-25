#!/usr/bin/env bash
# What happened, on demand. Run from your laptop, not the box.
#
# This is the other half of the quiet-alerts design (see infra/alerts.tf). Alarms and
# instance transitions no longer email anyone unless something is actually broken, which
# only works if there is somewhere to go and LOOK. This is that somewhere.
#
# Read-only: every call here is a Describe/Get/List. It cannot start, stop, or change
# anything, so it is safe to run mid-session and safe to hand to anyone.
#
# Each report block captures AWS output into a variable and hands it to python through
# the ENVIRONMENT, with the python itself on stdin via `python3 - <<'PY'`. That looks
# roundabout next to `aws ... | python3 -c '...'`, and it is deliberate: the -c form has
# to survive both bash's $() parser and python's f-string parser, and parentheses in the
# python silently truncate the program. Passing data out-of-band means neither parser
# ever sees the other's syntax.
set -euo pipefail

STACK="${PZ_STACK:-prod}"
REGION="${AWS_DEFAULT_REGION:-us-east-1}"

if [[ "${1:-}" == "-h" || "${1:-}" == "--help" ]]; then
  cat <<'EOF'
usage: pz-audit.sh [HOURS]

Reports the state and recent history of the PZ stack. HOURS controls how far back the
event timeline reaches (default 24).

  pz-audit.sh          # last 24 hours
  pz-audit.sh 72       # last three days

Environment: PZ_STACK (default prod), AWS_DEFAULT_REGION (default us-east-1).
EOF
  exit 0
fi

HOURS="${1:-24}"
export AWS_DEFAULT_REGION="$REGION"

PREFIX="pz-${STACK}"
LOG_GROUP="/pz/${STACK}/audit"
BUDGET_NAME="${PREFIX}-monthly"

if [[ -t 1 ]]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RESET=$'\033[0m'
else
  BOLD=''; DIM=''; RESET=''
fi

section() { printf '\n%s== %s%s\n' "$BOLD" "$1" "$RESET"; }
dim() { printf '%s%s%s\n' "$DIM" "$1" "$RESET"; }

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
printf '%sPZ audit -- stack=%s region=%s account=%s%s\n' \
  "$BOLD" "$STACK" "$REGION" "$ACCOUNT" "$RESET"
dim "$(date -u '+generated %Y-%m-%dT%H:%M:%SZ') -- last ${HOURS}h of events"

# --- Instance ------------------------------------------------------------------------
# Always the first question: is it running, and since when. A running game server is the
# only thing in this stack that costs meaningful money.
section "Instance"
DATA="$(aws ec2 describe-instances \
  --filters "Name=tag:pz:stack,Values=${STACK}" \
  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
  --query 'Reservations[].Instances[].{Role:Tags[?Key==`pz:role`]|[0].Value,Id:InstanceId,Type:InstanceType,State:State.Name,Since:LaunchTime}' \
  --output json 2>/dev/null || true)"

# Game-server uptime is written to a temp file because the Backups section needs it: a
# backup's wall-clock age is only meaningful once the box has been up long enough for a
# backup to have run. See the note there.
UPTIME_FILE="$(mktemp)"
trap 'rm -f "$UPTIME_FILE"' EXIT

DATA="$DATA" UPTIME_FILE="$UPTIME_FILE" python3 - <<'PY'
import datetime, json, os

rows = json.loads(os.environ["DATA"] or "[]")
if not rows:
    print("  (no instances found)")
    raise SystemExit

now = datetime.datetime.now(datetime.timezone.utc)
game_uptime = ""
for r in sorted(rows, key=lambda x: x.get("Role") or ""):
    up = ""
    if r["State"] == "running" and r.get("Since"):
        t = datetime.datetime.fromisoformat(r["Since"].replace("Z", "+00:00"))
        m = int((now - t).total_seconds() // 60)
        up = "  up {}h{:02d}m".format(m // 60, m % 60)
        if r.get("Role") == "gameserver":
            game_uptime = str(m)
    print("  {:<11} {:<12} {:<9} {}{}".format(
        r.get("Role") or "?", r["Type"], r["State"], r["Id"], up))

with open(os.environ["UPTIME_FILE"], "w") as fh:
    fh.write(game_uptime)
PY

# --- Spend ---------------------------------------------------------------------------
# Month-to-date against the budget. This is what the 50%/80% threshold emails used to
# deliver twice a month; having it on demand is strictly more useful.
section "Spend (month to date)"
START="$(python3 -c 'import datetime;print(datetime.date.today().replace(day=1))')"
END="$(python3 -c 'import datetime;print(datetime.date.today()+datetime.timedelta(days=1))')"

MTD="$(aws ce get-cost-and-usage \
  --time-period "Start=${START},End=${END}" \
  --granularity MONTHLY --metrics UnblendedCost \
  --filter "{\"Tags\":{\"Key\":\"pz:stack\",\"Values\":[\"${STACK}\"]}}" \
  --query 'ResultsByTime[0].Total.UnblendedCost.Amount' --output text 2>/dev/null || true)"

LIMIT="$(aws budgets describe-budget --account-id "$ACCOUNT" --budget-name "$BUDGET_NAME" \
  --query 'Budget.BudgetLimit.Amount' --output text 2>/dev/null || true)"

MTD="$MTD" LIMIT="$LIMIT" SINCE="$START" BUDGET_NAME="$BUDGET_NAME" python3 - <<'PY'
import os

mtd, limit = os.environ["MTD"].strip(), os.environ["LIMIT"].strip()
if not mtd or mtd == "None":
    print("  (no tagged spend reported)")
    print("  A new stack reports nothing until the pz:stack cost allocation tag is")
    print("  activated, and activation is not retroactive -- see DEPLOY.md.")
    raise SystemExit

spent = float(mtd)
if limit and limit != "None":
    cap = float(limit)
    pct = (spent / cap * 100) if cap else 0.0
    filled = max(0, min(20, int(pct // 5)))
    bar = "#" * filled + "." * (20 - filled)
    flag = ""
    if pct >= 100:
        flag = "  <-- OVER BUDGET"
    elif pct >= 80:
        flag = "  <-- close"
    print("  ${:,.2f} of ${:,.2f}  {:5.1f}%  [{}]{}".format(spent, cap, pct, bar, flag))
else:
    print("  ${:,.2f}  (no budget named {})".format(spent, os.environ["BUDGET_NAME"]))
print("  tagged pz:stack, since {}".format(os.environ["SINCE"]))
PY

# --- Alarms --------------------------------------------------------------------------
# All of them, not just what is firing. An alarm parked in INSUFFICIENT_DATA is the
# failure this stack has already hit twice, and listing only ALARMs hides it completely.
section "Alarms"
DATA="$(aws cloudwatch describe-alarms --alarm-name-prefix "$PREFIX" \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason}' \
  --output json 2>/dev/null || true)"

DATA="$DATA" python3 - <<'PY'
import json, os

rows = json.loads(os.environ["DATA"] or "[]")
if not rows:
    print("  (no alarms)")
    raise SystemExit

mark = {"OK": "ok  ", "ALARM": "FIRE", "INSUFFICIENT_DATA": "??  "}
# Anything not OK sorts first: the point of this section is what needs attention.
for r in sorted(rows, key=lambda x: (x["State"] == "OK", x["Name"])):
    print("  [{}] {}".format(mark.get(r["State"], "?   "), r["Name"]))
    if r["State"] != "OK":
        print("         {}".format((r.get("Reason") or "")[:100]))
PY

# --- Backups -------------------------------------------------------------------------
# Age of the newest is the number that matters. The list is there to show retention is
# actually rotating rather than silently keeping one file forever.
section "Backups"
BUCKET="pz-${STACK}-backups-${ACCOUNT}"
DATA="$(aws s3api list-objects-v2 --bucket "$BUCKET" --prefix "backups/${STACK}/" \
  --query 'sort_by(Contents,&LastModified)[-6:].{K:Key,M:LastModified,S:Size}' \
  --output json 2>/dev/null || true)"

DATA="$DATA" BUCKET="$BUCKET" UPTIME="$(cat "$UPTIME_FILE" 2>/dev/null || true)" python3 - <<'PY'
import datetime, json, os

raw = os.environ["DATA"].strip()
rows = json.loads(raw) if raw and raw != "null" else []
if not rows:
    print("  (no backups found in {})".format(os.environ["BUCKET"]))
    raise SystemExit

now = datetime.datetime.now(datetime.timezone.utc)
newest = datetime.datetime.fromisoformat(rows[-1]["M"].replace("Z", "+00:00"))
age = int((now - newest).total_seconds() // 60)

# Wall-clock age alone is misleading here, and saying so is the point. The instance is
# stopped by default, so after any long stop the newest backup is hours old the moment
# the box boots -- while pz-prod-backup-stale correctly reads OK, because the metric it
# watches is clamped to uptime (that is the whole of issue #20). Reporting a bare "past
# the threshold" next to an OK alarm would look like the alarm was broken.
uptime = os.environ.get("UPTIME", "").strip()
uptime_min = int(uptime) if uptime.isdigit() else None

note = ""
if age > 90:
    if uptime_min is None:
        note = "  (instance stopped -- backups only run while it is up)"
    elif uptime_min <= 90:
        note = "  (expected: box up only {}m; the alarm clamps to uptime)".format(uptime_min)
    else:
        note = "  <-- STALE: box up {}m with no fresh backup".format(uptime_min)
print("  newest is {}h{:02d}m old{}\n".format(age // 60, age % 60, note))

for r in reversed(rows):
    print("  {}  {:7.1f} MB  {}".format(
        r["M"][:19], r["S"] / 1e6, r["K"].rsplit("/", 1)[-1]))
PY

# --- Timeline ------------------------------------------------------------------------
# The section that replaces the notification stream: everything EventBridge and the
# watchdog recorded, in order, whether or not anyone was paged for it.
section "Events (last ${HOURS}h)"
SINCE_MS="$(python3 -c "import time;print(int((time.time() - ${HOURS} * 3600) * 1000))")"
DATA="$(aws logs filter-log-events --log-group-name "$LOG_GROUP" --start-time "$SINCE_MS" \
  --query 'events[].{T:timestamp,M:message}' --output json 2>/dev/null || true)"

DATA="$DATA" LOG_GROUP="$LOG_GROUP" python3 - <<'PY'
import datetime, json, os

raw = os.environ["DATA"].strip()
if not raw:
    print("  (log group {} not readable yet -- it is created by".format(os.environ["LOG_GROUP"]))
    print("   terraform apply, and nothing is recorded before that)")
    raise SystemExit

rows = json.loads(raw) if raw != "null" else []
if not rows:
    print("  (nothing recorded in this window)")
    raise SystemExit


def render(msg):
    """Three shapes land in this group: watchdog JSON, EventBridge alarm transitions and
    EC2 state changes. Anything unrecognised is printed raw rather than dropped -- a
    silently swallowed audit line is worse than an ugly one."""
    try:
        d = json.loads(msg)
    except Exception:
        return "INFO", msg.strip()[:110]

    if d.get("source") == "pz-watchdog":
        text = "{}: {}".format(d.get("event"), d.get("detail", ""))
        return d.get("level", "INFO"), text[:110]

    detail = d.get("detail") or {}
    kind = d.get("detail-type")
    if kind == "CloudWatch Alarm State Change":
        state = (detail.get("state") or {}).get("value", "?")
        name = detail.get("alarmName") or "?"
        level = "ALERT" if state == "ALARM" else "INFO"
        return level, "alarm {} -> {}".format(name, state)[:110]
    if kind == "EC2 Instance State-change Notification":
        return "INFO", "instance {}".format(detail.get("state"))
    return "INFO", (kind or msg)[:110]


for r in sorted(rows, key=lambda x: x["T"]):
    ts = datetime.datetime.fromtimestamp(r["T"] / 1000, datetime.timezone.utc)
    level, text = render(r["M"])
    print("  {} {:%m-%d %H:%M}  {}".format("!" if level == "ALERT" else " ", ts, text))
PY

printf '\n'
dim "Only emergencies page; everything above is recorded either way. See infra/alerts.tf."
