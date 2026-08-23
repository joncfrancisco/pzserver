# pzserver

Infrastructure for a Project Zomboid dedicated server on AWS that is **stopped by default
and started on demand from Discord**, so compute costs track actual play time instead of
wall-clock time.

Runs alongside [foodblog](../foodblog) in the same AWS account, on the same domain:
players connect to **`pz.joncfrancis.co:16261`**. A one-page map of everything in that
account is in [joninfra](https://github.com/joncfrancisco/joninfra).

## What's here

| | |
|---|---|
| [DESIGN.md](DESIGN.md) | The design of record — goals, constraints, trade-offs, phased rollout. |
| [INFRA.md](INFRA.md) | What actually got built, how it coexists with foodblog, real costs. |
| [DEPLOY.md](DEPLOY.md) | Runbook: first-time setup, backup/restore, resize, teardown. |
| [`infra/`](infra) | Terraform. Six modules; `infra/bootstrap` creates the state bucket. |
| [`ops/`](ops) | What runs on the game server: systemd units, backup/restore, the idle watchdog, a vendored RCON client. |

The Discord bot lives in a separate repo, [pzbot](../pzbot) — v1.0.0, ~3,800 lines, ten
test modules and a CI pipeline, **deployed and running** on the bot host. This repo
provisions its host, IAM role, and configuration; see
[INFRA.md § The pzbot handoff](INFRA.md#the-pzbot-handoff).

## Shape of it

```
Discord ──▶ bot host (t4g.nano, always on, ~$3/mo)
              │  ec2:StartInstances
              ▼
            game server (m7i.xlarge, x86_64, STOPPED by default)
              │  systemd brings the world up on boot; RCON save on every stop
              ├──▶ EBS data volume — the world, prevent_destroy
              └──▶ S3 — archives every 30 min, plus daily volume snapshots
```

Three things carry most of the design's weight:

- **The bot cannot live on the game server**, because `/pz start` has to work while the
  game server is off. Hence the second, tiny, always-on host.
- **The idle watchdog runs on the game server, not in the bot.** It has local RCON access
  and keeps working when Discord is down. The cost guarantee must not depend on Discord
  being healthy.
- **Every stop saves first.** `pzserver.service`'s `ExecStop` runs RCON `save` then `quit`,
  and the instance is set to ACPI-stop, so a stop from the AWS console gets the same
  treatment as one from Discord.

## Status

**Live since 2026-08-22.** Connect at **`pz.joncfrancis.co:16261`**.

The stack is applied (72 resources) and the full cycle is verified: a bare
`ec2:StartInstances` brings the world up unattended, and an `ec2:StopInstances` — even
from the AWS console — saves the world on the way down. Backups, metrics and the idle
watchdog are all running.

**[pzbot](../pzbot) is deployed and running** (v1.0.0) — the Discord application, the
`/pz/prod/discord/*` parameters and `deploy/install.sh` are all done, and
`pzbot.service` has been `active (running)` and `enabled` on the bot host since
2026-08-23. `/pz start` is the normal way in. The CLI equivalents still work and are in
[DEPLOY.md § Running it by hand](DEPLOY.md#running-it-by-hand-before-the-bot-exists) for
when Discord is the thing that's broken. Everything the bot needs is in
`terraform output bot_contract`.

Cost: **~$41/month** at 4 hours a day, against ~$164 for the same box left running. About
$16 of that is fixed and paid whether anyone plays or not. The server stops itself after
30 idle minutes.

## Cost, in one table

| | Monthly |
|---|---|
| Fixed floor (EBS, 2× public IPv4, bot host, snapshots, S3) | ~$16.46 |
| Compute at 4 hr/day (`m7i.xlarge` @ $0.2016/hr) | ~$24.19 |
| **Total** | **~$41** |
| *Same instance, 24/7* | *~$164* |
| *1-yr Reserved (billed 24/7, so cheaper only above ~16 hr/day)* | *~$97* |

Full breakdown, including the two line items the design's estimate missed, in
[INFRA.md § Costs](INFRA.md#costs).
