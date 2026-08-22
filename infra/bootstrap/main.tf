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

output "bucket" {
  description = "Paste this into ../backend.tf as `bucket`."
  value       = aws_s3_bucket.tfstate.id
}
