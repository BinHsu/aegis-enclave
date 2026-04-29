# Scaling Runbook — Single-Region → Multi-Region (AWS)

> **Forward-looking spec.** Spec-grade, not code-grade. This document describes an agent-executable plan for moving the cloud composition from single-region to multi-region active-active. The architectural target is **DynamoDB Global Tables active-active** per [ADR-0042](ADR/0042-dynamodb-global-tables-greenfield-multi-region.md).

> Forkers carrying an existing PostgreSQL/RDS investment may instead choose the Aurora migration path documented in [ADR-0040](ADR/0040-multi-region-frankfurt-ireland-route53.md) — alternative path, not the canonical one.

## When to run this

The single-region per-region 3-AZ posture (per [ADR-0007](ADR/0007-single-region-multi-az.md) + [ADR-0008](ADR/0008-reliability-targets-slo-rto-rpo.md) Tier 2 calibration) is sufficient for the SLO target of 15 min RTO. Multi-region tightens RTO further at ~2× cost and 2.5–3× cognitive complexity. Run this runbook when one of the following triggers is met:

1. **Workload concurrency** exceeds single-region capacity — parallel demand spikes that an autoscaling single region cannot serve.
2. **Globally distributed clients** require locally-terminated network paths — e.g., a second client population on a different continent where cross-Atlantic round-trips break latency or jurisdiction assumptions.
3. **Regulatory geographic redundancy** is explicitly required — auditor sign-off needed before applying.
4. **Production maturity gate** — quality-of-engineering signal (DR drill cadence, region-failure tested) is required by the operator's compliance posture.

If none apply, single-region 3-AZ is sufficient. Cost roughly doubles, cognitive complexity 2.5–3×, and an untested failover path is worse than no failover path — so this runbook also requires a **quarterly drill**.

## Format

Every step in this runbook follows the same six-field schema established in [ADR-0012](ADR/0012-migration-runbook-agent-executable.md). The schema makes each step both **agent-executable** (an AI coding agent can read the structured fields and act) and **human-reviewable** (each step has a verification command and a rollback path).

| Field | Meaning |
|---|---|
| `precondition` | What must be true before running this step |
| `action` | The intent of the step, described declaratively |
| `verify_cmd` | A command that confirms the step succeeded |
| `expected_output` | What the verify_cmd output looks like on success |
| `on_failure` | Rollback action or escalation path |
| `human_gate` | `true` when the step is irreversible or destructive |

## Service mapping (single-region → multi-region active-active)

| Single-region resource | Multi-region answer | Mechanism / Notes |
|---|---|---|
| `module "vpc"` (one VPC in `eu-central-1`) | Two VPCs (one per region), non-overlapping CIDRs | Provider aliases `aws.primary` / `aws.secondary`; instantiate `module "vpc"` twice. Non-overlapping CIDRs preserve future VPC peering / Transit Gateway option. |
| `aws_dynamodb_table.executions` (single-region) | DynamoDB Global Tables with `replica` blocks for both regions | Native multi-master multi-region; ~1 s replication lag; no promotion step on failover. |
| `module "ecs"` (one cluster) | Two ECS Fargate clusters (one per region) | Both clusters serve traffic via region-local ALB; Route53 weighted routing in front. |
| `module "alb"` (one internal) | Two internal ALBs (one per region) | Each region has its own internal ALB; cross-region routing via Route53. |
| `aws_ec2_client_vpn_endpoint` (one) | Two endpoints (one per region) | Endpoint is regional per [ADR-0006](ADR/0006-vpn-three-tier-story.md); operators have two `.ovpn` profiles. |
| `module "ecr"` (one repo) | One repo + cross-region replication | ECR `replication_configuration` replicates images to secondary region's ECR. |
| `aws_sqs_queue` (region-local) | Two SQS queues (region-local) | No cross-region SQS bridging — messages stay in originating region for processing locality. |
| `aws_elasticache_serverless_cache` (one) | Two ElastiCache Serverless instances | Region-local; bootstrap re-seeds in each region independently. |
| Route53 (not in current composition) | Public hosted zone + weighted routing + health checks | New addition — single source of routing truth across regions. |

The cost shape changes meaningfully: monthly bill scales roughly **2×** (per ADR-0042 — both regions provisioned at same baseline; DDB Global Tables replication ~$0.10–0.30/month replication cost). Cognitive complexity scales **2.5–3×** (replication-lag reasoning, DNS propagation timing, cross-region drill scheduling). Operations gains a hard requirement: a **quarterly DR drill**, otherwise the failover path is untested.

## Provider configuration (the structural change)

The single biggest infrastructure pattern enabling this runbook is **Terraform provider aliases**. The same module compositions run against both regions; only the alias changes per instantiation:

```hcl
provider "aws" {
  alias  = "primary"
  region = var.primary_region   # eu-central-1
  default_tags { tags = local.tags }
}

provider "aws" {
  alias  = "secondary"
  region = var.secondary_region # eu-west-1
  default_tags { tags = local.tags }
}

# Each module instantiation specifies which provider:
module "vpc_primary" {
  providers = { aws = aws.primary }
  # ... rest as before
}

module "vpc_secondary" {
  providers = { aws = aws.secondary }
  # ... rest as before
}
```

This is also why the existing composition's reliance on `terraform-aws-modules/*` community modules pays off here: the same module call works against either provider alias without modification.

## Track — Multi-region active-active rollout (estimated 7 steps)

Single-track because the same team owns the AWS estate end-to-end; Client VPN endpoints simply expand from one to per-region with Route53 weighted routing in front.

### Step 1 — Add provider aliases and `var.secondary_region`

| Field | Value |
|---|---|
| `precondition` | Existing single-region Terraform composition plans cleanly; `terraform validate` passes. |
| `action` | Edit `terraform/main.tf` to add `provider "aws"` blocks with `alias = "primary"` and `alias = "secondary"`. Add `secondary_region` variable (default `eu-west-1`). Existing un-aliased provider becomes the primary alias; no module call is migrated yet. |
| `verify_cmd` | `terraform fmt -check && terraform validate` |
| `expected_output` | No formatting drift; `Success! The configuration is valid.` |
| `on_failure` | Revert the edit (purely additive). |
| `human_gate` | `false` — configuration-only change with no resource impact. |

### Step 2 — Instantiate VPC, security groups, VPC endpoints in secondary region

| Field | Value |
|---|---|
| `precondition` | Step 1 complete; provider aliases declared. |
| `action` | Add `module "vpc_secondary"` (and matching SG modules) using `providers = { aws = aws.secondary }`. Mirror the CIDR shape using a non-overlapping range (e.g., `10.1.0.0/16` for the secondary if primary is `10.0.0.0/16`). Mirror VPC endpoints (8 interface + 1 gateway). |
| `verify_cmd` | `terraform plan -out=secondary-vpc.plan` and inspect the plan output. |
| `expected_output` | Plan shows new resources scoped to `eu-west-1`; primary-region resources show no changes. |
| `on_failure` | Discard the plan file; remove the new module blocks. No state has been modified. |
| `human_gate` | `false` — net-new resources in an empty region; reversible. |

### Step 3 — Promote DynamoDB table to Global Tables (add secondary replica)

| Field | Value |
|---|---|
| `precondition` | Step 1 complete; secondary VPC ready (Step 2). |
| `action` | Add `replica` block to `aws_dynamodb_table.executions` referencing the secondary region. DynamoDB performs the initial cross-region snapshot + ongoing replication automatically. **No data migration required** — Global Tables wraps the existing single-region table. |
| `verify_cmd` | `aws dynamodb describe-table --table-name aegis-enclave-executions --region eu-west-1` |
| `expected_output` | Replica reports `ReplicaStatus: ACTIVE` with `~1s` cross-region replication latency. |
| `on_failure` | Remove the `replica` block; DynamoDB detaches the secondary replica. The primary continues serving in eu-central-1. |
| `human_gate` | `false` — DynamoDB Global Tables transition is non-disruptive (existing reads + writes in primary continue uninterrupted). |

### Step 4 — Provision ECS Fargate cluster + internal ALB in secondary region

| Field | Value |
|---|---|
| `precondition` | Steps 1–3 complete; cross-region ECR replication configured + image present in secondary region's ECR. |
| `action` | Mirror the primary-region ECS + internal ALB composition under `aws.secondary`. Both clusters use the same task-definition shape; `desired_count = 3` per region (active-active baseline). Worker reads from + writes to the same region's DDB Global Tables replica. |
| `verify_cmd` | `aws ecs describe-services --cluster aegis-enclave-secondary --services app worker --region eu-west-1` and `curl -sf https://<secondary-internal-alb>/health` from a bastion in the secondary VPC. |
| `expected_output` | Both services show `runningCount` matches `desiredCount`; ALB target groups healthy; `/health` returns `{"status":"ok"}`. |
| `on_failure` | Scale the secondary services to 0 and remove the ALB target group. The primary remains untouched. |
| `human_gate` | `false` — secondary region is not yet traffic-bearing. |

### Step 5 — Provision per-region Client VPN endpoint and authorisation rules

| Field | Value |
|---|---|
| `precondition` | Step 2 complete (secondary VPC exists). ACM certificates issued in the secondary region (ACM is regional). |
| `action` | Add a second `aws_ec2_client_vpn_endpoint` resource using `provider = aws.secondary`. Mirror the authorisation rules and network associations to the secondary VPC's private subnets. mTLS PKI is shared (same CA signs both endpoints' server certs and operator client certs). |
| `verify_cmd` | `aws ec2 describe-client-vpn-endpoints --region eu-west-1` and a real client connection test from an operator workstation against the secondary `.ovpn` profile. |
| `expected_output` | Endpoint shows `State: available`; client connects and reaches the secondary internal ALB. |
| `on_failure` | Delete the secondary endpoint. Operators stay on the primary. |
| `human_gate` | `false` — additive resource. |

### Step 6 — Configure Route53 weighted routing with health checks

| Field | Value |
|---|---|
| `precondition` | Steps 1–5 complete; both regions independently pass smoke tests against their own internal ALB. |
| `action` | Create a public Route53 hosted zone (or use existing). Add two record sets with **weighted routing policy** 50/50 between Frankfurt ALB and Ireland ALB. Each record has a health check on `/health`; TTL 60 s. |
| `verify_cmd` | `aws route53 list-resource-record-sets --hosted-zone-id <zone-id>` + `aws route53 get-health-check --health-check-id <id>` |
| `expected_output` | Two weighted records (50/50); both health checks `Healthy`. |
| `on_failure` | Delete the records or set weights to 100/0 to revert traffic to a single region. |
| `human_gate` | `false` — initial setup; becomes traffic-bearing in Step 7. |

### Step 7 — Cutover traffic to multi-region routing + run failover drill

| Field | Value |
|---|---|
| `precondition` | Steps 1–6 complete and individually verified; rollback DNS record (direct primary-ALB CNAME, TTL 60 s) prepared. |
| `action` | Update the public DNS to use the Route53 weighted records. Verify traffic distributes ~50/50 between regions. Then in a maintenance window, deliberately disable one region's ALB (block its health check). Verify Route53 routes 100% to the healthy region within ~90 s health-check window + DNS TTL. Re-enable; verify recovery + automatic re-balancing. **Record observed RTO** for the drill. |
| `verify_cmd` | Smoke test from multiple geographic vantage points; `dig <api-host>` returns either ALB IP under normal conditions, only the healthy ALB during the simulated failure. |
| `expected_output` | Smoke passes from both regions during normal ops; smoke continues to pass against the healthy region during simulated failure (RTO ~60–300 s). |
| `on_failure` | Revert DNS to direct primary-ALB CNAME. |
| `human_gate` | **`true`** — production cutover + drill. Humans must approve and observe. Drill must be repeated quarterly to keep the failover path exercised. |

## RTO/RPO posture in multi-region active-active

| Indicator | Single-region (per ADR-0008 baseline) | Multi-region active-active (this runbook) |
|---|---|---|
| RTO — service | ≤ 15 min | ≤ 5 min (DNS-only failover ~60–300 s) |
| RTO — region failure | not applicable | ≤ 5 min (DNS health check + TTL; both regions are writers always, no promotion step) |
| RPO — DB writes | ≤ 5 min (DDB single-region durable) | ≤ 1 s typical (Global Tables async replication) |
| RPO — in-flight transactions | < 1 s (synchronous local commit) | < 1 s (synchronous local commit; cross-region replication is async) |

## Capability gates summary

| Step | Reason for gate |
|---|---|
| 7 | Production cutover + DR drill; observably traffic-bearing. |

Steps 1–6 are agent-autonomous — they are additive, region-isolated, and reversible by removing configuration before apply. The single gate concentrates at the production cutover + drill.

## Reusing this runbook

The spec format here is identical to `docs/migration_runbook.md`. The mapping table is the only artifact that changes when the destination changes — for example, dual-region GCP (Cloud Spanner + GCLB), dual-region Azure (Cosmos DB + Front Door), or AWS active-active in different region pairs. The format is the reusable artifact, not the AWS code.

## Related ADRs

- [ADR-0007](ADR/0007-single-region-multi-az.md) — Per-region 3-AZ posture (the in-region resilience this runbook extends across regions)
- [ADR-0008](ADR/0008-reliability-targets-slo-rto-rpo.md) — Reliability targets (the RTO/RPO baseline this runbook tightens)
- [ADR-0012](ADR/0012-migration-runbook-agent-executable.md) — Agent-executable runbook format
- [ADR-0040](ADR/0040-multi-region-frankfurt-ireland-route53.md) — Aurora migration path (alternative for forkers carrying existing PG)
- [ADR-0042](ADR/0042-dynamodb-global-tables-greenfield-multi-region.md) — DynamoDB Global Tables active-active (this runbook's data-layer target)
