# Terraform — aegis-enclave

This directory holds the AWS deployment as Terraform code. **It is `plan`-only for the case-study deliverable** (see ADR-0015). No state is committed; no apply is performed against a real account during the cycle.

## What's here (current state)

| File | Status | Purpose |
|---|---|---|
| `main.tf` | **Stub** with provider + commented community-module references | Establishes the FinOps + community-module patterns; Phase 1 build fills in the modules |
| `variables.tf` | Stub with named variables and defaults | Inputs the modules will consume |
| `outputs.tf` | Stub (commented, awaiting modules) | Will expose endpoint IDs, VPC ID, RDS endpoint when modules are wired up |

## What it demonstrates

Even as a stub, this directory shows three production-grade patterns:

1. **FinOps tagging** — `default_tags` in the provider block ensures every resource is tagged for cost attribution: Project, Environment, CostCenter, Owner. Cost dashboards aggregate on these tags without per-resource bookkeeping.
2. **Community-module discipline (ADR-0016)** — every module reference uses `terraform-aws-modules/*` rather than hand-rolling resources. The version pin (`~> 5.x`) absorbs provider breaking changes.
3. **Single-region multi-AZ posture (ADR-0007 + ADR-0009)** — `azs` spans two AZs in `eu-central-1`; `multi_az = true` on RDS is the free architectural credit that supports the RPO target in ADR-0008.

## How to plan (no apply)

```bash
make tf-init     # terraform init -backend=false (no remote state for case-study)
make tf-plan     # terraform plan -var-file=terraform.tfvars.example
```

The plan output is captured into `docs/deployment_guide.md` during Phase 1 build. The brief explicitly accepts a deployment guide as sufficient (Task 3 — § "A list of clear instructions would suffice"); applying real infrastructure is not the deliverable.

## Cross-cloud migration

Migration to alternative clouds (e.g., IONOS — see ADR-0005) is delivered as an agent-executable runbook in `docs/migration_runbook.md`, not as parallel Terraform code per cloud. The mapping table at the top of that runbook is the only destination-specific artifact; the migration spec format is invariant across destinations.
