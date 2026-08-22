# DESIGN section 9. Least privilege, tag-conditioned, no wildcards on resources except
# where the API genuinely does not support scoping.

data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

resource "aws_iam_role" "game" {
  name = "${var.name_prefix}-gameserver-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ec2.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_instance_profile" "game" {
  name = "${var.name_prefix}-gameserver-profile"
  role = aws_iam_role.game.name
}

# Session Manager (the only interactive shell into this box) and SendCommand target.
resource "aws_iam_role_policy_attachment" "game_ssm_core" {
  role       = aws_iam_role.game.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_role_policy" "game" {
  name = "${var.name_prefix}-gameserver"
  role = aws_iam_role.game.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        # Backups out, and the ops tree in. No s3:DeleteObject: the instance can write
        # backups but cannot remove them, so retention is enforced entirely by the
        # bucket lifecycle policy, which this role also cannot touch.
        Sid    = "BackupWriteAndOpsRead"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:GetObject"]
        Resource = [
          "${var.backup_bucket_arn}/backups/*",
          "${var.backup_bucket_arn}/ops/*",
        ]
      },
      {
        Sid      = "BackupList"
        Effect   = "Allow"
        Action   = ["s3:ListBucket"]
        Resource = var.backup_bucket_arn
        Condition = {
          StringLike = { "s3:prefix" = ["backups/*", "ops/*"] }
        }
      },
      {
        # RCON and PZ admin passwords, read once at boot.
        Sid      = "ReadOwnSecrets"
        Effect   = "Allow"
        Action   = ["ssm:GetParameter", "ssm:GetParameters"]
        Resource = "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/*"
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
        # The watchdog's whole job. Namespace-conditioned so a compromised host cannot
        # scribble over anyone else's metrics in this shared account.
        Sid      = "PublishMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = "PZ" }
        }
      },
      {
        # Self-stop for the idle watchdog. Tag-conditioned to this stack's game server,
        # so this role cannot stop the bot host or anything else in the account.
        Sid      = "SelfStop"
        Effect   = "Allow"
        Action   = ["ec2:StopInstances"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:${var.region}:${data.aws_caller_identity.current.account_id}:instance/*"
        Condition = {
          StringEquals = {
            "ec2:ResourceTag/pz:role"  = "gameserver"
            "ec2:ResourceTag/pz:stack" = var.stack
          }
        }
      },
      {
        # Describe* cannot be resource-scoped. Read-only.
        Sid      = "DescribeSelf"
        Effect   = "Allow"
        Action   = ["ec2:DescribeInstances", "ec2:DescribeTags", "ec2:DescribeVolumes"]
        Resource = "*"
      },
      {
        # The watchdog announces "shutting down in 5 minutes" through SNS, which the bot
        # mirrors into Discord. Publish only, to this stack's topic only.
        Sid      = "PublishAlerts"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.alert_topic_arn
      },
    ]
  })
}

# --- DLM service role --------------------------------------------------------------

resource "aws_iam_role" "dlm" {
  name = "${var.name_prefix}-dlm-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "dlm.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "dlm" {
  name = "${var.name_prefix}-dlm"
  role = aws_iam_role.dlm.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ec2:CreateSnapshot",
          "ec2:CreateSnapshots",
          "ec2:DeleteSnapshot",
          "ec2:DescribeInstances",
          "ec2:DescribeVolumes",
          "ec2:DescribeSnapshots",
        ]
        Resource = "*"
      },
      {
        Effect   = "Allow"
        Action   = ["ec2:CreateTags"]
        Resource = "arn:${data.aws_partition.current.partition}:ec2:*::snapshot/*"
      },
    ]
  })
}
