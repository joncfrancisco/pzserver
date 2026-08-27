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
        # PutObjectTagging as well as PutObject: pz-backup.sh uploads with
        # `--tagging keep=short|long`, and supplying tags on a PutObject authorizes
        # against BOTH actions. Without it the upload fails outright rather than landing
        # untagged, which is the good failure -- an untagged archive would fall through to
        # the lifecycle floor instead of its intended retention.
        Sid    = "BackupWriteAndOpsRead"
        Effect = "Allow"
        Action = ["s3:PutObject", "s3:PutObjectTagging", "s3:GetObject"]
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
        # Host config and the RCON/admin passwords, read fresh on every boot by
        # pz-config-refresh.sh.
        #
        # Two things this statement has to get right, both of which failed the first
        # apply: GetParametersByPath is a distinct action from GetParameter(s), and it
        # authorizes against the PATH itself, not only the parameters under it. Hence
        # the bare `/config` ARN as well as its wildcard.
        #
        # It is scoped to `/config/*` plus two named secrets rather than the whole
        # prefix, and that is the point of the statement. `${var.ssm_prefix}/*` also
        # matches `${var.ssm_prefix}/discord/*` -- a wildcard does not stop at a slash --
        # so the old form let the game server read the Discord bot token, the audit and
        # main channel ids, both role ids and the alert webhook. It did exactly that on
        # every boot, because pz-config-refresh.sh swept the prefix recursively with
        # --with-decryption; CloudTrail shows seven KMS Decrypt calls under this role for
        # parameters it never used. A separate always-on bot host exists so that the box
        # strangers connect to does not hold the bot's credentials; this statement is
        # what makes that true at the IAM layer rather than by convention.
        #
        # Anything added under the prefix in future is unreachable from here until it is
        # named below -- which is the intended failure mode.
        Sid    = "ReadOwnConfigAndSecrets"
        Effect = "Allow"
        Action = ["ssm:GetParameter", "ssm:GetParameters", "ssm:GetParametersByPath"]
        Resource = [
          "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/config",
          "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/config/*",
          "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/rcon_password",
          "arn:${data.aws_partition.current.partition}:ssm:${var.region}:${data.aws_caller_identity.current.account_id}:parameter${var.ssm_prefix}/admin_password",
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
        # The watchdog's whole job. Namespace-conditioned so a compromised host cannot
        # scribble over anyone else's metrics in this shared account.
        #
        # BOTH namespaces are required, and the omission of CWAgent silently broke the
        # disk and memory alarms from day one: the watchdog publishes to PZ, but the
        # CloudWatch agent publishes to CWAgent and was getting 403 AccessDenied on
        # every flush. Because those two alarms treat missing data as notBreaching, they
        # sat at OK having never received a single datapoint -- the same "guardrail that
        # looks healthy while watching nothing" failure as the untagged budget.
        # ops/etc/cloudwatch-agent.json sets the CWAgent namespace; the alarms in
        # modules/observability read it. If either moves, this list moves with it.
        Sid      = "PublishMetrics"
        Effect   = "Allow"
        Action   = ["cloudwatch:PutMetricData"]
        Resource = "*"
        Condition = {
          StringEquals = { "cloudwatch:namespace" = ["PZ", "CWAgent"] }
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
        # The watchdog's EMERGENCY path only -- a crash loop, an unreachable server, or a
        # stop that failed and left the instance billing. Routine notices ("shutting down,
        # nobody online") go to the audit log below instead, because paging about the
        # normal end of every session is what made this channel ignorable.
        # Publish only, to this stack's topic only.
        Sid      = "PublishAlerts"
        Effect   = "Allow"
        Action   = ["sns:Publish"]
        Resource = var.alert_topic_arn
      },
      {
        # The watchdog's audit path: why a session ended, idle warnings, anything worth
        # being able to look up later but not worth interrupting anyone for.
        #
        # No logs:CreateLogGroup -- the group is created by Terraform in the root module,
        # and withholding this means a bug in the watchdog cannot litter the account with
        # log groups that nothing retains or bills for.
        Sid      = "WriteAuditLog"
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${var.audit_log_group_arn}:*"
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
