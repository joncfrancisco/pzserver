# SNS -> Lambda -> Discord webhook. The thing DESIGN section 15 describes and that was
# never built.
#
# "Everything routes to SNS; the bot subscribes and mirrors into Discord. Discord is the
# pager." In practice `alert_topic_arn` reached the bot's Config dataclass and was never
# read again -- no subscriber, no poller, no endpoint -- so every alarm, every instance
# state change, every Budgets threshold and the watchdog's own shutdown notice resolved to
# one email.
#
# WHY A LAMBDA AND NOT THE BOT. The bot was the design's answer, and it is the wrong one
# for the alert that matters most: a bot cannot page you about its own host being down.
# This path shares no fate with the bot host. It also needs no inbound port -- sg-bot has
# deliberately zero inbound rules, so the SNS HTTPS push the `sns:Subscribe` grant implied
# was never going to work anyway.
#
# Cost at this volume is effectively zero: a handful of invocations a week against a
# 1M-request free tier, and the log group is capped below.

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

data "archive_file" "relay" {
  type        = "zip"
  source_file = "${path.module}/src/relay.py"
  output_path = "${path.module}/.build/relay.zip"
}

resource "aws_iam_role" "relay" {
  name = "${var.name_prefix}-alert-relay-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Deliberately not AWSLambdaBasicExecutionRole: that grants logs:CreateLogGroup across the
# account, and this function needs exactly one group that Terraform already creates.
resource "aws_iam_role_policy" "relay" {
  name = "${var.name_prefix}-alert-relay"
  role = aws_iam_role.relay.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "Logs"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.relay.arn}:*"
      },
      {
        # The webhook URL only. Not the whole /pz/<stack>/ tree -- this function has no
        # business reading the Discord bot token or the RCON password, and scoping it to
        # one parameter is what keeps the blast radius of the relay at "can post in one
        # channel".
        Sid      = "ReadWebhook"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.webhook_parameter}"
      },
      {
        Sid      = "DecryptWebhook"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
    ]
  })
}

# Created explicitly so it has a retention policy. A Lambda-created group defaults to
# "never expire", which is a slow leak in a stack this size.
resource "aws_cloudwatch_log_group" "relay" {
  name              = "/aws/lambda/${var.name_prefix}-alert-relay"
  retention_in_days = 30
  tags              = { Name = "${var.name_prefix}-alert-relay" }
}

resource "aws_lambda_function" "relay" {
  function_name = "${var.name_prefix}-alert-relay"
  role          = aws_iam_role.relay.arn
  handler       = "relay.handler"
  runtime       = "python3.12"
  architectures = ["arm64"] # cheaper per ms, and the function has no native deps

  filename         = data.archive_file.relay.output_path
  source_code_hash = data.archive_file.relay.output_base64sha256

  # Generous for a single HTTPS POST, but the first invocation in a cold container also
  # does an SSM GetParameter.
  timeout     = 15
  memory_size = 128

  environment {
    variables = {
      WEBHOOK_PARAM = var.webhook_parameter
      STACK         = var.stack
    }
  }

  depends_on = [
    aws_iam_role_policy.relay,
    aws_cloudwatch_log_group.relay,
  ]

  tags = { Name = "${var.name_prefix}-alert-relay" }
}

resource "aws_lambda_permission" "sns" {
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.relay.function_name
  principal     = "sns.amazonaws.com"
  source_arn    = var.alert_topic_arn
}

resource "aws_sns_topic_subscription" "relay" {
  topic_arn = var.alert_topic_arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.relay.arn

  depends_on = [aws_lambda_permission.sns]
}

# Lambda retries an async invocation twice and then drops it. Two retries is the right
# number for a transient Discord 5xx; what is not acceptable is a silent drop, so failures
# go back to the topic -- which still has the email subscription on it. The pager failing
# is itself worth an email.
resource "aws_lambda_function_event_invoke_config" "relay" {
  function_name                = aws_lambda_function.relay.function_name
  maximum_retry_attempts       = 2
  maximum_event_age_in_seconds = 3600

  destination_config {
    on_failure {
      destination = var.alert_topic_arn
    }
  }
}

resource "aws_iam_role_policy" "relay_on_failure" {
  name = "${var.name_prefix}-alert-relay-onfailure"
  role = aws_iam_role.relay.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid      = "PublishFailureBack"
      Effect   = "Allow"
      Action   = ["sns:Publish"]
      Resource = var.alert_topic_arn
    }]
  })
}
