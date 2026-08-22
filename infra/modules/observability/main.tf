# DESIGN section 15. Everything routes to the SNS topic created in the root module; the
# bot subscribes and mirrors into Discord.

locals {
  dims = { Stack = var.stack }
}

# --- Custom metrics from the watchdog ----------------------------------------------

# "Instance running" is not "server ready" -- PZ takes 2-5 minutes to load a large
# world. This fires when the box is up but the game is not answering RCON, which is the
# signature of a crashed or wedged server.
resource "aws_cloudwatch_metric_alarm" "not_ready" {
  alarm_name          = "${var.name_prefix}-server-not-ready"
  alarm_description   = "Instance is running but PZ has not answered RCON for 5 minutes."
  namespace           = "PZ"
  metric_name         = "ServerReady"
  dimensions          = local.dims
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 5
  threshold           = 1
  comparison_operator = "LessThanThreshold"

  # The metric simply stops being published while the instance is stopped, which is the
  # normal state. Missing data must not page anyone.
  treat_missing_data = "notBreaching"

  alarm_actions = [var.alert_topic_arn]
  ok_actions    = [var.alert_topic_arn]
}

# A backup that quietly stopped running is indistinguishable from a backup that is
# working, right up until you need it.
resource "aws_cloudwatch_metric_alarm" "stale_backup" {
  alarm_name          = "${var.name_prefix}-backup-stale"
  alarm_description   = "No successful backup in over 90 minutes while the server is running (T1 runs every 30)."
  namespace           = "PZ"
  metric_name         = "BackupAgeMinutes"
  dimensions          = local.dims
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  alarm_actions = [var.alert_topic_arn]
}

# Save directories grow with explored map area, so this will fire eventually. Much
# better to know a week early than to find out when the world fails to save.
resource "aws_cloudwatch_metric_alarm" "disk" {
  alarm_name          = "${var.name_prefix}-data-disk-high"
  alarm_description   = "Data volume above 85% used."
  namespace           = "CWAgent"
  metric_name         = "disk_used_percent"
  statistic           = "Maximum"
  period              = 300
  evaluation_periods  = 2
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  # These must match exactly what the agent publishes, or the alarm sits at
  # INSUFFICIENT_DATA forever and looks healthy. ops/etc/cloudwatch-agent.json sets
  # drop_device:true, which is what removes the `device` dimension -- the one whose
  # value (nvme1n1 vs nvme2n1) is not stable enough to hard-code here.
  dimensions = {
    InstanceId = var.game_instance_id
    path       = "/opt/pz/data"
    fstype     = "ext4"
  }

  alarm_actions = [var.alert_topic_arn]
}

# Early warning that it is time to move to r7i.xlarge (DESIGN C3: B42 memory use grows
# with explored area and uptime, not just player count).
resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "${var.name_prefix}-memory-high"
  alarm_description   = "Memory above 90% for 15 minutes -- consider r7i.xlarge."
  namespace           = "CWAgent"
  metric_name         = "mem_used_percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 90
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"

  dimensions = { InstanceId = var.game_instance_id }

  alarm_actions = [var.alert_topic_arn]
}

# --- Instance state changes --------------------------------------------------------

# The box can be stopped from four places: Discord, the console, the idle watchdog, and
# AWS itself (retirement or capacity). This makes every one of them visible. It is the
# only way to notice an instance retirement, which is the failure that looks exactly
# like a normal stop until someone asks why the server went down at 3am.
resource "aws_cloudwatch_event_rule" "state_change" {
  name        = "${var.name_prefix}-instance-state-change"
  description = "Any stop/start of the PZ game server, whoever caused it."

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
    detail = {
      "instance-id" = [var.game_instance_id]
      state         = ["stopped", "stopping", "running", "shutting-down", "terminated"]
    }
  })
}

resource "aws_cloudwatch_event_target" "state_change_sns" {
  rule      = aws_cloudwatch_event_rule.state_change.name
  target_id = "sns"
  arn       = var.alert_topic_arn
}

# --- Budget ------------------------------------------------------------------------

# Scoped to this stack's tag, NOT account-wide. The account already has a "Safety Net"
# budget covering everything including foodblog; this one exists so that PZ's cost
# control is about PZ and does not depend on, or interfere with, that one.
#
# IMPORTANT: a TagKeyValue filter only matches once `pz:stack` has been ACTIVATED as a
# cost allocation tag in Billing, and activation backfills nothing -- it applies from
# activation onward. Until then this budget happily reports $0.00 spent, which is the
# most dangerous possible failure for a guardrail. DEPLOY.md has the activation command
# and the verification step; do not skip it.
resource "aws_budgets_budget" "stack" {
  name         = "${var.name_prefix}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name = "TagKeyValue"
    # Budgets wants "user:<TagKey>$<TagValue>" -- a literal dollar sign as the
    # separator. format() rather than interpolation, because "$${var.stack}" in HCL
    # escapes to the literal text ${var.stack} instead of the value.
    values = [format("user:pz:stack$%s", var.stack)]
  }

  dynamic "notification" {
    for_each = [50, 80, 100]
    content {
      comparison_operator       = "GREATER_THAN"
      threshold                 = notification.value
      threshold_type            = "PERCENTAGE"
      notification_type         = "ACTUAL"
      subscriber_sns_topic_arns = [var.alert_topic_arn]
    }
  }

  # Forecast-based, so the 100% ACTUAL stop is a backstop rather than the first warning.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [var.alert_topic_arn]
  }
}
