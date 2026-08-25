# The always-on host that holds the Discord gateway connection.
#
# It exists because `/pz start` has to work while the game server is powered off, which
# is the entire point of the design (DESIGN G3). At ~$3.07/month it is the cheapest way
# to have a persistent WebSocket, and being persistent means no 3-second interaction
# deadline and somewhere to stream progress from.
#
# THIS MODULE PROVISIONS THE HOST, NOT THE BOT. The Python lives in the pzbot repo; see
# `terraform output bot_contract` for the values it needs and INFRA.md "The pzbot
# handoff" for the boundary.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

# AL2023 arm64 here rather than Ubuntu: Graviton is fine for pure Python (DESIGN C1
# constrains only the game server), the SSM agent is native rather than a snap, and on a
# 512 MB nano the smaller base image is worth having.
data "aws_ami" "al2023" {
  most_recent = true
  owners      = ["amazon"]

  filter {
    name   = "name"
    values = ["al2023-ami-2023.*-kernel-6.*-arm64"]
  }
  filter {
    name   = "state"
    values = ["available"]
  }
}

resource "aws_instance" "bot" {
  ami                    = data.aws_ami.al2023.id
  instance_type          = var.instance_type
  subnet_id              = var.subnet_id
  vpc_security_group_ids = [var.security_group_id]
  iam_instance_profile   = aws_iam_instance_profile.bot.name

  # See the game server for the reasoning. This box holds less that is irreplaceable, but
  # it is the one that is always on and the only one that can reach the game server.
  disable_api_termination = true

  # T-series instances default to `unlimited`, which bills for surplus CPU credits beyond
  # the baseline. An idle discord.py process will never come close -- but "will probably
  # never bill a surprise" is the wrong property for the ONE always-on resource in a stack
  # whose entire premise is a predictable fixed floor. `standard` makes the floor genuinely
  # fixed: past the baseline the instance throttles instead of charging.
  #
  # If the bot ever does need burst (it should not -- it is a WebSocket and some boto3
  # calls), the symptom is sluggish command responses, which is a visible thing to
  # investigate rather than a line item to discover at the end of the month.
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens                 = "required"
    http_endpoint               = "enabled"
    http_put_response_hop_limit = 1
  }

  root_block_device {
    volume_size = 8
    volume_type = "gp3"
    encrypted   = true
    tags        = { Name = "${var.name_prefix}-bot-root" }
  }

  user_data = <<-EOT
    #!/usr/bin/env bash
    set -euo pipefail
    dnf install -y python3.12 python3.12-pip git
    id pzbot >/dev/null 2>&1 || useradd --system --create-home --shell /usr/sbin/nologin pzbot
    install -d -o pzbot -g pzbot /opt/pzbot
    # The application is deployed from the pzbot repo. Nothing further happens here.
  EOT

  tags = {
    Name       = "${var.name_prefix}-bot"
    "pz:role"  = "bot"
    "pz:stack" = var.stack
  }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# The bot host is always on, so its address is stable anyway -- but an EIP means a
# rebuild does not change it, and it keeps the instance reachable over SSM without
# depending on a public IP being auto-assigned.
resource "aws_eip" "bot" {
  domain   = "vpc"
  instance = aws_instance.bot.id
  tags     = { Name = "${var.name_prefix}-bot-eip" }
}

# --- Monitoring -------------------------------------------------------------------------
#
# Every alarm in modules/observability is scoped to the GAME instance. This host -- the
# single point of failure for `/pz start`, the one box that is always on, the one nobody
# looks at -- had none at all. DESIGN section 16's own failure-mode table names both
# halves of the fix (detection: "missing heartbeat metric"; response: "consider an EC2
# auto-recovery alarm") and neither was built. If the bot host wedges, the first symptom
# is a player typing `/pz start` and getting silence.
#
# These alarms live here rather than in modules/observability deliberately: the module
# that provisions a host should own the alarms about that host, and it keeps
# observability's game_instance_id scoping honest.

# None of the three alarms below carry ok_actions, deliberately. Each of them already
# takes an automatic corrective action (recover / reboot), so the recovery notice was a
# second message about a problem that had resolved itself -- and paired with the ALARM it
# doubled the volume of the alerts that matter most. Every OK transition is still
# recorded in the audit log by the observability module's audit_alarm_state rule, so
# `pz-audit` can show that the host bounced overnight without anyone's phone buzzing.

# Hardware or hypervisor failure underneath the instance. `recover` migrates it to new
# hardware, keeping the instance id, private IP and EIP -- which matters, because the
# bot's whole job is to still be reachable.
resource "aws_cloudwatch_metric_alarm" "bot_system_check" {
  alarm_name        = "${var.name_prefix}-bot-system-check-failed"
  alarm_description = "Bot host failed its EC2 system status check -- underlying hardware. Recovering."

  namespace   = "AWS/EC2"
  metric_name = "StatusCheckFailed_System"
  dimensions  = { InstanceId = aws_instance.bot.id }

  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 2
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  # This box is meant to be up 100% of the time, so unlike the game server's alarms,
  # missing data here is itself a problem worth surfacing.
  treat_missing_data = "breaching"

  alarm_actions = [
    "arn:${data.aws_partition.current.partition}:automate:${var.region}:ec2:recover",
    var.alert_topic_arn,
  ]
}

# The guest itself: exhausted memory, a corrupted filesystem, a kernel that stopped
# answering. A reboot fixes the ones that are fixable and makes the rest loud.
resource "aws_cloudwatch_metric_alarm" "bot_instance_check" {
  alarm_name        = "${var.name_prefix}-bot-instance-check-failed"
  alarm_description = "Bot host failed its EC2 instance status check -- the guest is not answering. Rebooting."

  namespace   = "AWS/EC2"
  metric_name = "StatusCheckFailed_Instance"
  dimensions  = { InstanceId = aws_instance.bot.id }

  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [
    "arn:${data.aws_partition.current.partition}:automate:${var.region}:ec2:reboot",
    var.alert_topic_arn,
  ]
}

# The failure a status check CANNOT see: the instance is healthy, the process is running,
# and the asyncio event loop is wedged or the gateway connection has silently died. From
# the outside that is indistinguishable from a working bot, right up until someone types
# `/pz start`.
#
# The bot publishes PZ/BotAlive=1 from the 60-second presence loop it already runs, so a
# hung loop stops the metric. `breaching` on missing data is the entire point here.
#
# GATED, because the alarm and the metric ship from two different repos. Applying this
# before pzbot's heartbeat change is deployed would page continuously against a metric
# that does not exist yet. Flip it to true in prod.tfvars once the bot is publishing --
# `aws cloudwatch list-metrics --namespace PZ --metric-name BotAlive` is the check.
resource "aws_cloudwatch_metric_alarm" "bot_heartbeat" {
  count = var.enable_bot_heartbeat_alarm ? 1 : 0

  alarm_name        = "${var.name_prefix}-bot-heartbeat-missing"
  alarm_description = "No PZ/BotAlive heartbeat for 5 minutes. The host may be fine and the bot still dead."

  namespace   = "PZ"
  metric_name = "BotAlive"
  dimensions  = { Stack = var.stack }

  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "breaching"

  alarm_actions = [var.alert_topic_arn]
}
