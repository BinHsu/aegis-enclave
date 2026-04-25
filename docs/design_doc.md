# Design Document — aegis-enclave

## Scope and calibration

`aegis-enclave` is calibrated as **production-shape engineering at PoC scale** (ADR-0003). The deliverable answers a case-study brief that mixes "small application" framing with "long-term, multiple developers" hygiene language; the calibration resolves that tension by holding hygiene at production grade while letting feature surface stay deliberately small. The build is hard-capped at 15 hours (ADR-0002) and every cut taken to fit that budget is recorded as its own ADR rather than silently omitted.

The following operations layers are **intentionally absent**, named so the reviewer reads deliberate deferral rather than oversight:

- CI/CD pipelines, observability stack (Prometheus / Grafana), distributed tracing
- Load testing, region-level DR drills, multi-environment promotion
- Real `terraform apply` against a live cloud account (ADR-0015)
- Kubernetes manifests (Docker Compose covers the brief's orchestration ask — ADR-0015)

Every architectural claim below is anchored to a numbered ADR in [`docs/ADR/`](ADR/). When the rationale here gestures at "we chose X because Y," the ADR carries the alternatives table and the trade-off accounting. This document is a guided tour through those decisions — not a replacement for them.

## 1. Reliability and continuity

### 1.1 High availability

The cloud composition is deployed to a single AWS region (`eu-central-1`, Frankfurt) with two-AZ subnet distribution and an RDS Multi-AZ standby. Multi-region active-active is **out of Phase 1 scope** and lives instead as an agent-executable runbook in `docs/scaling_runbook.md` (ADR-0007, ADR-0012). The triggers that would move multi-region from Phase 2 plan into Phase 1 implementation are named explicitly in the Reliability section of the design — none of them are met at case-study scope:

1. Workload concurrency exceeding what a single region can absorb (e.g., simultaneous high-throughput streams from independent producers)
2. Globally distributed clients requiring locally-terminated network paths for latency or jurisdiction reasons
3. Regulatory requirements explicitly demanding geographic redundancy

A senior practitioner's honest estimate for full multi-region active-active in Phase 1 — Aurora Global Database, cross-region peering, per-region ECS / ALB / Client VPN endpoints, Route 53 failover, cross-region IAM and KMS replication, plus a failover drill — lands at 10-14 hours. That consumes the entire 15h budget for a capability the brief does not ask for. The reviewer reads "I have a Phase 2 plan" rather than "I forgot about scaling."

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

This section is also the **evidence-capture spec for Phase 2.3**: the table in § 3.1 is what gets screenshotted into `docs/deployment_guide.md` while the cloud-acceptance window is live, before teardown.

### 3.1 What the cloud composition emits for free

Every primitive in the Terraform composition publishes a baseline of CloudWatch metrics and structured logs without additional code. This is the observability surface available the moment a real `terraform apply` lands:

| Source | Metrics | Logs |
|---|---|---|
| Internal ALB | `RequestCount`, `HTTPCode_Target_{2,3,4,5}XX_Count`, `TargetResponseTime` (p50 / p90 / p99 built-in), `HealthyHostCount`, `UnHealthyHostCount` | Access logs to S3 (per request: client IP, path, response code, latency, target group) |
| ECS Fargate task | `CPUUtilization`, `MemoryUtilization`, container exit codes | stdout / stderr → CloudWatch Logs via `awslogs` driver (FastAPI's structured logging lands here intact) |
| RDS PostgreSQL Multi-AZ | `CPUUtilization`, `DatabaseConnections`, `FreeableMemory`, `ReadIOPS` / `WriteIOPS`, `ReplicaLag` | PostgreSQL log + slow-query log → CloudWatch Logs |
| AWS Client VPN endpoint | `ActiveConnectionsCount`, `AuthenticationFailures`, `IngressBytes`, `EgressBytes` | Connection log: client cert CN, source IP, connect / disconnect timestamps |
| VPC Flow Logs | (per-flow records) | All NIC-to-NIC traffic, including PrivateLink endpoint hits |

Phase 2.3's cloud-acceptance gate consumes this baseline by combining four evidence sources, captured before the stack is destroyed:

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

The architecture above mirrors the calibration shape in § 1.3: name the architecture, scope the implementation, leave deferred work as designed sketches rather than absent ones. Phase 2.3 ships the infrastructure-observability layer that AWS managed services emit by default; the application-observability sketch above gives the buyer enough design clarity to scope the upgrade conversation when (or if) the workload justifies it.

## 4. Where to read next

- **Smoke test** — [`README.md` § Initial Acceptance](../README.md#initial-acceptance-smoke-test). Five paste-and-run commands, two minutes, pass/fail visible without the candidate present.
- **Cloud deployment walkthrough** — [`docs/deployment_guide.md`](deployment_guide.md). Architecture diagram, component table, network flow, plan-only Terraform usage.
- **Cross-cloud migration spec** — [`docs/migration_runbook.md`](migration_runbook.md) (Phase 2). Agent-executable runbook with service-mapping table at the top; spec is invariant across destinations.
- **Single-region → multi-region** — [`docs/scaling_runbook.md`](scaling_runbook.md) (Phase 2). Same agent-executable schema, second axis of extension.
- **Every decision's full reasoning** — [`docs/ADR/`](ADR/) in numerical order. Each ADR carries Status, Context, Decision, Alternatives Considered, Consequences, and Related ADRs. When this document gestures at a choice, the ADR is the receipt.
