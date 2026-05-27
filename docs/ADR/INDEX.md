# ADR Index — read by goal, not by number

38 ADRs is overwhelming for first-time onboarding. This index groups them by reader goal so you can pick the load-bearing ones for *your* purpose and skip the rest.

Numbering has gaps (ADR-0002 / 0009 / 0021 / 0022 / 0028 / 0032 / 0035 are deleted; numbers are not reused per the monotonic numbering convention).

## Pick your goal

| Goal | Read | ~Time |
|---|---|---|
| **A. "I want to verify it works"** (run smoke + understand what passed) | Bands A + B-CORE (6 ADRs) | 20 min |
| **B. "I'm modifying / extending the architecture"** | A + B (full) (11 ADRs) | 50 min |
| **C. "Code review — I need to judge the engineering"** | A + B + C (~22 ADRs) | 90 min |
| **D. "Forking for production deployment"** | All bands + `production_adoption.md` | 2–3 hrs |

Within each band, ADRs are ordered by reading priority within that band, not by number.

## Engineering signal mapping (for code reviewers)

Mapping ADRs to senior-engineer rubric axes:

| Signal axis | Primary ADRs | What to look for |
|---|---|---|
| **Async API boundary** | 0029, 0033, 0030 | POST 202 + poll + DDB state machine; SQS visibility 90 s; ElasticMQ local parity |
| **Compute load management** | 0020, 0033, 0023 | Three-layer defense (schema cap / queue backpressure / SIGALRM) + auto-scaling on per-worker queue depth |
| **Failure handling** | 0033, 0038 | Idempotent retry; DLQ alarm + manual triage (anti-auto-retry rationale) |
| **Observability** | 0041, 0008, 0003 | SLI via EMF + CloudWatch Dashboard + multi-window burn-rate alarms (Google SRE Workbook pattern) + opt-in SNS email |
| **Reliability calibration** | 0008, 0007, 0042 | Workload-tier-driven SLO/RTO/RPO; per-region 3-AZ posture; multi-region active-active via DDB Global Tables |
| **Decision documentation** | (this INDEX + every ADR's Status / Related field) | Nygard MADR; sparse-Alternatives industry-context style |
| **Calibration honesty** | 0003, 0013, 0015, 0034, 0037, 0042 | PoC scope + prod hygiene split; deliverable-not-demo; methodology-as-meta-ADR; secret minimization |
| **Supply chain rigor** | 0039, 0036, 0026 | uv.lock + terraform exact-pin + `--provenance=false` ECR + OIDC short-lived tokens |
| **Cost discipline** | 0006, 0015, 0024, 0027, 0031 (+ deployment_guide § Cost shape) | Per-component cost analysis; per-hour rates; FinOps scope honest |
| **Security posture** | 0019, 0024, 0027, 0037, 0042 | Private-only VPC (no IGW/NAT); mTLS Client VPN; passwordless data plane (DDB IAM-authn); DDB endpoint via PrivateLink |
| **Agent-executable runbooks** | 0012, 0014 (+ migration_runbook + scaling_runbook) | precondition / action / verify_cmd / on_failure / human_gate schema |
| **Reproducibility from cold** | 0039, 0036, 0030 | Lock files; deterministic image tags; local↔cloud parity |
| **Test rigor** | (CLAUDE.md § 8 + tests/) | BVA mandatory; branch coverage 95%; sympy differential; deterministic-seed fuzz |
| **Capability gates / human-in-loop** | 0012, 0024 (+ CLAUDE.md § 6) | Auto / Confirm / Refuse policy on irreversible operations |

---

## Band A — Calibration (read these or you don't understand the deliverable)

These four set the scope, calibration framework, methodology, and target-shape that every other decision lives inside.

| ADR | What it decides | Why load-bearing |
|---|---|---|
| [0001](0001-repo-identity-aegis-enclave.md) | What this repo is — case-study deliverable shaped as a reusable portfolio template | Frames the 90/10 generic-vs-buyer split that shapes every gitignore decision |
| [0003](0003-poc-scope-prod-hygiene.md) | PoC feature surface + production-grade engineering hygiene | The central in-scope vs out-of-scope discriminator |
| [0008](0008-reliability-targets-slo-rto-rpo.md) | Workload-tier-driven SLO / RTO / RPO targets | Tier 2 ops support classification; calibrates every reliability decision downstream |
| [0034](0034-build-budget-22-to-24h-l4-expansion.md) | Delivery methodology — PoV/scrum staging with validation gates | The *how* sister to ADR-0003's *what* |

---

## Band B — Architecture (the choices that shape the code you read)

### B-CORE (smallest set that explains "why does it look like this?")

| ADR | What it decides |
|---|---|
| [0015](0015-no-k8s-no-real-apply.md) | ECS Fargate (over EKS) cloud + Docker Compose local parity — coupled architectural shape |
| [0019](0019-private-only-vpc-architecture.md) | Private-only VPC: no IGW, no NAT. All AWS API egress via interface VPC endpoints |
| [0029](0029-async-post-sqs-worker-pool.md) | POST returns 202 + queue + worker pool (vs synchronous compute) |
| [0031](0031-elasticache-serverless-valkey-zset-lua-coalescing.md) | ElastiCache Serverless Valkey + ZSET + Lua range-coalescing |
| [0033](0033-async-drain-semantics-sigalrm-sqs-redelivery.md) | Worker SIGALRM 60 s + SQS visibility 90 s; queue redelivery rescues message, SIGALRM rescues worker |
| [0042](0042-dynamodb-global-tables-greenfield-multi-region.md) | **Production data store**: DynamoDB Global Tables active-active dual-region (Frankfurt + Ireland) |

### B (full architecture set)

| ADR | What it decides |
|---|---|
| [0006](0006-vpn-three-tier-story.md) | Three VPN tiers: WireGuard local / Client VPN cloud / NetBird production-cross-cloud |
| [0007](0007-single-region-multi-az.md) | Per-region 3-AZ posture (production default; loss of one AZ = 33% degradation) |
| [0011](0011-topology-hub-and-spoke.md) | Network topology — single VPC with private subnets across AZs |
| [0017](0017-prime-computation-strategy.md) | The actual algorithm: 6k±1 small / sieve large / SIGALRM hard deadline |
| [0018](0018-managed-default-tool-selection.md) | Why each AWS managed service: Client VPN (managed, IAM-integrated) over self-hosted, DDB over Vault, etc. |
| [0020](0020-unified-prime-cache-and-cost-estimator.md) | Compute load management — three-layer defense (schema cap / queue backpressure / SIGALRM) |
| [0023](0023-deferred-autoscaling-fixed-task-count.md) | ECS worker auto-scaling — target tracking on per-worker SQS depth |
| [0024](0024-vpn-certificate-provisioning.md) | Self-signed CA + ACM-imported (vs ACM PCA at $400/mo) |
| [0027](0027-internal-alb-https-self-signed.md) | Internal ALB HTTPS via self-signed cert imported into ACM |

---

## Band C — Operational + supporting decisions (code reviewers and production forkers)

### C-OPERATIONS (how the system behaves in motion)

| ADR | What it decides |
|---|---|
| [0036](0036-image-tag-git-sha-immutable-ecr.md) | Git-SHA image tagging + `--provenance=false --sbom=false` for IMMUTABLE-friendly deterministic ECR manifests |
| [0037](0037-secrets-manager-rotation-deferred.md) | Secret minimization posture — IAM-first, mTLS over token, passwordless data plane |
| [0038](0038-dlq-alarm-triage-not-auto-retry.md) | DLQ pattern: CloudWatch alarm + manual triage script, NOT auto-retry worker (anti-pattern analysis) |
| [0041](0041-observability-amp-amg-not-grafana-cloud.md) | Observability backend: CloudWatch SLI emission + multi-window burn-rate alarms + opt-in SNS email |

### C-SUPPORTING (tool choices, build hygiene, dev parity)

| ADR | What it decides |
|---|---|
| [0010](0010-vpn-ownership-app-vs-platform.md) | Why VPN is part of the application repo (not a platform-level prereq) |
| [0014](0014-mermaid-smoke-test-acceptance.md) | Mermaid only; no draw.io / images / Figma |
| [0016](0016-community-terraform-modules.md) | terraform-aws-modules over hand-rolled — pinned exact-patch |
| [0025](0025-terraform-state-backend-s3-dynamodb.md) | S3 + DynamoDB remote state for production adoption |
| [0026](0026-pr-time-terraform-plan-via-oidc.md) | OIDC tier-1 read-only role for PR-time `terraform plan` workflow |
| [0030](0030-elasticmq-local-sqs-parity.md) | ElasticMQ in docker-compose for local SQS-shape parity |
| [0039](0039-supply-chain-rigor.md) | Exact-pin / lock / signed-source defaults — uv.lock, terraform exact-patch, `--provenance=false` ECR, brew-preferred tooling |
| [0043](0043-finops-opt-in-budget-guardrail.md) | Opt-in, forker-tunable `aws_budgets_budget` cost guardrail |
| [0044](0044-region-stack-module-platform-regional-split.md) | `region-stack` module — platform/regional layer split, `platform_region` + `regions` map |
| [0045](0045-ionos-data-layer-scylladb-alternator.md) | IONOS-side migration target: self-hosted ScyllaDB Alternator (DynamoDB-wire-compatible); closes the destination-cloud parity gap left by ADR-0042 |
| [0046](0046-n-region-envs-split-enable-catalog.md) | N-region scaling — `envs/` split + enable-catalog (Pattern X); accepted refinement of ADR-0044's regional-layer instantiation, lifts the N=2 cap (implementation deferred, issue #12) |

---

## Band D — Forward-looking / forker promotion paths

| Artifact | What it covers |
|---|---|
| [ADR-0040](0040-multi-region-frankfurt-ireland-route53.md) | **Aurora migration path** — Frankfurt + Ireland active-passive with Lambda-driven failover. For forkers carrying existing PostgreSQL/RDS investment. |
| `../production_adoption.md` | Canonical forker production-promotion checklist — OIDC apply at scale, cert management, secrets, observability |

---

## Cross-cycle / template ADRs (low forker load)

| ADR | Why probably not load-bearing for your fork |
|---|---|
| [0004](0004-reusability-90-10-split.md) | Repo template philosophy — describes how aegis-* portfolio reuses across case-study cycles |
| [0005](0005-aws-target-cross-cloud-as-runbook.md) | The "AWS-first, other-clouds-as-runbook" stance |
| [0012](0012-migration-runbook-agent-executable.md) | Schema for the agent-executable migration runbook |
| [0013](0013-deliverable-is-artifact-not-demo.md) | Why this is a build-and-leave artifact, not a hosted demo |

---

## How to use this index

1. **Pick your goal** from the top table.
2. **Read the listed ADRs in band order** (A → B → C → D). Within each band, the order is the suggested reading order.
3. **CLAUDE.md does NOT pin specific ADR numbers** — see [`feedback_claudemd_no_adr_numbers.md`](../../.claude/projects/.../memory/) reasoning. ADR numbers cited above are stable as long as the doc is current; if a link 404s, search the directory by topic keyword.
