# State lives in S3 with native S3 locking (no DynamoDB table). The bucket is created
# by the separate one-time stack in ./bootstrap -- deliberately NOT by this stack, so
# that this stack can never destroy the thing holding its own state.
#
# Fill in `bucket` with the name printed by `terraform -chdir=infra/bootstrap output`,
# then run `terraform init`.
terraform {
  backend "s3" {
    bucket       = "pz-tfstate-020949219706"
    key          = "pzserver/prod.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }
}
