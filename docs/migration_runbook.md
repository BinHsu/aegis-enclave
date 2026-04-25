# Migration Runbook — AWS → Alternative Cloud

> **Phase 2 deliverable.** Spec-grade, not code-grade. This document describes an agent-executable migration plan — designed for execution by an AI coding agent (with human oversight at marked gates) or a human engineer following the spec. The mapping table at the top is the only destination-specific artifact; the rest of the runbook is invariant.

The worked example destination here is **IONOS Cloud** (Frankfurt). To target a different destination — GCP, Azure, on-premise — only the **service-mapping** table changes; every step block below is destination-invariant.

---

## Format

Each step in this runbook follows a structured per-step schema, per [ADR-0012](ADR/0012-migration-runbook-agent-executable.md). The schema is what makes the runbook reliably executable by an AI coding agent: an agent that can read declarative intent, run a verification command, and halt at a `human_gate` boundary is a different operational asset from one given freeform prose.

| Field | Meaning |
|---|---|
| `precondition` | What must be true before running this step |
| `action` | The intent of the step, described declaratively |
| `verify_cmd` | A command that confirms the step succeeded |
| `expected_output` | What the verify_cmd output looks like on success |
| `on_failure` | Rollback action or escalation path |
| `human_gate` | `true` when the step is irreversible or destructive; halts agent autonomy |

---

## Service mapping (AWS → IONOS Cloud)

The AWS source-of-truth is `terraform/main.tf` in this repo. Each row below maps an AWS primitive used in that composition to its closest IONOS Cloud equivalent — or, where no managed equivalent exists, points at the Track 2 self-hosted answer.

| AWS | IONOS Cloud | Notes |
|---|---|---|
| `terraform-aws-modules/vpc/aws` (VPC + private/public subnets, NAT) | `ionoscloud_datacenter` + `ionoscloud_lan` (+ `ionoscloud_private_crossconnect` for inter-DC) | Datacenter is the IONOS containment unit; LANs are the L2 segments. Private cross-connects link datacenters when multi-DC topology is needed. |
| `terraform-aws-modules/rds/aws` (PostgreSQL 16, Multi-AZ) | `ionoscloud_dbaas_pgsql_cluster` | IONOS DBaaS PostgreSQL with HA replica. Engine version parity at PostgreSQL 16. Master credential management is operator-owned (no AWS Secrets Manager equivalent on the DB side). |
| `terraform-aws-modules/ecs/aws` (Fargate) | `ionoscloud_k8s_cluster` + `ionoscloud_k8s_node_pool` | IONOS has no managed serverless container runtime equivalent to Fargate. Managed Kubernetes is the closest peer; the application is repackaged as a Deployment + Service. |
| `terraform-aws-modules/alb/aws` (internal) | `ionoscloud_application_loadbalancer` | Application-layer (L7) load balancer. Health-check semantics map cleanly. |
| `terraform-aws-modules/ecr/aws` | self-hosted Harbor on IONOS, or external registry (`ghcr.io`, `quay.io`) | No native IONOS container registry. Harbor on a small VM is the typical self-hosted answer; an external public/private registry works if the buyer's policy allows. |
| `aws_ec2_client_vpn_endpoint` | **No equivalent** → see Track 2 (self-hosted NetBird) | This is the architectural pivot point — see paragraph below the table. |
| AWS Secrets Manager (RDS-managed master password) | self-hosted HashiCorp Vault, or SOPS+age committed to a private repo | No managed secrets service on IONOS at the DBaaS layer. Vault on a small VM is the typical self-hosted answer. |
| `terraform-aws-modules/security-group/aws` (stateful SGs at the ENI) | `ionoscloud_firewall` (rules at the NIC layer) | Stateful firewall rules attached per NIC. Semantically equivalent to AWS Security Groups for the patterns used in this repo. |
| AWS CloudWatch Logs | IONOS Logging Service (or self-hosted Loki / Elastic) | Out of scope for this runbook — observability migration is a separate axis. |

The cell that drives the rest of this runbook is the third-from-last row: **AWS Client VPN endpoint has no IONOS managed equivalent.** Per [ADR-0006](ADR/0006-vpn-three-tier-story.md), the recommendation is **self-hosted NetBird** — Berlin-based, EU-sovereign, WireGuard-mesh control plane. Cost analysis at typical team scale (30 users, 2 AZ associations, 24/7): AWS Client VPN endpoint lands near **~$1,400/month** ($16k/year); a NetBird control-plane VM on IONOS costs **~$8/month** at the same operational scale. A ~170× TCO reduction is the second-order benefit; the first-order driver is that there simply is no IONOS managed VPN endpoint to lift-and-shift to. The absence forces a self-hosted answer; the cost differential makes that answer attractive even where it isn't strictly forced.

---

## Track 1 — Application migration

**Owner:** Application / Cloud team (per [ADR-0010](ADR/0010-vpn-ownership-app-vs-platform.md)).
**Scope:** VPC-equivalent → managed PostgreSQL → container orchestration → load balancer → image registry → secrets → traffic cutover.
**Total estimated steps:** 7

### Step 1.1 — Provision IONOS datacenter and private network

| Field | Value |
|---|---|
| `precondition` | IONOS account active; API token configured in the agent's environment (`IONOS_TOKEN` env var or `~/.ionos/config`); destination region capacity confirmed. |
| `action` | Create an IONOS datacenter in `de/fra` (Frankfurt) — the closest geographic equivalent to AWS `eu-central-1`. Provision a LAN with the same CIDR shape as the AWS VPC (10.0.0.0/16, two private subnets in distinct availability zones — 10.0.1.0/24 and 10.0.2.0/24). |
| `verify_cmd` | `ionosctl datacenter list --cols Id,Name,Location` |
| `expected_output` | One row showing the new datacenter named `aegis-enclave-dc` in `de/fra` location. |
| `on_failure` | If the datacenter creation fails: check API token scope (must include `datacenter:create`), then re-run. If location quota exhausted: file a quota-increase request with IONOS support — this is a manual escalation, agent should halt and surface the ticket reference. |
| `human_gate` | `false` — creation is reversible; an empty datacenter can be deleted with no data impact. |

### Step 1.2 — Provision Managed PostgreSQL with HA replica

| Field | Value |
|---|---|
| `precondition` | Step 1.1 complete; LAN ID known; master-credential value generated and staged in the chosen secret store (Vault or SOPS). |
| `action` | Provision `ionoscloud_dbaas_pgsql_cluster` with PostgreSQL 16, instance class equivalent to `db.t4g.micro` (1 vCPU / 2 GiB RAM / 20 GiB storage), HA enabled (replica in a second availability zone), backup retention 7 days, attached to the LAN from Step 1.1. |
| `verify_cmd` | `ionosctl dbaas postgres cluster list --cols Id,DisplayName,State,Location` |
| `expected_output` | Cluster row in `AVAILABLE` state, located in `de/fra`. |
| `on_failure` | If cluster fails to reach `AVAILABLE` within 20 minutes: check IONOS service health page; if region-wide degradation, halt and notify operator. If quota error: file IONOS quota-increase request. |
| `human_gate` | `false` — provisioning is reversible, no data has been written yet. |

### Step 1.3 — Provision Managed Kubernetes cluster and node pool

| Field | Value |
|---|---|
| `precondition` | Step 1.1 complete; LAN ID known. Kubernetes version target chosen (track latest stable supported by IONOS Managed K8s). |
| `action` | Provision `ionoscloud_k8s_cluster` attached to the datacenter from Step 1.1, plus an `ionoscloud_k8s_node_pool` with 2 nodes (each 2 vCPU / 4 GiB RAM, sized as the closest peer to the ECS Fargate `cpu=256, memory=512` task definition × 2 task replicas). This replaces ECS Fargate from the AWS composition — IONOS has no managed serverless container runtime, so the application is repackaged as a Deployment. |
| `verify_cmd` | `ionosctl k8s cluster list --cols Id,Name,State` && `ionosctl k8s nodepool list --cluster-id <id> --cols Id,Name,State` |
| `expected_output` | Cluster row in `ACTIVE` state; node pool row in `ACTIVE` state with `NodeCount=2`. |
| `on_failure` | If cluster fails to reach `ACTIVE`: check IONOS service health; check that the LAN from Step 1.1 still exists. Delete and retry if stuck in `BUSY` for >30 minutes (rare but documented). |
| `human_gate` | `false` — empty cluster can be deleted with no impact. |

### Step 1.4 — Push application image to chosen registry

| Field | Value |
|---|---|
| `precondition` | Application image previously built and pushed to AWS ECR; chosen target registry decision recorded (self-hosted Harbor on IONOS, or external — typical choice: `ghcr.io/<org>/aegis-enclave`); registry credentials staged. |
| `action` | Pull the application image from AWS ECR by tag, retag for the destination registry, push to the destination registry. The image content is unchanged — only the registry coordinates differ. |
| `verify_cmd` | `crane manifest <destination-registry>/aegis-enclave:<tag>` (or `docker manifest inspect`, equivalent) |
| `expected_output` | Valid image manifest JSON returned; HTTP 200; same image digest as the AWS ECR source. |
| `on_failure` | If push fails: verify destination registry credentials and that the destination repo exists. If digest mismatch: re-pull from ECR; never push a re-tagged image without verifying digest parity. |
| `human_gate` | `false` — the image is content-addressable; failed pushes leave no artifact behind. |

### Step 1.5 — Deploy application via Kubernetes manifests

| Field | Value |
|---|---|
| `precondition` | Steps 1.2 (DBaaS), 1.3 (K8s cluster), 1.4 (registry) complete; secret store (Vault or SOPS) reachable from the cluster; manifests authored: Deployment, Service (ClusterIP), ExternalSecret (or sealed Secret) referencing the Vault path for the DB password. |
| `action` | Apply the Deployment + Service + Secret manifests to the cluster. The Deployment pulls the image from the registry chosen in Step 1.4. The Secret provides the DB password from the external secret store. The Service exposes port 8000 inside the cluster as a ClusterIP — the load balancer in Step 1.6 will be the external entrypoint. |
| `verify_cmd` | `kubectl get pods -l app=aegis-enclave -o jsonpath='{.items[*].status.phase}'` |
| `expected_output` | Both pods in `Running` phase; application healthcheck endpoint `/health` returns `200 OK` from inside the cluster (verified via `kubectl exec` from a debug pod). |
| `on_failure` | If pod stuck in `CrashLoopBackOff`: check logs (`kubectl logs`), most common cause is DB connectivity (verify firewall rule from cluster nodes to DBaaS). If `ImagePullBackOff`: verify registry credentials are present as `imagePullSecrets`. |
| `human_gate` | `false` — Deployment can be rolled back with `kubectl rollout undo`; no production traffic yet. |

### Step 1.6 — Provision Application Load Balancer

| Field | Value |
|---|---|
| `precondition` | Step 1.5 complete; Kubernetes Service from Step 1.5 exposes a stable internal endpoint. |
| `action` | Provision `ionoscloud_application_loadbalancer` in the datacenter from Step 1.1, targeting the Kubernetes Service NodePort (or LoadBalancer-type service backed by IONOS ALB). Health check matches the AWS ALB target group config: HTTP `GET /health`, healthy threshold 2, unhealthy threshold 3, interval 30s, timeout 5s. The ALB is internal — reachable only from inside the IONOS network, not from the public internet (matches AWS `internal = true`). |
| `verify_cmd` | `curl -sf http://<alb-internal-dns>/health` from a host on the IONOS LAN |
| `expected_output` | `200 OK` with the application healthcheck JSON payload (`{"status":"ok","db":"reachable"}`). |
| `on_failure` | If ALB shows healthy but `curl` fails: check `ionoscloud_firewall` rules — the NIC firewall must allow the ALB SNAT range to the K8s NodePort. If healthcheck fails on the ALB side but pods are healthy: check the listener/target-group port mapping. |
| `human_gate` | `false` — ALB has no production traffic yet; can be deleted without user impact. |

### Step 1.7 — Cutover traffic from AWS to IONOS

| Field | Value |
|---|---|
| `precondition` | Track 1 steps 1.1-1.6 complete and individually verified; Track 2 (VPN modernisation) steps 2.1-2.4 complete; operators tested via NetBird against the IONOS endpoint; DB schema and data parity verified between AWS RDS and IONOS DBaaS (final dump-and-restore window agreed with operators). |
| `action` | Update the DNS record for the API hostname (CNAME or A record at the operator's chosen DNS provider — typically Route 53, Cloudflare, or the buyer's internal DNS) to point operator/client traffic at the IONOS ALB DNS name. Optionally use weighted DNS for gradual cutover (10% / 50% / 100% over 24-72h) to limit blast radius if a regression is observed. |
| `verify_cmd` | `curl --resolve <api-host>:443:<ionos-alb-ip> https://<api-host>/health` from a VPN-connected operator host |
| `expected_output` | `200 OK` with healthy response from IONOS-side service; subsequent `GET /executions/<id>` returns rows from the IONOS DBaaS, not the AWS RDS. |
| `on_failure` | Rollback: revert DNS record to the AWS ALB. With a 60-second TTL on the DNS record, blast radius is minutes, not hours. Investigate the regression on IONOS-side without time pressure before re-attempting cutover. |
| `human_gate` | **`true`** — production traffic cutover is irreversible at the user-perception layer (operators see whichever cloud answers their requests). Humans must sign off on the cutover window and confirm the rollback path is staged. |

---

## Track 2 — VPN modernisation

**Owner:** Platform / Network team (per [ADR-0010](ADR/0010-vpn-ownership-app-vs-platform.md)).
**Scope:** Replace AWS Client VPN endpoint (no IONOS equivalent) with self-hosted NetBird control plane on IONOS infrastructure, configured for hub-and-spoke topology per [ADR-0011](ADR/0011-topology-hub-and-spoke.md).
**Total estimated steps:** 5

### Step 2.1 — Provision NetBird control-plane VM on IONOS

| Field | Value |
|---|---|
| `precondition` | Step 1.1 complete (datacenter exists); SSH key staged; firewall policy decided (control plane reachable on 443/TCP for management UI, 33073/TCP for signal, 3478/UDP for STUN, 49152-65535/UDP for TURN if Coturn co-located). |
| `action` | Provision a small IONOS VM (1 vCPU / 2 GiB RAM / 20 GiB storage — ~$8/month) in the Frankfurt datacenter from Step 1.1. Per the cost analysis in [ADR-0006](ADR/0006-vpn-three-tier-story.md), this represents a ~170× TCO reduction vs. AWS Client VPN endpoint at typical team scale (30 users, 24/7) — the cost differential is the second-order benefit on top of the primary fact that IONOS has no managed Client VPN endpoint to lift-and-shift to. |
| `verify_cmd` | `ionosctl server list --datacenter-id <id> --cols Id,Name,State` |
| `expected_output` | Server row in `AVAILABLE` state. |
| `on_failure` | If provisioning fails: check VM quota in the datacenter region. If state stuck in `BUSY` for >15 minutes: open IONOS support ticket, halt and surface the ticket reference. |
| `human_gate` | `false` — empty VM can be deleted with no impact. |

### Step 2.2 — Install NetBird management server, signal server, dashboard

| Field | Value |
|---|---|
| `precondition` | Step 2.1 complete; SSH access to the VM working; Docker + Docker Compose installed; OIDC/SSO provider details staged (the buyer's existing identity provider — Auth0, Keycloak, Azure AD, etc.). |
| `action` | Install NetBird from the official Docker Compose manifest (`getting-started-with-zitadel.sh` or equivalent self-hosted installer). Configure SSO integration so peer enrollment is identity-bound to the buyer's existing identity provider — peer provisioning never relies on shared static tokens. Generate TLS material for the management UI (Let's Encrypt or buyer's internal CA). |
| `verify_cmd` | `curl -sf https://<netbird-host>/api/health` |
| `expected_output` | `200 OK` with NetBird management API healthcheck JSON. |
| `on_failure` | If management server fails to start: check Docker logs for each service (management, signal, dashboard, Coturn). Common cause: misconfigured OIDC issuer URL — verify discovery endpoint is reachable from the VM. |
| `human_gate` | `false` — installation is non-destructive; no peers enrolled yet. |

### Step 2.3 — Configure ACL for hub-and-spoke topology

| Field | Value |
|---|---|
| `precondition` | Step 2.2 complete; NetBird admin account bootstrapped via SSO; group definitions decided (`operators`, `services`, `gateway`). |
| `action` | Configure NetBird ACL rules to enforce hub-and-spoke topology per [ADR-0011](ADR/0011-topology-hub-and-spoke.md). Allow: `operators` → `gateway` subnet, `gateway` → `services` subnet (which routes to the IONOS application LAN). Deny by default; explicitly: `operators` → `operators` is blocked (no peer-to-peer between operators despite NetBird's mesh capability). The mesh is constrained by policy, not by tool choice. |
| `verify_cmd` | `curl -sf -H "Authorization: Token <admin-token>" https://<netbird-host>/api/policies | jq '.[].rules'` |
| `expected_output` | JSON listing the three allow rules above; no rule listing `operators` → `operators` as allowed. |
| `on_failure` | If ACL doesn't apply: check NetBird management server logs for policy parse errors. Re-apply via the dashboard if the API path fails. |
| `human_gate` | `false` — ACL changes are applied to a non-production system at this stage; operators not yet enrolled. |

### Step 2.4 — Distribute peer credentials to operators

| Field | Value |
|---|---|
| `precondition` | Step 2.3 ACL applied and verified; operator roster confirmed by the buyer's identity owner; secure distribution channel agreed (1Password Business shared vault, HashiCorp Vault, or out-of-band per the buyer's policy). |
| `action` | Issue peer enrollment tokens via the NetBird dashboard — one-time-use, time-limited (24h expiry). Distribute to each operator via the agreed secure channel. Each operator runs the NetBird client install + enrollment with their personal token; the token binds to their SSO identity at first connect. |
| `verify_cmd` | NetBird dashboard `/peers` endpoint shows expected peer count under the `operators` group: `curl -sf -H "Authorization: Token <admin-token>" https://<netbird-host>/api/peers | jq '[.[] | select(.groups[].name == "operators")] | length'` |
| `expected_output` | Peer count matches the operator roster (e.g. `30` for a 30-operator team). |
| `on_failure` | Revoke unused tokens immediately; re-issue with corrected ACL group assignment. If a peer enrolls into the wrong group: revoke that peer in the dashboard, reset, re-enroll. |
| `human_gate` | **`true`** — credential distribution is identity-bound and auditable; humans must verify the recipient list against the operator roster before tokens are issued. An agent issuing tokens to a list it inferred is an audit failure. |

### Step 2.5 — Decommission AWS Client VPN endpoint

| Field | Value |
|---|---|
| `precondition` | Track 1 step 1.7 complete (DNS cutover in production); Track 2 steps 2.1-2.4 complete; observed clean operator traffic via NetBird for **>7 days** with no fallback connections to the AWS Client VPN endpoint (verified via AWS Client VPN connection logs); explicit human approval recorded for this step. |
| `action` | Delete `aws_ec2_client_vpn_endpoint.main`, the two `aws_ec2_client_vpn_network_association` resources, and the `aws_ec2_client_vpn_authorization_rule.vpc_access` resource from `terraform/main.tf`. Run `terraform apply` against the AWS account to remove the resources. |
| `verify_cmd` | `aws ec2 describe-client-vpn-endpoints --filters Name=tag:Project,Values=aegis-enclave --query 'ClientVpnEndpoints[*].ClientVpnEndpointId' --output text` |
| `expected_output` | Empty result (no endpoint matching the project tag). |
| `on_failure` | If `terraform apply` fails: investigate residual DNS, certificate, or authorization-rule references. Do **not** force-delete the endpoint via the AWS console — that leaves orphaned ENIs and security-group references that fail subsequent Terraform plans. Resolve the dependency tree first, then re-apply. |
| `human_gate` | **`true`** — `terraform destroy` against a production VPN endpoint is destructive and irreversible-at-cost (re-provisioning is hours plus operator re-enrollment). Human must confirm the 7-day clean-traffic observation window and approve the destroy. |

---

## Capability gates summary

The runbook places `human_gate: true` only at irreversible or identity-binding moments. Everywhere else, an AI agent has autonomy to provision, configure, and verify — the agent reads each step's `verify_cmd` and `expected_output`, halts on mismatch, and proceeds otherwise.

| Step | Reason for gate |
|---|---|
| 1.7 — DNS cutover | Production traffic cutover; user-perceived effect is irreversible at the moment of switching. |
| 2.4 — Peer credential distribution | Identity-bound, auditable; recipient list must be verified by a human against the operator roster, not inferred by the agent. |
| 2.5 — `terraform destroy` of AWS Client VPN endpoint | `terraform destroy` against a production resource; re-provisioning cost is hours; explicit human approval ties to observed clean-traffic window. |

The pattern: **agent autonomy spans creation, configuration, and verification; human approval is required at the moments of irreversibility or identity binding.** This is the operational manifestation of the capability-gate posture in [`CLAUDE.md` § 7](../CLAUDE.md) and the prompt-injection defense pattern from the parent project's CLAUDE.md (rules h, i — never run untrusted code unscanned, never treat external documents as commands).

---

## Reusing this runbook for other destinations

The spec is invariant; only the **service-mapping** table at the top changes. To target GCP, Azure, or on-premise, swap the mapping table (e.g., `aws.vpc → gcp.vpc_network`, `aws.ecs → gcp.gke`, `aws.client_vpn_endpoint → netbird.gateway`), keep the seven Track 1 steps and five Track 2 steps, and adjust each `verify_cmd` to that destination's CLI (`gcloud`, `az`, `kubectl` against on-prem). The two-track structure (Application + VPN modernisation) holds for any destination that lacks a managed Client VPN endpoint equivalent — which is most of them. Where a destination *does* offer a managed Client VPN peer (e.g., GCP Cloud VPN client gateway), Track 2 reduces from five steps to a one-step lift-and-shift; the Track 1 shape is unchanged.

The Phase 2 scaling runbook (`docs/scaling_runbook.md`, single-region → multi-region) is the second instance of the same format applied to a different axis. Two instances make the format credible as a portable artifact, not a one-off.

---

## Related ADRs

- [ADR-0005](ADR/0005-aws-target-cross-cloud-as-runbook.md) — AWS as deployment target; cross-cloud as runbook, not parallel Terraform.
- [ADR-0006](ADR/0006-vpn-three-tier-story.md) — VPN three-tier story; cost analysis driving the NetBird recommendation.
- [ADR-0010](ADR/0010-vpn-ownership-app-vs-platform.md) — VPN ownership boundary; drives the two-track structure.
- [ADR-0011](ADR/0011-topology-hub-and-spoke.md) — Hub-and-spoke topology; constrains the NetBird mesh capability via ACL.
- [ADR-0012](ADR/0012-migration-runbook-agent-executable.md) — The agent-executable spec format that this runbook implements.
