# ADR-0029: Async POST 202 + SQS + worker pool

## Status
Accepted (2026-04-26)

## Context

The Phase 1 architecture processed prime-range requests synchronously: `POST /primes` blocked the HTTP worker for the full duration of computation, which could run up to 30 seconds (ADR-0020's `_HARD_TIMEOUT_MS = 30_000`). Three problems converge on the synchronous path under the load profile defined in the service specification (§ B: bursty internal-tools, idle ~1 req/min, bursts 50–100 req/sec for ≤ 30 s):

1. **Connection saturation.** A burst of 50 concurrent requests, each holding a Fargate task HTTP worker for up to 30 s, saturates all available uvicorn workers immediately. Requests after the first batch are rejected with a connection-level timeout rather than an application-level 503 + `Retry-After`.

2. **Retry semantics are undefined.** A synchronous 504 from the ALB (ALB idle-timeout fires before compute finishes) gives the client no information about whether to retry and when. The 90th-percentile case (a cache-miss range near the 10⁷ ceiling) is exactly the case that times out at the ALB.

3. **Compute and I/O concerns are conflated in one thread.** The HTTP handler, the prime computation, and the audit write share one execution context. A slow DB write causes a slow HTTP response; a long compute causes the health check to be delayed.

The compute path must move to a worker that can absorb and bound long-running jobs outside the HTTP thread. The three-layer cost guard (ADR-0020 — schema cap, queue backpressure, worker SIGALRM) covers the same DoS-shape concerns without coupling them to the synchronous HTTP path.

## Decision

Decouple the HTTP tier from the compute tier using **SQS as the intermediate queue**:

- `POST /primes` writes an audit row with `status = 'queued'`, enqueues the job to `aegis-enclave-primes` (SQS), and returns **202 Accepted** with `{execution_id, status: "queued"}`.
- `GET /primes/{execution_id}` reads the audit row and returns `{status, result?, error_message?}`. This is a pure DB read — no compute, no queue interaction.
- A **worker pool** (separate ECS Fargate service, same container image, different CMD) polls SQS, executes the compute, writes the result back to the audit row, and acknowledges the message.

SQS properties:
- Visibility timeout: **90 s** (= compute budget 60 s × 1.5, per ADR-0033). A message that is received but not acknowledged becomes visible again after 90 s — the queue redelivers the message to another worker if the first worker fails or is killed.
- Dead-letter queue: skeletal design committed to Terraform for future DLQ retry policy; not wired in the PoC (L5 deferred).

Worker pool:
- Container: same image as the API, entrypoint `python -m prime_service.worker`.
- ECS Fargate auto-scaling: min=1, max=3, target tracking on `ApproximateNumberOfMessagesVisible` target value 5.
- Compute budget per message: **60 s SIGALRM** (ADR-0033).

Client polling convention:
- Recommended interval: 1–2 s.
- Status state machine: `queued → running → done | failed`.
- `failed` status carries `error_message` describing the cause (timeout, exception, etc.).

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **Keep synchronous POST (no queue)** | Saturates HTTP workers under burst; ALB idle timeout fires before long computes finish; no retry signal for the client; every HTTP worker is also a compute worker, so scaling compute requires scaling the API tier. |
| **AWS Lambda per-job** | Lambda has a 15-minute max invocation timeout — appropriate headroom, but adds cold-start latency (~100–400 ms), a new IAM + VPC configuration surface, and cold-start characteristics that interact poorly with the distributed cache (each invocation gets a fresh connection). Fargate workers are persistent consumers with warm connections to Valkey and RDS. Lambda is the right shape when jobs are short-lived and invocation rate is very low; the bursty-but-sustained profile favours persistent consumers. |
| **AWS Step Functions** | Provides visual workflow tracking, branching, and retry policies out of the box. Substantial operational overhead for a single-step workflow (compute + audit write). Billed per state-transition. Design value is low when the workflow is linear and the retry logic is simple (visibility timeout handles it). |
| **Webhooks (callback URL per request)** | Eliminates client polling but requires the caller to expose a stable HTTP endpoint for callbacks — not feasible for internal tooling clients (operator laptops, ground-station agents) behind NAT or VPN. Adds authentication complexity (how does the service authenticate to the caller's endpoint?). Pull semantics via polling are strictly simpler for the client profile described in the service specification. |

## Consequences

**Positive:**
- HTTP tier is decoupled from compute tier. `POST /primes` returns immediately (< 100 ms) regardless of range size. HTTP worker saturation is bounded by backpressure middleware (per ADR-0020 L2) before queue overflow, not by compute time.
- SQS visibility timeout (90 s) provides automatic redelivery if a worker fails mid-job. No application-level retry loop is required in the HTTP handler.
- Worker auto-scaling can track queue depth independently of HTTP tier scaling — they share an image but have separate ECS services and scaling policies.
- The audit table's status column (`queued → running → done | failed`) gives clients and operators a durable record of every job outcome, including failures with `error_message`.

**Negative:**
- Client must poll. Synchronous-style code that does `result = post_primes_and_wait()` must be rewritten as a polling loop. The service specification names this explicitly so callers are not surprised.
- End-to-end latency for small cache-hit requests is higher than synchronous: the queue enqueue + worker dequeue adds ~200–500 ms overhead versus a sub-100 ms synchronous return. The latency budget in the service specification (cache hit < 100 ms for the HTTP response, polling resolution 1–2 s for the full round-trip) reflects this correctly.
- Two ECS services (API + worker) to manage. Worker ECS service auto-scaling configuration adds Terraform surface.
- Local stack adds ElasticMQ (ADR-0030) to provide SQS-protocol parity without a live AWS account.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene — calibration this ADR sits inside)
- ADR-0020 (compute load management — the three-layer cost guard whose L2 backpressure works above this queue)
- ADR-0030 (ElasticMQ — local SQS parity for the queue this ADR introduces)
- ADR-0031 (Valkey distributed cache — the cache layer the worker writes to after compute)
- ADR-0033 (async drain semantics — SIGALRM + SQS visibility + distinction between message recovery and worker recovery)
