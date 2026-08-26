# DESIGN section 9, pz-bot-role.
#
# What is deliberately ABSENT is the interesting part: no ec2:TerminateInstances, no
# s3:DeleteObject, no s3:PutLifecycleConfiguration, no ssm:PutParameter. A leaked
# Discord token buys an attacker an expensive month, not a destroyed world.

resource "aws_iam_role" "bot" {
  name = "${var.name_prefix}-bot-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "bot" {
  name = "${var.name_prefix}-bot-profile"
  role = aws_iam_role.bot.name
}

resource "aws_iam_role_policy_attachment" "bot_ssm_core" {
  role       = aws_iam_role.bot.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "bot" {
  name = "${var.name_prefix}-bot"
  role = aws_iam_role.bot.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "LifecycleOnOwnGameServer"
        Effect   = "Allow"
        Action   = ["ec2:StartInstances", "ec2:StopInstances"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/pz:stack" = var.stack
            "ec2:ResourceTag/pz:role"  = "gameserver"
          }
        }
      },
      {
        # Describe* does not support resource-level permissions. Read-only, and this is
        # a shared account, so the bot can see other people's instances -- it just
        # cannot touch them.
        Sid      = "DescribeState"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeInstanceStatus", "ec2:DescribeTags"]
        Resource = "*"
      },
      {
        Sid      = "SendCommandToOwnGameServer"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        # `ssm:resourceTag`, not `ec2:ResourceTag`. Condition keys are populated per the
        # calling service's action namespace, not per the resource type -- `ec2:*`
        # actions (StartInstances/StopInstances above) get `ec2:ResourceTag`, but calling
        # `ssm:SendCommand` against this same EC2 instance ARN only populates
        # `ssm:resourceTag`. Getting this wrong doesn't warn or degrade; it denies the
        # call outright with no visible connection to the tag condition at all.
        Condition = {
          StringEquals = {
            "ssm:resourceTag/pz:stack" = var.stack
            "ssm:resourceTag/pz:role"  = "gameserver"
          }
        }
      },
      {
        # The documents the bot may invoke are enumerated, not wildcarded (issue #29).
        # AWS-RunShellScript is deliberately absent: its `commands` parameter has no
        # IAM-expressible constraint, so granting it would make every other
        # `allowedPattern` below decorative. pzbot's call sites all moved onto these
        # scoped documents in joncfrancisco/pzbot#16; this is the phase-3 removal that
        # actually closes the gap the issue describes.
        Sid      = "SendCommandDocuments"
        Effect   = "Allow"
        Action   = ["ssm:SendCommand"]
        Resource = var.ssm_document_arns
      },
      {
        Sid      = "ReadCommandResults"
        Effect   = "Allow"
        Action   = ["ssm:GetCommandInvocation", "ssm:ListCommandInvocations"]
        Resource = "*"
      },
      {
        Sid    = "ReadOwnConfigAndSecrets"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}",
          "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/*",
        ]
      },
      {
        Sid      = "DecryptOwnSecrets"
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = "*"
        Condition = {
          StringEquals = { "kms:ViaService" = "ssm.${var.region}.amazonaws.com" }
        }
      },
      {
        # `/pz backup list` inspects; it never writes and never deletes.
        Sid      = "ListBackups"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.backup_bucket_arn
        Condition = {
          StringLike = { "s3:prefix" = ["backups/*"] }
        }
      },
      {
        Sid      = "ReadBackups"
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${var.backup_bucket_arn}/backups/*"
      },
      {
        Sid      = "ReadMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:GetMetricStatistics", "cloudwatch:GetMetricData", "cloudwatch:ListMetrics"]
        Resource = "*"
      },
      {
        # The PZ/BotAlive heartbeat, published from the presence loop the bot already
        # runs. PutMetricData has no resource-level permissions at all, so the namespace
        # condition is the only way to scope it -- without it this would be a grant to
        # write any metric in the account.
        Sid      = "PublishOwnHeartbeat"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "PZ" }
        }
      },
      {
        # `/pz cost`. Cost Explorer has no resource-level permissions.
        Sid      = "ReadCost"
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = "*"
      },
      # NO sns:Subscribe. It was granted unconditionally on the topic, so a compromised
      # bot could have subscribed an attacker-controlled HTTPS endpoint and received every
      # alarm, state change and budget notification the stack emits -- a quiet, persistent
      # read on the infrastructure's telemetry.
      #
      # It was also never used: it was the vestige of DESIGN section 15's plan to have the
      # bot mirror SNS into Discord, which was never built and could not have worked
      # anyway (sg-bot has zero inbound rules, so an SNS HTTPS push has nowhere to land).
      # modules/alert-relay does that job now, out of band, so the bot has no reason to
      # touch the topic at all and the statement is gone rather than merely conditioned.
    ]
  })
}
