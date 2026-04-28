# Production Adoption — aegis-enclave

This guide answers the operator question: *"I cloned the repo. How do I plug this into our existing AWS environment?"* It is the practical complement to [`deployment_guide.md`](deployment_guide.md), which describes the Terraform composition itself.

The case-study deliverable is **plan-only** per ADR-0015 — no real `terraform apply` is performed. Everything below is the path the operator follows to take the deliverable to a real production posture.

## What the operator provides vs what the repo provides

The repo ships the application layer and the immediately adjacent network/data infrastructure. Cross-cutting platform concerns remain operator-owned, consistent with the team-boundary posture in ADR-0010.

| Provided by operator (out of repo scope) | Provided by repo (`terraform/`) |
|---|---|
| AWS account + IAM bootstrap (apply role, plan role) | VPC, two private subnets, two database subnets across two AZs |
| State backend — S3 bucket + DynamoDB lock table | 9 VPC Endpoints (8 interface + 1 gateway) routing AWS API egress through PrivateLink |
| ACM certificates for the Client VPN endpoint (server cert + root CA) | ECS Fargate cluster + service definition |
| VPC CIDR coordination with existing networks / IPAM | RDS PostgreSQL Multi-AZ with Secrets Manager-managed master password |
| Cost-allocation tag taxonomy | Internal ALB with `/health` target group |
| Optional Transit Gateway / VPC peering | Three security groups (ALB → app → RDS) wired by SG-source rules |
| Container image build pipeline (CodeBuild, GitHub Actions, etc.) | Client VPN endpoint with mTLS, two-AZ subnet associations, authorisation rule |
| Corporate identity provider integration (if replacing mTLS with SSO) | ECR repository with `IMMUTABLE` tags + scan-on-push (or external reference per § 4) |
| Observability stack (Prometheus / Grafana / Datadog / OTel collector) | CloudWatch log groups via the `logs` interface endpoint |
| Alerting and on-call routing | `default_tags` FinOps scaffolding on the AWS provider |

## 1. AWS account and identity bootstrap

The operator needs an AWS account they can `terraform apply` against (typically a per-environment workload account inside an AWS Organization), and an IAM role with the permissions the modules need: VPC / RDS / ECS / ECR create, EC2 Client VPN endpoint create, `iam:PassRole` for the ECS task role, and `aws_vpc_endpoint:*`. Local credentials come from `aws configure`, `aws sso login`, or the preferred credential broker.

Recommended: `terraform apply` runs as a dedicated CI role; personal users are limited to `terraform plan`. This separates "see what would change" from "change production" at the IAM layer.

## 2. State backend

The repo's `terraform/main.tf` does not configure a backend — `make tf-init` runs `terraform init -backend=false` (plan-only, ADR-0015). For production, append a backend block:

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

Either create these in a separate "bootstrap" Terraform stack or follow existing state-backend conventions. One bucket per organisation with per-stack object keys, and one lock table shared across stacks, is the common pattern.

## 3. ACM certificates for Client VPN endpoint

The Client VPN endpoint uses mutual TLS (per ADR-0006), requiring two certificate ARNs in `terraform.tfvars`:

| Variable | What it points to |
|---|---|
| `server_cert_arn` | ACM-imported or ACM-issued server certificate (endpoint identity to clients) |
| `client_cert_arn` | ACM-imported root CA certificate that signs the client certificates |

These ARNs are provisioned **outside** this composition — typically by the team that runs AWS Certificate Manager / a private CA. The example tfvars provide placeholder ARNs that satisfy the type system but fail at apply time.

If the operator has no existing private CA, the simplest paths are AWS Private CA (managed, integrates with ACM), self-signed via `openssl` imported to ACM (cheaper, operator-managed rotation), or a third-party CA (Vault PKI, Smallstep, corporate AD CS).

Issuing is a one-time setup; rotation is ongoing — the cert chain must remain valid, with overlap before expiry where possible.

If the operator already runs a corporate VPN (AnyConnect, GlobalProtect, Zscaler), they may prefer to remove the Client VPN endpoint resources entirely and have the application consume the existing corp VPN — see ADR-0010 for the application-vs-platform ownership boundary.

## 4. ECR — same account vs shared services account

The composition creates an ECR repository in the same account as the workload. For organisations with a **shared services account** pattern (build artifacts central, runtime per-environment), modify the composition:

**Option A — keep ECR in this composition.** Suitable when the workload account also holds the registry. No code changes.

**Option B — reference a cross-account ECR repository.** Suitable for central ECR in a shared services account. Three changes to `main.tf`:

1. Remove `module "ecr"`.
2. Replace the `module.ecr.repository_url` reference in the ECS task `image` field with a new variable:
   ```hcl
   variable "ecr_repository_url" {
     type        = string
     description = "Cross-account ECR URL, e.g. <shared-account-id>.dkr.ecr.<region>.amazonaws.com/aegis-enclave"
   }
   ```
3. Grant the ECS task IAM role cross-account read permissions: `ecr:GetAuthorizationToken`, `ecr:BatchGetImage`, `ecr:GetDownloadUrlForLayer`. The shared services account's ECR resource policy must explicitly allow the workload account's task role.

Cross-account ECR is an IAM concern, not networking — the VPC stays private-only either way (per ADR-0019). The build pipeline that pushes images runs **outside** this VPC. Image construction never happens inside the runtime VPC.

## 5. VPC CIDR coordination

The repo defaults to `10.0.0.0/16`. In any organisation with multiple VPCs:

1. **Verify no overlap** with existing VPCs — especially if peered or attached to a Transit Gateway. Overlapping CIDRs are unfixable post-deployment except by full re-provisioning.
2. **Reserve the range** in the IPAM tool / spreadsheet / CMDB used for IP coordination.
3. **Update `terraform.tfvars`** with the chosen CIDR. The composition's hardcoded subnet ranges (`10.0.1.0/24`, `10.0.2.0/24`, `10.0.201.0/24`, `10.0.202.0/24`) assume `10.0.0.0/16` — if the operator picks a different parent CIDR, update the subnet ranges in `main.tf` accordingly.

Optional: if the workload needs to reach other VPCs (typically a shared services VPC, though ECR PrivateLink in this VPC obviates that), set up Transit Gateway attachment in a separate stack. Out of scope here.

## 6. Tags and cost attribution

The provider block declares `default_tags` (per ADR-0018). The operator should override the values:

| Default tag | Operator should set to |
|---|---|
| `Project = "aegis-enclave"` | Keep, or align with project taxonomy |
| `Environment = "case-study"` | `dev` / `staging` / `prod` |
| `ManagedBy = "terraform"` | Keep |
| `CostCenter = "engineering"` | The organisation's cost-centre code |
| `Owner = "bin.hsu"` | Team or distribution list |
| `Repository = "github.com/BinHsu/aegis-enclave"` | The organisation's fork URL |

These tags drive cost reports, IAM policy scoping (some organisations use `aws:RequestTag/CostCenter`-conditional IAM), and compliance attribution.

## 7. terraform.tfvars values to provide

Every variable the operator must override before a real apply:

| Variable | Default | Operator must provide |
|---|---|---|
| `region` | `eu-central-1` | Target region (must be where the ACM certs live) |
| `environment` | `case-study` | Real environment label (`dev` / `staging` / `prod`) |
| `cost_center` | `engineering` | The organisation's cost centre |
| `owner` | `bin.hsu` | Team / individual / distribution list |
| `vpc_cidr` | `10.0.0.0/16` | Non-overlapping CIDR per § 5 |
| `server_cert_arn` | placeholder | Real ACM server-cert ARN per § 3 |
| `client_cert_arn` | placeholder | Real ACM root-CA ARN per § 3 |
| (new) `ecr_repository_url` | n/a | If using cross-account ECR per § 4 |

`terraform.tfvars` is gitignored — the operator commits a `terraform.tfvars.<env>` per environment in their fork's private branch, not in the public repo.

## 8. What this repo intentionally does NOT provide

- **CI/CD pipeline** — out of scope per ADR-0015. Operator brings their own (CodeBuild, GitHub Actions, Jenkins, GitLab CI). The image-build step runs outside this VPC.
- **Observability stack** (Prometheus, Grafana, OTel collector) — out of scope per ADR-0003. CloudWatch Logs is configured; layering Datadog / New Relic / OSS is operator choice.
- **Alerting and on-call** — same rationale; CloudWatch Logs + EventBridge is the starting point but not provisioned here.
- **Identity provider integration** (SSO, IAM Identity Center) — operator-specific. Mutual TLS is the default; SSO is one ACM rule + one variable away.
- **Backup / DR drill automation** — RDS automated backups (7-day retention) is enabled; cross-region replication, drill scripts, and runbooks are operator-specific.
- **VPN modernisation to NetBird** — out of Phase 1 per ADR-0006; migration runbook Track 2 covers it.
- **Multi-region** — out of Phase 1 per ADR-0007; `docs/scaling_runbook.md` documents the upgrade.
- **K8s migration** — out of Phase 1 per ADR-0015; migration runbook Track 3 covers ECS → EKS.
- **Application-level authn/authz** — the app is internal HTTP only; Client VPN handles network-layer auth. JWT / Cognito / OAuth2 in front is operator choice.

The pattern: **the deliverable is the application layer plus the immediately adjacent infrastructure**. Cross-cutting platform concerns are platform-team concerns, consistent with ADR-0010.

## 9. Adoption sequence (operator's checklist)

1. Fork or clone the repo into the operator's git host.
2. Bootstrap a state backend (S3 + DynamoDB) per § 2.
3. Provision ACM certs (server + client root CA) per § 3.
4. Coordinate the VPC CIDR per § 5.
5. Decide ECR placement per § 4 and apply Option B changes if needed.
6. Override `terraform.tfvars` per § 7 and configure tags per § 6.
7. `terraform init` + `terraform plan` — review against § 8 expectations and the architecture in `deployment_guide.md`.
8. (Optional) Push a test image to ECR using the build pipeline (out of scope here).
9. `terraform apply` in a non-prod environment first.
10. Verify with the smoke test (adapted) — see [`README.md` § Initial Acceptance](../README.md#initial-acceptance-smoke-test).
11. Promote to prod via the operator's environment-promotion process.

## 10. When this composition stops being the right fit

The deliverable is calibrated to ADR-0003 (PoC scope, prod hygiene). When the workload outgrows that — many services, multi-team service mesh, autoscaling beyond Fargate's per-task ceiling, multi-region — the upgrade paths live in the Phase 2 runbooks. Multi-region itself bifurcates by deployment starting point: **greenfield → ADR-0042 (DynamoDB Global Tables active-active)**, or **existing-PG → ADR-0040 (Aurora Global active-passive with Lambda failover)**. `docs/migration_runbook.md` Track 3 covers ECS → EKS; `docs/scaling_runbook.md` covers single-region → multi-region with both paths. The composition is a starting point, not an end state.
