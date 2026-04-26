# IAM permissions required

What the operator (or CI runner) needs in their AWS profile to run each `make` target. Two tiers: **read-only / pre-flight** (validation, smoke, evidence, teardown verification) and **full deploy** (terraform apply, ECR push, cert provisioning).

Bin 04/26 rule: «ci 如果沒有 aws access 那就不應該執行 make cloud-up». Scripts fail loudly on missing permissions and print the raw AWS CLI output (per `feedback_aws_creds_agnostic.md` rule #4) — operators self-diagnose by reading `UnauthorizedOperation` / `AccessDenied` messages.

## Tier 1 — read-only / pre-flight (minimum for validation paths)

These are the perms `make tfvars-init`, `make cloud-smoke`, `make cloud-evidence`, and the verification stages of `make cloud-down` need. Granted alone, they let CI validate inputs and confirm post-destroy cleanliness, but cannot deploy anything.

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PreflightAndValidation",
      "Effect": "Allow",
      "Action": [
        "sts:GetCallerIdentity",
        "ec2:DescribeRegions",
        "ec2:DescribeVpcs",
        "ec2:DescribeClientVpnEndpoints",
        "ec2:ExportClientVpnClientConfiguration",
        "acm:ListCertificates",
        "acm:DescribeCertificate",
        "ecr:ListImages",
        "ecr:GetAuthorizationToken",
        "cloudwatch:GetMetricWidgetImage",
        "logs:DescribeLogGroups",
        "logs:FilterLogEvents",
        "secretsmanager:ListSecrets",
        "ce:GetCostAndUsage"
      ],
      "Resource": "*"
    }
  ]
}
```

**Per-target mapping** (which perms each target actually exercises):

| Target | Perms required |
|---|---|
| `make tfvars-init` (incl. via `cloud-up`) | `sts:GetCallerIdentity`, `ec2:DescribeRegions`, `ec2:DescribeVpcs` |
| `make cloud-smoke` | `sts:GetCallerIdentity` (terraform output read; no AWS API beyond auth) |
| `make cloud-evidence` | `sts:GetCallerIdentity`, `cloudwatch:GetMetricWidgetImage`, `logs:DescribeLogGroups`, `logs:FilterLogEvents` |
| `make cloud-down` (verify step) | `sts:GetCallerIdentity`, `ec2:DescribeVpcs`, `ec2:DescribeClientVpnEndpoints`, `acm:ListCertificates` |

## Tier 2 — full deploy (`make cloud-up` end-to-end + `make cloud-down` destroy)

`make cloud-up` provisions VPC + RDS + ALB + ECS + ElastiCache Serverless Valkey + SQS + Client VPN + IAM roles + Secrets Manager (master password) + CloudWatch log groups + ACM (cert import). `make cloud-down` deletes all of the above plus drains ECR + deletes ACM-imported certs.

For the case-study Phase 2.5 window (3-hour bounded apply-then-destroy), the simplest correct grant is **AWS managed policy `PowerUserAccess`** (covers all service APIs, excludes IAM admin) plus an inline policy for IAM role provisioning:

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "IAMRoleProvisioning",
      "Effect": "Allow",
      "Action": [
        "iam:CreateRole",
        "iam:DeleteRole",
        "iam:AttachRolePolicy",
        "iam:DetachRolePolicy",
        "iam:PutRolePolicy",
        "iam:DeleteRolePolicy",
        "iam:GetRole",
        "iam:GetRolePolicy",
        "iam:ListRolePolicies",
        "iam:ListAttachedRolePolicies",
        "iam:PassRole",
        "iam:CreateInstanceProfile",
        "iam:DeleteInstanceProfile",
        "iam:AddRoleToInstanceProfile",
        "iam:RemoveRoleFromInstanceProfile",
        "iam:GetInstanceProfile",
        "iam:TagRole",
        "iam:UntagRole"
      ],
      "Resource": "arn:aws:iam::*:role/aegis-enclave-*"
    }
  ]
}
```

For **production adoption** outside the case-study window, derive a tighter policy from `terraform plan -out=plan.tf && terraform show -json plan.tf | jq '.resource_changes[].address'` and grant only the specific service:Action combinations the plan demands. The `PowerUserAccess + IAM-scoped` posture above is appropriate for the time-boxed case-study apply only.

## Tier 3 — recommended SSO setup (vs long-term keys)

Bin recommends SSO over long-term IAM access keys (per `feedback_aws_creds_agnostic.md`). Quick SSO setup:

```bash
# One-time setup (per profile):
aws configure sso --profile aegis
# Follow the prompts: SSO start URL, region, account, role

# First-time login + shell export (also one-time per shell session):
aws sso login --profile aegis
export AWS_PROFILE=aegis

# From here on, only this:
make cloud-up   # cloud-up auto-detects expired SSO tokens and re-runs 'aws sso login --profile $AWS_PROFILE'
                # AWS_PROFILE unset? cloud-up prompts for it. Already set? cloud-up uses it.
                # No more manual 'aws sso login' / 'export' needed for the make-target flow.
```

Long-term keys also work (placed in `~/.aws/credentials`), but SSO is preferred for: short-lived tokens, audit trail in CloudTrail, multi-account role assumption, no key rotation overhead.

## CI runner usage

Pre-create the IAM policy as a customer managed policy:

```bash
aws iam create-policy \
  --policy-name AegisEnclaveCaseStudy \
  --policy-document file://docs/iam-policy-tier2.json
```

Attach to the CI runner role (e.g., GitHub Actions OIDC role):

```bash
aws iam attach-role-policy \
  --role-name GithubActionsAegisEnclave \
  --policy-arn arn:aws:iam::aws:policy/PowerUserAccess

aws iam attach-role-policy \
  --role-name GithubActionsAegisEnclave \
  --policy-arn arn:aws:iam::<account>:policy/AegisEnclaveCaseStudy
```

Then in CI:

```yaml
# .github/workflows/cloud-deploy.yml (sketch)
permissions:
  id-token: write   # for OIDC
  contents: read
steps:
  - uses: aws-actions/configure-aws-credentials@v4
    with:
      role-to-assume: arn:aws:iam::<account>:role/GithubActionsAegisEnclave
      aws-region: eu-central-1
  - run: |
      TF_REGION=eu-central-1 \
      TF_OWNER=github-actions \
      TF_VPC_CIDR=10.20.0.0/16 \
      make cloud-up   # batch mode auto-detected (no TTY in CI runner)
```

## Debugging missing perms

Scripts print the raw AWS CLI error verbatim on failure (per `feedback_aws_creds_agnostic.md` rule #4):

```
--- aws ec2 describe-vpcs --region eu-central-1 failed (exit 254) ---
An error occurred (UnauthorizedOperation) when calling the DescribeVpcs operation:
You are not authorized to perform this operation.
--- end ---
Hint: looks like missing IAM permission ec2:DescribeVpcs.
```

Operator/CI debugger reads the `UnauthorizedOperation` line, identifies the missing action (here `ec2:DescribeVpcs`), grants it via the runner role, and retries. The hint line is supplementary — when in doubt, trust the raw stderr.
