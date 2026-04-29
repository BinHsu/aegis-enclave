# ADR-0033: Async drain semantics — SIGALRM + SQS redelivery

## Status
Accepted (2026-04-28)

## Context

The async architecture (per ADR-0029) splits execution into two distinct processes with different drain concerns:

- **API process** — HTTP only, no compute. Longest legitimate request is the DB write + SQS enqueue (< 100 ms). Drain is straightforward: finish in-flight HTTP, exit.
- **Worker process** — long-running SQS consumer loop. Receives one message at a time, executes compute (up to 60 s), writes result to DDB, acknowledges message. The "graceful shutdown" question is "what happens to an in-flight job when the worker is killed?", not "drain in-flight HTTP connections".

Two distinct failure modes in the worker tier require separate treatment:

**Mode A — Clean shutdown (ECS rolling deploy / scale-in).** ECS sends SIGTERM. Worker should: finish current job within budget, write final status, ack the SQS message, exit. If finish-within-budget is impossible, do NOT ack — SQS visibility timeout will redeliver to another worker.

**Mode B — CPU-bound worker bug (infinite loop, no OOM).** A bug in the prime sieve causes the worker to spin forever. Unlike a memory leak (which eventually triggers OOM → container restart → message redelivery), a pure CPU-bound bug does not self-recover. The worker continues holding the SQS message (preventing redelivery) and consuming CPU (crowding out legitimate jobs).

**Critical safety property**: queue redelivery rescues the message only after visibility timeout expires; it does not rescue the worker. The worker itself requires an explicit signal. SIGTERM alone is insufficient because the Python signal handler runs only between bytecode instructions — a tight C-extension loop (or a sieve inner loop) can ignore SIGTERM for seconds to minutes.

## Decision

**Per-message compute budget: SIGALRM 60 s.**

The worker wraps the compute call in `signal.alarm(60)`. On SIGALRM, Python raises `TimeoutError` (via a `signal.signal(SIGALRM, handler)` that raises). The worker catches `TimeoutError`, writes `status=failed` + `error_message="compute timeout"` to the audit row, and acknowledges the SQS message. The message is not redelivered — the outcome was processed, just unsuccessfully. SIGALRM is the only mechanism that interrupts a Python GIL holder; `asyncio.wait_for` cannot interrupt synchronous CPU-bound code.

**SQS visibility timeout: 90 s** (= 60 s SIGALRM + 30 s buffer).

If the worker is killed (SIGKILL, host failure, task eviction) without acknowledging the message, the 90 s visibility timeout expires and SQS redelivers to another worker. The 30 s buffer accommodates DB write latency, SQS ack latency, and unexpected slowness.

**SIGTERM grace on clean shutdown: 5 s.**

On SIGTERM, the worker sets a stop flag. At the end of the current SQS poll cycle (every ~20 s idle or immediately after message ack), the worker checks the flag and exits. If a job is in-flight when SIGTERM arrives, the worker finishes it (within the 60 s SIGALRM budget) then exits. ECS container `stop_timeout` is 70 s (60 s budget + 5 s grace + 5 s slack); ECS sends SIGKILL if the container has not exited in 70 s.

**API tier drain (no user-facing compute connection):**

| Tier | Setting | Value |
|---|---|---|
| uvicorn graceful timeout | `--timeout-graceful-shutdown` | 15 s (longest HTTP request < 100 ms; generous buffer) |
| ECS container stop_timeout (API) | `stop_timeout` | 30 s |
| ALB deregistration_delay | `deregistration_delay` | 30 s |
| ALB idle_timeout | (unchanged) | 45 s |

The API has no compute — POST returns 202 immediately and the client polls separately. There is no user-facing connection waiting on compute, so the API drain numbers are short.

### Worker recovery guarantee summary

| Failure mode | Recovery mechanism | Recovery latency |
|---|---|---|
| CPU-bound bug (infinite loop) | SIGALRM 60 s → TimeoutError → status=failed + ack | 60 s max |
| Clean SIGTERM | Finish current job, then exit | ≤ 60 s + 5 s grace |
| SIGKILL (host/task failure) | SQS visibility timeout 90 s → redelivery | 90 s max |
| OOM | Container restart (Linux OOM killer) → SQS visibility redeliver | Restart + 90 s max |

The key insight: **queue redelivery rescues the message, not the worker.** A stuck worker (CPU-bound bug) continues consuming resources until SIGALRM fires or the container is killed externally. SIGALRM is the worker-side guard; SQS visibility timeout is the message-side guard. They address different failure modes — neither suffices alone.

## Alternatives Considered

| Alternative | Industry context |
|---|---|
| **Sync-API graceful shutdown** (four-tier coordinate uvicorn / ECS / ALB / app) | Industry pattern for sync APIs where the client connection is waiting on compute. Not applicable in async architecture — there is no user-side waiting connection during compute. |
| **SQS visibility timeout only (no SIGALRM)** | A CPU-bound bug without OOM keeps the worker alive but stuck; the message stays held, the worker stays unproductive. SIGALRM closes this gap by bounding compute time at the process level. |
| **`asyncio.wait_for`** (async timeout) | Only interrupts Python coroutine awaits; cannot interrupt synchronous C-extension or tight Python loop. SIGALRM bypasses this limitation as an OS-level signal. |
| **Subprocess per job** (separate PID, SIGKILL-able) | Clean kill semantics. ~20–50 ms fork overhead per message; cannot share Valkey / DDB connection pools; worker becomes fork-per-message process manager. SIGALRM in-process is sufficient for the workload profile. |
| **Worker poll-based shutdown** (check termination flag every iteration) | Polling leaks the graceful half-window; SIGALRM is the more reliable interrupt mechanism for CPU-bound code. |

## Consequences

- Worker code has a SIGALRM handler in `worker.py`; the handler raises `TimeoutError`. Unit tests verify the handler fires after the configured budget.
- The audit row's `error_message` column captures `"compute timeout"` on SIGALRM — clients polling `GET /primes/{id}` see `status=failed` with a clear message rather than a perpetual `status=running`.
- ECS worker `stop_timeout` is 70 s — longer than the API service's 30 s. A future engineer changing the worker compute budget must update both `compute_budget_seconds` (Terraform variable) and `stop_timeout` together.
- 90 s redelivery delay on SIGKILL is acceptable for a Tier 2 ops support workload (the service contract does not promise sub-60 s end-to-end for compute-miss requests).

## Related ADRs
- ADR-0008 (reliability targets — Tier 2 calibration that the 60 s / 90 s composition fits)
- ADR-0020 (compute load management — L3 SIGALRM is the per-task budget; this ADR records the implementation)
- ADR-0029 (async POST + SQS + worker pool — the architecture this drain design supports)
- ADR-0030 (ElasticMQ local SQS parity — the local equivalent of the visibility timeout behaviour)
- ADR-0038 (DLQ alarm + manual triage — the failure-recovery layer above this drain semantics)
