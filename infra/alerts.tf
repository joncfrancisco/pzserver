# Two destinations, and the difference between them is the whole alerting design:
#
#   aws_sns_topic.alerts       -- EMERGENCIES ONLY. Email + the Discord relay. Something
#                                 is broken or expensive and a human needs to act.
#   aws_cloudwatch_log_group.audit
#                              -- EVERYTHING ELSE. Written directly by EventBridge, read
#                                 on demand by `bin/pz-audit.sh`. Pages nobody, ever.
#
# This used to be one destination. Every alarm transition, every instance start and stop,
# every budget threshold and every watchdog notice went to SNS, which has both an email
# subscription and the Discord relay on it. A completely healthy two-hour session
# produced roughly six emails and six Discord messages -- start, world load, idle
# warning, save, stop -- none of them actionable. An alert channel that behaves that way
# gets muted, and a muted channel cannot deliver "STOP FAILED -- it is still billing",
# which is the one message this system exists to send.
#
# So the test for putting something on the SNS topic is not "is this interesting?" but
# "would I want to be woken up?". Everything interesting still gets recorded; it just
# gets recorded somewhere that waits until you ask.
#
# Both live in the root module rather than inside modules/observability because the game
# server (which publishes to both) and observability (which wires alarms and EventBridge
# rules to them) each need the ARNs, and putting them in either module would make the two
# depend on each other.

resource "aws_sns_topic" "alerts" {
  name = "${local.name_prefix}-alerts"
  tags = { Name = "${local.name_prefix}-alerts" }
}

resource "aws_sns_topic_policy" "alerts" {
  arn = aws_sns_topic.alerts.arn

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowAwsServicesToPublish"
        Effect    = "Allow"
        Principal = { Service = ["cloudwatch.amazonaws.com", "events.amazonaws.com", "budgets.amazonaws.com"] }
        Action    = "sns:Publish"
        Resource  = aws_sns_topic.alerts.arn
        Condition = {
          StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        }
      },
    ]
  })
}

# Email is the backstop for the case the Discord mirror cannot cover: the bot host
# itself being the thing that is down.
#
# Note this subscription is exactly why the quiet/loud split had to happen at the topic
# and not inside the relay Lambda: an email subscriber receives everything published to
# the topic, so filtering downstream in the relay would have quietened Discord and left
# the inbox untouched.
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.budget_notification_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}

# --- The audit trail ----------------------------------------------------------------

# Written by EventBridge (alarm transitions, instance state changes) and by the watchdog
# on the box (shutdown reasons, idle warnings). Nothing here is delivered anywhere; it
# waits for `bin/pz-audit.sh` to come and read it.
#
# 90 days is chosen to outlive the question it usually gets asked -- "why did the server
# stop last week / what happened while I was away" -- without paying to store a year of
# routine start/stop chatter.
resource "aws_cloudwatch_log_group" "audit" {
  name              = "/pz/${var.stack}/audit"
  retention_in_days = 90

  tags = { Name = "${local.name_prefix}-audit" }
}

# EventBridge delivers to the log group directly, which needs a resource policy on the
# group rather than an execution role.
data "aws_iam_policy_document" "audit_delivery" {
  statement {
    effect  = "Allow"
    actions = ["logs:CreateLogStream", "logs:PutLogEvents"]

    # The ":*" suffix matters -- delivery targets log STREAMS inside the group, and a
    # policy naming only the group itself fails to deliver, silently.
    resources = ["${aws_cloudwatch_log_group.audit.arn}:*"]

    # events.amazonaws.com ONLY. Adding delivery.amazonaws.com (which appears in a lot of
    # vended-log examples) makes PutResourcePolicy fail with the wonderfully unhelpful
    # "Could not convert to persistable policy" -- CloudWatch Logs validates the service
    # principals it will accept here, and that is not one of them for EventBridge targets.
    principals {
      type        = "Service"
      identifiers = ["events.amazonaws.com"]
    }

    # Scoped to this account so the policy cannot be used as a confused deputy by another
    # account's event bus.
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

resource "aws_cloudwatch_log_resource_policy" "audit" {
  policy_name     = "${local.name_prefix}-audit-delivery"
  policy_document = data.aws_iam_policy_document.audit_delivery.json
}
