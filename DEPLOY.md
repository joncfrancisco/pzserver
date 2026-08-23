# Deploy & operations runbook

Step-by-step procedures. For *what exists*, see [INFRA.md](INFRA.md); for *why*, see
[DESIGN.md](DESIGN.md).

Everything here assumes the `default` AWS profile in `us-east-1`, and Terraform ≥ 1.10
(needed for native S3 state locking).

---

## Outstanding after the 2026-08-23 remediation deploy

The audit remediation is applied and verified. One prerequisite is still outstanding, and
it is the one that matters most.

| Step | State on 2026-08-23 | Consequence |
|---|---|---|
| Activate the `pz:stack` cost allocation tag | **Still not active** after three attempts across two days — AWS returns `Tag keys not found: pz:stack` | `pz-prod-monthly` reports **$0.00** against a $45 limit and reads healthy |
| Raise the account-wide `Safety Net` budget | ✅ done — now **$70** | — |
| Discord alert webhook in Parameter Store | ✅ done — relay verified end to end | — |
| Quarterly restore drill | Never run | A backup nobody has restored is not a backup |

### The tag activation is a waiting game, not a missing step

The resources **are** tagged — `aws ec2 describe-tags --filters Name=key,Values=pz:stack`
returns 17 of them — but Billing only offers a key for activation once it has propagated
into the cost-allocation registry, and that has taken longer than the 24 hours the docs
suggest. Keep retrying:

```bash
aws ce update-cost-allocation-tags-status --cost-allocation-tags-status \
  'TagKey=pz:stack,Status=Active' 'TagKey=project,Status=Active'

# The check that matters — not the command above exiting 0:
aws ce list-cost-allocation-tags --status Active \
  --query 'CostAllocationTags[?TagKey==`pz:stack`]'
```

Until it takes, **pzbot's budget kill-switch is inert by design**. `guards.budget` refuses
to gate on a `stack_usd` of $0.00 while the account has spent something, because that
figure is fictional rather than zero. So the tag is not just a reporting nicety — it is
what switches PZ-08 on.

### Account-level items, recorded rather than changed

Not owned by this stack:

- **No CloudTrail** anywhere in the account. A single-region trail of management events is
  free and would give a shared account an audit record.
- **`jon-claude-local` holds `AdministratorAccess`** via the `bots` group, with **no MFA**
  and **two active access keys** (2026-07-08 and 2026-08-20). Bigger exposure than
  anything in the stack itself.
- **13 CloudWatch alarms against a 10-alarm free tier.** Seven are PZ's; the rest are
  pre-existing `Spotify*` / `UserData*` / `Users*` DynamoDB alarms. Retiring the dead ones
  would put the account back inside the free tier.

## First-time setup

Do these in order. Steps 0–2 are prerequisites; step 3 is what starts the meter.

### 0. Before anything: raise the account budget

**Read [INFRA.md § Budgets: the collision](INFRA.md#budgets-the-collision) first.**

The account has one guardrail — `Safety Net`, **$25/month, account-wide**, alerting at
80% — and it is currently the only thing watching foodblog's spend. PZ will exceed it
permanently, and an alert that fires every month is an alert nobody reads.

Raise it to something that still means something with a game server in the account
(`$70` leaves headroom over the expected ~$41 + foodblog's ~$5.50 without being so high
it would miss a runaway):

```bash
aws budgets describe-budget --account-id 020949219706 --budget-name "Safety Net" \
  > /tmp/safety-net.json                       # keep a copy of the current state

python3 - <<'PY'
import json
b = json.load(open('/tmp/safety-net.json'))['Budget']
b['BudgetLimit']['Amount'] = '70.0'
for k in ('CalculatedSpend', 'HealthStatus', 'LastUpdatedTime'):
    b.pop(k, None)                             # read-only fields; the API rejects them
json.dump({'NewBudget': b}, open('/tmp/safety-net-new.json', 'w'))
PY

aws budgets update-budget --account-id 020949219706 \
  --cli-input-json "$(cat /tmp/safety-net-new.json)"
```

Terraform deliberately does not manage this budget — it predates PZ and protects other
projects in a shared account.

### 1. Cost allocation tags — note the ordering trap

The PZ budget filters on the `pz:stack` tag, and **that filter matches nothing until the
tag is activated in Billing**.

You cannot activate it yet. AWS only offers a tag key for activation once it has *seen*
it on a real resource, so running the command before `apply` fails with
`Tag keys not found: pz:stack,project`. It is therefore a **post-apply** step — do it
immediately after step 3, not before:

```bash
aws ce update-cost-allocation-tags-status --cost-allocation-tags-status \
  'TagKey=pz:stack,Status=Active' 'TagKey=project,Status=Active'
```

Verify (the key can take a few hours to appear for activation, and up to 24 h to show as
`Active` afterwards):

```bash
aws ce list-cost-allocation-tags --status Active \
  --query 'CostAllocationTags[?TagKey==`pz:stack`]'
```

⚠️ **Activation is not retroactive** — it applies from activation onward, so any spend
before you run this is invisible to the budget forever. And until it is `Active`,
`pz-prod-monthly` reports **$0.00 spent** regardless of actual cost: it looks healthy
while protecting nothing. Put a reminder in a week to confirm it is reporting real
numbers.

### 2. Secrets

Generated, never chosen, and all three distinct from one another (DESIGN §14).

```bash
# RCON password. Per DESIGN C7 this is equivalent to full control of the server.
aws ssm put-parameter --name /pz/prod/rcon_password --type SecureString \
  --value "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"

# The in-game PZ admin account. Deliberately NOT the same as the RCON password.
aws ssm put-parameter --name /pz/prod/admin_password --type SecureString \
  --value "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"
```

The Discord parameters are only needed once the bot exists, but the paths are worth
knowing:

```bash
aws ssm put-parameter --name /pz/prod/discord/token          --type SecureString --value '…'
aws ssm put-parameter --name /pz/prod/discord/guild_id       --type SecureString --value '…'
aws ssm put-parameter --name /pz/prod/discord/role_player    --type SecureString --value '…'
aws ssm put-parameter --name /pz/prod/discord/role_admin     --type SecureString --value '…'
aws ssm put-parameter --name /pz/prod/discord/channel_main   --type SecureString --value '…'
aws ssm put-parameter --name /pz/prod/discord/channel_audit  --type SecureString --value '…'
```

Read one back with `aws ssm get-parameter --name … --with-decryption --query Parameter.Value --output text`.

### 3. Apply

```bash
# One-time: the bucket that holds the main stack's state.
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap apply          # prints the bucket name

# The stack itself. The bucket name is already filled into infra/backend.tf.
terraform -chdir=infra init
terraform -chdir=infra plan  -var-file=prod.tfvars
terraform -chdir=infra apply -var-file=prod.tfvars
```

Expect ~72 resources. **This is the point at which billing starts** — from here the fixed
floor of ~$16/month applies whether or not anyone plays.

Confirm the SNS email subscription when it arrives; unconfirmed subscriptions silently
drop every alert.

**Now go back and do [step 1](#1-cost-allocation-tags--note-the-ordering-trap)** — the tag
keys exist as of this apply, so activation will work from here on.

### 4. First boot

`apply` leaves the instance **running** and provisioning. It takes 5–15 minutes: package
installs, then a SteamCMD download of the PZ server (several GB).

```bash
GAME=$(terraform -chdir=infra output -raw game_instance_id)

# Watch it provision. There is no SSH; this is the way in.
aws ssm start-session --target "$GAME"
sudo tail -f /var/log/pz-bootstrap.log
```

Provisioning is done when `provision.sh` prints `provisioning complete.` Then start the
world:

```bash
sudo systemctl start pzserver.service
journalctl -u pzserver -f
```

### 5. Verify

```bash
# DNS resolves to the Elastic IP
dig +short pz.joncfrancis.co
terraform -chdir=infra output -raw game_public_ip     # must match

# On the box: RCON answers, which is the real definition of "ready"
sudo bash -c 'set -a; . /etc/pz/env; /opt/pz/bin/pz-rcon players'

# The heap assertion actually ran
journalctl -u pzserver | grep pz-preflight

# The world is on the data volume, not the root disk
df -h /opt/pz/data && ls -la /home/pzuser/Zomboid
```

Then connect from the PZ client: **Join → `pz.joncfrancis.co`, port `16261`**.

Finally, prove the important property — that a stop saves the world:

```bash
sudo systemctl stop pzserver.service
journalctl -u pzserver | grep pz-stop     # expect "saving world" then "PZ exited cleanly"
```

---

## Running it by hand (before the bot exists)

Phases 1–2 of the rollout need no bot at all.

```bash
GAME=$(terraform -chdir=infra output -raw game_instance_id)

# Start a session. pzserver.service is enabled, so this is all it takes.
aws ec2 start-instances --instance-ids "$GAME"

# Stop it. ACPI shutdown → systemd → RCON save → quit. The world is saved either way.
aws ec2 stop-instances --instance-ids "$GAME"

# Where is it?
aws ec2 describe-instances --instance-ids "$GAME" \
  --query 'Reservations[0].Instances[0].State.Name' --output text

# Who is online? (PZ/PlayersOnline, published every 60s by the watchdog)
aws cloudwatch get-metric-statistics --namespace PZ --metric-name PlayersOnline \
  --dimensions Name=Stack,Value=prod --start-time "$(date -u -v-1H +%FT%TZ)" \
  --end-time "$(date -u +%FT%TZ)" --period 300 --statistics Maximum \
  --query 'sort_by(Datapoints,&Timestamp)[-5:]'
```

**These two commands are the manual fallback for a Discord outage** — worth keeping
somewhere findable that is not Discord.

Anything RCON, from a session on the box:

```bash
sudo -i
set -a; . /etc/pz/env; set +a
/opt/pz/bin/pz-rcon players
/opt/pz/bin/pz-rcon save
/opt/pz/bin/pz-rcon 'servermsg "restarting in 5 minutes"'
```

---

## Backups

### On demand

```bash
sudo /opt/pz/bin/pz-backup.sh manual before-mod-update
```

Triggers are `scheduled | prestop | prerestore | manual`; the trigger and label both land
in the S3 key, which is how you later find "the backup from right before the thing that
broke everything".

### List what exists

```bash
aws s3 ls s3://$(terraform -chdir=infra output -raw backup_bucket)/backups/prod/ --human-readable
```

### Restore

Restore is the most dangerous operation in the system. The script enforces the safeguards
so you do not have to remember them: it refuses to run while PZ is up, takes a
`prerestore` backup of the current world first, and refuses an archive missing any of
`Saves/`, `Server/`, `db/`.

```bash
sudo systemctl stop pzserver.service          # required; the script will refuse otherwise

sudo /opt/pz/bin/pz-restore.sh 2026-08-22T04-30-11Z__scheduled.tar.zst
#   → prints a summary and exits. Re-run with --yes to actually do it.
sudo /opt/pz/bin/pz-restore.sh 2026-08-22T04-30-11Z__scheduled.tar.zst --yes

sudo systemctl start pzserver.service
```

The previous world is left on disk as `*.pre-restore-<stamp>` under
`/opt/pz/data/Zomboid/`, and in S3 as the `prerestore` archive. Delete the local copies
once you are satisfied.

### Restore from an EBS snapshot (T3)

When the filesystem itself is the problem, not the world:

```bash
aws ec2 describe-snapshots --owner-ids self \
  --filters "Name=tag:pz:stack,Values=prod" \
  --query 'sort_by(Snapshots,&StartTime)[-5:].{Id:SnapshotId,When:StartTime}' --output table

aws ec2 stop-instances --instance-ids "$GAME"
# create a volume from the snapshot in us-east-1a, detach the old one, attach the new as
# /dev/sdf, start the instance. The mount is by LABEL=pzdata, so nothing else changes.
```

Then lay the latest S3 archive on top to recover the last 30 minutes.

### Restore drill (quarterly)

**A backup you have not restored is not a backup.** Put this on the calendar; it is the
only way to discover that the archive has been silently missing `db/` for two months.

```bash
terraform -chdir=infra workspace new drill
terraform -chdir=infra apply -var-file=prod.tfvars \
  -var stack=drill -var dns_label=pz-drill -var game_instance_type=m7i.large -var game_xmx=6g
# restore the latest prod backup into it, confirm the world loads and players exist, then:
terraform -chdir=infra destroy -var-file=prod.tfvars -var stack=drill -var dns_label=pz-drill
```

The `prevent_destroy` guards apply to the drill stack too — see
[Tearing the stack down](#tearing-the-stack-down).

---

## Routine operations

### Re-provisioning after an ops change

Anything under [`ops/`](ops) ships in two steps: Terraform re-uploads it to S3, then the
box re-runs the (idempotent) provisioner.

⚠️ **This restarts the game server if it is running.** `provision.sh` restarts
`pz-config.service`, and `pzserver.service` has `Requires=` on it, so systemd propagates
the restart. It is safe — `ExecStop` saves the world first — but anyone playing is
disconnected, and an RCON call in flight will fail. Prefer re-provisioning with the world
down. If you must do it live, expect one `RCON unreachable (1/10)` line from the watchdog
while the server comes back; that is the bounce, not a fault.

```bash
terraform -chdir=infra apply -var-file=prod.tfvars      # re-uploads ops/ to s3://…/ops/

aws ssm send-command --instance-ids "$GAME" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["aws s3 sync s3://'"$(terraform -chdir=infra output -raw backup_bucket)"'/ops/ /opt/pz/bootstrap/ --delete","chmod +x /opt/pz/bootstrap/provision.sh /opt/pz/bootstrap/bin/*","/opt/pz/bootstrap/provision.sh"]' \
  --query 'Command.CommandId' --output text
```

Read the result with `aws ssm get-command-invocation --command-id <id> --instance-id "$GAME"`.

### Changing configuration

`server_name`, `xmx`, the idle timeouts and the session cap live in SSM and are re-read on
every boot, so:

```bash
# edit infra/prod.tfvars
terraform -chdir=infra apply -var-file=prod.tfvars
# takes effect on the next start; no reprovisioning, no restart choreography
```

### Resizing the instance

Stop → modify → start. About two minutes of downtime, no data movement.

```bash
# infra/prod.tfvars: move BOTH of these together
#   game_instance_type = "r7i.xlarge"
#   game_xmx           = "24g"
terraform -chdir=infra apply -var-file=prod.tfvars
```

`r7i.xlarge` (4 vCPU / 32 GiB, same clock) is the right upgrade when Build 42's memory
growth bites — RAM runs out before cores do. If you change the type without changing
`game_xmx`, the boot-time assertion in `pz-preflight.sh` refuses to start and says why.

### Pinning the PZ build

When a Steam update breaks something and you need the world up on the version that worked:

```bash
sudo touch /opt/pz/skip-update     # pz-update.service is ConditionPathExists=!this
sudo rm /opt/pz/skip-update        # resume updating
```

### Rotating the RCON password

```bash
aws ssm put-parameter --name /pz/prod/rcon_password --type SecureString --overwrite \
  --value "$(openssl rand -base64 24 | tr -d '/+=' | cut -c1-24)"

# On the box: re-render /etc/pz/env, rewrite the .ini, restart.
sudo systemctl restart pz-config.service
sudo systemctl restart pzserver.service
```

Then restart the bot so it picks up the new value.

### Rotating the Discord token

```bash
aws ssm put-parameter --name /pz/prod/discord/token --type SecureString --overwrite --value '…'
aws ssm send-command --instance-ids "$(terraform -chdir=infra output -raw bot_instance_id)" \
  --document-name AWS-RunShellScript \
  --parameters 'commands=["systemctl restart pzbot"]'
```

Two commands, documented, because tokens do leak and the fix should not require thinking.

### OS patching

Unlike foodblog, nothing here auto-patches. The game server is stopped most of the time
and gets rebuilt from an AMI far more readily, so the pragmatic policy is: patch when you
happen to be in there, and rebuild the root volume rather than nurse it.

```bash
sudo apt-get update && sudo apt-get dist-upgrade -y
[ -f /var/run/reboot-required ] && sudo reboot
```

The bot host is always on and *does* want attention — check it monthly.

---

## Troubleshooting

| Symptom | Where to look |
|---|---|
| `apply` fails on the DLM policy description | Descriptions must match `[0-9A-Za-z _-]+`; no parentheses. |
| Instance runs, nobody can connect | `journalctl -u pzserver`. Then check `dig +short pz.joncfrancis.co` matches `terraform output game_public_ip`, and that the client is using port **16261**. |
| `pzserver` refuses to start, log says `pz-preflight: FATAL` | Working as intended. Either `game_xmx` exceeds 75% of RAM, or the data volume did not mount. The message says which. |
| `pz-config: FATAL … missing under /pz/prod` | A secret was never put. See [Secrets](#2-secrets). |
| Server up but the bot says not ready | Correct behaviour — readiness is RCON answering, not EC2 state. A large world takes 2–5 min. |
| Instance stopped itself unexpectedly | `journalctl -u pz-watchdog`. Either the idle timeout, the session cap, or 10 consecutive RCON failures (the "crashed server billing overnight" guard). |
| Idle shutdown never fires | The counter only advances at **zero** players. Check `PZ/PlayersOnline` — an idle character in a safehouse still counts as a player, which is what the session cap is for. |
| Budget shows $0.00 spent | Cost allocation tags are not active. See [step 1](#1-activate-cost-allocation-tags). |
| `unit opt-pz-data.mount not found` | The unit filename must match the mount point. Not `pz-data.mount`. |
| Cannot get a shell | There is no SSH by design. If SSM is down: `aws ssm describe-instance-information` to confirm the agent has checked in. |

---

## Tearing the stack down

`prevent_destroy` is set on the EBS data volume and the S3 backup bucket, so a plain
`terraform destroy` **fails**. That is the point: those two resources are the only ones
whose loss is unrecoverable, and destroying them should take a deliberate act rather than
a typo.

```bash
# 1. Take a final backup and confirm it landed.
sudo /opt/pz/bin/pz-backup.sh manual final-before-teardown
aws s3 ls s3://$(terraform -chdir=infra output -raw backup_bucket)/backups/prod/ | tail -3

# 2. Everything except the two guarded resources.
terraform -chdir=infra destroy -var-file=prod.tfvars \
  -target=module.game_server.aws_instance.game \
  -target=module.bot_host.aws_instance.bot
#    …or remove the `lifecycle { prevent_destroy = true }` blocks and destroy fully.

# 3. The data volume and the bucket, only if you really mean it, by hand.
```

To rebuild afterwards: `terraform apply`, then restore the final archive per
[Restore](#restore). That is [G6](DESIGN.md#goals) — with the guard removal as an explicit
first step rather than the one-liner the design implies.

---

## Deployment log

Trimmed deliberately — keep entries that change what a future run should *do*, and fold
anything durable up into the step it belongs to.

### 2026-08-23 — audit remediation (PZ-01 … PZ-21)

**Re-provisioning restarts the game server.** `provision.sh` runs
`systemctl restart pz-config.service`, and `pzserver.service` has `Requires=` on it, so
the restart propagates. Observed live: an RCON save failed mid-bounce and the watchdog
logged `RCON unreachable (1/10 consecutive)` before the server came back. It is *safe* —
`ExecStop` saves the world on the way down — but it is not free, and it will disconnect
anyone playing. Re-provision with the world down unless you mean to bounce it.

**`aws s3 cp` has no `--tagging`, and an unknown option is fatal.** Shipped broken in
PZ-02: the CLI raised `ParamValidation: Unknown options: --tagging`, `set -e` killed the
script, and T2 uploads silently stopped while T1 kept working. Fixed by tagging in a
second `aws s3api put-object-tagging` call. The lesson generalises: after any change to
`pz-backup.sh`, verify the object actually **arrives**, not just that the script logs an
upload line.

```bash
sudo /opt/pz/bin/pz-backup.sh manual verify
KEY=$(aws s3api list-objects-v2 --bucket $(terraform -chdir=infra output -raw backup_bucket) \
  --prefix backups/prod/ --query 'sort_by(Contents,&LastModified)[-1].Key' --output text)
aws s3api get-object-tagging --bucket $(terraform -chdir=infra output -raw backup_bucket) --key "$KEY"
# expect keep=short for scheduled, keep=long for prestop/prerestore/manual
```

**CI does not catch a missing provider in `.terraform.lock.hcl`.** `terraform init
-backend=false` *adds* a missing provider to the lockfile rather than failing, so
`hashicorp/archive` sat in `versions.tf` unlocked and green through CI. Catching it needs
`-lockfile=readonly` in the workflow. Worth doing.

**A PR retargeted to a feature branch does not follow that branch to `main`.** #10 was
based on `fix/cost-guarantee` to resolve a conflict; #4 merged to `main` at 07:16, #10
merged into the now-orphaned `fix/cost-guarantee` at 07:17, and the change never reached
`main`. GitHub only auto-retargets when the base branch is *deleted* on merge. Caught only
because the pre-deploy plan was one resource short of the rehearsal. **Enable
auto-delete-branch on merge**, or keep stacked PRs based on `main` and resolve conflicts
at merge time.

**Two Terraform stacks.** `infra/bootstrap` has its own local state and does not travel
with the main apply. It is easy to forget because nothing references it.

