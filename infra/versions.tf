terraform {
  # 1.10+ is required for native S3 state locking (`use_lockfile`), which is what
  # lets us skip the DynamoDB lock table entirely. See backend.tf.
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.6"
    }
  }
}

provider "aws" {
  region = var.region

  # Account 020949219706 is SHARED (foodblog, symfal.com, other IAM users). Every
  # resource this stack creates carries these tags so that (a) the Budgets filter in
  # modules/observability matches exactly this stack and nothing else, and (b) a human
  # reading the console can tell at a glance what belongs to the game server.
  default_tags {
    tags = {
      "pz:stack"  = var.stack
      "project"   = "pzserver"
      "managedBy" = "terraform"
      "repo"      = "joncfrancisco/pzserver"
    }
  }
}
