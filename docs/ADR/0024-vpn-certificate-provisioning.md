# ADR-0024: VPN certificate provisioning — easy-rsa + ACM imported (no PCA)

## Status
Accepted (2026-04-25)

## Context
The Client VPN endpoint declared in `terraform/main.tf:330` requires two ACM certificate ARNs to come from somewhere:

- `var.server_cert_arn` — the TLS server certificate the VPN endpoint presents to connecting clients.
- `var.client_cert_arn` — the **root CA certificate** that signed the client certificates the endpoint will accept (mutual TLS authentication).

Both variables are currently empty placeholders; they must be filled before `terraform apply` can produce a working VPN. Three provisioning paths exist in AWS:

| Path | What it is | Cost | Fits this case? |
|---|---|---|---|
| **ACM public-trust certificate** | DNS-validated cert chained to a public CA. | $0 / cert. | ❌ — requires a registered domain on Route53. The case-study deliverable is a private VPN endpoint with no DNS exposure; setting up a domain is out of scope. |
| **AWS Private CA (ACM PCA)** | Fully-managed private CA, integrated with ACM. | **$400/month per CA** for general-purpose; **$50/month** for short-lived (≤7-day) mode + $0.058 per cert. | ❌ — flat monthly fee dwarfs the entire compute footprint of the case study. The deliverable does not justify a $50-$400/month CA. |
| **Self-signed CA + ACM imported certificates** | Generate a CA + server cert + client cert with `easy-rsa` locally; import the resulting PEMs into ACM as **imported** certificates. | **$0 / month, $0 / cert.** ACM imports are free (the per-month fee is on PCA, not on ACM itself). | ✅ — matches the cost envelope, the privacy posture, and the AWS-recommended workflow for Client VPN cert authentication. |

`easy-rsa` is the workflow AWS Client VPN documentation explicitly recommends for cert-based authentication (`https://docs.aws.amazon.com/vpn/latest/clientvpn-admin/client-authentication.html#mutual`). It is the OpenVPN community's standard tooling, not bespoke shell.

## Decision
Use `easy-rsa` to generate a private CA and the two certificates the Client VPN endpoint requires; import them into ACM with `aws acm import-certificate`; pass the resulting ARNs to Terraform via `terraform.tfvars`.

**Provisioning artefact:** `scripts/bootstrap-vpn-certs.sh` runs the full sequence end-to-end:

1. Bootstrap a fresh PKI directory with `easyrsa init-pki`.
2. Build a CA (`easyrsa build-ca nopass`) — emits `ca.crt` + `ca.key`.
3. Issue the server certificate (`easyrsa --san=DNS:server build-server-full server nopass`) — emits `server.crt` + `server.key`.
4. Issue one client certificate per operator (`easyrsa build-client-full <name> nopass`) — emits `<name>.crt` + `<name>.key`.
5. Import the server cert into ACM (server cert + key + CA chain) — emits `server_cert_arn`.
6. Import the CA root into ACM (root cert + root key, since Client VPN's mutual-TLS expects the root certificate) — emits `client_cert_arn`.
7. Print the two ARNs ready to paste into `terraform.tfvars`.
8. Print the path of `<name>.ovpn` files generated for distribution.

The script is **idempotent**: re-running with the same `--operator` list re-imports certs (ACM treats re-import of the same certificate as no-op). New operator names trigger fresh client cert issuance.

## Cost model

| Component | Frequency | Cost |
|---|---|---|
| Generate CA + certs locally | Once per environment | $0 |
| Import 2 certificates into ACM | Once per environment (re-import idempotent) | $0 |
| Store imported certificates | Ongoing | $0 (ACM imports are free) |
| Client cert issuance to add a new operator | Ad-hoc | $0 |
| **Total monthly** | | **$0** |

Compare: ACM PCA short-lived mode would be $50/month (one CA) + $0.058 per cert. For a 5-operator case study, that's $50 + 5 × $0.058 ≈ $50.29/month vs $0. Over a 6-month case-study cycle: $300+ vs $0. The trade-off is that a self-signed CA does not auto-rotate; client certs are valid for the default 825 days (~2.25 years), which is comfortably longer than any case-study lifetime.

## Security posture

A self-signed CA has the same trust model as a private commercial CA from the perspective of the Client VPN endpoint — both are private CAs, neither is publicly trusted. The differentiator is **CA root key custody**:

- ACM PCA stores the root key in CloudHSM, never exposes it.
- Self-signed easy-rsa stores the root key as a file (`pki/private/ca.key`) on the operator's laptop or in a secrets store.

For a case-study deployment with 1-3 operators and no production data, a file-on-laptop CA root with reasonable handling (chmod 600, gitignored, rotated when staff change) is appropriate. **For a real production deployment with operator turnover or compliance requirements, ACM PCA short-lived mode is the upgrade path** — declared in this ADR's Future section.

The script writes all PKI artefacts to a directory (`./pki/`) that the repo's `.gitignore` already covers (`*.key`, `*.pem`). The script refuses to run if it would overwrite an existing `pki/` without explicit `--force`, preventing accidental CA destruction.

## Operator distribution

Each operator gets one `<name>.ovpn` file containing:
- Inline `<ca>` block (CA root cert)
- Inline `<cert>` block (their client cert)
- Inline `<key>` block (their client private key)
- The Client VPN endpoint hostname (looked up from Terraform output post-`apply`)

`<name>.ovpn` opens directly in OpenVPN, Tunnelblick (macOS), or AWS VPN Client. No separate config exchange needed.

## Consequences

**Positive:**
- $0/month VPN cert footprint vs $50-$400/month for ACM PCA.
- Standard tooling (easy-rsa) means operators can audit the script.
- Idempotent re-runs — adding a new operator is one command.
- Drops cleanly into the existing `ts_apply.sh` pre-flight check 5/6 (ACM cert reachable).

**Negative:**
- CA root key lives as a file. Rotation = generate new CA, re-issue all certs, re-import. Not automated.
- No CRL (Certificate Revocation List) automation. Revoking a leaving operator's access requires re-generating the CA root — manual, but the case-study operator count makes that workable.
- Imported ACM certs do not auto-renew. The 825-day default expiry is well past any case-study lifetime, but a long-running deployment would need a manual re-import on year ~2.

## Alternatives considered

**A. Use ACM PCA short-lived mode.** $50/month with $0.058/cert. **Rejected for Phase 1 / 2 case study** — the cost is real and the value (managed key custody, CRL automation) doesn't pay back at this scale. **Listed as the Phase-3 upgrade path** if the deliverable becomes long-lived production.

**B. Use Let's Encrypt for the server cert + a private CA only for client root.** Lets Encrypt requires public DNS validation, which means exposing a hostname for the VPN endpoint — counter to the "private-only VPC, VPN-gated reachability" posture (ADR-0019, ADR-0006). **Rejected** — couples public-DNS hygiene to an internal access path that should not require it.

**C. SAML/OIDC federation instead of mutual-TLS.** AWS Client VPN supports SAML / Active Directory / mutual-TLS; mutual-TLS is the chosen mode in `terraform/main.tf:336`. SAML would integrate with the SSO already in place (per Bin's note 2026-04-25), removing the cert distribution step entirely. **Deferred to Phase 3** — switching auth modes is an `aws_ec2_client_vpn_endpoint` argument change, not an architectural overhaul; can be done after the cert path is proven. Tracked as a follow-up.

## Future direction

If the deployment graduates from case-study to long-running production:

1. Generate a fresh CA with **ACM PCA short-lived mode** ($50/month).
2. Switch the Client VPN endpoint's `client_cert_arn` to the new CA root in ACM.
3. Re-issue all operator client certs from the new CA via PCA's auto-renewal.
4. Or — **switch authentication from mutual-TLS to SAML federation** to eliminate per-operator cert distribution entirely (Alternative C above).

Either upgrade is single-digit hours of work at the point it becomes economical.

## Related
- ADR-0006 — VPN three-tier story (informs why mutual-TLS was the case-study choice)
- ADR-0015 — no real apply during case-study cycle (this ADR is in scope for the Phase-2 supersession block)
- ADR-0019 — private-only VPC architecture (informs why public-DNS validation paths are out of bounds)
- ADR-0023 — deferred auto-scaling (sister ADR for "what we left configuration-only for Phase 2")
