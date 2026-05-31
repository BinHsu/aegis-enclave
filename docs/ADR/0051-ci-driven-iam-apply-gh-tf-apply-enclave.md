# ADR-0051: CI-driven IAM-creating apply/destroy via `gh-tf-apply-enclave` (governed-org path)

## Status
**Proposed** (2026-05-31). Supersedes — **for the governed-org deploy path only** — the operator-only-deploy stance of ADR-0015 and the "no CI/CD deploy" calibration of CLAUDE.md § 4. The forker / local path is unchanged. Awaiting sign-off before any workflow YAML or bootstrap role is scaffolded.

## Context

Today the enclave deploys **operator-driven**: a human runs `make cloud-up` under their `PlatformAdmin` SSO identity, which does the full `terraform apply` (ADR-0015, ADR-0034). CI does only **read-only** work — `ci.yml` (ruff + pytest) and `terraform-plan.yml` (PR-time read-only plan via the existing `aegis-enclave-gha-terraform-plan` OIDC role, ADR-0026, gated on the `AWS_TF_PLAN_ROLE_ARN` repo variable). CLAUDE.md § 4 lists CI/CD-to-deploy as out-of-scope at PoC calibration. The GitHub OIDC provider already exists in `terraform/bootstrap/`.

That model breaks when the enclave is deployed **into the aegis governed org**. The org SCP `deny-iam-privilege-escalation` denies the IAM-mutating actions (`iam:CreateRole`, `iam:AttachRolePolicy`, `iam:PassRole`, and the teardown twins `iam:DetachRolePolicy` / `iam:DeleteRolePolicy`) for **every** principal in member accounts **except** a name-glob allow-list: `gh-tf-*`, `aegis-emergency-*`, Control Tower / StackSets, and the K8s controllers. The human `PlatformAdmin` role and the read-only plan role are **not** in it.

Consequences proven on 2026-05-30:
- `make cloud-up` (human) cannot create the enclave's own IAM roles (ECS task/execution roles, etc.) → `iam:CreateRole` AccessDenied, apply halts.
- `make cloud-down` (human) cannot tear them down either — `DetachRolePolicy` / `DeleteRolePolicy` are in the same deny list. **Destroy is gated symmetrically with apply.**

So in the governed org, the enclave's IAM-creating apply **and** its IAM-destroying teardown must run as an identity inside the SCP carve-out. The carve-out namespace for CI deploy identities is `gh-tf-*` (landing-zone ADR-014; this repo's decision A: standardize CI apply roles as `gh-tf-apply-<repo>`, so the existing glob covers them with **zero SCP change** per repo).

## Decision

**1. Add a `gh-tf-apply-enclave` OIDC apply role** to `terraform/bootstrap/`, alongside the existing OIDC provider and the read-only plan role.
- Named in the `gh-tf-*` family → the org SCP glob already permits its IAM mutations; **the landing-zone needs no SCP edit**.
- Trust is rename-proof, matching the landing-zone pattern: `StringEquals` on `aud` + the immutable `repository_id`; `StringLike` on `sub` = `repo:<org>/*:ref:refs/heads/main`.
- Permissions are **scoped to the enclave apply surface**, not org-wide admin: VPC / ECS / SQS / S3 / DynamoDB / ElastiCache / Client VPN / ACM-read / CloudWatch, plus `iam:CreateRole`/`AttachRolePolicy`/`PassRole` constrained to `aegis-enclave-*` role paths, plus the IPAM allocate/read actions ADR-0050 needs (`ec2:AllocateIpamPoolCidr`, `ec2:GetIpamPoolAllocations`, `ec2:GetIpamPoolCidrs`).
- The existing read-only plan role (`aegis-enclave-gha-terraform-plan`) keeps its name — it is read-only, so it needs no carve-out. Aligning it to `gh-tf-plan-enclave` for family tidiness is optional, not required.

**2. Add two GitHub Actions workflows** (governed-org path):
- **apply** — on push to `main` (paths `terraform/**` + the image). Assumes `gh-tf-apply-enclave`, runs the IAM-creating apply. Injects the region→IPAM-pool-id mapping via an `*.auto.tfvars` (ADR-0050), so the governed deploy uses IPAM while the committed example stays static.
- **destroy** — `workflow_dispatch` (manual, deliberate). Assumes `gh-tf-apply-enclave`, runs `terraform destroy` — required because teardown needs the carved-out identity. Mirrors the sibling `aegis-platform-aws`'s `infra-ops.yml` dispatch-destroy pattern.

**3. Split of duties.** CI owns the IAM-creating apply/destroy. The operator still runs the human-in-the-loop steps locally — VPN cert PKI provisioning, the `cross-region-check` / smoke verification, evidence capture. `make cloud-up` / `make cloud-down` are **retained but re-scoped** in the governed org: the operator path covers the non-IAM + human steps; the IAM apply/destroy moves to CI.

**4. Forker dual-path (first-class).** A forker in an **ungoverned** account (no SCP) keeps the existing **end-to-end local** `make cloud-up` / `make cloud-down` — no CI role, no governance wall, no IPAM. The `gh-tf-apply-enclave` bootstrap and the two workflows are an **opt-in governed-org overlay**, not a requirement. This is the same forker-first split as ADR-0050.

**5. Chicken-and-egg seed.** The first creation of `gh-tf-apply-enclave` is itself an `iam:CreateRole` blocked for a human by the SCP → it needs **one** break-glass (`aegis-emergency-break-glass`) to seed the role (or the landing-zone's own apply seeds it). After that the role self-sustains via OIDC; no recurring break-glass.

## Alternatives Considered

- **Keep operator-only; break-glass each deploy.** Rejected. `aegis-emergency-break-glass` is an incident-only, audited identity; routing routine deploys through it normalizes the emergency path — the exact anti-pattern the SCP exists to prevent. Routine IAM-creation is meant to go through `gh-tf-*`.
- **Put the enclave deploy role in the landing-zone.** Rejected — gravity anti-pattern. The workload's deploy identity belongs **with the workload** (self-ownership); the landing-zone stays fabric-only (its ADR-017). The SCP glob is repo-agnostic, so the role lives in this repo and is still covered.
- **Put it in `aegis-platform-aws`.** Rejected — that is the EKS/ACK/IRSA tier for Kubernetes workloads; the enclave is standalone ECS, a different tier.
- **Broaden the SCP to allow `aegis-enclave-apply` (decision B).** Rejected per decision A — repo-branded role names force an SCP edit per repo (gravity/churn); `gh-tf-*` is the repo-agnostic CI-deploy namespace the SCP already governs.

## Consequences

- The enclave gains a governed, auditable, least-privilege CI deploy path with **no human Admin in the IAM-creating loop**.
- A new least-privilege **permission surface to maintain** — the `gh-tf-apply-enclave` policy must track the enclave apply footprint (including the ADR-0050 IPAM actions). Over-scoping it re-opens the escalation path the SCP closes; this policy is the load-bearing artifact to review.
- **Teardown behavior changes in the governed org**: destroy is a deliberate `workflow_dispatch`, no longer a pure-local `make cloud-down`. README + deployment_guide deploy/teardown sections need updating when scaffolding lands.
- **One break-glass to seed** the role (recorded; surgical `update-assume-role-policy`/create, not a full org-window detach).
- Scaffolding (the bootstrap role + two workflow YAMLs + the Makefile/README/deployment_guide re-scope + the CLAUDE.md § 4 supersession edit) is **deferred to a follow-up** after this ADR is signed off. On sign-off, Status → Accepted.

## Related ADRs
- **ADR-0015** — plan-only / operator-driven deploy: this adds the governed-org CI apply path (local path unchanged).
- **ADR-0025** — state bootstrap module (where the apply role is added).
- **ADR-0026** — the read-only OIDC plan role: `gh-tf-apply-enclave` is its apply sibling.
- **ADR-0034** — bounded cloud-acceptance apply window.
- **ADR-0050** — IPAM allocation: the apply workflow supplies the pool id via `*.auto.tfvars`.
- Cross-repo: landing-zone ADR-014 (the `gh-tf-*` role family) and the `deny-iam-privilege-escalation` SCP whose glob covers this role.
