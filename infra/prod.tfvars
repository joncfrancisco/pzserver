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

# Enabled 2026-08-23, once pzbot was deployed and confirmed publishing PZ/BotAlive
# (10 datapoints in 10 minutes, one per minute from the presence loop). The gate existed
# only for the cross-repo ordering: the alarm is here and the metric is in pzbot, and
# because a heartbeat alarm must treat missing data as breaching, applying it first would
# have paged continuously against a metric that did not exist yet.
enable_bot_heartbeat_alarm = true

# --- DNS ---
# Shared with foodblog. This stack reads the zone and manages only pz.joncfrancis.co.
route53_zone_id = "Z02575211T1QV3GILBPJH"
dns_label       = "pz"
