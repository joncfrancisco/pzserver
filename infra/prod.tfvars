# Production stack -- one PZ world, alongside foodblog in account 020949219706.

region            = "us-east-1"
availability_zone = "us-east-1a"
stack             = "prod"

# --- Game server ---
# m7i.xlarge for 6-8 players on Build 42 (DESIGN C1/C2/C3).
#
# 11g, not the design's 12g. A "16 GiB" instance reports MemTotal = 15703 MiB once
# firmware and the kernel have taken their share, and 12g (12288 MiB) is 78% of that --
# over the 75% ceiling pz-preflight.sh enforces, which refused to start until this was
# corrected. 11g leaves ~4.3 GiB for the OS and page cache, which is actually closer to
# the design's stated intent ("leaving ~4 GiB") than 12g ever was.
#
# If B42 memory growth bites, the upgrade is r7i.xlarge + game_xmx = "23g" -- same
# arithmetic, RAM runs out before cores do.
game_instance_type = "m7i.xlarge"
game_xmx           = "11g"
server_name        = "pzprod"

# Direct-connect only. Flip to true ONLY if you also set Public=true in the server .ini;
# it opens UDP 8766-8767 for the Steam server browser.
public_server = false

# --- Cost control ---
idle_warn_minutes    = 25
idle_timeout_minutes = 30
session_cap_hours    = 12
down_timeout_minutes = 15

# ~$12.31/mo fixed + ~$24 compute at 4 hr/day = ~$37. 45 leaves headroom before the
# 100% threshold starts refusing player-tier /pz start.
monthly_budget_usd = 45

budget_notification_emails = ["joncfrancisco@gmail.com"]

# Flip to true only AFTER pzbot's heartbeat change is deployed and
# `aws cloudwatch list-metrics --namespace PZ --metric-name BotAlive` returns it.
enable_bot_heartbeat_alarm = false

# --- DNS ---
# Shared with foodblog. This stack reads the zone and manages only pz.joncfrancis.co.
route53_zone_id = "Z02575211T1QV3GILBPJH"
dns_label       = "pz"
