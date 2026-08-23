# Tier 2 of the three backup tiers (DESIGN section 11): S3 objects.
# T1 is a local rolling archive on the data volume; T3 is DLM snapshots, defined in
# modules/game-server alongside the volume it snapshots.

resource "aws_s3_bucket" "backups" {
  bucket = "${var.name_prefix}-backups-${var.account_id}"

  # One of exactly two resources in this stack whose loss is unrecoverable (the other is
  # the EBS data volume). A `terraform destroy` will FAIL here by design -- see
  # DEPLOY.md "Tearing the stack down" for the deliberate two-step.
  lifecycle {
    prevent_destroy = true
  }

  tags = { Name = "${var.name_prefix}-backups" }
}

# Versioning is what makes an overwrite recoverable. It also means a delete leaves a
# marker rather than removing bytes, which is why the instance role has no DeleteObject
# and retention is enforced only by the lifecycle rules below.
resource "aws_s3_bucket_versioning" "backups" {
  bucket = aws_s3_bucket.backups.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "backups" {
  bucket = aws_s3_bucket.backups.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "backups" {
  bucket                  = aws_s3_bucket.backups.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Retention. THE THING THIS HAS TO ACTUALLY DO IS DELETE.
#
# The previous version of this rule had a transition to Glacier IR and a
# `noncurrent_version_expiration`, and no `expiration` for current versions. Because
# pz-backup.sh writes every archive to a unique timestamped key, objects are never
# overwritten and noncurrent versions essentially never exist -- so the only expiry rule
# in the configuration matched almost nothing, and current versions lived forever. At the
# 30-minute cadence that is ~240 archives a month, growing with the world, against an
# INFRA.md budget line of "~5 GB, ~$0.15" describing a steady state the bucket would never
# reach.
#
# Retention is split by what the archive is FOR, which is why pz-backup.sh now tags each
# object `keep=short|long` on upload.
#
# The `expire-untagged-backups` rule below DOES overlap the two tagged rules, and that is
# intentional rather than an oversight. It cannot be written as "objects without a keep
# tag" -- S3 lifecycle filters can match a tag, never its absence -- so it is written as a
# floor over the whole prefix instead. Where it overlaps, S3 resolves competing expiration
# actions by taking the SOONEST, so a keep=short object still goes at 21 days and only
# genuinely untagged objects (uploaded by hand, or by a pz-backup.sh predating this
# change) fall through to 180. The failure mode it removes -- "untagged means immortal" --
# is the exact bug this block exists to fix, so a backstop that is too generous beats a
# gap that is unbounded.
#
# No Glacier IR transition at all. It carries a 128 KB minimum billable object size and a
# 90-day minimum storage duration billed as an early-delete charge, both of which are
# actively wrong for objects this small-lived: everything here is now deleted before 90
# days, so a transition would only ever add cost.
resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket     = aws_s3_bucket.backups.id
  depends_on = [aws_s3_bucket_versioning.backups]

  # The 30-minute churn. Six of these are already on the data volume (T1) and a daily DLM
  # snapshot covers the same ground; three weeks of half-hourly history in S3 is well past
  # the point of diminishing returns for a game world.
  rule {
    id     = "expire-scheduled-backups"
    status = "Enabled"

    # Scoped to the backups/ prefix, not the whole bucket. Same discipline as foodblog's
    # `expire-old-db-backups` rule: a blanket rule is how you silently delete the one
    # thing you were keeping. The ops/ tree lives in this bucket too.
    filter {
      and {
        prefix = "backups/"
        tags   = { keep = "short" }
      }
    }

    expiration {
      days = 21
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # prestop, prerestore and manual. These are the archives you actually reach for -- the
  # last good state before a stop, the "undo" for a restore you regret, and whatever
  # someone deliberately labelled before trying something. They are also rare, so a long
  # retention costs almost nothing.
  rule {
    id     = "expire-milestone-backups"
    status = "Enabled"

    filter {
      and {
        prefix = "backups/"
        tags   = { keep = "long" }
      }
    }

    expiration {
      days = 180
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # The floor. See the header comment: this overlaps the two rules above on purpose,
  # because "has no keep tag" is not expressible as a lifecycle filter and soonest-wins
  # makes the overlap harmless.
  rule {
    id     = "expire-untagged-backups"
    status = "Enabled"

    filter {
      prefix = "backups/"
    }

    expiration {
      days = 180
    }

    noncurrent_version_expiration {
      noncurrent_days = 30
    }
  }

  # Bucket-wide, and the one rule that should be: a half-finished multipart upload is
  # never worth keeping, whatever prefix it is under.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

# Deny any request that is not TLS. Cheap, and the kind of thing that is annoying to
# retrofit once objects exist.
resource "aws_s3_bucket_policy" "backups" {
  bucket = aws_s3_bucket.backups.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.backups.arn,
        "${aws_s3_bucket.backups.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })
}
