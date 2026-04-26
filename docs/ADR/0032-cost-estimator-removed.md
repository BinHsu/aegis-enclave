# ADR-0032: Cost estimator removed — schema cap + backpressure + worker timeout suffice

## Status
Accepted (2026-04-26) — supersedes ADR-0020 (cost-estimator component)

## Context

ADR-0020 introduced `_estimate_compute_ms(start, end, _known_max)` as a pre-flight check: if the estimated compute time exceeded `_HARD_TIMEOUT_MS = 30_000`, the request was rejected with a 400. The estimator's goal was to prevent the synchronous HTTP handler from being pinned by a long compute — a DoS risk when the handler and the compute share the same thread.

The async architecture (ADR-0029) changes the execution model: the HTTP handler no longer executes the compute. It enqueues a job and returns 202 immediately. The compute runs in a separate worker process with its own timeout (SIGALRM 60 s, ADR-0033). This removes the original motivation for the estimator.

Independently, the estimator has known weaknesses:
1. **Cache-state dependency.** The estimate is `f(start, end, _known_max)` — as the in-process cache grows, the same `(start, end)` transitions from "estimated expensive" to "estimated cheap." This is correct in principle but produces false 400s for the same input during the cache warm-up window, making the behaviour non-deterministic from the client's perspective.
2. **Estimation error.** The estimator over-estimates to avoid under-estimated 504s. Over-estimation rejects legitimate requests — a conservative bias the service specification's throughput SLO cannot absorb.
3. **No equivalent in the distributed cache world.** With ElastiCache Serverless Valkey (ADR-0031), the relevant `_known_max` is per-cluster, not per-worker. The estimator would need to query Valkey on every request to calibrate — making the "cheap pre-flight check" expensive.

Three independent guard layers remain after the estimator is removed, each addressing a distinct failure mode:

| Layer | Guard | Failure mode addressed |
|---|---|---|
| **Schema cap** | `end - start ≤ 10⁷`, enforced by Pydantic at request ingress | Unbounded input — `(2, 10⁹)` rejected with 422 before any queueing or compute |
| **Backpressure** | Queue depth > `5 × worker_count` → 503 + `Retry-After: 60` | Queue saturation — prevents SQS from accumulating unbounded backlog when workers fall behind a sustained burst |
| **Worker timeout** | SIGALRM 60 s per job → status=failed + error_message | Runaway compute — bounds per-job wall time regardless of input shape |

These three layers form a defence-in-depth without requiring the estimator's cache-state awareness. The memory rule `feedback_safety_guard_recovery_test.md` confirms the important distinction: removing a safety guard is only safe when an equivalent automated recovery exists. The analysis is:

- **Schema cap** (Pydantic 422): no equivalent in the estimator — this is actually stronger (synchronous, no cache dependency, no estimation error).
- **Backpressure** (503 + Retry-After): the estimator could catch an expensive single request; backpressure catches the aggregate load. Together with the schema cap's 10⁷ ceiling, a single request cannot cause more than 60 s of compute, which is within the worker timeout. Backpressure prevents accumulation of many concurrent requests.
- **Worker timeout** (SIGALRM 60 s): the estimator's primary purpose was to avoid long computes in the HTTP handler. In the async architecture, the HTTP handler never runs the compute — the worker does. The worker timeout is the replacement, not the estimator.

The recovery guarantee that makes removing the estimator safe: **the worst-case scenario after removal is that a request that the estimator would have rejected instead enters the queue and times out after 60 s with status=failed.** The client receives a structured failure response (not a connection reset or a 504), and the SQS message is acknowledged (no redelivery loop). The client's retry behaviour is governed by the `Retry-After: 60` signal from the backpressure middleware or by inspecting `status=failed`.

## Decision

Remove the cost-estimator (`_estimate_compute_ms`) entirely from `src/prime_service/primes.py` and `src/prime_service/main.py`. The three-layer guard (schema cap + backpressure + worker timeout) provides equivalent defence with fewer assumptions about cache state and without estimation error.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **Keep estimator, adapt to query Valkey for `_known_max`** | Makes the "cheap pre-flight" expensive (a network round-trip to Valkey on every POST). Cache latency in the p99 path (~5–15 ms) is acceptable for a compute call; it is not acceptable as a pre-flight tax on every request. |
| **Keep estimator, use static `_known_max = 0` (pessimistic)** | The estimator with `_known_max = 0` rejects every request whose range is expensive starting from cold — i.e., rejects the exact requests that the cache is designed to serve cheaply once warm. Produces a large false-rejection window immediately post-deploy. |
| **Keep estimator for the HTTP tier only (not the worker)** | The HTTP tier in the async architecture does no compute. The estimator has nothing to estimate from the HTTP tier's perspective — it cannot know whether the cache is warm. This is equivalent to removing it. |

## Consequences

- `primes.py` loses `_estimate_compute_ms` and associated pre-flight logic. Code is simpler.
- The POST handler no longer produces 400 on "expensive" inputs — it produces 202 unconditionally (within the schema cap). Callers who relied on a 400 to signal "too expensive" must now poll for `status=failed` instead. This is consistent with the async contract and documented in the service specification.
- Test suite removes estimator BVA cases from `tests/test_primes.py`; adds SIGALRM timeout test cases and schema-cap BVA.

## Related ADRs
- ADR-0020 (the ADR this supersedes — original cache + estimator + three-layer timeout decision)
- ADR-0029 (async POST + SQS + worker pool — the architectural change that makes the estimator redundant)
- ADR-0031 (Valkey distributed cache — eliminates the per-worker `_known_max` that the estimator depended on)
- ADR-0033 (async drain semantics — SIGALRM worker timeout that replaces the estimator's compute-time guard)
- ADR-0003 (PoC scope, prod hygiene — calibration this ADR sits inside)
