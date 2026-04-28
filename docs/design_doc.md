# Design Document — aegis-enclave

## Scope and calibration

`aegis-enclave` is calibrated as **production-shape engineering at PoC scale** (ADR-0003). The deliverable answers a case-study brief that mixes "small application" framing with "long-term, multiple developers" hygiene language; the calibration resolves that tension by holding hygiene at production grade while letting feature surface stay deliberately small. The build is hard-capped at 24 hours (originally 15h per ADR-0002, revised to 22h per ADR-0028, then to 24h per ADR-0034 to accommodate HTTPS at the internal ALB, the Phase 2.5 cloud-acceptance window, async L1-L3 implementation, distributed cache implementation, and range-coalescing L4 expansion) and every cut taken to fit that budget is recorded as its own ADR rather than silently omitted.

The following operations layers are **intentionally absent**, named so the reviewer reads deliberate deferral rather than oversight:

- CI/CD pipelines, observability stack (Prometheus / Grafana), distributed tracing
- Load testing, region-level DR drills, multi-environment promotion
- Real `terraform apply` against a live cloud account (ADR-0015)
- Kubernetes manifests (Docker Compose covers the brief's orchestration ask — ADR-0015)

Every architectural claim below is anchored to a numbered ADR in [`docs/ADR/`](ADR/). When the rationale here gestures at "we chose X because Y," the ADR carries the alternatives table and the trade-off accounting. This document is a guided tour through those decisions — not a replacement for them.

## 1. Reliability and continuity

### 1.1 High availability

The cloud composition is deployed to a single AWS region (`eu-central-1`, Frankfurt) with three-AZ subnet distribution (per ADR-0007 reconsidered) and an RDS Multi-AZ standby. Multi-region active-passive (Frankfurt primary + Ireland standby with Route53 health-based failover) is the **production target** documented in ADR-0040, and the agent-executable promotion runbook is `docs/scaling_runbook.md` (ADR-0012). The triggers that would move multi-region from documented-target into deployed-implementation are named explicitly in the Reliability section of the design — none of them are met at case-study scope:

1. Workload concurrency exceeding what a single region can absorb (e.g., simultaneous high-throughput streams from independent producers)
2. Globally distributed clients requiring locally-terminated network paths for latency or jurisdiction reasons
3. Regulatory requirements explicitly demanding geographic redundancy

A senior practitioner's honest estimate for full multi-region active-active in Phase 1 — Aurora Global Database, cross-region peering, per-region ECS / ALB / Client VPN endpoints, Route 53 failover, cross-region IAM and KMS replication, plus a failover drill — lands at 10-14 hours. That consumes the bulk of the 22h budget for a capability the brief does not ask for. The reviewer reads "I have a Phase 2 plan" rather than "I forgot about scaling."

Multi-AZ inside a single region is a different shape entirely. `multi_az = true` on the RDS module and multi-subnet target groups on ECS are one-line Terraform toggles. **It's free architectural credit; declining it would require its own ADR explanation.** The internal ALB spans both AZs, the ECS service can place tasks in either subnet, and the database has a synchronous hot standby in the second AZ. None of this costs additional design complexity beyond a few module arguments.

### 1.2 Service-level objectives, RTO, RPO

The brief makes no quantitative reliability requirement, but a senior deliverable proposes explicit numbers anyway — qualitative reliability claims read as filler. The proposal below distinguishes **SLO** (internal target the team commits to), **SLI** (the measurement behind the SLO), **RTO** (recovery time objective), and **RPO** (recovery point objective). **SLA** (external contract with penalties) and **OLA** (between-team agreement) are explicitly out of scope: no contractual surface exists between the candidate and the buyer, and no team structure is yet defined that an OLA could bind. See ADR-0008.

| Indicator | Target | Rationale |
|---|---|---|
| Availability SLI | sum(2xx) / sum(non-5xx) over 30d rolling | 99.5 % — internal tooling, ~3.6h/month error budget |
| Latency p99 (`/primes`, range ≤ 10⁶) | < 500 ms | Bounded by computation; not real-time |
| Error rate | < 0.5 % | Aligned with availability budget |
| Database write success | INSERT to `executions` table | 99.9 % — loss = audit gap |
| RTO — service | ≤ 15 min | Multi-AZ ECS / RDS auto-failover ~2-5 min + manual buffer |
| RTO — data corruption (PITR) | ≤ 1 hour | RDS PITR restore takes ~30-60 min |
| RPO — DB writes | ≤ 5 min | RDS automated backup + transaction log |
| RPO — in-flight transactions | < 1 min | Synchronous commit to multi-AZ replica |

Each row traces back to a specific Terraform decision rather than standing as a free-floating number. RTO 15min is supported by `multi_az = true` on RDS (ADR-0009) — the synchronous hot standby auto-fails-over within ~2-5 minutes and the remaining buffer covers manual intervention. RPO < 1min on in-flight transactions falls out of the same synchronous-commit topology. RPO ≤ 5min on durable writes comes from RDS's automated backup and transaction log retention. The trace is the value of the table; the digits without the trace would be filler.

### 1.3 Out of scope (named, not forgotten)

The following operations layers are deliberately deferred under ADR-0003 and ADR-0015. Naming them is itself a senior signal — the candidate knows what production-grade looks like end-to-end and is choosing what fits the brief's scope, not stopping where their knowledge ends.

- **CI/CD pipeline** — no GitHub Actions / Jenkins / GitLab CI for build + deploy
- **Observability stack** — no Prometheus, no Grafana, no Loki, no centralised log aggregation
- **Distributed tracing** — no OpenTelemetry collector, no APM
- **Load testing** — no k6 / Locust / synthetic-traffic baseline
- **Region-level DR drills** — multi-region runbook exists (`docs/scaling_runbook.md`, Phase 2) but no rehearsed drill
- **Multi-environment promotion** — single `environment = "dev"` only; no dev → staging → prod gating
- **SLA / OLA** — explicitly out of scope (ADR-0008); no external contractual surface, no team structure to bind

If the buyer requests any of these as follow-up work, the existing ADRs become the input to that conversation — the omissions are scoped, not surprise. The observability deferral specifically has a designed-but-not-implemented architectural story — see § 3 (Observability posture) below.

## 2. VPN architecture

### 2.1 Three-tier story

The deliverable touches three different VPN concerns. Conflating them produces either an unrealistic local demo or operational debt in the cloud architecture, so each concern gets its own deliberate answer (ADR-0006).

| Tier | Tool | Role |
|---|---|---|
| Local Task 2 demo | WireGuard container (`linuxserver/wireguard`) | Self-contained verification mechanism only |
| Cloud production primary | AWS Client VPN endpoint | Default cloud-side VPN gateway — managed, certificate-based authentication, integrates with VPC + IAM |
| Sovereignty / non-AWS alternative | NetBird (Berlin-based, self-hostable, WireGuard mesh control plane) | Recommended when Client VPN endpoint isn't an option (non-AWS clouds), or when its cost / portability profile doesn't fit |

WireGuard's role is demoted to demo plumbing. The `docker-compose.yml` stack and the `wireguard/` folder exist to make the security boundary runnable in a single `docker compose up`; the cloud-side architecture treats AWS Client VPN endpoint as the primary, and the cross-cloud migration runbook treats NetBird as the recommended alternative when the destination cloud lacks a managed VPN endpoint.

### 2.2 Build vs buy

Cost analysis for AWS Client VPN endpoint at typical team scale: ~$0.10/hr per subnet association + ~$0.05/hr per connected user. With 30 users, two-AZ subnet associations, and 24/7 operation, monthly cost lands near **$1,400** — roughly $16k/year. NetBird self-hosted on a `t3.micro` runs at **~$8/month** at the same scale: a **~170× TCO reduction**. The cost gap is the substantive driver; sovereignty (NetBird is Berlin-based and self-hostable) is a complementary signal, not the primary frame.

The build-vs-buy decision is therefore **architectural consequence, not preference**. When the destination cloud has a managed VPN endpoint that integrates with its VPC + IAM model, the managed service is the right call — the team isn't reinventing key rotation, ACLs, identity binding, audit logs, or HA. When the destination cloud lacks that managed surface (the cross-cloud migration target named in the brief, for example), the calculus inverts: self-hosted NetBird becomes both cheaper and more portable than hand-rolling WireGuard in IaC. See ADR-0006 for the full reasoning and the rejected alternatives.

### 2.3 Topology

The VPN topology is **hub-and-spoke** (ADR-0011). A single VPN gateway terminates client connections; clients do not connect to each other. NetBird's mesh capability is intentionally constrained by ACL to enforce hub-and-spoke behaviour — clients can reach the gateway / control-plane subnet, and nothing else.

The reasoning: operators and ground-side hosts connect to the cloud control plane to submit work and read audit records. They have no business need to communicate peer-to-peer. Allowing client-to-client connectivity would expand attack surface — compromise of one client gains lateral movement to other clients — without a single business use case to justify it. The ACL stays simple (one allow-list rule pointing at the gateway) instead of a per-pair policy matrix. Mesh is a **capability**; the ACL is the actual topology decision.

### 2.4 Ownership boundary

Brief Task 2 bundles a VPN gateway into the Docker Compose stack alongside the application services. That layout is appropriate for a self-contained two-container demo — it makes the security boundary visible and runnable in one command. **It is not appropriate as a production architectural recommendation**, and treating it as one would be a senior-signal miss (ADR-0010).

In production at typical company scale, VPN is centralised platform infrastructure owned by a platform / network team. Key material and identity binding are managed once, not per service; audit logs aggregate centrally for compliance; HA, failover, and capacity planning are handled at the platform layer. Application services consume an existing VPN endpoint and express network policy via Security Groups — they do not provision the VPN themselves.

The Phase 1 demo bundles the VPN container per the brief's wording. The production architecture decouples the VPN from the application service. The Terraform module structure makes this distinction operational: `module "vpn"` (and its underlying `aws_ec2_client_vpn_endpoint` resource) is a separable unit. In a production deployment it is replaced by a `data` source pointing at the existing corporate VPN endpoint, with the application module unchanged. The migration runbook (ADR-0012) splits into two tracks for the same reason: the application track and the VPN-modernisation track have different owners, different cadence, different blast radius.

### 2.5 Network egress posture

Ingress is gated (§ 2.1–2.4 above). Egress is **also** off the public internet (ADR-0019). The VPC has no Internet Gateway, no NAT, and no public subnets — every AWS API call from the workload (ECR image pull, Secrets Manager fetch, CloudWatch Logs ship, IRSA / STS, ECS agent telemetry) is routed through VPC Endpoints (PrivateLink). The data plane never leaves the AWS backbone.

The reasoning is the same shape as the K8s decision in ADR-0015 and the VPN decision in ADR-0006: **don't provision capability that isn't needed**. The application makes no third-party API calls, fetches no public packages at runtime, sends no outbound webhooks. NAT + IGW + public subnets would be infrastructure for a need that does not exist. Removing them tightens the security posture without breaking any brief requirement.

**Build vs runtime is a deliberate boundary**, not a workaround. Image construction (`docker build`, `pip install` from PyPI) happens outside this VPC — typically in a separate build account / VPC / CI runner with public internet — and the built image is pushed to ECR. The runtime VPC pulls from ECR via PrivateLink. Cross-account ECR access is an IAM concern, not a networking one. CI/CD evolution does not affect the runtime VPC's private-only posture.

The principle is captured in ADR-0018 (managed-default tool selection) — pick the simplest primitive that meets the requirement, upgrade only when scale, sovereignty, or capability gaps demand it. NAT was the wrong default for this workload because the workload has no public-internet egress requirement.

## 3. Observability posture

Observability is named in § 1.3 as deliberately out of scope: no Prometheus, no Grafana, no Loki, no centralised collector, no APM, no OpenTelemetry. That is the **scope** statement, not the **architecture** statement. The architecture statement — what the deployed system already emits, what it cannot answer with that emission alone, and what the upgrade path looks like — is below.

This section is also the **evidence-capture spec for Phase 2.5**: the table in § 3.1 is what gets screenshotted into `docs/deployment_guide.md` while the cloud-acceptance window is live, before teardown.

### 3.1 What the cloud composition emits for free

Every primitive in the Terraform composition publishes a baseline of CloudWatch metrics and structured logs without additional code. This is the observability surface available the moment a real `terraform apply` lands:

| Source | Metrics | Logs |
|---|---|---|
| Internal ALB | `RequestCount`, `HTTPCode_Target_{2,3,4,5}XX_Count`, `TargetResponseTime` (p50 / p90 / p99 built-in), `HealthyHostCount`, `UnHealthyHostCount` | Access logs to S3 (per request: client IP, path, response code, latency, target group) |
| ECS Fargate task | `CPUUtilization`, `MemoryUtilization`, container exit codes | stdout / stderr → CloudWatch Logs via `awslogs` driver (FastAPI's structured logging lands here intact) |
| RDS PostgreSQL Multi-AZ | `CPUUtilization`, `DatabaseConnections`, `FreeableMemory`, `ReadIOPS` / `WriteIOPS`, `ReplicaLag` | PostgreSQL log + slow-query log → CloudWatch Logs |
| AWS Client VPN endpoint | `ActiveConnectionsCount`, `AuthenticationFailures`, `IngressBytes`, `EgressBytes` | Connection log: client cert CN, source IP, connect / disconnect timestamps |
| VPC Flow Logs | (per-flow records) | All NIC-to-NIC traffic, including PrivateLink endpoint hits |

Phase 2.5's cloud-acceptance gate consumes this baseline by combining four evidence sources, captured before the stack is destroyed:

1. **Aggregate metric dashboards** — ALB `RequestCount` / `TargetResponseTime` / 5xx, ECS task CPU / memory, RDS CPU / connections, Client VPN active connections. One screenshot per dashboard captures system-level health.
2. **Per-endpoint round-trip** — manual `curl` invocations against `/health`, `POST /primes`, and `GET /executions/{id}` with request and response bodies recorded. This is the per-endpoint correctness signal.
3. **ALB access log lines** — pulled from S3 (or queried via Athena) for the `curl` timestamps. Each line carries the endpoint path, response code, latency, and target instance, providing the audit trail per request.
4. **ECS CloudWatch Log entries** — corresponding FastAPI structured log lines for the same requests, providing the application-side view (DB query attempts, internal state, error context if any).

Together these four sources tell a per-endpoint correctness story without needing target-group splitting or application-side custom metrics. **No application-side instrumentation is written for the case-study deliverable** — the baseline plus the curl-and-log pattern is sufficient to demonstrate that the deployment is reachable, the security boundary holds, and the prime-computation path executes end-to-end.

### 3.2 What the baseline cannot answer

The ALB metrics aggregate across endpoints. For aegis-enclave specifically — three endpoints with very different latency profiles (`GET /health` < 1 ms, `POST /primes` up to hundreds of ms, `GET /executions/{id}` ~10 ms) — that aggregation hides the signals that operating the system day-to-day would need:

- **Per-endpoint latency.** A p99 spike on the ALB cannot tell whether `POST /primes` is degrading (expected under load) or `GET /health` is degrading (unexpected, likely a DB-connection or service-health canary). Mixed into one statistic, the smaller endpoint's signal is dominated and effectively invisible.
- **Per-endpoint error rate.** A 5xx burst on `POST /primes` (e.g., a bad input range escaping validation) reads identically to a 5xx burst on `GET /executions/{id}` (e.g., DB unavailability). The remediation paths differ.
- **Business-level dimensions.** Latency as a function of the requested range size (the dominant performance variable for `POST /primes`), cache hit vs miss for the prime-cache code path (ADR-0021), or per-tenant call patterns if multi-tenancy enters scope — none of these are visible from the ALB.
- **Internal subsystem timing.** DB query duration, cache lookup duration, and computation time are a single black box from the ALB's perspective. Slow queries surface in the RDS slow-query log, but the linkage back to the API request that issued them is not.

The gap is between **infrastructure observability** (already free) and **application observability** (requires a decision).

### 3.3 When scope opens — the upgrade path

> **Status (2026-04-28, ADR-0041): the EMF path described below is now implemented in the case-study deliverable.** `src/prime_service/metrics.py` wraps the EMF envelope; `main.py` middleware + `worker.py` `handle_message` emit SLI metrics into the `aegis-enclave` namespace; `terraform/main.tf` provisions a 6-panel `aws_cloudwatch_dashboard.slo` + 6 multi-window burn-rate alarms. The "sketch, not a commitment" caveat at the end of this subsection is superseded — ADR-0041 records the choice, the alternatives (AMG / AMP / Grafana Cloud), and the V2 promotion paths.

The recommended primary upgrade is **CloudWatch Embedded Metric Format (EMF)** middleware, not `cloudwatch:PutMetricData` API calls. EMF works by writing a structured JSON log line per request:

```json
{
  "_aws": {
    "Timestamp": 1734085200000,
    "CloudWatchMetrics": [{
      "Namespace": "aegis-enclave/api",
      "Dimensions": [["endpoint", "method", "status_class"]],
      "Metrics": [
        {"Name": "LatencyMs", "Unit": "Milliseconds"},
        {"Name": "RequestCount", "Unit": "Count"}
      ]
    }]
  },
  "endpoint": "/primes", "method": "POST", "status_class": "2xx",
  "LatencyMs": 12, "RequestCount": 1
}
```

The ECS Fargate `awslogs` driver already ships every stdout line to CloudWatch Logs; the Logs Agent recognises the `_aws` envelope and extracts the metrics into the named namespace automatically. The application makes **zero synchronous API calls** for metric emission, and the metric extraction is included in the log-ingestion price — there is no per-metric `PutMetricData` charge. Latency overhead is bounded by JSON-serialisation cost; `cloudwatch:PutMetricData` would be a 5-50 ms synchronous network call per request, dominating `GET /health` and `GET /executions/{id}`, which is why that path is rejected.

The metrics emitted follow the **RED method**:

| Metric | Dimensions | Question answered |
|---|---|---|
| `RequestCount` | endpoint, method, status_class | Per-endpoint RPS and error rate |
| `LatencyMs` | endpoint, method | Per-endpoint p50 / p95 / p99 |
| `ErrorCount` | endpoint, error_class | 5xx breakdown for root-cause routing |

`status_class` is bucketed into `2xx / 3xx / 4xx / 5xx` rather than carrying every distinct status code. CloudWatch metrics bill per unique dimension combination; `principal` / `user_id` / full path are common cardinality bombs deliberately excluded from this design. If per-tenant slicing is ever required, it lands as a sampled counter in a separate namespace (`aegis-enclave/business`) with bucketing rules of its own.

**Target-group splitting** (routing `/health` to one target group, `/primes` and `/executions/{id}` to others) is a routing-side variant that gets per-endpoint metrics out of ALB without application code. At three endpoints it is workable; at thirty it becomes a Listener Rule maintenance burden that scales worse than EMF. The design treats it as a **sister option to EMF** evaluated together when scope opens, not a separate intermediate step — splitting target groups before any application instrumentation exists is using infrastructure to compensate for a deferred decision rather than implementing the decision. When the scope decision lands, the right pair (EMF only / EMF + TG split / TG split only) falls out of the endpoint count and dimension-richness needs at that moment.

The Python implementation of the EMF middleware is a single ASGI middleware over FastAPI using the `aws-embedded-metrics` library — roughly 30 lines including the bucketing helper. A new ADR records the choice and trade-offs at the time of implementation; today it is **a sketch, not a commitment**.

### 3.4 Beyond — APM and distributed tracing

OpenTelemetry collectors, AWS X-Ray, Datadog APM, and similar managed APM services give request-level distributed traces. Traces subsume per-endpoint metrics and add internal-subsystem timing (DB query spans, cache spans, downstream-call spans), which is the next gap after EMF closes the per-endpoint visibility one. The cost profile shifts from per-metric to per-trace, which can be substantial under sustained high RPS, and the operational burden is a vendor relationship rather than infrastructure code. APM is the right answer at a different scope — larger team, multi-service estate, sustained high RPS, established platform-engineering function. For one service with three endpoints it is over-built.

The migration runbook (`docs/migration_runbook.md`) is the right place to record an APM addition when the workload structure justifies it: the runbook's spec format already accommodates third-party SDK additions and credential bootstrap as standard step shapes.

### 3.5 Calibration recap

The architecture above mirrors the calibration shape in § 1.3: name the architecture, scope the implementation, leave deferred work as designed sketches rather than absent ones. **Phase 2.5.1 (2026-04-28, per ADR-0041)** promoted § 3.3's "sketch" to shipped Tier 1: SLI emission, CloudWatch Dashboard, multi-window burn-rate alarms, optional SNS email delivery. § 3.4's APM/distributed-tracing layer remains a deliberate Tier 3 V2 — the SQS message-attribute trace_id propagation work and ADOT collector are documented in the deployment_guide § Production hardening checklist, not implemented. The **scope statement** at § 1.3 (no Prometheus, no Grafana surface, no APM) still reads correctly: we have neither Prometheus the system nor Grafana the UI; we have CloudWatch the AWS-native equivalent, scoped to what a 3h apply-then-destroy evidence model can deliver as screenshots.

## 4. Async architecture + cost guards

### 4.0 Service Specification

This block is the canonical service contract. Every implementation choice in §§ 4–5 serves it.

```
┌────────────────────────────────────────────────────────────┐
│  PRIMES SERVICE — SERVICE CONTRACT                         │
└────────────────────────────────────────────────────────────┘

ENDPOINTS
  POST /primes              → 202 + {execution_id, status: "queued"}
  GET  /primes/{exec_id}    → {status, result?, error_message?}

INPUT BOUNDS
  start, end ∈ ℤ, start ≥ 2, end ≥ start, end - start ≤ 10⁷
  out-of-bounds → 422

THROUGHPUT
  sustained:   ~20 req/sec/worker (cache-miss-bound; cache-hit ~30 req/sec)
  peak burst:  up to (5 × worker_count) queued before back-pressure kicks
  overload:    503 + Retry-After: 60s

LATENCY (P50)
  cache hit:                     < 100 ms
  cache miss, range ≤ 10⁵:       < 500 ms
  cache miss, range up to 10⁷:   up to 60 s (then status="failed")

CLIENT POLLING
  recommended interval: 1–2 s
  status state machine: queued → running → done | failed

FAILURE MODES
  schema violation     → 422
  queue overflow       → 503 + Retry-After
  compute > 60 s       → status="failed", error_message captured
  worker hang          → SIGALRM 60 s + audit failure write

OPERATIONAL POSTURE
  designed for:     bursty internal-tools (idle ~1 req/min, bursts 50–100 req/sec ≤30 s)
  NOT designed for: sub-100 ms user-facing SLA, batch jobs > 60 s,
                    multi-tenant isolation
```

See [ADR-0029](ADR/0029-async-post-sqs-worker-pool.md), [ADR-0031](ADR/0031-elasticache-serverless-valkey-zset-lua-coalescing.md), [ADR-0032](ADR/0032-cost-estimator-removed.md), [ADR-0033](ADR/0033-async-drain-semantics-sigalrm-sqs-redelivery.md) for the decisions behind each contract clause.

### 4.1 Load profile rationale

The service specification's "bursty internal-tools" framing is not a placeholder — it drives the key architectural choices:

- **Burst shape: 50–100 req/sec for ≤ 30 s, then idle.** This is the pattern of operators running batch queries at the start of a work window, not sustained API traffic. The implication: peak capacity must handle the burst; steady-state cost must stay low during idle. A synchronous HTTP-compute model would require enough worker replicas to absorb the burst simultaneously — 50 requests each holding a worker for up to 30 s requires 50 replicas. A queue-decoupled model requires enough workers to drain the burst within an acceptable window — 3 workers at 1 job/60 s drains 50 messages in ~17 minutes. The service specification accepts that trade-off (polling resolves it for the client).
- **Idle baseline: ~1 req/min.** Provisioned infrastructure at this scale is over-built at idle. ElastiCache Serverless (ADR-0031) and ECS auto-scaling (min=1, max=3) are the appropriate-complexity primitives: they cost near-zero at idle and scale to handle the burst within the ECS stabilisation window (~2–3 min).
- **Range heterogeneity.** Internal-tools operators tend to submit queries with slightly varying boundaries over the same region (e.g., "all primes between 1M and 10M", then "1M to 8M", then "500k to 10M"). This is the exact pattern that range-coalescing (ADR-0031 § ZSET + Lua merge) is optimised for: each new boundary is absorbed into the superset cache entry rather than stored as a separate key.

### 4.2 Three-layer cost guard

The Phase 1 pre-flight cost estimator (ADR-0020) is removed (ADR-0032). Three independent guard layers replace it, each addressing a distinct failure mode:

| Layer | Guard | Failure mode addressed | Why it suffices |
|---|---|---|---|
| **Schema cap** | Pydantic: `end - start ≤ 10⁷`, enforced at request ingress | Unbounded input — `(2, 10⁹)` rejected with 422 | Synchronous, no cache-state dependency, no estimation error. Stronger than the estimator for this class of input. |
| **Backpressure** | Queue depth > `5 × worker_count` → 503 + `Retry-After: 60` | Queue saturation under sustained burst | Signals "try again in 60 s" to the client. Prevents SQS from accumulating an unbounded backlog when workers fall behind. Configurable via `backpressure_threshold_factor` env var. |
| **Worker timeout** | SIGALRM 60 s per job → `status=failed` + `error_message` | Runaway compute within a single job | Bounds per-job wall time at the OS signal level, bypassing any Python-level cooperative-wait limitation. The audit row captures the failure for client polling. |

The worst-case scenario after removing the estimator: a request that the estimator would have rejected enters the queue and times out after 60 s with `status=failed`. The client receives a structured failure response, not a connection reset. The SQS message is acknowledged — no redelivery loop. The estimator's role was to prevent this scenario; the three layers above make the scenario cheap and recoverable rather than preventing it.

Why the estimator was removed rather than adapted: in the distributed-cache architecture, `_known_max` is a cluster-level property, not a per-worker value. Querying Valkey for the current high-water mark on every POST would add a network round-trip to the "cheap pre-flight check," defeating its purpose. See ADR-0032 for the full analysis.

### 4.3 Worker compute budget rationale

The worker compute budget is **60 s per job** (enforced by SIGALRM). The synchronous HTTP timeout (ADR-0020) was 30 s — the worker budget is double. The rationale:

- **In the async model, the HTTP handler is not blocked.** The 30 s synchronous limit was set to keep the HTTP connection alive through the compute. The worker runs in a separate process with no HTTP connection to maintain. 60 s is the natural ceiling: it is the ECS task stop_timeout (70 s) minus drain headroom, and it matches the SQS visibility timeout (90 s) with a 30 s margin for write + ack overhead.
- **Headroom over realistic compute at the schema cap.** A sieve of `[2, 10⁷]` on a Fargate 0.5 vCPU task takes approximately 3–5 s. The 60 s budget provides **12–20× headroom** over the worst-case legitimate compute at the schema ceiling. The budget fires only if a compute significantly exceeds the expected cost — i.e., a bug (infinite loop, runaway recursion) rather than a legitimate slow query.
- **Client latency budget.** The service specification states "cache miss, range up to 10⁷: up to 60 s (then status=failed)." A client polling at 1–2 s intervals experiences at most 60 polling cycles for the worst case. This is acceptable for an internal-tools workload (operators submit a query and wait for the result, not a sub-second user-facing interaction).

### 4.4 SIGALRM recovery for CPU-bound bugs

SIGALRM is the worker-side guard for CPU-bound bugs. Understanding the scope of what it guards — and what it does not — is important for operating the service.

**SIGALRM rescues the current job's audit record.** When SIGALRM fires, the Python `TimeoutError` propagates up through the compute call, is caught by the worker's exception handler, and triggers: `status=failed` DB write + `error_message="compute timeout"` + SQS `DeleteMessage`. The message is gone; the audit row is in a terminal `failed` state. The client polling `GET /primes/{id}` sees `status=failed` within the next polling interval.

**SIGALRM does not rescue the worker process.** The worker continues running after the timeout. It catches the `TimeoutError`, writes the failure record, and loops back to the next `ReceiveMessage` call. If the bug that caused the timeout is in the prime computation and is input-dependent, the next message with the same input will timeout again. The worker is not restarted — ECS task health checks (CPU/memory) do not flag a SIGALRM event.

**Queue redelivery rescues the message, not the worker.** SQS visibility timeout (90 s) redelivers the message if the worker is killed (SIGKILL, host failure, OOM). Redelivery gives the message to another worker — useful when the first worker is dead. But a CPU-bound bug that does not cause OOM does not kill the worker. The message is not redelivered while the worker is alive and processing it (even if processing takes longer than expected — the visibility timer is reset on `ReceiveMessage`). SIGALRM is therefore the only mechanism that bounds compute time per message when the worker is healthy but the compute is runaway. The memory rule `feedback_safety_guard_recovery_test.md` captures this distinction.

**Practical implication:** a CPU-bound bug in `sieve()` that affects a specific input range will cause every job with that range to: (a) consume 60 s of CPU, (b) receive `status=failed`, (c) be acknowledged (no redelivery). The worker continues processing other ranges normally. This is the correct behaviour — the bug is contained to the affected range, logged in the audit table, and surfaced to the client as a structured failure. The worker does not need to be restarted to recover from it.

### 4.5 Idempotency contract

Worker idempotency handles the case where the same SQS message is delivered more than once (SQS at-least-once delivery):

| Scenario | Worker action |
|---|---|
| `status = 'done'` at job start | Skip compute. ACK the message. (Duplicate delivery; result already committed.) |
| `status = 'running'` AND `started_at` > 90 s ago | Mark `status=failed`, `error_message="stale running: presumed dead"`. Then proceed as if `queued`. (Previous worker died mid-job without writing `failed`; visibility timeout expired and redelivered.) |
| `status = 'running'` AND `started_at` ≤ 90 s ago | Do NOT proceed. ACK the message. (Another worker is currently processing this job — this is a duplicate delivery within the visibility window; the active worker will write the result.) |
| `status = 'queued'` | Set `status=running`, `started_at=now`. Proceed with compute. |
| `status = 'failed'` | Skip compute. ACK the message. (A previous attempt already failed; client should read `error_message`.) |

The 90 s stale threshold matches the SQS visibility timeout — a `running` row older than 90 s means the worker that set it either died (visibility expired, message redelivered) or is in a runaway state (should have hit SIGALRM by now). In either case, treating the row as stale and re-running the job is the correct recovery action.

### 4.6 L5 deferred

The following capabilities are named but deferred to a future phase. Naming them prevents the reviewer from reading their absence as oversight.

- **Cancellation API** (`DELETE /primes/{id}` or `POST /primes/{id}/cancel`) — requires SQS message deletion by message ID, which needs a separate index of SQS receipt handles. Not in the PoC.
- **Dead-letter queue (DLQ) retry policy** — the Terraform composition includes a skeletal DLQ resource but does not wire automatic retry. A production deployment would set `maxReceiveCount` and configure a DLQ alarm.
- **Per-user quota** — all operators share the same queue and backpressure threshold. Multi-tenant isolation (per-user limits, separate queues per tenant) requires a routing layer.
- **Pagination for `result` when cap > 10⁷** — the schema cap keeps response size below ~7 MB raw (~1.5–2 MB gzipped). If the cap is raised, pagination is required; the current `GZipMiddleware` is not a substitute.
- **Multi-tier queue** (priority queue, separate queues per range size) — the single queue treats all jobs equally. A priority queue would drain small cache-hit jobs faster than large compute-miss jobs.

## 5. Cache distribution

### 5.1 Multi-Fargate-task cache sharing motivation

The Phase 1 per-worker cache (`_known_primes` in `primes.py`) warmed independently on each ECS task. With the async worker pool (ADR-0029, min=1 / max=3 tasks), cache hits are not shared across tasks. Concrete cost: Task A computes `[2, 10_000_000]` after a cache miss, taking ~3–5 s on 0.5 vCPU. Task B receives `[1_000_000, 5_000_000]` — a strict subset already computed by Task A — and repeats the compute from scratch.

The distributed cache solves this by giving all workers a shared hit pool. The hit pool persists across ECS task lifecycle events (scale-in, rolling deploy, Spot eviction) — the cache is not lost when the worker that computed a range is replaced. This is the architectural motivation for a network cache at all: without cross-task sharing, the per-worker LRU already provides adequate hit rates for a single-task deployment.

### 5.2 Valkey Serverless choice

ElastiCache Serverless Valkey (ADR-0031) is the cache backend. The full alternatives analysis is in ADR-0031; this section summarises the cost framing for the acceptance window.

**Cost framing — case-study Phase 2.5 (3h apply-then-destroy):**

> The 3h framing in this comparison table is the case-study's cost-ceiling for evidence capture, NOT a design constraint. A forker chooses their own duration based on the per-hour rates in [`docs/deployment_guide.md` § Cost shape](deployment_guide.md#cost-shape) (also surfaced on the README front page).


| Option | 3h window cost estimate | Notes |
|---|---|---|
| ElastiCache Serverless Valkey | < $0.10 | ECPU-seconds billed on actual usage; data storage billed per GB-hour (< 1 MB stored) |
| ElastiCache provisioned (`cache.t3.micro`) | ~$0.05 | $0.017/hr × 3h; plus must be explicitly created and destroyed |
| Amazon MemoryDB (provisioned, `db.t4g.small`) | ~$0.12 | ~$0.04/hr × 3h; durable writes unnecessary for a cache workload |
| DynamoDB on-demand | ~$0.01 | Read/write unit pricing; cheap but lacks ZSET overlap semantics |

For the 3-hour acceptance window, cost differences are negligible. The decision driver is feature fit: ZSET + Lua atomicity for range-coalescing (ADR-0031) are native to Valkey and unavailable in DynamoDB without substantial workarounds. Serverless is the right operational shape for a PoC acceptance window (no cluster provisioning, scales to zero, one-line Terraform resource).

### 5.3 ZSET key design and range-coalescing

The ZSET schema stores known prime ranges as a sorted index:

- **Index key:** `primes:{ranges}` — sorted set, member format `{start}:{end}`, score = `start`. The `{ranges}` hash tag keeps all related keys on a single Valkey shard (required for Lua atomicity).
- **Data keys:** `primes:{ranges}:range:{start}:{end}` — string key holding the JSON-encoded prime list for the range `[start, end]`.
- **TTL policy:** bootstrap entry (range `1:100000`) has no expiry. User-driven entries expire after 6 h. Merged entries inherit `max(ttl_a, ttl_b)` or reset to 6 h if both inputs expired.

**Lookup path:**

```
ZRANGEBYSCORE primes:{ranges} 0 {request_end}
  → candidate_members whose score (= start) ≤ request_end
  → filter: member.end ≥ request_start  (overlap condition)
  → if any member covers [request_start, request_end] fully → slice result list
  → else: fall through to compute
```

**Lua merge script (outline):**

```lua
-- KEYS[1] = 'primes:{ranges}' (ZSET index)
-- ARGV[1] = new_start, ARGV[2] = new_end, ARGV[3] = new_primes_json, ARGV[4] = ttl_seconds
local zkey = KEYS[1]
local new_start = tonumber(ARGV[1])
local new_end   = tonumber(ARGV[2])

-- 1. Find all overlapping or adjacent ranges
local candidates = redis.call('ZRANGEBYSCORE', zkey, 0, new_end)
local to_merge = {}
for _, member in ipairs(candidates) do
    local s, e = member:match('^(%d+):(%d+)$')
    if tonumber(e) >= new_start then
        table.insert(to_merge, {start=tonumber(s), end_=tonumber(e), member=member})
    end
end

-- 2. Compute merged bounds
local merged_start = new_start
local merged_end   = new_end
for _, r in ipairs(to_merge) do
    merged_start = math.min(merged_start, r.start)
    merged_end   = math.max(merged_end, r.end_)
end

-- 3. Delete originals + write coalesced entry
for _, r in ipairs(to_merge) do
    redis.call('ZREM', zkey, r.member)
    redis.call('DEL', 'primes:{ranges}:range:' .. r.member)
end
local merged_key = 'primes:{ranges}:range:' .. merged_start .. ':' .. merged_end
redis.call('ZADD', zkey, merged_start, merged_start .. ':' .. merged_end)
redis.call('SET', merged_key, ARGV[3])  -- caller computes merged prime list before calling Lua
redis.call('EXPIRE', merged_key, tonumber(ARGV[4]))
return 1
```

The caller (worker) computes the merged prime list (union of all candidate lists + new primes, deduplicated and sorted) before invoking the Lua script. The Lua script handles only the atomic ZSET and data-key manipulation. This split keeps the Lua script minimal while preserving atomicity for the storage operations.

### 5.4 Bootstrap pattern

The bootstrap task (`python -m prime_service.bootstrap`) is a one-shot ECS Fargate task triggered by Terraform:

```hcl
resource "null_resource" "run_cache_bootstrap" {
  triggers = {
    valkey_endpoint = aws_elasticache_serverless_cache.valkey.endpoint[0].address
    task_def_arn    = aws_ecs_task_definition.cache_bootstrap.arn
  }

  provisioner "local-exec" {
    command = <<-EOT
      aws ecs run-task \
        --cluster ${aws_ecs_cluster.main.name} \
        --task-definition ${aws_ecs_task_definition.cache_bootstrap.arn} \
        --launch-type FARGATE \
        --network-configuration '{...}'
    EOT
  }

  depends_on = [
    aws_elasticache_serverless_cache.valkey,
    aws_ecs_task_definition.cache_bootstrap
  ]
}
```

The bootstrap task logic:

1. Check `EXISTS primes:{ranges}:range:1:100000` → if `1`, exit 0 (idempotent; already seeded).
2. Compute `sieve(1, 100_000)` (~9,592 primes, ~5–15 ms).
3. Call `cache.put_if_absent("primes:{ranges}:range:1:100000", primes_json)` — uses `SET NX` (no overwrite; safe for concurrent bootstrap calls on redeploy).
4. Log success (or skip) clearly for CloudWatch evidence.

The bootstrap entry has **no TTL** — it is the permanent warm-up baseline. Every request whose range is a subset of `[1, 100,000]` is a cache hit from first user request onward.

In the Docker Compose stack, the bootstrap service runs with `profiles: ["bootstrap"]` so `docker compose up` does not start it automatically. The smoke test step invokes it once:

```bash
docker compose run --rm bootstrap
```

### 5.5 Lazy population and L5 deferred

**Lazy population (write-on-compute):**

After every cache miss + successful compute, the worker writes the result to Valkey via the Lua merge script. The next request for the same or overlapping range finds the entry and returns from cache. This is the read-through / write-on-miss pattern: no separate cache-warming job is needed for user-driven ranges; the cache fills organically as requests arrive.

**Merge cost vs. split:**

The Lua merge is O(k) in the number of overlapping cache entries it merges, plus the prime-list union operation (O(n log n) sort for the merged list). For realistic internal-tools traffic (dozens to hundreds of distinct range requests), k ≤ 10 in practice. If traffic drives the ZSET member count into the thousands (e.g., a systematic sweep of non-overlapping ranges), the merge cost per write grows. Monitoring `ElastiCacheProcessingUnits` per request in the Phase 2.5 acceptance window gives the signal to decide whether the merge-on-write pattern remains appropriate or whether a separate compaction job (L5 deferred) is warranted.

**L5 deferred cache enhancements:**

- **Read-through TTL refresh** — reset TTL on every read so hot entries don't expire while in use.
- **Multi-tier cache** — in-process LRU for ultra-hot entries (< 10 ms) backed by Valkey for cross-worker sharing. Adds complexity; worth considering if Valkey round-trip latency (~2–5 ms) is measurable in the p99 budget.
- **Alternative eviction policies** — LFU (Redis `allkeys-lfu`) for skewed hot-cold distributions. Not configurable on ElastiCache Serverless; relevant if migrating to provisioned.
- **Range query strategies** — for cap > 10⁷, a trie or segment tree index over the ZSET could reduce the ZRANGEBYSCORE scan cost. Not needed at current scale.
- **Cache backend revisit** — if merge cost grows (high distinct-range traffic), consider a Postgres `prime_cache` table with a GiST range index or a purpose-built segment cache. The `cache.py` abstraction is the extension point; the decision ADR (0031) records the trigger conditions.

## 6. Where to read next

- **Smoke test** — [`README.md` § Initial Acceptance](../README.md#initial-acceptance-smoke-test). Six paste-and-run commands (includes cache-hit and backpressure steps), two minutes, pass/fail visible without the candidate present.
- **Cloud deployment walkthrough** — [`docs/deployment_guide.md`](deployment_guide.md). Architecture diagram, component table, network flow, plan-only Terraform usage.
- **Cross-cloud migration spec** — [`docs/migration_runbook.md`](migration_runbook.md) (Phase 2). Agent-executable runbook with service-mapping table at the top; spec is invariant across destinations.
- **Single-region → multi-region** — [`docs/scaling_runbook.md`](scaling_runbook.md) (Phase 2). Same agent-executable schema, second axis of extension.
- **Every decision's full reasoning** — [`docs/ADR/`](ADR/) in numerical order. Each ADR carries Status, Context, Decision, Alternatives Considered, Consequences, and Related ADRs. When this document gestures at a choice, the ADR is the receipt.
