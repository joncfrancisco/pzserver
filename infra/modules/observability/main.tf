# DESIGN section 15. Two destinations, both created in the root module (infra/alerts.tf):
# the SNS topic for emergencies, which reaches email and Discord, and the audit log group
# for everything else, which reaches nobody until asked.
#
# When adding an alarm here, the question is not "is this worth recording?" -- everything
# is recorded, automatically, by the audit_alarm_state rule below. The question is only
# whether it is worth WAKING SOMEONE UP for. If it is not, give it no alarm_actions at
# all and it will still show up in `bin/pz-audit.sh`.

data "aws_partition" "current" {}

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

  # No ok_actions. Every ALARM here is followed by an OK -- either the server finished
  # loading or someone restarted it -- so recovery notices doubled the volume of this
  # alarm while telling nobody anything they could act on. The OK transition is still
  # recorded by audit_alarm_state and shows up in `pz-audit`.
  alarm_actions = [var.alert_topic_arn]
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
#
# This watches mem_AVAILABLE_percent, not mem_used_percent, and that is not a stylistic
# choice -- on this workload the "used" metric cannot cross 90% no matter how close the
# box is to OOM. PZ's JVM allocates its heap through a memfd (/memfd:java_heap, ~11 GB),
# so the heap is accounted as Shmem, which lands inside /proc/meminfo's Cached. The
# agent computes used% as (Total - Free - Buffers - Cached)/Total, so it subtracts the
# entire heap and reports ~9% while MemAvailable says the box is 82% spoken for.
# Reaching 90% used would take ~14.5 GB of non-shmem memory on a host that has ~4.5 GB
# outside the heap -- it would OOM first, silently, with this alarm sitting at OK.
#
# MemAvailable is the kernel's own estimate and correctly excludes non-reclaimable
# shmem, so it is the only one of the two that tracks reality here.
resource "aws_cloudwatch_metric_alarm" "memory" {
  alarm_name          = "${var.name_prefix}-memory-low-available"
  alarm_description   = "Less than 10% of memory available for 15 minutes -- consider r7i.xlarge."
  namespace           = "CWAgent"
  metric_name         = "mem_available_percent"
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 10
  comparison_operator = "LessThanThreshold"

  # Same reasoning as the other alarms: the instance is stopped by default, so missing
  # data is the normal state and must not page anyone. Note this is exactly what let the
  # alarm sit at OK for two days while the agent was 403ing -- "no data" and "healthy"
  # are indistinguishable here by design. Detecting a mute agent needs its own signal,
  # not a treat_missing_data flag that would cry wolf on every stopped instance.
  treat_missing_data = "notBreaching"

  dimensions = { InstanceId = var.game_instance_id }

  alarm_actions = [var.alert_topic_arn]
}

# --- The backstop behind the watchdog ------------------------------------------------

# pz-watchdog.sh is the cost guarantee, and it now covers both the idle case and the
# crashed-unit case. This alarm exists for the one failure it cannot cover: the watchdog
# ITSELF being dead -- a wedged guest, a broken timer, a botched ops deploy. Nothing that
# runs on the box can detect that, so this is deliberately built only out of things AWS
# publishes about the instance from the outside.
#
# Two things make it safe to give this an automatic stop action:
#
#   * CPUUtilization is an AWS/EC2 metric with a native InstanceId dimension. EC2 alarm
#     actions (arn:aws:automate:...) require that dimension -- they silently do nothing on
#     a custom metric dimensioned by Stack, which is why this is not an alarm on
#     PZ/ServerReady despite that being the more obvious metric.
#   * The window is 13 hours, just past the 12-hour session cap that is the watchdog's own
#     last line of defence. In normal operation every software guard fires long before
#     this does, INCLUDING `/pz idle off` (which is bounded by that same session cap), so
#     this can never stop a box that something else was still managing correctly.
#
# What it converts: "an m7i.xlarge billing at $0.2016/hour until somebody reads an email"
# into "at most 13 hours, once". Missing data means the instance is stopped, which is the
# normal state and must never page or act.
resource "aws_cloudwatch_metric_alarm" "runaway_auto_stop" {
  alarm_name        = "${var.name_prefix}-runaway-auto-stop"
  alarm_description = "Game instance has been running at near-zero CPU for 13 hours -- past the session cap, so every in-guest guard has failed. Stopping it."

  namespace   = "AWS/EC2"
  metric_name = "CPUUtilization"
  dimensions  = { InstanceId = var.game_instance_id }

  statistic           = "Maximum"
  period              = 3600
  evaluation_periods  = 13
  datapoints_to_alarm = 13
  threshold           = 3
  comparison_operator = "LessThanThreshold"
  treat_missing_data  = "notBreaching"

  # Maximum, not Average: one busy five-minute window in an hour is enough to prove
  # something is alive, and it keeps a mostly-paused-but-healthy server off this path.
  #
  # The stop is an ACPI stop, so it still runs pzserver.service's ExecStop and saves the
  # world on the way down -- the same property that makes a console stop safe (G5).
  alarm_actions = [
    "arn:${data.aws_partition.current.partition}:automate:${var.region}:ec2:stop",
    var.alert_topic_arn,
  ]
}

# --- The audit trail ----------------------------------------------------------------

# Everything that happens gets recorded here; only emergencies are allowed to interrupt
# anyone. That split is the whole point of this section.
#
# The original design routed every signal to SNS, and SNS has both an email subscription
# and the Discord relay on it. So a completely healthy two-hour session -- start, world
# load, players leave, idle warning, save, stop -- produced six emails and six Discord
# messages, none of which anyone can act on. An alert channel like that gets muted, and a
# muted channel cannot deliver the one message that matters ("STOP FAILED -- it is still
# billing"). Alarm fatigue on a $0.20/hour instance is the expensive failure.
#
# EventBridge writes straight to the log group: no SNS, no Lambda, nothing to page. It
# also captures strictly MORE than the old setup -- every alarm transition including OK
# and INSUFFICIENT_DATA, which previously only existed as email nobody kept.
# Every alarm transition for this stack, ALARM and OK alike. This is what `pz-audit`
# reads to answer "what actually happened last night" without anyone having been paged.
resource "aws_cloudwatch_event_rule" "audit_alarm_state" {
  name        = "${var.name_prefix}-audit-alarm-state"
  description = "Record every pz alarm state transition to the audit log. Never pages."

  event_pattern = jsonencode({
    source        = ["aws.cloudwatch"]
    "detail-type" = ["CloudWatch Alarm State Change"]
    detail = {
      alarmName = [{ prefix = var.name_prefix }]
    }
  })
}

resource "aws_cloudwatch_event_target" "audit_alarm_state" {
  rule      = aws_cloudwatch_event_rule.audit_alarm_state.name
  target_id = "audit-log"
  arn       = var.audit_log_group_arn
}

# --- Instance state changes ----------------------------------------------------------

# The box can be stopped from four places: Discord, the console, the idle watchdog, and
# AWS itself (retirement or capacity). All four are recorded; see below for the one that
# also pages.
#
# start/stop is the NORMAL operating rhythm of this stack -- the instance is stopped by
# default and that is the entire cost model -- so routine transitions are audit-only.
resource "aws_cloudwatch_event_rule" "state_change" {
  name        = "${var.name_prefix}-instance-state-change"
  description = "Any stop/start of the PZ game server, whoever caused it. Audit only."

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
    detail = {
      "instance-id" = [var.game_instance_id]
      state         = ["stopped", "stopping", "running", "shutting-down", "terminated"]
    }
  })
}

resource "aws_cloudwatch_event_target" "state_change_audit" {
  rule      = aws_cloudwatch_event_rule.state_change.name
  target_id = "audit-log"
  arn       = var.audit_log_group_arn
}

# The one instance transition that is never routine. Nothing in this stack terminates the
# game server -- the watchdog stops it, `/pz stop` stops it -- so `terminated` means
# either an AWS retirement or somebody in the console, and the world volume's
# prevent_destroy is the only thing standing between that and a lost save.
resource "aws_cloudwatch_event_rule" "terminated" {
  name        = "${var.name_prefix}-instance-terminated"
  description = "Game server TERMINATED -- never normal for this stack. Pages."

  event_pattern = jsonencode({
    source        = ["aws.ec2"]
    "detail-type" = ["EC2 Instance State-change Notification"]
    detail = {
      "instance-id" = [var.game_instance_id]
      state         = ["terminated"]
    }
  })
}

resource "aws_cloudwatch_event_target" "terminated_sns" {
  rule      = aws_cloudwatch_event_rule.terminated.name
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

  # 100% only. The 50% and 80% thresholds were pure noise: they fire predictably every
  # month on a stack whose whole design is to spend money when someone plays, and neither
  # one is a state anybody acts on. Budgets can only notify SNS or email -- there is no
  # EventBridge target -- so the quiet option is not to subscribe them at all.
  #
  # This loses nothing, because `pz-audit` reports month-to-date spend against the limit
  # on demand, which beats a threshold email: it tells you the number whenever you ask
  # rather than only at the two moments AWS chose.
  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [var.alert_topic_arn]
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
