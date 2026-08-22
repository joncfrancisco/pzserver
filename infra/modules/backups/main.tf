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

resource "aws_s3_bucket_lifecycle_configuration" "backups" {
  bucket     = aws_s3_bucket.backups.id
  depends_on = [aws_s3_bucket_versioning.backups]

  rule {
    id     = "pz-backup-tiering"
    status = "Enabled"

    # Scoped to the backups/ prefix, not the whole bucket. Same discipline as foodblog's
    # `expire-old-db-backups` rule: a blanket rule is how you silently delete the one
    # thing you were keeping.
    filter {
      prefix = "backups/"
    }

    transition {
      days          = 30
      storage_class = "GLACIER_IR"
    }

    noncurrent_version_expiration {
      noncurrent_days = 180
    }

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
