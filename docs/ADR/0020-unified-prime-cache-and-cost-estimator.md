# ADR-0020: Compute load management — three-layer defense derived from worst-case request budget

## Status
Accepted (2026-04-28)

## Context

The brief PDF was surveyed for `timeout|seconds|response time|latency|sla|deadline` — **0 hits**. The brief is silent on temporal and capacity constraints. The defense layers below are OUR derived design from worst-case-request reasoning, not honoring an external mandate (per the cycle-discipline of separating brief mandates from architectural judgments).

The compute service has three orthogonal failure modes that each require their own guard:

- **Unbounded input** — a malicious or careless `(2, 10⁹)` request that requires gigabytes of memory and minutes of CPU.
- **Aggregate burst** — a sudden 50–100 req/sec spike that fills the queue faster than workers can drain.
- **Single-task hijack** — a CPU-bound bug or pathological input that pins a worker indefinitely.

A single guard cannot cover all three. Schema-level rejection blocks unbounded input but cannot detect a stuck worker. Backpressure sheds aggregate burst but cannot interrupt a running compute. SIGALRM bounds per-task wall time but cannot prevent the queue from accumulating an unbounded backlog. **Three independent layers, each addressing a distinct failure mode, compose into a defense-in-depth.**

### Policy choices that drive the derived constants

| Policy choice | Value | Source |
|---|---|---|
| Worker count baseline | 3 | per-AZ posture (ADR-0007 — one task per AZ) |
| Per-task time budget | 60 s SIGALRM | SLO-derived round minute (300 s SLO / 5 polls); not benchmark-anchored — see § Per-task budget honesty below |
| Acceptable p99 queue wait | 5 min | SLO calibration per Tier 2 ops support (ADR-0008) |

Once these three policy values are set, the layer constants below are **derived, not chosen**.

## Decision

| Layer | Value | Derivation | Failure mode addressed |
|---|---|---|---|
| **L1 — schema absolute caps** | start, end ∈ [2, 10⁷] | static `_SMALL_PRIMES` table covers √(10⁷) = 3163 primes; trial_division correctness requires small_primes ≥ √n; only valid for n ≤ 10⁷ | Unbounded input |
| **L1 — range size cap** | end - start ≤ 10⁷ | redundant given absolute caps; explicit guard for clarity | Unbounded input |
| **L2 — queue backpressure** | depth > 5 × worker_count → 503 + Retry-After: 60 | (acceptable_wait / per-task_budget) = 300 s / 60 s = **5** | Aggregate burst |
| **L3 — worker SIGALRM** | 60 s | per-task budget hard ceiling at OS-signal level (bypasses Python GIL) | Single-task hijack |

The static `_SMALL_PRIMES` table size is auto-aligned with the L1 absolute cap: range cap → √cap → table size. Cache cross-leverage between the small-primes table and the layered cache (Valkey) is unnecessary at this cap; `primes.py` uses the static table only. Anything above 10⁷ would require a different correctness story (probabilistic primality, pre-computed segments) — out of scope.

### Why three layers, not redundant

| Layer | Failure scenario it addresses | Why other layers don't suffice |
|---|---|---|
| L1 schema cap | Client submits `(2, 10⁹)` | L2 only sheds when queue is full; L3 only fires after compute starts. L1 rejects at request ingress with 422, no resource consumed. |
| L2 backpressure | 100 concurrent legitimate requests | L1 lets them all through (each is in-bounds). L3 fires per-task but doesn't prevent unbounded queue accumulation. |
| L3 SIGALRM | CPU-bound bug pins worker on a legitimate input | L1 and L2 don't run inside the worker's compute path. Only an OS signal interrupts a Python tight loop holding the GIL. |

## Alternatives Considered

- **Cost estimator pattern** (industry-known: estimate compute cost, reject if above threshold). Schema cap already serves the equivalent gate at O(1) decision cost; estimate-then-reject adds attack surface (the estimator itself can be tricked or be wrong) and adds code complexity. FinOps-style cost estimation is an infra-level concern, separate from request-level defense. Industry pattern preserved here as context, not as journey-defense.
- **Dynamic SIGALRM based on input range size** — e.g., 10 s for small ranges, 60 s for large. Variable budget complicates monitoring and alarm thresholds. Static 60 s simplifies reasoning and matches the SLO end-to-end calibration.
- **Per-worker queue depth** instead of global threshold. SQS is region-shared; a global threshold suffices. Per-worker would require service-discovery for the worker count, which is dynamic under autoscale.
- **Token-bucket rate-limit at API tier** (X req/sec/tenant). Useful for Tier 1 multi-tenant; aegis-enclave is Tier 2 single-tenant, no per-tenant accounting needed. Forker promoting to multi-tenant adds this layer.
- **Pre-flight DB lookup for similar-range cache hit before enqueue.** Adds a synchronous read on the hot POST path; the worker already does the cache lookup with the same latency cost — moving it earlier doesn't reduce work.

## Consequences

- **DoS-by-input-shape is closed at L1.** Pydantic validation rejects in O(1) before any allocation.
- **Burst absorbance is bounded at L2.** Queue depth above 5 × worker_count signals "shed load now" rather than letting SQS accumulate an unbounded backlog. Auto-scaling (ADR-0023) catches up over the next 60–90 s.
- **Worker-side runaway is bounded at L3.** SIGALRM 60 s + Python `TimeoutError` propagation + audit-row `status=failed` write + SQS `DeleteMessage` (no redelivery — the outcome was processed, just unsuccessfully). Client polling sees the structured failure within one polling interval.
- **The three constants — 10⁷, 5×, 60 s — are derived, not magic numbers.** Anyone changing one of them must revisit the policy values they derive from (per-AZ baseline, p99 queue wait SLO, worst-case sieve cost).
- **Per-worker cache cold-starts** on each ECS task boot (~5–15 ms for the bootstrap range). Acceptable for Fargate task lifecycle.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene calibration)
- ADR-0007 (per-region 3-AZ posture — supplies worker_count baseline = 3)
- ADR-0008 (reliability targets — supplies acceptable p99 queue wait = 5 min)
- ADR-0017 (prime computation strategy — the algorithm whose worst-case cost the per-task budget bounds)
- ADR-0023 (worker auto-scaling — the dynamic capacity layer that catches up after L2 backpressure fires)
- ADR-0029 (async POST + SQS + worker pool — the architecture inside which these layers run)
- ADR-0031 (Valkey range-coalescing cache — the cache layer that compounds L1's effectiveness over time)
- ADR-0033 (async drain semantics — the SIGALRM / SQS visibility composition realising L3)
