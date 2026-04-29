# Production Adoption — aegis-enclave

This guide answers the operator question: *"I cloned the repo. How do I plug this into our existing AWS environment and run it as a sustained production deployment?"* It is the practical complement to [`deployment_guide.md`](deployment_guide.md), which describes the Terraform composition itself.

The composition's case-study scope is calibrated to ADR-0003 (PoC scope, prod hygiene). This guide describes everything a forker adds on top to reach production-grade operations.

## What the operator provides vs what the repo provides

The repo ships the application layer and the immediately adjacent network/data infrastructure. Cross-cutting platform concerns remain operator-owned, consistent with the team-boundary posture in ADR-0010.

| Provided by operator (out of repo scope) | Provided by repo (`terraform/`) |
|---|---|
| AWS account + IAM bootstrap (apply role, plan role) | Per-region VPC + 3 private subnets across 3 AZs |
| State backend — S3 bucket + DynamoDB lock table | 9 VPC endpoints (8 interface + 1 gateway) routing AWS API egress through PrivateLink |
| ACM certificates for the Client VPN endpoint (server cert + root CA) | ECS Fargate cluster + service definitions (app + worker + bootstrap) |
| VPC CIDR coordination with existing networks / IPAM | DynamoDB Global Tables (eu-central-1 + eu-west-1 by default; configurable via `tfvars-init.sh`) |
| Cost-allocation tag taxonomy | Internal ALB with HTTPS:443 (self-signed cert imported into ACM per ADR-0027) |
| Optional Transit Gateway / VPC peering | Three security groups (ALB → app → worker) wired by SG-source rules |
| Container image build pipeline (CodeBuild, GitHub Actions, etc.) | Client VPN endpoint with mTLS, 3-AZ subnet associations, authorisation rule |
| Corporate identity provider integration (if replacing mTLS with SSO) | ECR repository with `IMMUTABLE` tags + cross-region replication |
| Observability stack at production scale (Grafana / Loki / OTel) | CloudWatch SLI emission + 6-panel dashboard + multi-window burn-rate alarms (ADR-0041) |
| Alerting and on-call routing | `default_tags` FinOps scaffolding on the AWS provider |

## 1. AWS account and identity bootstrap

The operator needs an AWS account they can `terraform apply` against (typically a per-environment workload account inside an AWS Organization), and an IAM role with permissions per `docs/iam-permissions.md`. Local credentials come from `aws configure`, `aws sso login`, or the preferred credential broker.

Recommended: `terraform apply` runs as a dedicated CI role (see § OIDC apply at production scale below); personal users are limited to `terraform plan`. This separates "see what would change" from "change production" at the IAM layer.

## 2. State backend

The case-study composition runs `terraform init -backend=false` (local state). For production, append a backend block:

```hcl
terraform {
  backend "s3" {
    bucket         = "<your-state-bucket>"
    key            = "aegis-enclave/terraform.tfstate"
    region         = "<your-region>"
    dynamodb_table = "<your-lock-table>"
    encrypt        = true
  }
}
```

The bucket should have versioning, KMS encryption, and access logging enabled. The DynamoDB table is for state locking — partition key `LockID` (string), on-demand billing.

`terraform/bootstrap/` provisions S3 + DynamoDB lock + GHA OIDC role (see § OIDC apply below) — run that stack once per account.

## 3. ACM certificates for Client VPN endpoint

The Client VPN endpoint uses mutual TLS (per ADR-0006), requiring two certificate ARNs in `terraform.tfvars`:

| Variable | What it points to |
|---|---|
| `server_cert_arn` | ACM-imported or ACM-issued server certificate |
| `client_cert_arn` | ACM-imported root CA certificate that signs the client certificates |

The case-study composition uses self-signed easy-rsa certs imported into ACM (`scripts/bootstrap-vpn-certs.sh`). For sustained production use see § Cert management at production scale below.

If the operator already runs a corporate VPN (AnyConnect, GlobalProtect, Zscaler), they may prefer to remove the Client VPN endpoint resources entirely and have the application consume the existing corp VPN — see ADR-0010 for the application-vs-platform ownership boundary.

## 4. ECR — same account vs shared services account

The composition creates an ECR repository in the same account as the workload. For organisations with a **shared services account** pattern:

**Option A — keep ECR in this composition.** Suitable when the workload account also holds the registry. No code changes.

**Option B — reference a cross-account ECR repository.** Suitable for central ECR in a shared services account. Three changes to `main.tf`:

1. Remove `module "ecr"`.
2. Replace `module.ecr.repository_url` reference in the ECS task `image` field with a new variable `ecr_repository_url`.
3. Grant the ECS task IAM role cross-account read permissions: `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`. The shared services account's ECR resource policy must explicitly allow the workload account's task role.

Cross-account ECR is an IAM concern, not networking — the VPC stays private-only either way (per ADR-0019).

## 5. VPC CIDR coordination

Each region defaults to `10.0.0.0/16` (primary) + `10.1.0.0/16` (secondary). In any organisation with multiple VPCs:

1. **Verify no overlap** with existing VPCs — especially if peered or attached to a Transit Gateway. Overlapping CIDRs are unfixable post-deployment except by full re-provisioning.
2. **Reserve the range** in the IPAM tool / spreadsheet / CMDB used for IP coordination.
3. **Update `terraform.tfvars`** with the chosen CIDRs.

Optional: if the workload needs to reach other VPCs (typically a shared services VPC, though endpoint PrivateLink obviates that), set up Transit Gateway attachment in a separate stack.

## 6. Tags and cost attribution

The provider block declares `default_tags` (per ADR-0018). Override in `terraform.tfvars`:

| Default tag | Operator should set to |
|---|---|
| `Project = "aegis-enclave"` | Keep or align with project taxonomy |
| `Environment = "case-study"` | `dev` / `staging` / `prod` |
| `ManagedBy = "terraform"` | Keep |
| `CostCenter = "engineering"` | The organisation's cost-centre code |
| `Owner = "<your-handle>"` | Team or distribution list |
| `Repository = "<your-fork-url>"` | The organisation's fork URL |

These tags drive cost reports, IAM policy scoping (`aws:RequestTag/CostCenter`-conditional IAM), and compliance attribution.

## 7. terraform.tfvars values to provide

| Variable | Default | Operator must provide |
|---|---|---|
| `primary_region` | `eu-central-1` | Primary AWS region |
| `secondary_region` | `eu-west-1` | Secondary region (active-active per ADR-0042) — set `""` to disable Global Tables |
| `environment` | `case-study` | Real environment label |
| `cost_center` | `engineering` | The organisation's cost centre |
| `owner` | placeholder | Team / individual / distribution list |
| `vpc_cidr_primary` | `10.0.0.0/16` | Non-overlapping CIDR per § 5 |
| `vpc_cidr_secondary` | `10.1.0.0/16` | Non-overlapping CIDR per § 5 |
| `server_cert_arn` | placeholder | Real ACM server-cert ARN per § 3 |
| `client_cert_arn` | placeholder | Real ACM root-CA ARN per § 3 |
| `alarm_email` | `""` | Email for SNS alarm subscription (per ADR-0041); `""` disables SNS provisioning |

`terraform.tfvars` is gitignored. Operators commit `terraform.tfvars.<env>` per environment in their fork's private branch, not in the public repo.

## 8. What this repo intentionally does NOT provide

- **CI/CD apply pipeline** — case-study scope ships PR-time `plan` only (per ADR-0026). Apply on merge is a production extension; see § OIDC apply at production scale below.
- **Production-grade observability stack** — case-study ships CloudWatch SLI emission + dashboard + alarms (per ADR-0041). Production extension is Grafana Cloud + Loki + OpenTelemetry; see § Observability at production scale below.
- **Identity provider integration** (SSO, IAM Identity Center) — operator-specific. mTLS is the default; SSO is one ACM rule + one variable away.
- **Backup / DR drill automation** — DynamoDB PITR + on-demand backup are enabled; cross-region replication is automatic; quarterly drill cadence is operator-specific (per scaling_runbook.md Step 7).
- **Cert management at production scale** — case-study uses self-signed + ACM import (per ADR-0027). Production path: AWS Private CA or Let's Encrypt automation; see § Cert management at production scale below.
- **Secrets at production scale** — case-study uses secret minimization stance (per ADR-0037). Residual cert keys live in Terraform state (KMS-encrypted, acceptable for one-shot demo). See § Secrets at production scale below.

The pattern: **the deliverable is the application layer plus the immediately adjacent infrastructure**. Cross-cutting platform concerns are platform-team concerns, consistent with ADR-0010.

## 9. Adoption sequence (operator's checklist)

1. Fork or clone the repo into the operator's git host.
2. Bootstrap a state backend (S3 + DynamoDB) per § 2.
3. Provision ACM certs (server + client root CA) per § 3.
4. Coordinate the VPC CIDRs per § 5.
5. Decide ECR placement per § 4 and apply Option B changes if needed.
6. Override `terraform.tfvars` per § 7 and configure tags per § 6.
7. `terraform init` + `terraform plan` — review against § 8 expectations.
8. (Optional) Push a test image to ECR using the build pipeline.
9. `terraform apply` in a non-prod environment first.
10. Verify with the smoke test — see [`README.md` § Initial Acceptance](../README.md#initial-acceptance-smoke-test).
11. Promote to prod via the operator's environment-promotion process.

---

## Production extensions

The case-study composition stops at the boundary of "PoC + prod-hygiene at PoC scale". The sections below describe the production extensions a forker adds on top.

### OIDC apply at production scale

Forker production extension of ADR-0026 (PR-time plan via OIDC):

- **Branch-protected `terraform apply`** triggered by merge to `main`
- **`AWS_TF_APPLY_ROLE_ARN`** repo variable (higher privilege than plan role) — granted Create/Modify/Delete permissions scoped to the workload account
- **Required PR reviewers** + status checks pass (lint + tests + plan succeeds) + linear history (no merge commits)
- **Environment-scoped secrets** (per-environment AWS roles via GitHub `environment` keyword in workflow)
- **Manual approval gate** for sensitive changes (DDB schema modify, VPC modify) — GitHub Environments with required reviewers
- **Plan output diff** review at PR-time + apply approval at merge-time (two-step gate)
- Effort: ~6–8 h (workflow + branch protection + per-env role setup)

Reference: `aegis-aws-landing-zone` (sister repo in the aegis-* portfolio) for multi-account context (Organizations + IAM Identity Center + account factory).

### Cert management at production scale

Forker production extension of ADR-0027 (ALB self-signed) + ADR-0024 (VPN root CA self-signed):

**ALB cert** options:

- **AWS Private CA** (~$400/month/CA + per-cert) — internal certs with auto-renewal via ACM. Right call when regulatory/sovereignty constraints prefer in-AWS.
- **Let's Encrypt + DNS-01 challenge** + automation (certbot / lego / cert-manager off-K8s) — free, auto-renewing. Requires public domain + DNS automation.

**VPN root CA** options:

- **AWS CloudHSM** for hardware-rooted trust + key custody
- **AWS KMS-backed CA** with per-environment key policies

Cert lifecycle:

- Annual cert renewal (ALB) / multi-year (VPN root CA) per security policy
- Automated rotation alarm (CloudWatch metric on cert expiry < 30 days) feeding into the same SNS topic per ADR-0041

Effort:
- Private CA: ~3–4 h setup + monthly cost
- Let's Encrypt automation: ~6–8 h setup, near-zero ongoing
- HSM-backed root CA: ~8–12 h initial setup

Trade-off: regulatory/sovereignty (Private CA stays in AWS) vs cost (Let's Encrypt free).

### Secrets at production scale

Forker production extension of ADR-0037 (secret minimization posture):

The case-study minimises static credentials at architecture-time (DDB IAM-authn, ECS task roles, mTLS for ingress, SSO for operators). Residual intrinsic-secret material:

- **ALB cert private key** (per ADR-0027): currently in Terraform state, KMS-encrypted. Production path: migrate to Secrets Manager + Parameter Store with stricter IAM scope; rotate on cert renewal.
- **VPN root CA private key** (per ADR-0024): currently on operator's laptop in repo-gitignored `pki/`. Production path: HSM-backed (AWS CloudHSM) for hardware-rooted custody.
- **Valkey AUTH token** (if enabled): production deployments crossing tenant or region boundaries should enable Valkey AUTH. Use Secrets Manager + 30-day Lambda rotation.

DynamoDB itself stays passwordless (IAM-based authn) — no rotation surface introduced.

Effort:
- ALB cert migration to Secrets Manager: ~2–3 h
- HSM setup for VPN root CA: ~8–12 h
- Valkey AUTH token + rotation Lambda: ~3–4 h

### Observability at production scale

Forker production extension of ADR-0041 (CloudWatch SLI emission).

**Recommended primary path (vendor-neutral, multi-cloud-portable):**

**Grafana Cloud + Loki + OpenTelemetry** — the canonical vendor-neutral observability triad:

- **Grafana Cloud** (SaaS): free tier covers small workloads; integrated metrics + logs + traces; multi-cloud portable; lower ops tax than self-hosted Grafana
- **Loki**: cardinality-friendly log indexing — much cheaper than CloudWatch Logs Insights at sustained-ops scale
- **OpenTelemetry**: industry-standard instrumentation; not AWS-locked; future-proof
- Effort: ~16–20 h total (instrumentation + ADOT collector for OTel transport + Loki agent + dashboards-as-code)

**AWS-flavored alternative** (if regulatory/sovereignty constraints prefer in-AWS):

- **AMG (Amazon Managed Grafana)** + **AMP (Amazon Managed Prometheus)** + **ADOT collector** + **AWS X-Ray**
- Pros: stays in AWS, IAM Identity Center auth, in-VPC private connectivity
- Cons: loses vendor-neutrality + SaaS ops-savings; recreates Grafana inside AWS without Loki's cardinality advantage
- Effort: AMG ~7–8 h + AMP ~3–4 h + X-Ray ~10–12 h

**Distributed tracing** (separate axis):

- OpenTelemetry → Tempo (Grafana Cloud) — preferred — OR X-Ray (AWS).
- SQS message-attribute trace_id propagation is the non-trivial piece.
- Effort: ~10–12 h.

**PagerDuty / Slack delivery**:

- Email is the floor (per ADR-0041); AWS Chatbot or Grafana OnCall for sustained ops paging.
- Effort: ~3–4 h.

**Cross-region SNS aggregation**:

- Multi-region active-active deployments need per-region alarms + cross-region SNS or single failover topic.
- Effort: ~2–3 h.

### Other production extensions

**VPC Flow Logs** — not enabled in the case-study composition. Production should add `aws_flow_log` resources at the VPC level for both rejected and accepted traffic, written to a dedicated S3 bucket with lifecycle rules. Adds ~5 lines of Terraform + an S3 bucket + IAM scope. Cost: ~$0.50/GB ingest for active VPCs.

**Dependabot / Renovate for dependency updates** — `uv.lock` (committed) pins exact Python dependency versions. Terraform modules + providers are exact-pinned per ADR-0039. Without an automated bump tool, pinned versions go stale. Configure either Dependabot (GitHub-native) or Renovate (more flexible, supports Terraform modules natively) with weekly bump PRs.

**FinOps cap + anomaly detection** — case-study has cost attribution (provider `default_tags`) + per-hour cost table but does not wire `aws_budgets_budget` or `aws_ce_anomaly_monitor`. For a forker:

- **Budget cap** (~10 lines TF): `aws_budgets_budget` with `budget_type = "COST"`, monthly limit set to your steady-state estimate × 1.5, plus a `notification` block at 80%/100%/forecasted-100% to an SNS topic or email.
- **Anomaly detection** (~15 lines TF): `aws_ce_anomaly_monitor` scoped to `monitor_dimension = "SERVICE"`, plus an `aws_ce_anomaly_subscription` with daily summary or above-threshold alert.

Both are free at the AWS billing layer; cost is only the SNS messages or email delivery.

---

## When this composition stops being the right fit

The deliverable is calibrated to ADR-0003 (PoC scope, prod hygiene). When the workload outgrows that — many services, multi-team service mesh, autoscaling beyond Fargate's per-task ceiling, customer geographies beyond EU — the upgrade paths live in the runbooks. Cross-cloud migration: `docs/migration_runbook.md` Track 3 (ECS → EKS) + Track 1 (cross-cloud). Multi-region scaling: `docs/scaling_runbook.md`. The composition is a starting point, not an end state.
