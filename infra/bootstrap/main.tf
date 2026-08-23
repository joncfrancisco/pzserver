# One-time bootstrap: the S3 bucket that holds the main stack's Terraform state.
#
# Deliberately a separate stack with LOCAL state (committed nowhere -- see .gitignore),
# so the stack that manages the game server can never destroy the bucket holding its own
# state file. Run this once, note the output, paste it into ../backend.tf, then forget
# about it.
#
#   terraform -chdir=infra/bootstrap init
#   terraform -chdir=infra/bootstrap apply

terraform {
  required_version = ">= 1.10"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"

  default_tags {
    tags = {
      project   = "pzserver"
      managedBy = "terraform"
      purpose   = "tfstate"
    }
  }
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket" "tfstate" {
  bucket = "pz-tfstate-${data.aws_caller_identity.current.account_id}"

  lifecycle {
    prevent_destroy = true
  }
}

# Versioning is the recovery path for a corrupted or truncated state file, which is the
# whole reason this bucket is worth being careful about.
resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# The same TLS-only policy the backups bucket has had since day one. The argument for it
# is made in modules/backups/main.tf's own comment -- "cheap, and the kind of thing that is
# annoying to retrofit once objects exist" -- and it simply was not applied here, which
# left the bucket holding every resource id, ARN and the full topology of the account as
# the less carefully protected of the two.
resource "aws_s3_bucket_policy" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "DenyInsecureTransport"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource = [
        aws_s3_bucket.tfstate.arn,
        "${aws_s3_bucket.tfstate.arn}/*",
      ]
      Condition = {
        Bool = { "aws:SecureTransport" = "false" }
      }
    }]
  })

  # A bucket policy applied before the public access block can be rejected by
  # BlockPublicPolicy evaluation ordering. Cheap to make explicit.
  depends_on = [aws_s3_bucket_public_access_block.tfstate]
}

# Versioning above is the recovery path for a corrupted state file, and it is worth
# keeping -- but unbounded it means every apply's state, forever. Ninety days is far more
# history than any recovery has ever needed, and unlike the backups bucket these
# noncurrent versions are real: the state file is written to the SAME key every time, so
# every apply creates one.
resource "aws_s3_bucket_lifecycle_configuration" "tfstate" {
  bucket     = aws_s3_bucket.tfstate.id
  depends_on = [aws_s3_bucket_versioning.tfstate]

  rule {
    id     = "expire-old-state-versions"
    status = "Enabled"

    filter {}

    # No `expiration` block. The CURRENT state version must never expire -- that is the
    # live state file, and deleting it is how you orphan an entire stack.
    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

output "bucket" {
  description = "Paste this into ../backend.tf as `bucket`."
  value       = aws_s3_bucket.tfstate.id
}
