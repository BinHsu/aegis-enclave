# Scaling Runbook — Single-Region → Multi-Region (AWS)

> **Phase 2 deliverable.** Spec-grade, not code-grade. This document describes an agent-executable plan for moving the cloud composition in `terraform/main.tf` from single-region multi-AZ to multi-region active-passive (`eu-central-1` primary + `eu-west-1` secondary). Uses the same per-step schema as `docs/migration_runbook.md` — proving the runbook format is invariant across axes of extension.

## When to run this

The case-study deliverable is intentionally single-region per [ADR-0007](ADR/0007-single-region-multi-az.md). **Do NOT execute this runbook unless one of the following triggers is met:**

1. **Workload concurrency** exceeds single-region capacity — parallel demand spikes that an autoscaling single region cannot serve (rephrased generically from ADR-0007's multi-mission concurrency framing).
2. **Globally distributed clients** require locally-terminated network paths — e.g., a second client population on a different continent where cross-Atlantic round-trips break latency or jurisdiction assumptions.
3. **Regulatory geographic redundancy** is explicitly required — auditor sign-off needed before applying.

If none apply, multi-region is over-engineering. The single-region multi-AZ posture ([ADR-0007](ADR/0007-single-region-multi-az.md)) and the RTO 15min / RPO ≤ 5min targets ([ADR-0008](ADR/0008-reliability-targets-slo-rto-rpo.md)) are sufficient. Cost roughly doubles, cognitive complexity 2.5–3×, and an untested failover path is worse than no failover path — so the runbook below also requires a quarterly drill.

## Format

Every step in this runbook follows the same six-field schema established in [ADR-0012](ADR/0012-migration-runbook-agent-executable.md) and used by `docs/migration_runbook.md`. The schema makes each step both **agent-executable** (an AI coding agent can read the structured fields and act on them) and **human-reviewable** (each step has a verification command and a rollback path). The schema is invariant across runbooks; the only artifact that varies between destinations is the service-mapping table in the next section.

| Field | Meaning |
|---|---|
| `precondition` | What must be true before running this step |
| `action` | The intent of the step, described declaratively |
| `verify_cmd` | A command that confirms the step succeeded |
| `expected_output` | What the verify_cmd output looks like on success |
| `on_failure` | Rollback action or escalation path |
| `human_gate` | `true` when the step is irreversible or destructive; halts agent autonomy |

## Service mapping (single-region → multi-region)

| Single-region resource | Multi-region answer | Mechanism / Notes |
|---|---|---|
| `module "vpc"` (one VPC in `eu-central-1`) | Two VPCs (one per region) + VPC peering or Transit Gateway | Use provider aliases `aws.primary` / `aws.secondary`; instantiate `module "vpc"` twice. Non-overlapping CIDRs required for peering. |
| `module "rds"` Multi-AZ standby | **Aurora Global Database** (primary cluster + secondary cluster, async cross-region replication) | Replaces RDS PostgreSQL — see [ADR-0007 alternatives](ADR/0007-single-region-multi-az.md) and [ADR-0009](ADR/0009-db-topology-multi-az-standby.md). RPO drops from ~5min to <1s typical. RTO ~1min on cross-region failover. Cost premium ~3× vs single-region RDS. |
| `module "ecs"` (Fargate, one cluster) | Two ECS Fargate clusters (one per region) | Both clusters serve traffic via region-local ALB; Route 53 latency-based or failover routing in front. |
| `module "alb"` (internal, one) | Two internal ALBs (one per region) | Each region has its own internal ALB; cross-region routing via Route 53 health checks. |
| `aws_ec2_client_vpn_endpoint` (one) | Two endpoints (one per region) + Route 53 latency-based routing | Endpoint is regional per [ADR-0006](ADR/0006-vpn-three-tier-story.md); can't span regions. |
| `module "ecr"` (one repo) | One repo + cross-region replication | ECR `replication_configuration` replicates images to the secondary region's ECR. |
| `module "secrets_manager"` (RDS-managed) | Cross-region replica via Secrets Manager replication | `replica { region = ... }` block on the secret; Aurora Global Database emits one master-user secret per cluster. |
| Route 53 (not in current composition) | Public hosted zone + health checks + failover routing policy | New addition — single source of routing truth across regions. |

The cost shape changes meaningfully: monthly bill scales roughly **2–2.5×** (per ADR-0007 — Aurora Global premium, cross-region transfer, duplicated managed services, second Client VPN endpoint hourly fee). Cognitive complexity scales **2.5–3×** (split-brain reasoning, replication lag, DNS propagation timing, cross-region orchestration). Operations gains a hard requirement: a **quarterly DR drill**, otherwise the failover path is untested and the multi-region investment buys you a false sense of security rather than actual continuity.

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

This is also why the existing composition's reliance on `terraform-aws-modules/*` community modules pays off here: the same module call works against either provider alias without modification. The destination region is a parameter, not a rewrite.

## Track — Multi-region rollout (estimated 8 steps)

Unlike the cross-cloud migration runbook (`docs/migration_runbook.md`), which has two tracks (Application + VPN modernisation) because the cross-cloud move crosses an ownership boundary, this runbook is **single-track**. The same team owns the AWS estate end-to-end; the Client VPN endpoints simply expand from one to per-region with Route 53 in front.

### Step 1 — Add provider aliases and `var.secondary_region`

| Field | Value |
|---|---|
| `precondition` | Existing single-region Terraform composition (`terraform/main.tf`) plans cleanly; `terraform validate` passes against current state. |
| `action` | Edit `terraform/main.tf` to add `provider "aws"` blocks with `alias = "primary"` and `alias = "secondary"`. Add `secondary_region` variable to `terraform/variables.tf` (default `eu-west-1`). Existing un-aliased provider becomes the primary alias; no module call is migrated yet. |
| `verify_cmd` | `terraform fmt -check && terraform validate` |
| `expected_output` | No formatting drift; `Success! The configuration is valid.` |
| `on_failure` | Revert the edit (the change is purely additive — no resources are touched). Re-run `terraform validate`. |
| `human_gate` | `false` — configuration-only change with no resource impact. |

### Step 2 — Instantiate VPC, security groups in secondary region

| Field | Value |
|---|---|
| `precondition` | Step 1 complete; provider aliases declared. |
| `action` | Add a `module "vpc_secondary"` block (and matching `module "alb_sg_secondary"`, `module "app_sg_secondary"`, `module "rds_sg_secondary"`) using `providers = { aws = aws.secondary }`. Mirror the CIDR shape using a non-overlapping range (e.g., `10.1.0.0/16` for the secondary if the primary is `10.0.0.0/16`) so VPC peering or Transit Gateway is possible later. Existing primary modules are unchanged. |
| `verify_cmd` | `terraform plan -out=secondary-vpc.plan` and inspect the plan output. |
| `expected_output` | Plan shows `+ aws_vpc.this` and related resources scoped to `eu-west-1`; primary-region resources show no changes. |
| `on_failure` | Discard the plan file; remove the new module blocks. No state has been modified. |
| `human_gate` | `false` — net-new resources in an empty region; reversible by removing the configuration before apply. |

### Step 3 — Provision Aurora Global Database

| Field | Value |
|---|---|
| `precondition` | Step 1 complete; secondary VPC and database subnet group ready (Step 2). A current snapshot of the existing single-region RDS PostgreSQL is taken and verified. A non-prod rehearsal of the same migration has already been performed end-to-end. |
| `action` | Replace the single-region `module "rds"` with `aws_rds_global_cluster` (primary cluster in `eu-central-1`, secondary cluster in `eu-west-1`). Use `terraform-aws-modules/rds-aurora/aws` or direct resources. The primary cluster keeps writes; the secondary cluster is read-only until promoted. Application connection strings must be updated to point at the cluster endpoint, not an instance endpoint. |
| `verify_cmd` | `aws rds describe-global-clusters --global-cluster-identifier aegis-enclave-global` |
| `expected_output` | Two member clusters listed; primary cluster shows `IsWriter: true`, secondary cluster shows `IsWriter: false` and reachable for reads. |
| `on_failure` | Aurora Global supports rollback to single-cluster: detach the secondary, retain the primary as a standalone Aurora cluster. Data is preserved. If the migration from RDS PostgreSQL → Aurora itself fails, restore from the snapshot taken in the precondition and revert the application connection string. |
| `human_gate` | **`true`** — replacing RDS PostgreSQL with Aurora Global is a data-bearing change. Snapshots and a full non-prod rehearsal are required first. Production execution requires explicit approval. |

### Step 4 — Provision ECS Fargate cluster, internal ALB in secondary region

| Field | Value |
|---|---|
| `precondition` | Steps 1–3 complete; cross-region ECR replication is configured and the application image is present in the secondary region's ECR. |
| `action` | Mirror the primary-region ECS + internal ALB composition under `aws.secondary`. The secondary ECS service connects to the secondary Aurora cluster's reader endpoint for reads, and to the global cluster's primary writer endpoint for writes (cross-region until failover, regional after promotion). Both clusters use the same task-definition shape; only the connection-string environment values differ. |
| `verify_cmd` | `aws ecs describe-services --cluster aegis-enclave-secondary --services app --region eu-west-1` and `curl -sf <secondary-internal-alb>/health` from a bastion in the secondary VPC. |
| `expected_output` | Service shows `runningCount` matches `desiredCount`; ALB target group reports targets healthy; `/health` returns `{"status":"ok","db":"reachable"}`. |
| `on_failure` | Scale the secondary service to 0 and remove the secondary ALB target group. The primary remains untouched. |
| `human_gate` | `false` — secondary region is not yet traffic-bearing; scaling to zero is a safe rollback. |

### Step 5 — Provision per-region Client VPN endpoint and authorization rules

| Field | Value |
|---|---|
| `precondition` | Step 2 complete (secondary VPC exists). ACM certificates either replicated to the secondary region or freshly issued there (ACM is regional). |
| `action` | Add a second `aws_ec2_client_vpn_endpoint` resource using `provider = aws.secondary`. Mirror the authorization rules and network associations to the secondary VPC's private subnets. Each region has its own endpoint per [ADR-0006](ADR/0006-vpn-three-tier-story.md) — Client VPN endpoints are regional and cannot span regions. |
| `verify_cmd` | `aws ec2 describe-client-vpn-endpoints --region eu-west-1` and a real client connection test from an operator workstation against the secondary endpoint's `.ovpn` profile. |
| `expected_output` | Endpoint shows `State: available`; client successfully connects and can reach the secondary internal ALB on port 80. |
| `on_failure` | Delete the secondary endpoint and its authorization rules. The primary endpoint is unaffected; existing operators stay on the primary. |
| `human_gate` | `false` — additive resource in the secondary region; no traffic depends on it yet. |

### Step 6 — Configure Route 53 hosted zone with health checks and failover routing

| Field | Value |
|---|---|
| `precondition` | Steps 1–5 complete; both regions independently pass smoke tests against their own internal ALB (smoke test adapted to target each ALB DNS directly). |
| `action` | Create a public Route 53 hosted zone (or use an existing one) with a failover routing policy: primary record points at `eu-central-1`'s ALB DNS, secondary record points at `eu-west-1`'s ALB DNS. Health check targets the primary internal ALB via a public-facing CloudWatch synthetic or a side-channel HTTP endpoint (since the ALB is internal). TTL of 60s on the failover record to minimise stale-DNS blast radius. |
| `verify_cmd` | `aws route53 list-resource-record-sets --hosted-zone-id <zone-id>` and `aws route53 get-health-check --health-check-id <id>` |
| `expected_output` | Failover record set lists primary + secondary; health check status `Healthy`. |
| `on_failure` | Delete the failover record set and revert any DNS pointing at the new zone. The setup is configuration-only and has not yet received traffic. |
| `human_gate` | `false` — initial setup; this becomes traffic-bearing in Step 7, gated there. |

### Step 7 — Cutover traffic to multi-region routing

| Field | Value |
|---|---|
| `precondition` | Steps 1–6 complete and individually verified; secondary region passes its own smoke test (smoke.sh adapted for the secondary endpoint); rollback DNS record (direct primary-ALB CNAME, TTL 60s) prepared and held in reserve. |
| `action` | Update the public DNS to use the Route 53 failover record. Initial routing: 100% to primary, secondary as health-triggered failover. The application API hostname now resolves through Route 53 instead of pointing directly at a single ALB. |
| `verify_cmd` | `dig <api-host>` from multiple geographic vantage points (e.g., DigitalOcean droplets in different regions); `curl -sf https://<api-host>/health` from each. |
| `expected_output` | DNS returns the primary ALB DNS under normal conditions; failover to secondary occurs within Route 53 health-check window when primary is marked unhealthy. `/health` returns `{"status":"ok","db":"reachable"}` in both modes. |
| `on_failure` | Revert DNS to direct primary-ALB CNAME (TTL of 60s minimises blast radius — most clients re-resolve within a minute). |
| `human_gate` | **`true`** — production cutover. Humans must approve and observe the first failover drill within 24 hours. |

### Step 8 — Conduct cross-region failover drill

| Field | Value |
|---|---|
| `precondition` | Step 7 complete; no outstanding production incidents; maintenance window scheduled and communicated. |
| `action` | In a maintenance window, deliberately disable the primary-region ALB (or block the health check). Route 53 detects the unhealthy primary and routes clients to the secondary ALB. Verify the Aurora Global secondary cluster is reachable for reads. **Do NOT** actually promote the secondary Aurora cluster unless this is the real DR scenario — promotion is a one-way operation in the drill window. After the drill, re-enable the primary and verify recovery. Record the observed times for DNS propagation and client recovery. |
| `verify_cmd` | Smoke test against `<api-host>` while primary is disabled; `aws rds describe-global-clusters --global-cluster-identifier aegis-enclave-global` reports the secondary cluster reachable for reads. |
| `expected_output` | Smoke test passes from secondary region within Route 53 TTL + health-check window (~3 min); reads from secondary Aurora cluster succeed; after recovery, primary resumes serving traffic and the global cluster returns to normal. |
| `on_failure` | If failover is slow: tune Route 53 health-check interval and threshold (default 30s × 3 ≈ 90s; reducing to 10s × 3 ≈ 30s tightens RTO at the cost of more noise). If the Aurora secondary is not reachable: investigate cross-region replication lag (`aws rds describe-global-clusters` reports lag in seconds; sustained lag >60s warrants an incident review). |
| `human_gate` | **`true`** — even drills are operations on production posture. Approval required to schedule, and a designated incident commander must observe the drill in real time. |

## RTO/RPO posture in multi-region

The reliability targets in [ADR-0008](ADR/0008-reliability-targets-slo-rto-rpo.md) are stated for the single-region multi-AZ topology. Multi-region tightens them — at the cost shape and complexity shape laid out above:

| Indicator | Single-region (ADR-0008) | Multi-region (this runbook) |
|---|---|---|
| RTO — service | ≤ 15 min (multi-AZ failover) | ≤ 3 min (Route 53 health-check + DNS TTL) |
| RTO — region failure | not applicable | ≤ 5–10 min (manual Aurora Global secondary promotion) |
| RPO — DB writes | ≤ 5 min | < 1 sec typical (Aurora Global async cross-region replication) |
| RPO — in-flight transactions | < 1 min (sync to AZ standby) | depends on replication lag at the moment of failure |

The cost of these tighter targets: **~2–2.5× monthly cost** (per ADR-0007), **2.5–3× cognitive complexity**, and a **mandatory quarterly drill** to keep the failover path exercised. None of these are free, which is why ADR-0007 explicitly defers multi-region to Phase 2 unless one of the named triggers is met.

## Capability gates summary

The schema's `human_gate` flag concentrates at three points in this runbook, mirroring the capability-gates principle from [ADR-0012](ADR/0012-migration-runbook-agent-executable.md):

| Step | Reason for gate |
|---|---|
| 3 | Data-bearing replacement (RDS PostgreSQL → Aurora Global Database). |
| 7 | Production cutover (DNS becomes traffic-bearing across two regions). |
| 8 | Production-posture drill (deliberate failure injection on production). |

Steps 1, 2, 4, 5, and 6 are agent-autonomous — they are additive, region-isolated, and reversible by removing configuration before apply. The gates concentrate at data-bearing changes, traffic cutover, and posture-affecting drills. This is the same pattern as the cross-cloud migration runbook: most steps are safe for an AI agent to execute end-to-end; a small number of irreversible or destructive steps require explicit human approval.

## Reusing this runbook

The spec format here is identical to `docs/migration_runbook.md`. The mapping table is the only artifact that changes when the destination changes — for example, dual-region GCP (Cloud SQL with cross-region read replicas, GCLB with multi-cluster ingress), dual-region Azure (Azure Database for PostgreSQL Flexible Server replicas, Front Door), or AWS active-active multi-master (which would require an entirely different DB strategy). The two-track structure of the cross-cloud runbook collapses to a single track here because there is no ownership boundary to cross — the same team owns the entire AWS estate, so VPN modernisation and application work proceed in lockstep rather than as parallel tracks. Future axes of extension (per-tenant region pinning, edge POPs, etc.) can reuse this same schema with their own mapping table; the format is the reusable artifact, not the AWS code.

## Related ADRs

- [ADR-0007](ADR/0007-single-region-multi-az.md) — Single-region eu-central-1 multi-AZ; multi-region in Phase 2 (the trigger conditions and complexity rationale that gate this runbook)
- [ADR-0008](ADR/0008-reliability-targets-slo-rto-rpo.md) — Reliability targets (the RTO/RPO baseline that this runbook tightens)
- [ADR-0009](ADR/0009-db-topology-multi-az-standby.md) — RDS PostgreSQL Multi-AZ (the database topology being replaced by Aurora Global)
- [ADR-0012](ADR/0012-migration-runbook-agent-executable.md) — Agent-executable runbook format (the schema this runbook instantiates)
