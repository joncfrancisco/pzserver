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
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/pz:stack" = var.stack
            "ec2:ResourceTag/pz:role"  = "gameserver"
          }
        }
      },
      {
        # The documents the bot may invoke are enumerated, not wildcarded. There is no
        # path from a Discord message to arbitrary shell on the game server.
        Sid    = "SendCommandDocuments"
        Effect = "Allow"
        Action = ["ssm:SendCommand"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ssm:${var.region}::document/AWS-RunShellScript",
        ]
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
        # `/pz cost`. Cost Explorer has no resource-level permissions.
        Sid      = "ReadCost"
        Effect   = "Allow"
        Action   = ["ce:GetCostAndUsage"]
        Resource = "*"
      },
      {
        Sid      = "SubscribeToAlerts"
        Effect   = "Allow"
        Action   = ["sns:Subscribe", "sns:Receive", "sns:GetTopicAttributes"]
        Resource = var.alert_topic_arn
      },
    ]
  })
}
