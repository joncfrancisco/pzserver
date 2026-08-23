# Infrastructure

> **Status: LIVE as of 2026-08-22.** Applied to account 020949219706 (72 resources).
> The world is up, `pz.joncfrancis.co:16261` resolves and answers, and the full
> stop→save→start cycle has been verified end to end. **Billing is running**: ~$16/month
> fixed plus ~$0.20 per hour the game server is up.
>
> Live IDs: game `i-0c319547d110e4179` · bot `i-09158ffe716ee3c5e` ·
> EIP `34.233.59.251` · data volume `vol-09e3f5065531b0ccb` ·
> bucket `pz-prod-backups-020949219706`.
>
> Account: **020949219706** — **shared**. This is the same account that runs
> [foodblog](../foodblog) (`joncfrancis.co`), `symfal.com`, and several other IAM
> users and projects. Scope any account-wide reasoning accordingly. Region: **us-east-1**.
>
> A one-page map of all three projects in this account lives in
> [joninfra](https://github.com/joncfrancisco/joninfra).
>
> This documents the infrastructure **as built in code**. For the *why*, see
> [DESIGN.md](DESIGN.md); for step-by-step runbooks, see [DEPLOY.md](DEPLOY.md).

## Overview

A single **EC2 instance that is stopped by default** runs the Project Zomboid dedicated
server under **systemd**. A separate always-on **`t4g.nano` bot host** holds the Discord
gateway connection, so `/pz start` works while the game server is powered off — which is
the entire point. The world lives on its **own EBS volume**, mounted at `/opt/pz/data`,
which survives an instance rebuild. Players connect to **`pz.joncfrancis.co:16261`**, an
A record in foodblog's existing Route 53 zone pointing at a static Elastic IP. Backups go
to **S3** in three tiers. Cost is bounded by an **idle watchdog running on the game server
itself**, not in the bot.

```
                        ┌───────────── Discord ─────────────┐
                        │  players + admins, /pz commands   │
                        └────────────────┬──────────────────┘
                                         │ gateway WSS (outbound only)
 ┌───────────────────── VPC 10.20.0.0/16, us-east-1a ───────┼──────────────────────┐
 │  public subnet 10.20.1.0/24                              │                      │
 │                                                          ▼                      │
 │   ┌──────────────────────┐   ec2:Start/Stop   ┌────────────────────────────┐    │
 │   │ GAME  m7i.xlarge     │◀──────────────────▶│ BOT   t4g.nano, arm64      │    │
 │   │ x86_64, Ubuntu 24.04 │   RCON tcp/27015   │ always on, AL2023          │    │
 │   │ STOPPED BY DEFAULT   │◀───── sg-bot ─────▶│ pzbot.service              │    │
 │   │                      │      only          └────────────────────────────┘    │
 │   │ systemd:             │                                                      │
 │   │  opt-pz-data.mount   │                                                      │
 │   │  pz-config.service   │◀── /pz/prod/* ── SSM Parameter Store                 │
 │   │  pz-update.service   │                                                      │
 │   │  pzserver.service    │──── ExecStop: RCON save → quit  (G5)                 │
 │   │  pz-watchdog.timer   │──── 60s: players → idle → self-stop                  │
 │   │  pz-backup.timer     │──── 30 min                                           │
 │   └──────────┬───────────┘                                                      │
 │              │ EBS data volume, prevent_destroy — THE WORLD                     │
 └──────────────┼──────────────────────────────────────────────────────────────────┘
                │                        ▲
  players ──────┘ udp 16261-2            │ EIP 
  via pz.joncfrancis.co ─── Route 53 ────┘ (shared zone, foodblog's)
                │
                ├──▶ S3  backups/prod/*.tar.zst   (T2, versioned → Glacier IR)
                └──▶ DLM daily volume snapshots   (T3, 7 days)
```

## How this coexists with foodblog

The two projects share an AWS account and a domain name, and **nothing else**. That is
worth being explicit about, because the shared pieces are exactly where a careless change
to one takes out the other.

### The domain: `pz.joncfrancis.co`

Route 53 zone `Z02575211T1QV3GILBPJH` (`joncfrancis.co.`) was created by the registrar
and is what foodblog serves from — apex and `www` both A-record to the Lightsail box at
`52.201.206.142`. This stack adds exactly one record:

| Name | Type | TTL | Value | Owner |
|---|---|---|---|---|
| `joncfrancis.co.` | A | 300 | `52.201.206.142` | foodblog (manual) |
| `www.joncfrancis.co.` | A | 300 | `52.201.206.142` | foodblog (manual) |
| **`pz.joncfrancis.co.`** | **A** | **300** | **the PZ Elastic IP** | **this stack** |

[`modules/dns`](infra/modules/dns/main.tf) reads the zone with a **`data` source** and
manages only the `pz` record. The hosted zone is never a managed resource in this stack's
state, so **`terraform destroy` here removes the `pz` record and cannot touch the blog's
DNS.** That is the single most important safety property of sharing the zone, and it is a
one-word difference (`data` vs `resource`) — do not change it.

**This also settles the EIP debate in [DESIGN §5](DESIGN.md#the-eip-question) in a way
the design could not.** The design weighed a $3.65/month Elastic IP against "a Route 53 A
record updated on each boot", and picked the EIP to keep DNS propagation out of the start
path. Sharing an existing zone lets us have both: the record targets the EIP, which never
changes, so it is written once at apply time and **never touched at boot**. Players get a
memorable address, the start path has no DNS step in it, and it costs nothing extra —
Route 53 bills per hosted zone, and foodblog already pays that $0.50.

### Budgets: the collision

**This is the one place where standing up PZ actively breaks something foodblog relies on,
and it needs a deliberate decision before `apply`.**

The account had a budget named **`Safety Net`: $25/month, account-wide (no cost filters),
one alert at 80% ACTUAL** — the account's only cost guardrail, and the one covering
foodblog. **It was raised to $70 on 2026-08-23**, before `apply`, exactly as this section
required; what follows is why.

PZ at ~$41/month blows straight through it, permanently, from the first month. The alert
would fire every month forever and become noise — which is precisely how the one alarm
that protects the blog stops being read.

The resolution has two halves:

1. **This stack brings its own budget.** [`modules/observability`](infra/modules/observability/main.tf)
   creates `pz-prod-monthly`, filtered on the `pz:stack` tag, with 50/80/100% ACTUAL alerts
   plus a FORECASTED alert at 100%. PZ's cost control is about PZ and is independent of
   the account-wide one.
2. **`Safety Net` had to be raised by hand** to a number that still means something with
   the game server in the account. It is not this stack's resource to own — it predates PZ
   and protects other projects — so Terraform deliberately does not manage it. ✅ **Done:
   $25 → $70 on 2026-08-23.** The command is in
   [DEPLOY.md](DEPLOY.md#0-before-anything-raise-the-account-budget); re-run it if the
   account's shape changes again.

⚠️ **The tag filter only works once `pz:stack` is activated as a cost allocation tag** in
Billing, and activation is **not retroactive** — it applies from activation onward. Until
then the PZ budget cheerfully reports $0.00 spent, which is the most dangerous possible
failure mode for a guardrail: it looks healthy. DEPLOY.md has the activation command and
a verification step; do not skip it.

The precondition is easy to misread as a failure. Tagging the resources is **not**
sufficient — 20 resources carry `pz:stack` and activation still returns
`Tag keys not found`. A tag key only becomes activatable once a **charge carrying that
tag has posted**, which had not happened as of 2026-08-23 (the stack was created
2026-08-22/23 and no EC2 or VPC charge has landed yet). So this is a waiting state with a
specific thing to wait for, not a broken step — see
[DEPLOY.md § The tag activation is a waiting game](DEPLOY.md#the-tag-activation-is-a-waiting-game--and-here-is-the-thing-to-wait-for)
for the leading indicator to poll.

### Networking: no path between them

foodblog runs on **Lightsail**, which sits in its own AWS-managed network outside your
VPCs. This stack creates its own VPC (`10.20.0.0/16`). There is no peering, no shared
security group, no shared subnet, and nothing to coordinate. A change to one cannot
affect the other's reachability.

Worth knowing: **us-east-1 has no default VPC in this account** (verified 2026-08-22 —
`describe-vpcs` returns empty, while us-east-2/us-west-2/eu-west-1 each still have one).
There is nothing to reuse and nothing to collide with, but it also means anything you
launch here by hand expecting a default VPC will fail.

### Cost attribution

foodblog is ~$5.50/month. PZ will be ~$41/month at the expected usage, making it **the
largest single line item in the account by a wide margin.** foodblog's
[INFRA.md § Costs](../foodblog/INFRA.md#costs) previously described the non-foodblog
remainder as belonging to "other projects" — that note has been updated to point here,
because from now on most of the account bill is this stack.

Everything in this stack carries `pz:stack=prod`, `project=pzserver`, `managedBy=terraform`
via provider `default_tags`, so cost attribution is a tag filter away.

### Shared-account hygiene

Seven IAM users live in this account. Both instance roles are tag-conditioned to
`pz:stack=prod` and `pz:role=gameserver`, so neither can start, stop, or command anything
belonging to anyone else. `Describe*` actions cannot be resource-scoped by AWS and are
therefore account-wide read-only — the bot can *see* foodblog's resources; it cannot touch
them.

## Resources

| Resource | Config | Notes |
|---|---|---|
| VPC | `10.20.0.0/16`, one public subnet `10.20.1.0/24`, IGW | Single AZ (`us-east-1a`, same AZ as the foodblog Lightsail box — cosmetic, they share no network). **No NAT gateway**: at ~$32/month it would cost more than the game server. |
| `sg-game` | in: UDP 16261–16262 from `0.0.0.0/0`; TCP 27015 from `sg-bot` only. **No port 22.** | Steam browser ports 8766–8767 are opened only when `public_server = true`. |
| `sg-bot` | in: nothing. out: all | Purely a client. |
| EC2 game server | `m7i.xlarge`, x86_64, Ubuntu 24.04 LTS, EIP | `pz:role=gameserver`, `pz:stack=prod`. IMDSv2 required; instance metadata tags enabled. Shutdown behaviour **stop**, not terminate. |
| EBS root | 30 GB gp3, encrypted, delete-on-termination | OS, SteamCMD, PZ binaries. Rebuildable. |
| EBS data | 30 GB gp3, encrypted, **`prevent_destroy`** | Mounted `/opt/pz/data`; `~pzuser/Zomboid` symlinks to it. **This volume is the world.** |
| EC2 bot host | `t4g.nano`, arm64 AL2023, EIP | `pz:role=bot`. Provisioned here; the Python lives in [pzbot](../pzbot). |
| S3 bucket | `pz-prod-backups-020949219706` — versioned, SSE-S3, public access blocked, TLS-only policy | `backups/prod/` = world archives (lifecycle: Standard → Glacier IR at 30d, noncurrent expire 180d); `ops/` = the provisioning tree. |
| DLM policy | Daily snapshot of the data volume at 09:00 UTC, 7-day retention | Selects on `pz:role=gameserver-data`. Runs after foodblog's 08:15/08:30 backup timers. |
| SSM Parameter Store | `/pz/prod/config/*` (String, Terraform-managed) and `/pz/prod/{rcon,admin}_password`, `/pz/prod/discord/*` (SecureString, **out of band**) | See "Secrets" below. |
| IAM roles | `pz-prod-gameserver-role`, `pz-prod-bot-role`, `pz-prod-dlm-role` | Tag-conditioned. See DESIGN §9 and the two `iam.tf` files. |
| SNS topic | `pz-prod-alerts` | CloudWatch alarms, EventBridge state changes, Budgets, and the watchdog all publish here. The bot subscribes and mirrors into Discord. |
| CloudWatch | `PZ/PlayersOnline`, `PZ/ServerReady`, `PZ/BackupAgeMinutes`, `PZ/BackupSizeBytes`; `CWAgent` disk + memory | Four alarms; see [modules/observability](infra/modules/observability/main.tf). |
| EventBridge | Rule on EC2 state-change for the game instance | Catches stops from the console **and instance retirement**, which otherwise looks exactly like a normal stop. |
| Budgets | `pz-prod-monthly`, $45, filtered on `pz:stack=prod` | Separate from the account-wide `Safety Net` — see above. |

**Terraform state**: `s3://pz-tfstate-020949219706/pzserver/prod.tfstate`, versioned, with
native S3 locking (`use_lockfile = true`, TF ≥ 1.10). **No DynamoDB lock table** — it is
not needed on 1.10+. The bucket is created by the separate
[`infra/bootstrap`](infra/bootstrap) stack so that the stack managing the game server can
never destroy the bucket holding its own state.

## Access

- **Shell: SSM Session Manager only.** There are no key pairs, no port 22, and no
  `aws_key_pair` resource anywhere in this repo.
  ```bash
  aws ssm start-session --target <instance-id>
  ```
  This is a real difference from foodblog, which is SSH-only (Lightsail, no SSM agent).
  Do not go looking for a `.pem` file for this stack; there isn't one.
- **Scripted access:** `ssm send-command` with `AWS-RunShellScript`. The bot's IAM policy
  enumerates the documents it may invoke rather than wildcarding them, so there is no path
  from a Discord message to arbitrary shell.
- **AWS CLI:** `default` profile, `us-east-1`, currently `jon-claude-local`
  (group `bots`, `AdministratorAccess`). Shared account — check ownership before acting
  account-wide.
- **Secrets (never in this repo, never in Terraform state):**
  - `/pz/prod/rcon_password` — SecureString. Per DESIGN C7 this is equivalent to full
    control of the server.
  - `/pz/prod/admin_password` — SecureString. The in-game PZ admin account. Distinct from
    the RCON password on purpose.
  - `/pz/prod/discord/token`, `/pz/prod/discord/role_*`, `/pz/prod/discord/channel_*` —
    SecureString, read by the bot.
  - All created with `aws ssm put-parameter` per [DEPLOY.md](DEPLOY.md#2-secrets). Terraform
    manages the parameter *names and IAM access*, never the values; there is deliberately
    no `data "aws_ssm_parameter"` anywhere in this repo, because it would pull plaintext
    into state.

## How the server runs

Boot order, all systemd, no cloud-init after the first boot:

```
ec2:StartInstances
  └─ systemd
      ├─ opt-pz-data.mount        the world's filesystem, mounted by LABEL=pzdata
      ├─ pz-config.service        oneshot: SSM → /etc/pz/env  (0600 root)
      ├─ pz-update.service        oneshot: steamcmd +app_update 380870 validate
      │                           skipped if /opt/pz/skip-update exists
      ├─ pzserver.service         Type=simple, enabled, Restart=on-failure/RestartSec=30
      │     ExecStart  pz-start-server.sh  → preflight, patch -Xmx, exec PZ
      │     ExecStop   pz-stop-server.sh   → RCON save → RCON quit
      │     TimeoutStopSec=180, StartLimitBurst=3 per 900s
      ├─ pz-watchdog.timer        every 60s
      └─ pz-backup.timer          every 30 min
```

`pzserver.service` is **enabled**, so a bare `ec2:StartInstances` brings the world up —
the bot never needs to send a command to start the game. The start path has exactly one
failure point on purpose.

**Paths on the box:** PZ install `/opt/pz/server/` (root volume, rebuildable); world
`/opt/pz/data/Zomboid/` (data volume); scripts `/opt/pz/bin/`; config `/etc/pz/env`;
watchdog state `/var/lib/pz/`; local backups `/var/lib/pz/backups/` (on the ROOT volume,
deliberately — see the comment on `LOCAL_DIR` in `ops/bin/pz-backup.sh`).

**Logs:** `journalctl -u pzserver -f`, `journalctl -u pz-watchdog`, `journalctl -u pz-config`.

### Two mechanisms worth understanding before you change anything

**`ExecStop` is the entire safety net behind [G5](DESIGN.md#goals)** ("a stop always saves
first"). The instance's `instance_initiated_shutdown_behavior` is `stop`, so an
`ec2:StopInstances` from *anywhere* — the bot, the idle watchdog, the AWS console, an
instance retirement — arrives as ACPI shutdown → systemd stop → `pz-stop-server.sh` → RCON
`save`, then `quit`. **There is no way to stop this box that skips a save.** If you ever
find yourself adding a `--force` path that bypasses `systemctl stop`, you are removing
this property.

**Configuration is pulled from SSM on every boot, and that is load-bearing.**
[DESIGN C6](DESIGN.md#3-constraints-that-shape-the-design) notes that `user-data` runs
once; because this instance is stopped and started for its whole life rather than
replaced, anything baked in at first boot is frozen forever. `pz-config.service` re-renders
`/etc/pz/env` from Parameter Store on every start, so changing `game_xmx` in
`prod.tfvars` and applying takes effect on the next `/pz start` with no reprovisioning.
**Do not move configuration into `user_data` to "simplify" it.**

## Deploy / provisioning

There is no CI/CD. The flow is:

1. `terraform apply` uploads everything under [`ops/`](ops) to `s3://…/ops/` and creates
   the instance.
2. `user_data` (first boot only) installs the AWS CLI, syncs `s3://…/ops/` to
   `/opt/pz/bootstrap/`, and runs `provision.sh`.
3. [`provision.sh`](ops/provision.sh) is **idempotent** — that is its defining property.
   The same script runs at first boot, on demand over `ssm send-command` after any change
   under `ops/`, and (in Phase 5) at Packer bake time. Being safe to re-run is what makes
   the golden-image promotion in DESIGN §7 cheap.

To ship a change to an ops file: `terraform apply` (re-uploads to S3), then re-run
`provision.sh` on the box — the exact command is in
[DEPLOY.md](DEPLOY.md#re-provisioning-after-an-ops-change).

`aws_instance.game` has `ignore_changes = [ami, user_data]`. A new Canonical AMI release
must not silently replace the instance and take the root volume with it.

## Backups

Three tiers, because they fail in different ways. Every one of them is preceded by an RCON
`save` — see [`pz-backup.sh`](ops/bin/pz-backup.sh).

| Tier | What | When | Retention | Recovers from |
|---|---|---|---|---|
| **T1** local | `tar.zst` (zstd -10) of `Saves/Multiplayer/<name>` + `Server/` + `db/` on the data volume | every 30 min while running; always before a stop | last 6 on disk | "roll back an hour", bad mod update, griefing |
| **T2** S3 | the same archive, uploaded | every T1, plus before every stop and every restore | versioned; Standard → Glacier IR at 30d; noncurrent expires 180d | volume loss, instance loss |
| **T3** snapshots | whole data volume, via DLM | daily 09:00 UTC | 7 days | filesystem corruption |

Key naming: `backups/prod/<YYYY-MM-DDTHH-MM-SSZ>__<trigger>__<label>.tar.zst`, trigger being
`scheduled | prestop | prerestore | manual`. Having the trigger in the key is what lets you
find "the backup taken right before the thing that broke everything" without opening any of
them.

**All three directories are one unit.** A backup covering `Saves/` but not `Server/*.ini`
restores a world with the wrong sandbox settings, and `db/` holds player accounts and the
whitelist. [`pz-backup.sh`](ops/bin/pz-backup.sh) refuses to archive unless all three exist,
and [`pz-restore.sh`](ops/bin/pz-restore.sh) refuses to restore an archive missing any of
them. That check exists because the realistic failure is an archive that has been silently
missing `db/` for two months.

**The instance role has no `s3:DeleteObject`.** It can write backups but cannot remove
them; retention is enforced entirely by bucket lifecycle, which the role also cannot touch.
Same shape as foodblog's write-only backup key, for the same reason.

**A backup you have not restored is not a backup.** The quarterly restore drill is in
[DEPLOY.md](DEPLOY.md#restore-drill-quarterly). Put it on the calendar.

## Costs

Fixed floor, paid whether or not anybody plays:

| Item | Monthly |
|---|---|
| Game root + data EBS, 60 GB gp3 @ $0.08/GB-mo | $4.80 |
| Game Elastic IP, $0.005/hr — **billed while the instance is stopped** | $3.65 |
| Bot host `t4g.nano` @ $0.0042/hr × 730 | $3.07 |
| Bot host EBS, 8 GB gp3 | $0.64 |
| **Bot host public IPv4** — always-on instance, no NAT, so it needs one | **$3.65** |
| EBS snapshots (T3): 7 daily incrementals of the data volume | ~$0.50 |
| S3 backups, ~5 GB steady state under the 21/180-day lifecycle | ~$0.15 |
| Route 53 record in the shared zone | $0.00 |
| **Fixed subtotal** | **~$16.46** |

Variable, at the live `m7i.xlarge` on-demand price of **$0.2016/hr** (verified against the
Pricing API on 2026-08-22, along with `r7i.xlarge` $0.2646, `m7i.large` $0.1008,
`t4g.nano` $0.0042 — all matching DESIGN §5):

| Usage | Hours/mo | Compute | **Total** |
|---|---|---|---|
| 2 hr/day | 60 | $12.10 | **~$29** |
| **4 hr/day** | **120** | **$24.19** | **~$41** |
| 6 hr/day | 180 | $36.29 | **~$53** |
| Weekends only, 8 hr | 64 | $12.90 | **~$29** |
| 24/7 (no stopping) | 730 | $147.17 | **~$164** |

> **[G2](DESIGN.md#goals) — "under $40/month at ~4 hours/day" — is missed by about a
> dollar.** Two line items the design's $12.31 fixed subtotal did not include: the bot
> host's own public IPv4 ($3.65/mo — an always-on instance in a public subnet with no NAT
> gateway needs one, and since Feb 2024 AWS bills auto-assigned addresses exactly like
> Elastic IPs, so there is no cheaper variant of this), and the T3 snapshots (~$0.50).
> The levers, in order of preference: **drop the idle timeout from 30 to 15 minutes** (the
> design's own Q4, worth roughly $1–2/month at this usage), or accept ~$41. Do not put the
> bot behind a NAT gateway to avoid the IPv4 charge — that trades $3.65 for ~$32.

The comparison that matters is unchanged, and is the reason [C4](DESIGN.md#3-constraints-that-shape-the-design)
is written down: a 3-year Reserved Instance bills 24/7 at $0.091/hr = **$66/month**, so
on-demand-plus-stopping is cheaper than even a 3-year commitment until about **11 hours a
day** of play. Nobody should "optimize" this into an RI.

## What the first apply found

`terraform plan` cannot catch runtime behaviour. Five things only surfaced on a real
apply, all fixed in the commits that followed:

| Symptom | Cause | Fix |
|---|---|---|
| `pz-config.service` failed on first boot, taking the rest of provisioning with it | The role granted `ssm:GetParameter` but the script calls **`GetParametersByPath`** — a distinct action, and one that authorizes against the *path* resource, not only the parameters beneath it | Added the action and both ARNs to `pz-gameserver-role` |
| `steamcmd`: `Failed to install app '380870' (Missing configuration)` | **`+force_install_dir` preceded `+login`.** SteamCMD authenticates fine, then rejects the app with a message that points nowhere near the cause | `+login anonymous` first, in `pz-update.service` |
| `pz-start-server.sh: /etc/pz/env: Permission denied` | The env file was `0600 root:root`, but `ExecStart` drops to `User=pzuser` before running | `0640 root:pzuser` — readable by the service account, nobody else |
| `pz-preflight: FATAL: PZ_XMX=12g exceeds 75% of MemTotal` | **A "16 GiB" `m7i.xlarge` reports `MemTotal` = 15703 MiB.** The design's `-Xmx12g` is 78% of that | `game_xmx = "11g"`, which also lands closer to the design's stated "~4 GiB for OS + page cache" |
| PZ logged `Router detection… If the server hangs here, set UPnP=false` | There is no UPnP router in a VPC | `UPnP=false` added to the managed `.ini` keys |

The `-Xmx` one is worth dwelling on: **the boot-time assertion did exactly the job it was
added for.** It turned the single most common PZ hosting mistake into a loud refusal to
start, forty seconds in, instead of an OOM kill three hours into a session. Size heap
against `MemTotal`, never against the instance type's marketing number.

## Verified on the live stack

- **DNS** — `pz.joncfrancis.co` → `34.233.59.251`; `joncfrancis.co` still → `52.201.206.142`
  and the blog still answers HTTP 200. The shared zone works as designed.
- **Boot chain is unattended** — `ec2:StartInstances` alone took the box from `stopped` to
  a world answering RCON: mount → `pz-config` → `pz-update` (SteamCMD validate) →
  `pzserver`. No command sent, no shell.
- **G5 holds.** An `aws ec2 stop-instances` — the console path, bypassing the bot entirely
  — reached `ExecStop` via ACPI: `pz-stop: saving world` → `World saved` → `Quit` →
  `PZ exited cleanly`, in about 30 seconds, with the save directory's mtime advancing to
  prove it. **There is no way to stop this box that skips a save.**
- **Backups** — a manual run forced an RCON save, archived all three of
  `Saves/Multiplayer/pzprod` + `Server/` + `db/`, and landed in S3 (771 KiB for a fresh
  world).
- **Metrics** — all four `PZ/*` metrics publishing on the 60s timer, with `ServerReady`
  correctly stepping 0 → 1 as the world finished loading.
- **Security** — only UDP 16261–16262 is world-open; RCON 27015 is source-restricted to
  `sg-bot`; no port 22 rule exists anywhere in the account; no key pairs exist; the backup
  bucket blocks all public access.
- **Config plumbing** — changing `game_xmx` in `prod.tfvars` and applying moved the value
  through Parameter Store to `/etc/pz/env` on the next start, with no reprovisioning.
  C6 is handled.

## Known issues & gotchas

- **`Safety Net` must be raised before `apply`** — ✅ done for this deploy ($25 → $70 on
  2026-08-23). It is the account's only cost guardrail and PZ would exceed the old limit
  permanently. See [Budgets: the collision](#budgets-the-collision). Still the one
  prerequisite that breaks something if skipped on a rebuild into a fresh account.
- **Cost allocation tags are not retroactive.** The PZ budget filters on `pz:stack`, which
  reports $0.00 until the tag is activated in Billing. A guardrail that reads healthy
  because it is matching nothing is worse than no guardrail.
- **`prevent_destroy` makes `terraform destroy` fail**, on the data volume and the backup
  bucket. That is the intent, but it means [G6](DESIGN.md#goals)'s "`terraform destroy`
  then `apply`" is really a deliberate two-step: remove the guard, then destroy. See
  [DEPLOY.md](DEPLOY.md#tearing-the-stack-down).
- **`-Xmx` must move with the instance type.** They are separate Terraform variables and
  nothing links them. Changing `game_instance_type` without changing `game_xmx` either
  wastes RAM or trips the boot-time assertion in
  [`pz-preflight.sh`](ops/bin/pz-preflight.sh) — which refuses to start, loudly, rather
  than OOMing three hours into a session.
- **The mount unit is `opt-pz-data.mount`, not `pz-data.mount`.** systemd derives mount
  unit names from the mount point and refuses to load a mismatch. DESIGN §8 names it
  `pz-data.mount`; under that name nothing downstream would ever start. Not cosmetic.
- **`provision.sh` formats only a device with no filesystem on it.** That single condition
  is what stands between a re-provision and the deletion of the world. Do not "simplify"
  it into an unconditional `mkfs`.
- **The PZ admin password is visible in `ps`.** `pz-start-server.sh` passes it as
  `-adminpassword`, so it appears in the process command line to any local user. Exposure
  is small — the box has only `root` and `pzuser`, and no SSH — but it is real. PZ stores
  the password in `db/` after first run, so the argument could be dropped once set; it is
  kept because dropping it would break password rotation. Worth revisiting if a third
  local account ever appears.
- **No SSH.** If SSM is broken, there is no way in. `provision.sh` warns if the SSM agent
  is not running; treat that warning as blocking.
- **PZ is x86_64 only** ([C1](DESIGN.md#3-constraints-that-shape-the-design)). The game
  server cannot be Graviton. The bot host can, and is.
- **`server_name` is effectively immutable.** It determines the `.ini` filename and the
  save directory under `Saves/Multiplayer/`. Changing it after first boot orphans the
  existing world rather than renaming it.
- **Ops files must stay LF** (`ops/**`) — they are pulled straight onto a Linux box and
  executed by shebang and by systemd's parser. Pinned in `.gitattributes`, same as
  foodblog.
- **`public_server = true` needs both halves.** The Terraform variable opens UDP
  8766–8767; the `.ini` needs `Public=true`. Setting one without the other either opens
  two ports for nothing or produces a server that never appears in the browser.

## The pzbot handoff

This repo provisions the bot's **host, IAM role, security group, SSM parameter paths, and
alert topic**. It does not contain the bot. The Python — `discord.py`, the command
surface, the state machine, the single-flight lock — lives in [pzbot](../pzbot): v1.0.0,
~3,800 lines, ten test modules, a CI pipeline and an installer. **It is deployed and
running** — `pzbot.service` on the bot host has been `active (running)` and `enabled`
since 2026-08-23, so the two repos are no longer out of step. See
[pzbot/DEPLOY.md](../pzbot/DEPLOY.md) for upgrades and rotation.

Everything the bot needs to configure itself comes out of `terraform output bot_contract`:

```json
{
  "region": "us-east-1",  "stack": "prod",
  "game_instance_id": "i-…",  "game_private_ip": "10.20.1.x",
  "connect_host": "pz.joncfrancis.co",  "rcon_port": 27015,
  "ssm_prefix": "/pz/prod",  "backup_bucket": "pz-prod-backups-020949219706",
  "alert_topic_arn": "arn:aws:sns:…",  "metric_namespace": "PZ"
}
```

Two contracts the bot must honour, both from DESIGN §10:

- **Never cache state.** Every command re-reads `DescribeInstances` plus a live RCON
  probe. This box can be stopped from four places (Discord, the console, the idle
  watchdog, a budget alarm); cached state is a bug waiting to happen.
- **"Running" is not "ready."** PZ takes 2–5 minutes to load a large world. Readiness is
  RCON answering `players` with a well-formed response — the `PZ/ServerReady` metric, or a
  direct probe. Never announce "server is up" from EC2 state alone.

Until the bot is deployed, every operation has a manual equivalent in
[DEPLOY.md](DEPLOY.md#running-it-by-hand-before-the-bot-exists). Phases 1–2 of the rollout
do not need the bot at all.
