# ADR-0033: Async drain semantics — SIGALRM + SQS redelivery

## Status
Accepted (2026-04-26) — supersedes ADR-0022 (synchronous drain semantics)

## Context

ADR-0022 defined drain semantics for the synchronous architecture: four timer tiers (uvicorn graceful shutdown, FastAPI lifespan, ECS container stop_timeout, ALB deregistration_delay) aligned so every in-flight HTTP request finishes before SIGKILL. The longest legitimate request was 40 s (30 s compute + 10 s audit write per ADR-0020).

The async architecture (ADR-0029) splits the execution into two separate processes:

1. **API process** — handles HTTP only. No compute. The longest legitimate request is < 100 ms (DB write + SQS enqueue). The synchronous drain math still applies here but the numbers are far smaller.
2. **Worker process** — runs SQS consumer loop. Receives one message at a time, executes compute (up to 60 s), writes result to DB, acknowledges message. This is a **long-running background process**, not an HTTP handler. The "graceful shutdown" concern is different: the relevant question is "what happens to an in-flight job when the worker is killed?"

Two distinct failure modes require separate treatment:

**Mode A — Clean shutdown (ECS rolling deploy or scale-in).** ECS sends SIGTERM. The worker should: finish the current job if it can complete within budget, write the final status (done or failed), acknowledge the SQS message, then exit. If it cannot finish within budget, it should not acknowledge the SQS message — SQS visibility timeout (90 s) will redeliver the message to another worker.

**Mode B — CPU-bound worker bug (infinite loop, no OOM).** A bug in the prime sieve causes the worker to spin forever. Unlike a memory leak (which eventually causes OOM → container restart → message redelivery), a pure CPU-bound bug does not self-recover. The worker continues holding the SQS message (preventing redelivery) and consuming CPU (crowding out legitimate jobs). **This is the critical safety property identified in the memory rule `feedback_safety_guard_recovery_test.md`:** queue redelivery rescues the message only after the visibility timeout expires; it does not rescue the worker. The worker itself requires an explicit signal.

SIGTERM alone is insufficient for Mode B because the handler checks for SIGTERM only between Python bytecode instructions — a tight C-extension loop (e.g., a sieve inner loop) can ignore SIGTERM for seconds to minutes.

## Decision

**Per-message compute budget: SIGALRM 60 s.**

The worker wraps the compute call in `signal.alarm(60)`. On SIGALRM, Python raises `TimeoutError` (via a `signal.signal(SIGALRM, handler)` that raises). The worker catches `TimeoutError`, writes `status=failed` + `error_message="compute timeout"` to the audit row, and acknowledges the SQS message. The message is not redelivered (it was processed — the outcome is failure, not error).

**SQS visibility timeout: 90 s (= 60 s compute + 30 s buffer).**

If the worker is killed (SIGKILL, host failure, task eviction) without acknowledging the message, the 90 s visibility timeout expires and SQS redelivers the message to another worker. The 30 s buffer accommodates: DB write latency (~5–10 ms), SQS ack latency (~5–10 ms), and unexpected slowness under load. 90 s ≥ 60 s SIGALRM + realistic overhead.

**SIGTERM grace on clean shutdown: 5 s.**

On SIGTERM, the worker sets a stop flag. At the end of the current SQS poll cycle (every ~20 s idle or immediately on message receipt and acknowledgement), the worker checks the stop flag and exits. If a job is currently in-flight when SIGTERM arrives, the worker finishes it (it is within the 60 s SIGALRM budget) and then exits. The ECS container `stop_timeout` is set to 70 s (60 s compute budget + 5 s grace + 5 s slack) — ECS sends SIGKILL if the container has not exited in 70 s.

**API tier drain semantics (unchanged from ADR-0022 structure, with updated numbers):**

| Tier | Setting | Value |
|---|---|---|
| uvicorn graceful timeout | `--timeout-graceful-shutdown` | 15 s (longest HTTP request is < 100 ms; generous buffer) |
| ECS container stop_timeout (API) | `stop_timeout` | 30 s |
| ALB deregistration_delay | `deregistration_delay` | 30 s |

The numbers are shorter than ADR-0022 because the API no longer executes compute. The ALB `idle_timeout` stays at 45 s (already set per ADR-0020).

**Worker recovery guarantee summary:**

| Failure mode | Recovery mechanism | Recovery latency |
|---|---|---|
| CPU-bound bug (infinite loop) | SIGALRM 60 s → TimeoutError → status=failed + ack | 60 s max |
| Worker SIGTERM (clean shutdown) | Finish current job, then exit | ≤ 60 s + 5 s grace |
| Worker SIGKILL (host/task failure) | SQS visibility timeout 90 s → redelivery to another worker | 90 s max |
| Memory exhaustion (OOM) | Container restart (Linux OOM killer) → SQS visibility redeliver | Restart + 90 s max |

The key insight from `feedback_safety_guard_recovery_test.md`: **queue redelivery rescues the message, not the worker.** A stuck worker (CPU-bound bug) continues consuming resources until SIGALRM fires or the container is killed externally. SIGALRM is the worker-side guard; SQS visibility timeout is the message-side guard. They address different failure modes.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **Rely solely on SQS visibility timeout (no SIGALRM)** | A CPU-bound bug without OOM keeps the worker alive but stuck indefinitely. The message is not redelivered until the visibility timeout expires (~90 s), but the worker process is not recovered — it continues consuming CPU until the ECS task is killed by an external mechanism (CloudWatch alarm, human intervention). In the meantime, the worker cannot process other messages. SIGALRM closes this gap: it bounds the compute time per message at the process level. |
| **Use `asyncio.wait_for` (async timeout)** | `asyncio.wait_for` only interrupts Python coroutine awaits — it does not interrupt a running C extension or a tight synchronous loop. The sieve implementation is synchronous CPU-bound code; `asyncio.wait_for` wrapping a `run_in_executor` call raises `TimeoutError` in the event loop but cannot interrupt the thread running the sieve. SIGALRM bypasses this limitation because it is an OS-level signal delivered to the process, not an asyncio construct. |
| **Run each job in a subprocess (separate PID)** | Clean kill semantics: `kill(child_pid, SIGKILL)` terminates the subprocess. But: forking a subprocess per message adds ~20–50 ms overhead; the subprocess cannot share the Valkey connection pool or the DB connection pool; and the worker becomes a fork-per-message process manager, adding significant complexity. SIGALRM in the same process is sufficient for the PoC profile. |
| **Keep synchronous architecture + ADR-0022 drain semantics** | Addressed in ADR-0029 — the synchronous architecture has fundamental saturation problems under the target load profile. ADR-0022's drain math does not apply to an async worker loop. |

## Consequences

- Worker code has a SIGALRM handler in `worker.py`. The handler raises `TimeoutError`. Unit tests include a test that the handler fires after the configured budget.
- The audit table's `error_message` column captures `"compute timeout"` on SIGALRM — clients polling `GET /primes/{id}` see `status=failed` with a clear message rather than a perpetual `status=running`.
- ECS container `stop_timeout` for the worker service is 70 s in Terraform. This is longer than the API service's 30 s — a future engineer changing the worker compute budget must update both `compute_budget_seconds` (Terraform variable) and `stop_timeout` together.
- SQS visibility timeout 90 s means a killed worker results in a 90 s redelivery delay. This is acceptable for a best-effort compute service (the service specification does not promise sub-60 s latency for large compute-miss requests).

## Related ADRs
- ADR-0022 (superseded — synchronous four-tier drain semantics; body preserved as historical record)
- ADR-0029 (async POST + SQS + worker pool — the architecture this drain design supports)
- ADR-0032 (cost estimator removed — SIGALRM is the replacement for the estimator's compute-time guard role)
- ADR-0003 (PoC scope, prod hygiene — calibration this ADR sits inside)
- ADR-0020 (partially superseded — original compute timeout of 30 s; revised to 60 s here)
