# The one SNS topic everything alerts through: CloudWatch alarms, EventBridge instance
# state changes, Budgets thresholds, and the watchdog's own "shutting down in 5 minutes"
# notice. The bot subscribes and mirrors all of it into Discord -- Discord is the pager.
#
# It lives in the root module rather than inside modules/observability because both the
# game server (which publishes to it) and observability (which wires alarms to it) need
# the ARN, and putting it in either one would make the two modules depend on each other.

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
resource "aws_sns_topic_subscription" "email" {
  for_each = toset(var.budget_notification_emails)

  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = each.value
}
