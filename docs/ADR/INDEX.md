# ADR Index — read by goal, not by number

39 ADRs is overwhelming for first-time onboarding. This index groups them by reader goal so you can pick the load-bearing ones for *your* purpose and skip the rest.

## Pick your goal

| Goal | Read | ~Time |
|---|---|---|
| **A. "I want to verify it works"** (run smoke + understand what passed) | Bands A + B-CORE below (4 ADRs) | 15 min |
| **B. "I'm modifying / extending the architecture"** | A + B (full) (10 ADRs) | 45 min |
| **C. "Code review — I need to judge the engineering"** | A + B + C (~22 ADRs) | 90 min |
| **D. "Forking for production deployment"** | All bands + skim superseded for context | 2-3 hrs |

Within each band, ADRs are ordered by reading priority within that band, not by number.

## Engineering signal mapping (for code reviewers)

If you are evaluating the repo against a senior-engineer rubric, here are the ADRs that evidence each signal axis (multiple ADRs often touch the same axis — listed in order of weight):

| Signal axis | Primary ADRs | What to look for |
|---|---|---|
| **Async API boundary** | 0029, 0033, 0030 | POST 202 + poll + DB state machine; SQS visibility 90s; ElasticMQ local parity |
| **Timeout philosophy** | 0022, 0033, 0027 | 4-tier drain (app/ECS/ALB/SQS); SIGALRM 60s on CPU-bound; ALB idle 45s |
| **Failure handling** | 0033, 0038, 0035 | Idempotent retry; DLQ alarm + manual triage (anti-auto-retry); bootstrap idempotency |
| **Observability** | 0003, 0008 (+ design_doc § 3) | Calibrated stop-line; SLO/RTO/RPO targets; CloudWatch + structured logs only (no APM by design) |
| **Scalability** | 0029, 0009, 0007 | SQS-depth-driven autoscale; Multi-AZ standby; single-region with multi-region triggers documented |
| **Decision documentation** | (this INDEX + every ADR's Status / Related field) | Nygard MADR; supersession chains (0002→0028→0034, 0020→0029/0031/0032, 0023→0029) |
| **Calibration honesty** | 0003, 0013, 0015, 0034, 0037, 0038 | PoC scope + prod hygiene split; deliverable-not-demo; explicit anti-pattern analyses |
| **Supply chain rigor** | 0039, 0036, 0016 | uv.lock + terraform exact-pin + `--provenance=false` ECR + signed-source defaults |
| **Cost discipline** | 0006, 0015, 0024, 0027, 0031, 0032 (+ deployment_guide § Cost shape) | Per-component cost analysis; per-hour rates; FinOps scope honest |
| **Security posture** | 0019, 0024, 0027, 0037 | Private-only VPC (no IGW/NAT); mTLS Client VPN; managed master password; rotation deferral path |
| **Agent-executable runbooks** | 0012, 0014 (+ migration_runbook + scaling_runbook) | precondition / action / verify_cmd / on_failure / human_gate schema |
| **Reproducibility from cold** | 0039, 0036, 0030 | Lock files; deterministic image tags; local↔cloud parity |
| **Test rigor** | (CLAUDE.md § 8 + tests/) | BVA mandatory; branch coverage 95%; sympy differential; deterministic-seed fuzz |
| **Incident-evidence discipline** | 0035 (Reconsidered block), 0038, 0027 (Future) | ADRs that document lessons from real incidents, not just decisions |
| **Capability gates / human-in-loop** | 0012, 0024 (+ CLAUDE.md § 6) | Auto / Confirm / Refuse policy on irreversible operations |

---

## Band A — Calibration (read these or you don't understand the deliverable)

These four set the scope, trade-off framework, and time budget that every other decision lives inside.

| ADR | What it decides | Why load-bearing |
|---|---|---|
| [0001](0001-repo-identity-aegis-enclave.md) | What this repo is — case-study deliverable shaped as a reusable portfolio template | Frames the 90/10 generic-vs-buyer split that shapes every gitignore decision |
| [0003](0003-poc-scope-prod-hygiene.md) | PoC feature surface + production-grade engineering (NOT production-grade operations) | The central in-scope vs out-of-scope discriminator. When in doubt, this ADR decides |
| [0028](0028-time-budget-revised-22h.md) | Time budget revised 15h → 22h (supersedes 0002) | Why the deliverable is sized the way it is — feature cuts derive from this |
| [0034](0034-build-budget-22-to-24h-l4-expansion.md) | Final budget revision 22h → 24h (supersedes part of 0028) | The current budget anchor. All scope decisions reference this |

---

## Band B — Architecture (the choices that shape the code you read)

### B-CORE (smallest set that explains "why does it look like this?")

| ADR | What it decides |
|---|---|
| [0015](0015-no-k8s-no-real-apply.md) | ECS Fargate over EKS (saves ~$73/mo control-plane fee at PoC scale) — supersession block on the "no real apply" stance |
| [0019](0019-private-only-vpc-architecture.md) | Private-only VPC: no IGW, no NAT. All AWS API egress via interface VPC endpoints |
| [0029](0029-async-post-sqs-worker-pool.md) | POST returns 202 + queue + worker pool (vs synchronous compute). Why the API, worker, and SQS resources exist |
| [0031](0031-elasticache-serverless-valkey-zset-lua-coalescing.md) | ElastiCache Serverless Valkey + ZSET + Lua merge. The cache architecture |
| [0033](0033-async-drain-semantics-sigalrm-sqs-redelivery.md) | Worker SIGALRM 60s + SQS visibility timeout 90s + how no-ack vs ack-after-fail decisions cascade |

### B (full architecture set)

| ADR | What it decides |
|---|---|
| [0006](0006-vpn-three-tier-story.md) | Three VPN tiers: WireGuard local / Client VPN cloud / NetBird production-cross-cloud |
| [0007](0007-single-region-multi-az.md) | Single region + Multi-AZ at PoC; multi-region triggers documented |
| [0009](0009-db-topology-multi-az-standby.md) | RDS Multi-AZ synchronous standby (one-line free architectural credit) |
| [0011](0011-topology-hub-and-spoke.md) | Network topology — single VPC with private subnets across two AZs |
| [0017](0017-prime-computation-strategy.md) | The actual algorithm: 6k±1 small / sieve large / SIGALRM hard deadline |
| [0018](0018-managed-default-tool-selection.md) | Why each AWS managed service: Client VPN (managed, IAM-integrated) over self-hosted, Secrets Manager over Vault, etc. |
| [0024](0024-vpn-certificate-provisioning.md) | Self-signed CA stored on operator's laptop (vs ACM PCA at $400/mo). Why cert-gen runs locally |
| [0027](0027-internal-alb-https-self-signed.md) | Internal ALB HTTPS via self-signed cert imported into ACM (cycle: revisit when production scale justifies ACM PCA) |

---

## Band C — Operational + supporting decisions (code reviewers and production forkers)

### C-OPERATIONS (how the system behaves in motion)

| ADR | What it decides |
|---|---|
| [0008](0008-reliability-targets-slo-rto-rpo.md) | Stated SLOs / RTO / RPO targets and why they're set where they are |
| [0022](0022-drain-semantics-four-tier.md) | Four-tier drain: app wait_for / ECS deregister 60s / ALB idle 45s / SQS visibility 90s |
| [0035](0035-bootstrap-task-includes-schema-migration.md) | One-shot bootstrap ECS task carries both schema migration + cache seed (Phase 2.5 reconsidered: V2 must replace driver + split together, not one without the other) |
| [0036](0036-image-tag-git-sha-immutable-ecr.md) | Git-SHA image tagging + `--provenance=false --sbom=false` for IMMUTABLE-friendly deterministic ECR manifests |
| [0038](0038-dlq-alarm-triage-not-auto-retry.md) | DLQ pattern: CloudWatch alarm + manual triage script, NOT auto-retry worker (anti-pattern analysis) |

### C-SUPPORTING (tool choices, build hygiene, dev parity)

| ADR | What it decides |
|---|---|
| [0010](0010-vpn-ownership-app-vs-platform.md) | Why VPN is part of the application repo (not a platform-level prereq) |
| [0014](0014-mermaid-smoke-test-acceptance.md) | Mermaid only; no draw.io / images / Figma |
| [0016](0016-community-terraform-modules.md) | terraform-aws-modules over hand-rolled — pinned exact-patch since Phase 2.5.1 (see ADR-0039) |
| [0023](0023-deferred-autoscaling-fixed-task-count.md) | Original fixed task count (superseded by 0029 worker autoscale on SQS depth) |
| [0025](0025-terraform-state-backend-s3-dynamodb.md) | S3 + DynamoDB remote state for production adoption (case-study uses local) |
| [0026](0026-pr-time-terraform-plan-via-oidc.md) | OIDC tier-1 read-only role for PR-time `terraform plan` workflow |
| [0030](0030-elasticmq-local-sqs-parity.md) | ElasticMQ in docker-compose for local SQS-shape parity |
| [0032](0032-cost-estimator-removed.md) | Why the Phase 1 cost estimator was removed (replaced by three-layer cost guard in design_doc § 4.2) |
| [0039](0039-supply-chain-rigor.md) | Exact-pin / lock / signed-source defaults — uv.lock, terraform exact-patch, `--provenance=false` ECR, brew-preferred tooling |

---

## Band D — Forward-looking / V2 acknowledgments (production forkers)

These ADRs explicitly mark items deferred to V2 with the upgrade path documented. Read when forking for production.

| ADR | What it defers + why |
|---|---|
| [0037](0037-secrets-manager-rotation-deferred.md) | Secrets Manager rotation Lambda is V2 (Lambda + KMS coupling overhead). Manual rotation procedure documented; IAM database authentication is the preferred V2 upgrade |
| [0038](0038-dlq-alarm-triage-not-auto-retry.md) | (Also in Band C-OPS.) `alarm_actions = []` is the case-study stance; SNS topic + email/Slack subscriber is the production add |

---

## Superseded / historical context (skim only when the supersession trail matters)

| ADR | Superseded by | Why preserved |
|---|---|---|
| [0002](0002-time-budget-15h.md) | [0028](0028-time-budget-revised-22h.md) → [0034](0034-build-budget-22-to-24h-l4-expansion.md) | Original time budget; supersession chain documents why the budget grew |
| [0020](0020-unified-prime-cache-and-cost-estimator.md) | [0029](0029-async-post-sqs-worker-pool.md), [0031](0031-elasticache-serverless-valkey-zset-lua-coalescing.md), [0032](0032-cost-estimator-removed.md) | Original Phase-1 design; supersessions show how the architecture matured |
| [0021](0021-cache-leveraging-compute-paths.md) | [0031](0031-elasticache-serverless-valkey-zset-lua-coalescing.md) | In-process unified monotonic cache; replaced by distributed Valkey cache |

## Cross-cycle / template ADRs (low forker load)

| ADR | Why probably not load-bearing for your fork |
|---|---|
| [0004](0004-reusability-90-10-split.md) | Repo template philosophy — describes how aegis-* portfolio reuses across case-study cycles. Not architecture |
| [0005](0005-aws-target-cross-cloud-as-runbook.md) | The "AWS-first, other-clouds-as-runbook" stance. Now embodied in `docs/migration_runbook.md` |
| [0012](0012-migration-runbook-agent-executable.md) | Schema for the agent-executable migration runbook. Reference if writing your own runbook |
| [0013](0013-deliverable-is-artifact-not-demo.md) | Why this is a build-and-leave artifact, not a hosted demo |

---

## How to use this index

1. **Pick your goal** from the top table
2. **Read the listed ADRs in band order** (A → B → C → D). Within each band, the order on the page is the suggested reading order
3. **When you see "supersedes ADR-NNNN" / "superseded by ADR-NNNN"** in the body of an ADR, follow the chain only if you need historical context (e.g. understanding why a constraint changed). Otherwise, the latest ADR in the chain is the live decision
4. **CLAUDE.md does NOT pin specific ADR numbers** — see [`feedback_claudemd_no_adr_numbers.md`](../../.claude/projects/.../memory/) reasoning. ADR numbers cited above will eventually rot if ADRs are renumbered; if a link 404s, search the directory by topic keyword
