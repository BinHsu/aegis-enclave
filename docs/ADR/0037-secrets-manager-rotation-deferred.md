# ADR-0037: Secret minimization posture — IAM-first, mTLS over token, passwordless data plane

## Status
Accepted (2026-04-28)

## Context

The conventional production-secrets pattern is "store secrets in a vault (Secrets Manager / Vault / KMS) and rotate them on schedule." This works, but it accepts as given that the system has many secrets. A stronger architectural stance is **secret minimization**: design out static credentials at architecture-time, so the only material that ends up in a vault is intrinsically secret (private keys, root CA material) — not derived secrets that exist because we chose a credential-based authn flow.

aegis-enclave applies this stance across the data plane and control plane:

| Surface | Conventional pattern | aegis-enclave stance |
|---|---|---|
| DB authentication | Password in Secrets Manager + rotation Lambda | **DynamoDB IAM-based authn** (per ADR-0042) — no password exists |
| AWS service-to-service authn (ECS → DDB / SQS / Valkey) | API keys / access tokens | ECS task IAM role assumed via STS — short-lived credentials, no static keys |
| Operator authn to ALB | Bearer token / API key | mTLS via Client VPN endpoint (per ADR-0024) — cert-based, no token rotation |
| Operator authn to AWS Console / API | Long-term IAM access keys | SSO (recommended) or short-lived STS via SSO; no long-lived keys in `~/.aws/credentials` |
| App authn between containers | Shared secret / token | VPC + SG isolation + mTLS where strict identity required (the VPN cert path) |

The remaining intrinsic-secret material:

- ALB self-signed cert private key (per ADR-0027) — currently in Terraform state, KMS-encrypted at rest
- VPN root CA private key (per ADR-0024) — currently on operator's laptop in repo-gitignored `pki/` directory
- Any AUTH-token Valkey would require if AUTH were enabled (currently passwordless inside private VPC; AUTH would only matter for cross-region or shared-tenant deployments)

These are intrinsically secret — not derivable from architectural redesign. Their handling is a production-extension concern (HSM-backed root keys, automated cert renewal); see `production_adoption.md` § Secrets at production scale.

## Decision

**Architectural posture: design out static credentials wherever feasible.**

| Decision | Surface |
|---|---|
| Use DynamoDB (per ADR-0042), not RDS PG | Eliminates DB master password + rotation Lambda + Secrets Manager rotation grant |
| ECS task IAM roles for AWS service access | No static AWS credentials in container env or app code |
| Client VPN mTLS for operator ingress | Cert-based authn replaces username/password or token-based ingress auth |
| SSO for operator → AWS authn | Forker scripts default to SSO; long-term keys are supported but not preferred |
| No app-level shared secrets | Service-to-service identity via SG / IAM, not bearer tokens |

**Surfaced secrets** (the residual that cannot be eliminated): cert private keys (ALB self-signed, VPN root CA). Their rotation policy is production-extension scope, lives in `production_adoption.md` § Secrets at production scale.

## Alternatives Considered

| Alternative | Industry context |
|---|---|
| **Password-based DB authn + Secrets Manager rotation Lambda** | Industry default. Adds Lambda + IAM + KMS grant + CloudWatch alarm + SNS topic to maintain. Eliminated by choosing DDB (IAM-authenticated) over PG. |
| **Long-term AWS access keys for operator + CI** | Industry default for years; deprecated by SSO + OIDC. Forker scripts treat long-term keys as supported-but-not-preferred. |
| **API tokens for service-to-service authn** | Mature pattern (OAuth2 client credentials, JWT bearer). aegis-enclave service-to-service stays inside one VPC + IAM-bound — no token rotation, no token leakage class of bug. |
| **Vault / Conjur / corporate secret broker** | Right call for orgs with many secrets across many services. aegis-enclave's secret minimization keeps the secret count small enough that AWS-native primitives (Secrets Manager for the residual, plus IAM for everything else) suffice. |
| **Always-rotate everything (90-day mandate)** | Reasonable default when you have many secrets. Better default: have fewer secrets. |

## Consequences

- **Operationally lighter at production**: fewer rotation Lambdas to maintain, fewer secret-leak attack surfaces, fewer scheduled-task failures at 03:00 to triage.
- **Forker promotion path** for the residual cert keys is documented in `production_adoption.md` § Cert management at production scale + § Secrets at production scale. Both reference HSM-backed root key custody (AWS Private CA / CloudHSM) as the production-grade endpoint.
- **Code-side simplicity**: app code never reads `secrets_manager.get_secret_value(...)` for DB auth — `boto3.client("dynamodb")` with the task role does the right thing automatically.
- **Forker who promotes to a different data store** (e.g., Aurora PG) re-introduces the password-rotation surface; that's a forker decision, recorded in their fork.

## Related ADRs
- ADR-0019 (private-only VPC — the network-layer enforcement that makes "no service-to-service token" safe)
- ADR-0024 (VPN cert provisioning — the mTLS path that replaces token-based operator ingress)
- ADR-0026 (PR-time Terraform plan via OIDC — short-lived OIDC tokens replace long-term IAM keys for CI)
- ADR-0027 (internal ALB HTTPS self-signed — the residual secret material this stance acknowledges)
- ADR-0042 (DynamoDB Global Tables — the data-store choice that eliminates DB password rotation)
