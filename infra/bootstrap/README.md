# Bootstrap: Terraform state bucket

Run once, before anything else:

```bash
terraform -chdir=infra/bootstrap init
terraform -chdir=infra/bootstrap apply
```

It creates `pz-tfstate-020949219706` (versioned, encrypted, private) and prints the
name. That name is already filled into [`../backend.tf`](../backend.tf); if you are
deploying into a different account, update it there.

State for *this* stack is local and intentionally not committed — it describes one
bucket, and re-creating it is `terraform import` on a name you can guess. State for the
*main* stack lives in the bucket this creates, locked with native S3 locking
(`use_lockfile = true`, Terraform ≥ 1.10), which is why there is no DynamoDB table
anywhere in this repo.
