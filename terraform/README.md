# Terraform — aegis-enclave

This directory holds the AWS deployment as Terraform code. **It is `plan`-only for the case-study deliverable** (per ADR-0015). No state is committed; no apply is performed during the cycle.

## What's here

| File | Purpose |
|---|---|
| `main.tf` | Provider (with optional `aws.secondary` alias for multi-region) + `default_tags` + community-module composition (VPC / DynamoDB Global Tables / ECS Fargate / internal ALB / ECR / Client VPN endpoint / ElastiCache Serverless Valkey / SQS) |
| `variables.tf` | Input variables (region, secondary_region, environment, tags, CIDRs, cert ARNs) |
| `outputs.tf` | VPC ID, subnets, DynamoDB table ARN, ALB DNS, ECR URL, Client VPN endpoint, ECS cluster ARN, Route53 record FQDNs (multi-region) |
| `terraform.tfvars.example` | Sample values; copy to `terraform.tfvars` (gitignored) for `make tf-plan` |

## What it demonstrates

1. **FinOps tagging** — `default_tags` on the provider tags every resource with Project / Environment / CostCenter / Owner / Repository.
2. **Community-module discipline (ADR-0016)** — `terraform-aws-modules/*` for VPC, ECS, ALB, ECR, security groups. Hand-rolled HCL for `aws_ec2_client_vpn_endpoint`, `aws_dynamodb_table` (with replica blocks for Global Tables), and the multi-region provider-aliased resources.
3. **Per-region 3-AZ posture (ADR-0007)** — three AZs in each provisioned region (`eu-central-1` + optional `eu-west-1` for active-active); ECS `desired_count = 3` baseline with autoscaling on SQS depth (ADR-0023).
4. **DevSecOps**: ECR scan on push, IMMUTABLE image tags (ADR-0036), self-signed internal ALB cert via ACM-imported (ADR-0027), private-only ALB.
5. **Private-only VPC (ADR-0019)** — no public subnets, no IGW, no NAT. AWS API egress is replaced with VPC Endpoints (PrivateLink): one S3 gateway endpoint plus eight interface endpoints (`ecr.api`, `ecr.dkr`, `secretsmanager`, `logs`, `ecs`, `ecs-agent`, `ecs-telemetry`, `sts`). Combined with the Client VPN endpoint (ingress, ADR-0006), both ingress and egress are off the public internet.

## How to plan (no apply)

```bash
cp terraform/terraform.tfvars.example terraform/terraform.tfvars
# Adjust placeholder cert ARNs if you have real ones; otherwise leave defaults

make tf-init     # terraform init -backend=false (no remote state for case-study)
make tf-plan     # terraform plan -var-file=terraform.tfvars
```

The plan output is captured into `docs/deployment_guide.md`. The brief explicitly accepts a deployment guide as sufficient (Task 3 — "A list of clear instructions would suffice"); the case-study deliverable demonstrates infrastructure composition, with one bounded cloud-acceptance window for evidence capture.

## Plan prerequisites and limitations

- **No real AWS credentials are required for `terraform plan`.** The configuration deliberately avoids `data "aws_*"` lookups that hit the AWS API at plan time.
- **`server_cert_arn` and `client_cert_arn` are placeholder values** in the example. They satisfy the type constraint so `terraform plan` succeeds but `terraform apply` would fail without real ACM certificates. ACM provisioning is treated as an out-of-band prerequisite — the candidate is testing infrastructure composition, not certificate authority operations.
- **No `terraform.tfvars`** is committed. The example file is the seed.

## Cross-cloud migration

Migration to alternative clouds (e.g., IONOS — see ADR-0005) is delivered as an agent-executable runbook in `docs/migration_runbook.md`, not as parallel Terraform per cloud. The mapping table at the top of that runbook is the only destination-specific artifact; the migration spec format is invariant across destinations.

## Scaling runbook

Sustained-traffic scaling guidance is `docs/scaling_runbook.md`. It uses the same agent-executable schema as the cross-cloud migration runbook — only the AWS-to-AWS-multi-region mapping table differs.
