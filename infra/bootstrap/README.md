# Bootstrap — Terraform backend infrastructure

Creates the S3 state buckets and the DynamoDB lock table that `environments/dev`
and `environments/prod` use as their remote backend.

## Why this is a separate root

Terraform can't store its state in a bucket that doesn't exist yet. That's the
chicken-and-egg: the backend has to be created before any root can use it.

So this root **has no `backend` block** and keeps local state. It's the one
place in the repo where that's correct, not an oversight.

Run it once per AWS account. After that it rarely changes.

## Usage

```bash
cd infra/bootstrap
terraform init          # no -backend-config; local state on purpose
terraform plan
terraform apply
terraform output        # the values to paste into each backend.hcl
```

No `tf.sh` wrapper and no `.env` here — every variable has a working default,
so plain `terraform` is enough. The wrapper exists in the environment roots to
load their large `TF_VAR_*` sets; this root has three variables.

## What it creates

| Resource | Name |
|---|---|
| S3 bucket (dev state) | `squatwolf-alphapro-dev-tfstate` |
| S3 bucket (prod state) | `squatwolf-alphapro-prod-tfstate` |
| DynamoDB table (locks) | `squatwolf-alphapro-terraform-locks` |

Both buckets get versioning, AES256 encryption, and full public-access blocking.
Versioning is the one that matters most — it's what lets you recover from a
corrupted or truncated state write.

The lock table's partition key is `LockID` (String). Terraform's S3 backend
hardcodes that name; a different one silently fails to lock.

One table serves both environments — the lock key includes the bucket name, so
dev and prod locks can't collide.

## Its own state

Local, and git-ignored via `*.tfstate`. Two consequences worth knowing:

- **Don't re-apply after losing it.** You'll get "already exists" errors. Use
  `terraform import` on the three resources instead.
- **Every resource here has `prevent_destroy`.** Destroying a state bucket
  orphans the record of every resource that environment manages, so a stray
  `destroy` is blocked. Decommissioning means removing that block deliberately.

If you'd rather not keep local state at all, you can migrate this root's state
into the bucket it just created: add a `backend "s3" {}` block after the first
apply and run `terraform init -migrate-state`. It works, it's just mildly
self-referential.

## Order of operations

1. `apply` this root — creates buckets + table
2. In each environment: `cp backend.hcl.example backend.hcl`
3. Uncomment `backend "s3" {}` in that environment's `versions.tf`
4. `./tf.sh init -backend-config=backend.hcl`
