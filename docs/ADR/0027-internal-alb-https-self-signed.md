# ADR-0027: Internal ALB HTTPS via self-signed ACM-imported cert

## Status
Accepted (2026-04-25)

## Context

Phase 2.5 of the delivery (cloud-acceptance gate, see [ADR-0015](0015-no-k8s-no-real-apply.md) supersession block; phase numbering resequenced per ADR-0034 to put cloud-acceptance after async impl + cache impl) runs a real `terraform apply` against a personal AWS account inside a ≤ 3-hour window. The operator's curl from inside the Client VPN tunnel hits the internal ALB and verifies the prime-computation path end-to-end.

The composition's calibration is **production-shape architecture at PoC scale** ([ADR-0003](0003-poc-scope-prod-hygiene.md)). Production-shape implies TLS-everywhere at the ingress to compute — even when the hop in question is already inside an encrypted Client VPN tunnel. Defence-in-depth is canonical for production deployments: an attacker who breaches one layer (compromised VPN client cert, lateral movement from a compromised internal host) should not gain plaintext access to the application path. The brief never asks for it explicitly, but the buyer reading the deployment evidence with a `curl http://...` invocation reads "this candidate stopped at the first sufficient encryption layer" rather than "this candidate built the production-shape pattern".

The cost of TLS-everywhere at this scope is small — one ACM cert and one extra listener. The cost of *not* having it is a `https://` vs `http://` mismatch between the documentation (which has used `https://` from the beginning) and the deployed ALB.

The candidate hostname `api.enclave.internal` is internal-only — not in any public DNS zone the deliverable owns. ACM does not issue public certs for non-public hostnames; the alternatives table below covers the choices.

## Decision

The internal ALB terminates TLS on port 443 with a **self-signed certificate generated at `terraform apply` time via the `tls` provider, then imported into AWS Certificate Manager** as a regular ACM certificate.

Concretely:
- `tls_private_key.alb` (RSA-2048) — generated on first apply, persisted in remote state.
- `tls_self_signed_cert.alb` — `common_name = var.alb_internal_hostname` (default `api.enclave.internal`), one-year validity, `server_auth` extended key usage, `dns_names = [var.alb_internal_hostname]`.
- `aws_acm_certificate.alb` — imports the self-signed cert + private key; `lifecycle { create_before_destroy = true }` so listener-attached cert can rotate without an outage.
- ALB listener config replaces the prior HTTP-only listener with HTTPS:443 referencing `aws_acm_certificate.alb.arn` and `ssl_policy = "ELBSecurityPolicy-TLS13-1-2-2021-06"` (TLS 1.2 floor, TLS 1.3 preferred).
- ALB security group ingress changed from `http-80-tcp` to `https-443-tcp` — port 80 is not exposed.
- Two new outputs: `alb_cert_arn` (the ACM ARN) and `alb_self_signed_ca_pem` (the cert PEM body, public material). The operator captures the latter into a local file and uses `curl --cacert /tmp/alb-ca.pem ...` so cert verification passes without `-k` (`--insecure`) — the verification is real, just against an explicitly-loaded CA rather than a system trust store.

The operator's curl pattern from macOS during the Phase 2.5 acceptance window:

```bash
ALB_DNS=$(terraform -chdir=terraform output -raw alb_dns_name)
ALB_IP=$(dig +short $ALB_DNS | head -1)
terraform -chdir=terraform output -raw alb_self_signed_ca_pem > /tmp/alb-ca.pem
CURL="curl --cacert /tmp/alb-ca.pem --resolve api.enclave.internal:443:${ALB_IP}"
$CURL https://api.enclave.internal/health
```

The `--resolve` flag handles the DNS gap (no Route53 private zone), the `--cacert` handles the trust gap (self-signed cert).

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **HTTP only on port 80** | Forces every doc / curl example to read `http://`. Does not match the production-shape calibration the design doc commits to in § 1 / § 2. The encrypted boundary at the Client VPN tunnel is real, but defence-in-depth is the canonical production posture and the cost of adding TLS at the ALB is small. |
| **ACM public cert via DNS validation against an owned domain (e.g., `aegis-enclave.binhsu.org`)** | Trusted by default (no `--cacert` flag), auto-renewing, fully prod-shape. *But*: requires the binhsu.org Route53 zone to be in the same AWS account that runs the case-study build, or cross-account DNS delegation set up. Couples the deliverable's deployment to a personal-domain DNS arrangement that is not part of the case-study scope. The portability gain of `api.enclave.internal` (works in any AWS account without external coupling) outweighs the trust-store convenience. |
| **AWS Certificate Manager Private CA** | Issues a cert from a private CA hierarchy that ACM manages. Fully prod-shape (rotation, hierarchy, audit logs, IAM-controlled issuance). *But*: ACM Private CA costs ~**$400/month** for the CA itself, regardless of how many certs are issued. For a 3-hour acceptance window the cost is unacceptable (~$1.65 of pro-rated CA cost vs. $0 for self-signed-imported). For a sustained production deployment Private CA becomes the right call; the migration runbook can record that as a Phase X step when scale justifies it. |
| **Let's Encrypt via cert-bot DNS-01 challenge** | Free, trusted, auto-renewing. Requires a public domain (same constraint as the ACM-public option). Adds operational layer (cert-bot or an ACME terraform provider) which is not currently in the composition. Equivalent trade-off to the ACM-public option but with more moving parts. |
| **Sidecar TLS terminator (e.g., Envoy / nginx as a Fargate sidecar in front of the app)** | Decouples TLS from ALB, gives more flexibility (mTLS, custom headers, etc.). Adds a sidecar container, increases cognitive surface, blocks direct `terraform-aws-modules/alb` use. Over-engineered for the case-study scope and slows the Phase 2.5 acceptance window. Production architectures with strict mTLS requirements would revisit this. |

## Consequences

- The Phase 2.5 evidence section in `docs/deployment_guide.md` uses `https://` curl invocations consistently with the rest of the documentation, no `http://` mismatch to explain.
- The operator's curl command is more verbose (`--cacert` + `--resolve`) than the HTTP equivalent — strategy.md Phase 2.5 sequence pre-bakes a `CURL=` shell alias to compress the flags into a single repeated variable.
- The cert is regenerated on every fresh `tls_private_key` resource creation. With the S3-backed state backend ([ADR-0025](0025-terraform-state-backend-s3-dynamodb.md)) the key persists across applies; cert rotation requires explicit `terraform taint tls_private_key.alb` or destroy/recreate.
- One-year cert validity means a sustained deployment crossing the one-year boundary needs a re-apply or pre-emptive re-issue. Phase 2.5 is a 3-hour window, so this is theoretical for the case-study cycle but worth flagging for any operator extending the deliverable into a long-lived deployment.
- The cert's private key lives in Terraform state (S3 + DynamoDB lock per [ADR-0025](0025-terraform-state-backend-s3-dynamodb.md)). State-bucket access controls become the boundary that protects the key. This is the same trust assumption that already applies to RDS master credentials when those are managed inline.
- Adding the `tls` provider to `required_providers` is the only new provider dependency — already a built-in HashiCorp provider, no third-party trust addition.
- `--cacert` not `-k`: the operator runs *real* cert verification, just against an explicitly-loaded CA. This avoids the bad habit of `-k` (which silences all cert errors, including ones from genuine attacks).

## Related ADRs
- [ADR-0003](0003-poc-scope-prod-hygiene.md) — production-shape calibration that this decision matches
- [ADR-0006](0006-vpn-three-tier-story.md) — VPN three-tier story; the encrypted Client VPN tunnel is the *first* layer, this ADR adds TLS as the second
- [ADR-0015](0015-no-k8s-no-real-apply.md) — supersession block; Phase 2.5 (the cloud-acceptance window enabled by this ADR) is what makes ALB HTTPS visible
- [ADR-0019](0019-private-only-vpc-architecture.md) — private-only VPC; ALB is internal regardless of TLS termination, this ADR doesn't change the ingress path
- [ADR-0024](0024-vpn-certificate-provisioning.md) — Client VPN cert provisioning; **not** the same cert, but the same operational pattern (provision out-of-band, import into ACM)
- [ADR-0025](0025-terraform-state-backend-s3-dynamodb.md) — state backend that protects the ALB cert's private key
