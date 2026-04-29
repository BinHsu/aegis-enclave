# ADR-0027: Internal ALB HTTPS via self-signed ACM-imported cert

## Status
Accepted (2026-04-28)

This case-study uses self-signed cert + ACM import. For production cert management at scale (AWS Private CA / Let's Encrypt automation / HSM-backed root keys), see `production_adoption.md` § Cert management at production scale.

## Context

Production-shape architecture (per ADR-0003) implies TLS-everywhere at the ingress to compute — even when the hop in question is already inside an encrypted Client VPN tunnel. Defence-in-depth is canonical for production deployments: an attacker who breaches one layer (compromised VPN client cert, lateral movement from a compromised internal host) should not gain plaintext access to the application path.

The candidate hostname `api.enclave.internal` is internal-only — not in any public DNS zone the deliverable owns. ACM does not issue public certs for non-public hostnames. The cost of TLS-everywhere at this scope is small (one ACM cert + one extra listener); the cost of *not* having it is a `https://` vs `http://` mismatch between the documentation (which has used `https://` from the beginning) and the deployed ALB.

## Decision

The internal ALB terminates TLS on port 443 with a **self-signed certificate generated at `terraform apply` time via the `tls` provider, then imported into AWS Certificate Manager** as a regular ACM certificate.

Terraform composition:

- `tls_private_key.alb` (RSA-2048) — generated on first apply, persisted in state.
- `tls_self_signed_cert.alb` — `common_name = var.alb_internal_hostname` (default `api.enclave.internal`), one-year validity, `server_auth` extended key usage, `dns_names = [var.alb_internal_hostname]`.
- `aws_acm_certificate.alb` — imports the self-signed cert + private key; `lifecycle { create_before_destroy = true }` so the listener-attached cert can rotate without an outage.
- ALB listener: HTTPS:443 referencing `aws_acm_certificate.alb.arn`, `ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"` (TLS 1.2 floor, TLS 1.3 preferred).
- ALB security group ingress: `https-443-tcp` only — port 80 is not exposed.
- Two outputs: `alb_cert_arn` (the ACM ARN) and `alb_self_signed_ca_pem` (the cert PEM body, public material). The operator captures the latter into a local file and uses `curl --cacert /tmp/alb-ca.pem ...` so cert verification passes without `-k` (`--insecure`) — the verification is real, just against an explicitly-loaded CA rather than a system trust store.

Operator curl pattern from inside the Client VPN tunnel:

```bash
ALB_DNS=$(terraform -chdir=terraform output -raw alb_dns_name)
ALB_IP=$(dig +short $ALB_DNS | head -1)
terraform -chdir=terraform output -raw alb_self_signed_ca_pem > /tmp/alb-ca.pem
CURL="curl --cacert /tmp/alb-ca.pem --resolve api.enclave.internal:443:${ALB_IP}"
$CURL https://api.enclave.internal/health
```

The `--resolve` flag handles the DNS gap (no Route53 private zone), the `--cacert` handles the trust gap (self-signed cert).

## Alternatives Considered

| Alternative | Industry context |
|---|---|
| **HTTP only on port 80** | Forces every doc / curl example to read `http://`. Loses defence-in-depth at the layer most exposed to lateral-movement attacks. |
| **Public ACM cert via DNS validation against an owned domain** | Trusted by default (no `--cacert`), auto-renewing. Internal ALB has no public hostname; couples the deliverable's deployment to a personal-domain DNS arrangement. Right call once a real DNS-owned hostname enters scope. |
| **AWS Private CA** | Fully prod-shape (rotation, hierarchy, audit logs, IAM-controlled issuance). ~$400/month/CA + per-cert fees. Right call at production sustained-deployment scale; over-budget for case-study one-shot. |
| **Let's Encrypt + DNS-01 challenge** | Free, trusted, auto-renewing. Requires public domain + automation (certbot/lego/ACME terraform provider) + renewal scheduler. Equivalent trade-off to ACM-public with more moving parts. |
| **cert-manager on K8s** | K8s not in scope (per ADR-0015). Right call when K8s is already present. |
| **Sidecar TLS terminator** (Envoy / nginx as Fargate sidecar) | Decouples TLS from ALB; gives mTLS / custom-header flexibility. Adds container, blocks direct `terraform-aws-modules/alb` use. Right call when strict mTLS app-to-app is in scope. |
| **Self-signed + ACM import (chosen)** | Cost-zero, production-shape pattern, matches Tier 2 ops calibration (per ADR-0008). |

## Consequences

- The deployment_guide curl invocations use `https://` consistently — no `http://` mismatch to explain.
- Operator's curl is more verbose (`--cacert` + `--resolve`) than HTTP equivalent; deployment scripts pre-bake a `CURL=` shell alias.
- The cert is regenerated on every fresh `tls_private_key` resource creation. With S3-backed state (per ADR-0025) the key persists across applies; rotation requires explicit `terraform taint tls_private_key.alb`.
- One-year cert validity. A sustained deployment crossing the one-year boundary needs a re-apply or pre-emptive re-issue.
- The cert's private key lives in Terraform state (S3 + DynamoDB lock per ADR-0025). State-bucket access controls protect the key — same trust assumption as other in-state secret material. See ADR-0037 for the secret minimization stance this fits within.
- `--cacert` not `-k`: the operator runs *real* cert verification, just against an explicitly-loaded CA. Avoids the bad habit of `-k` (which silences all cert errors, including ones from genuine attacks).
- Adding the `tls` provider to `required_providers` is the only new provider dependency — already a built-in HashiCorp provider, no third-party trust addition.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene calibration that this decision matches)
- ADR-0006 (VPN three-tier story; the encrypted Client VPN tunnel is the *first* layer, this ADR adds TLS as the second)
- ADR-0019 (private-only VPC; ALB is internal regardless of TLS termination)
- ADR-0024 (VPN cert provisioning; **not** the same cert, but the same operational pattern — provision out-of-band, import into ACM)
- ADR-0025 (state backend that protects the ALB cert's private key)
- ADR-0037 (secret minimization stance — this ADR's in-state private key is one of the intrinsic-secret materials surfaced under that posture)
