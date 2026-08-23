# pzserver — Context for Claude Code

## Purpose
Terraform and server-side ops for a Project Zomboid dedicated server on AWS that is
**stopped by default and started on demand from Discord**, so compute cost tracks play
time. Lives in the **shared** AWS account `020949219706` alongside
[foodblog](../foodblog), and shares its Route 53 zone: players connect to
`pz.joncfrancis.co:16261`.

**The stack is LIVE** in account `020949219706` as of 2026-08-22 — 72 resources, and
billing is running (~$16/mo fixed plus ~$0.20 per hour the game server is up). The game
server is normally **stopped**; the bot host is always on. `terraform apply` now changes
production, so it needs the user's explicit go-ahead — as does anything that starts the
game server. `plan` and `validate` remain free and safe.

## Stack & Commands
Terraform ≥ 1.10 (native S3 state locking — no DynamoDB table) · AWS provider ~> 6.0 ·
Ubuntu 24.04 game server · AL2023 arm64 bot host · bash + systemd on the boxes · Python 3
for the vendored RCON client.

```bash
terraform -chdir=infra init
terraform -chdir=infra fmt -recursive
terraform -chdir=infra validate
terraform -chdir=infra plan  -var-file=prod.tfvars
terraform -chdir=infra apply -var-file=prod.tfvars     # ← starts billing; ask first
```

There is no Terraform binary installed on this machine. To validate without installing
one, download a release into the scratchpad and run it from there; to `plan` without the
S3 backend, copy `infra/` + `ops/` somewhere, delete `backend.tf`, and `init` there
(`ops/` must come along — `modules/game-server` uploads it with a relative `fileset`).

Shell into either box with `aws ssm start-session --target <id>`. **There is no SSH and no
key pair** — do not go looking for a `.pem`.

## Code Map
```
DESIGN.md                  ← design of record: goals, constraints C1-C7, phased rollout
INFRA.md                   ← as-built reference + how it coexists with foodblog + real costs
DEPLOY.md                  ← runbook: setup, backup/restore, resize, rotation, teardown
infra/
  main.tf variables.tf outputs.tf alerts.tf prod.tfvars
  backend.tf               ← S3 state, use_lockfile = true
  bootstrap/               ← one-time stack that creates the state bucket
  modules/
    network/               ← VPC, subnet, IGW, sg-game + sg-bot
    game-server/           ← instance, EIP, data volume, IAM, DLM, ops upload, SSM config
    bot-host/              ← instance, EIP, IAM (the bot's HOST; the code is in ../pzbot)
    backups/               ← S3 bucket, lifecycle, TLS-only policy
    dns/                   ← the one record in foodblog's shared zone
    observability/         ← alarms, EventBridge state-change rule, tag-scoped budget
ops/                       ← everything that runs on the game server; uploaded to S3 by TF
  provision.sh             ← IDEMPOTENT provisioner: first boot, SSM re-run, and Packer later
  systemd/                 ← opt-pz-data.mount, pz-config, pz-update, pzserver, watchdog, backup
  bin/                     ← pz-rcon (vendored), start/stop, preflight, backup, restore, watchdog
  etc/cloudwatch-agent.json
```

## Architecture
Two instances in one public subnet. The **game server** (`m7i.xlarge`, x86_64) is stopped
by default; `pzserver.service` is `enabled`, so `ec2:StartInstances` alone brings the world
up — the start path has exactly one failure point. The **bot host** (`t4g.nano`, arm64) is
always on and holds the Discord gateway, which is the only reason `/pz start` can work
while the game server is off.

The world lives on a **separate EBS volume** (`prevent_destroy`) mounted at `/opt/pz/data`,
with `~pzuser/Zomboid` symlinked to it. Backups are three tiers: local `tar.zst` every
30 min (last 6), the same archive to versioned S3, and daily DLM volume snapshots.

RCON (tcp/27015) is reachable **only from `sg-bot`** — it is plaintext with weak auth, and
on the open internet it is a full-control backdoor. Only UDP 16261–16262 faces the world.

## Conventions & Gotchas

- **`terraform apply` starts billing (~$16/mo fixed, ~$41 at 4 hr/day).** Never run it
  unprompted. `plan` and `validate` are free and safe.
- **The Route 53 zone is a `data` source, never a `resource`.** It is foodblog's — the apex
  and `www` records serve the blog. That one word is what stops `terraform destroy` here
  from taking down `joncfrancis.co`. Do not "clean this up" into a managed zone.
- **The account-wide `Safety Net` budget must be raised before applying** — ✅ done,
  $25 → $70 on 2026-08-23. PZ exceeds the old limit permanently and would have turned
  foodblog's only cost alarm into noise. See
  [INFRA.md § Budgets](INFRA.md#budgets-the-collision).
- **Config goes in SSM, never in `user_data`.** `user_data` runs once (DESIGN C6) and this
  instance is stopped and started for its whole life, so anything baked in at first boot is
  frozen forever. `pz-config.service` re-renders `/etc/pz/env` from Parameter Store on
  every boot; that is what makes `game_xmx` changeable.
- **No `data "aws_ssm_parameter"` anywhere.** It would pull SecureString plaintext into
  state. Terraform manages parameter *names and IAM access*; values are put out of band.
- **The mount unit must be named `opt-pz-data.mount`.** systemd derives mount unit names
  from the mount point. DESIGN §8 calls it `pz-data.mount`; under that name nothing
  downstream starts. Not cosmetic.
- **`ExecStop` in `pzserver.service` is the whole of G5** ("a stop always saves"). Combined
  with ACPI-stop shutdown behaviour, it means a console-initiated stop saves the world too.
  Any code path that stops the box without going through `systemctl stop` breaks this.
- **`provision.sh` must stay idempotent**, and must only ever `mkfs` a device with no
  filesystem on it. That single condition is what stands between a re-provision and the
  deletion of the world.
- **`game_instance_type` and `game_xmx` must move together.** Nothing links them;
  `pz-preflight.sh` asserts `-Xmx` ≤ 75% of RAM at boot and refuses to start otherwise,
  which is the failure you want instead of an OOM three hours into a session.
- **Backups are a set: `Saves/` + `Server/` + `db/`.** Both the backup and restore scripts
  refuse a partial. A save with the wrong sandbox config is a subtly broken world.
- **PZ is x86_64 only (C1)** and heavily single-threaded (C2) — clock speed over core
  count. The game server cannot be Graviton; the bot host is.
- **Ops files must stay LF.** `ops/**` is pulled straight onto Linux and run by shebang and
  systemd's parser; CRLF breaks both obscurely. Pinned in `.gitattributes`, same rule as
  foodblog.
- **The bot is not in this repo.** `../pzbot` holds the Python. This repo owns its host,
  IAM role, and config; `terraform output bot_contract` is the interface.

## Key Files
- [infra/modules/game-server/main.tf](infra/modules/game-server/main.tf) — instance, world volume, ops upload
- [infra/modules/game-server/config.tf](infra/modules/game-server/config.tf) — the SSM answer to C6
- [infra/modules/dns/main.tf](infra/modules/dns/main.tf) — the shared-zone record and why it is a data source
- [ops/provision.sh](ops/provision.sh) — the idempotent host build
- [ops/bin/pz-watchdog.sh](ops/bin/pz-watchdog.sh) — idle shutdown, session cap, metrics
- [ops/bin/pz-restore.sh](ops/bin/pz-restore.sh) — the three guards on the riskiest operation
- [INFRA.md](INFRA.md) — coexistence with foodblog, costs, gotchas
