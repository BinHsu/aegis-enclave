# ADR-0025: Terraform state backend — S3 + DynamoDB lock, separately bootstrapped

## Status
Accepted (2026-04-25)

## Context
Phase 1 of the deliverable runs `terraform plan -backend=false` only (per ADR-0015) — no state is ever written. The Phase-2 ambition (apply from the operator's AWS account, reach the service through Client VPN) requires a real state backend, and the choice cannot be deferred without re-doing the topology later.

The two questions are: **where does state live**, and **how is concurrent apply prevented**?

For state location, AWS-native options reduce to two:

| Option | Pros | Cons |
|---|---|---|
| **S3** | Versioned, encrypted at rest, region-stable. Native Terraform support. Pennies-per-month at this scale. | No native locking — needs DynamoDB sidecar. |
| **Terraform Cloud / HCP Terraform** | Built-in lock, UI, state history, run logs. | $20/user/month after free tier; introduces a third-party dependency on what is otherwise a pure-AWS deliverable. |

For lock prevention with S3, the established pattern is a **DynamoDB lock table**. S3 itself has no atomic compare-and-swap primitive that Terraform can use; DynamoDB's `ConditionExpression` provides exactly that.

## Decision
Use **S3 + DynamoDB lock** as the state backend. Provision both via a **separate bootstrap module** (`terraform/bootstrap/`) that runs with the local backend, then have `terraform/main.tf` declare the S3 backend pointing at that module's outputs.

**Backend declaration in `terraform/main.tf`:**

```hcl
terraform {
  required_version = ">= 1.5.0"
  required_providers { ... }

  backend "s3" {
    bucket         = "aegis-enclave-tfstate-${random}"
    key            = "main/terraform.tfstate"
    region         = "eu-central-1"
    encrypt        = true
    dynamodb_table = "aegis-enclave-tflock"
  }
}
```

**Bootstrap module (`terraform/bootstrap/main.tf` — runs once, with local backend):**

```hcl
resource "random_id" "tfstate_suffix" {
  byte_length = 4
}

resource "aws_s3_bucket" "tfstate" {
  bucket = "aegis-enclave-tfstate-${random_id.tfstate_suffix.hex}"
}

resource "aws_s3_bucket_versioning" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "tfstate" {
  bucket = aws_s3_bucket.tfstate.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_public_access_block" "tfstate" {
  bucket                  = aws_s3_bucket.tfstate.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_dynamodb_table" "tflock" {
  name         = "aegis-enclave-tflock"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "LockID"

  attribute {
    name = "LockID"
    type = "S"
  }

  point_in_time_recovery { enabled = true }
}

output "tfstate_bucket" { value = aws_s3_bucket.tfstate.id }
output "tflock_table"   { value = aws_dynamodb_table.tflock.name }
```

## Why a separate bootstrap module — the chicken-and-egg problem

The S3 bucket holding state cannot itself live in the state file, because it must exist *before* the state backend can be initialised. The standard pattern across the industry is:

1. **One-time:** `cd terraform/bootstrap && terraform init && terraform apply` — creates the bucket + lock table using the **local** backend. State lives in `terraform/bootstrap/terraform.tfstate` (kept locally and gitignored).
2. **Ongoing:** `cd terraform && terraform init` — picks up the S3 backend declared in `main.tf`. State for the main composition lives in S3.
3. **Bootstrap is essentially "set and forget"** — it changes when bucket naming or lock table config changes, which is rare. The local state file is small (two resources); a one-line note in `terraform/bootstrap/README.md` advises operators to commit the local state into a personal vault if disaster-recovery of the bucket name is needed.

This matches how AWS Architecture Center, Gruntwork's Terragrunt patterns, and most `terraform-aws-modules` examples bootstrap state.

## DynamoDB lock — the mechanics

When `terraform apply` starts, Terraform writes a single item to the lock table:

```
{
  "LockID": "<bucket>/<key>-md5",
  "Info": "<who, when, op-id>",
  ...
}
```

The write uses `PutItem` with `ConditionExpression: "attribute_not_exists(LockID)"`. If the item already exists (another `apply` is in progress), the write fails atomically and Terraform shows:

> Error acquiring the state lock
> Lock Info: <details of the lock holder>

When `apply` finishes (success or failure), Terraform issues `DeleteItem` to release. If a process crashes mid-apply, the lock remains stuck — Terraform provides `terraform force-unlock <lock-id>` to release it manually after confirming no apply is actually running.

**This is the only thing the DynamoDB table does.** It is not a state store, not a cache, not a queue. One row per active apply, deleted when the apply ends.

## Cost model

| Resource | Mode | Monthly cost at case-study scale |
|---|---|---|
| S3 bucket (versioned, AES256) | Standard | < $0.01 (state file is < 1 MB; versions accumulate slowly) |
| S3 lifecycle rules | Optional | $0 — not added; state versions are kept |
| DynamoDB lock table | On-demand (`PAY_PER_REQUEST`) | < $0.01 (a few writes/reads per apply, free tier covers it) |
| **Total** | | **effectively $0/month** |

Compare: Terraform Cloud Free tier covers up to 5 users with managed state, but adds a third-party dependency. HCP Terraform Standard ($20/user/month) is overkill at this scale.

## Single-user vs multi-user lock necessity

Strictly speaking, a one-person operator running `terraform apply` from one laptop does not race against themselves and does not need the lock. The DynamoDB lock becomes load-bearing the moment **either of these is true**:

- **CI runs `terraform plan` or `apply`** — it's a separate process from the laptop apply.
- **A second operator joins** — even if they only run `plan`, plans read state and want a consistent snapshot.

Because both of those conditions are inevitable in any "real" deployment (and the Phase-2 ambition explicitly contemplates CI plan jobs per ADR-0023), the lock is not optional in practice. The cost of including it now (one resource, one config block, < $0.01/month) is below the cost of debugging a corrupted state file later.

## Consequences

**Positive:**
- Phase-2 apply has a real state backend with concurrency safety.
- Versioning + encryption + public-access block by default — meets `aws-foundations` security baseline.
- DynamoDB on-demand pricing means the lock table costs nothing when idle.
- Bootstrap module is small and self-contained — local state for two resources is acceptable.

**Negative:**
- Two-stage Terraform initialisation. New operators must understand "first bootstrap, then main."
- Bucket name is not deterministic (uses `random_id` suffix) — operators must capture the output name and write it back into `main.tf`'s backend block (or into a `backend.hcl` partial-config file). Friction, but documented.
- DynamoDB lock can stick if a process crashes — operators must know `terraform force-unlock` exists.

## Alternatives considered

**A. S3-only without DynamoDB lock.** Works for single-user, breaks the moment CI runs `plan`. **Rejected** — the cost difference is < $0.01/month and the failure mode (state corruption) is silent and expensive to recover from.

**B. Terraform Cloud / HCP Terraform.** Built-in lock, UI, run history. **Rejected** for case-study scope — adds a third-party dependency on what is otherwise pure-AWS, and the deliverable's value is in the AWS architecture not the SaaS chosen.

**C. Single combined module — bucket + lock + main composition all in one apply.** Cannot work: backend cannot reference resources in its own state file (Terraform errors at init time). **Rejected** — chicken-and-egg.

**D. Bootstrap via raw AWS CLI / CloudFormation, then point Terraform at the result.** Avoids the second Terraform module, but introduces a second tool. **Rejected** — keeping all infra-as-code in Terraform is cleaner; the bootstrap module's local-state burden is small.

## Implementation hooks

This ADR is config-only; the changes land alongside the Phase-2 apply work, not in the case-study deliverable cycle (ADR-0015 still binds Phase 1).

When Phase-2 apply happens:

1. Create `terraform/bootstrap/` directory with `main.tf` (above), `variables.tf`, `outputs.tf`.
2. Run `cd terraform/bootstrap && terraform init && terraform apply` — capture the bucket name + lock table name from outputs.
3. Add the `backend "s3"` block to `terraform/main.tf` populated with the captured names.
4. Run `cd terraform && terraform init` — Terraform prompts to migrate state (if any) from local to S3; for a fresh apply, state starts empty in S3.
5. Update `scripts/ts_apply.sh` to verify backend is configured (a new pre-flight check).

## Related
- ADR-0015 — Phase-1 plan-only stance (this ADR's existence is a Phase-2 scope shift)
- ADR-0023 — deferred auto-scaling (Phase-2 ambition that requires a state backend to be real)
- ADR-0024 — VPN cert provisioning (Phase-2 sibling — both unblock real deployment)
