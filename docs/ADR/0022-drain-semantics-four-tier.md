# ADR-0022: Four-tier drain semantics — uvicorn + ECS task + ALB target group

## Status
Accepted (2026-04-25)

## Context
"Graceful shutdown" is not a single Python feature. When ECS scheduler decides to terminate a task — for a rolling deploy, scale-in event, or Fargate Spot reclaim — four independent timers must align so an in-flight request can finish without the client seeing a connection reset:

| Tier | Mechanism | Default |
|---|---|---|
| **App** (uvicorn) | On SIGTERM: stop accepting new connections, wait for in-flight requests, then exit. Bounded by `--timeout-graceful-shutdown`. | 30s |
| **App** (FastAPI lifespan) | `@asynccontextmanager` post-`yield` block runs as the event loop drains. | n/a |
| **Container** (ECS task) | ECS sends SIGTERM, waits `stop_timeout`, then sends SIGKILL. | 30s |
| **Load balancer** (ALB target group) | After ECS deregisters the target, ALB allows existing connections to keep traffic flowing for `deregistration_delay` seconds. | 300s |

The case-study workload has a defined longest legitimate request: **30s prime compute (ADR-0020) + 10s audit write (ADR-0020) = 40s end-to-end**. Anything beyond that is rejected pre-flight by `_estimate_compute_ms` (ADR-0021). So every legitimate in-flight request finishes within 40s.

With the four defaults above, two anti-patterns surface during deploy:

1. **uvicorn force-kills at 30s before its own request finishes.** A `/primes` call that started 1s before SIGTERM has 39s of legitimate work ahead but uvicorn drops it at T+30s. Client sees connection reset.
2. **ALB blocks rolling deploy for 5 minutes.** Default `deregistration_delay = 300s` keeps the old task in "draining" state long after it's quiet. Each deploy stalls on the slowest in-flight request for 5 minutes — operationally painful and disproportionate to the 40s actual work envelope.

## Decision
Pin all four tiers to values that strictly satisfy the invariant **"every legitimate request started before SIGTERM finishes before SIGKILL"**:

| Tier | Setting | Where | Value |
|---|---|---|---|
| uvicorn graceful timeout | `--timeout-graceful-shutdown 45` | `Dockerfile` CMD | **45s** |
| FastAPI lifespan | unchanged — post-yield logging only | `src/prime_service/main.py:53-57` | n/a |
| ECS container `stop_timeout` | `stop_timeout = 60` | `terraform/main.tf` container_definitions.app | **60s** |
| ALB `deregistration_delay` | `deregistration_delay = 60` | `terraform/main.tf` target_groups.app | **60s** |

Rationale for the specific numbers:

- **45s ≥ 40s longest request** — uvicorn finishes any legitimate in-flight request before dropping it.
- **60s ≥ 45s + 15s slack** — ECS waits long enough for uvicorn to finish naturally; the 15s headroom absorbs FastAPI lifespan teardown, Docker stop overhead, and any post-yield cleanup. ECS sends SIGKILL only if uvicorn somehow missed its own deadline, which is a bug worth seeing.
- **60s deregistration_delay** — matches the same 60s envelope. New connections stop landing immediately when ECS deregisters; old connections drain within the same window the app has to finish them. No 5-minute deploy stall.
- **ALB `idle_timeout = 45`** (already set per ADR-0020) is unaffected — it bounds total connection idle time, not drain.

## Drain timeline (happy path)

```
T+0    ECS scheduler decides to stop task
       ├─→ deregisters target from ALB target group
       └─→ sends SIGTERM to container

T+0~5  ALB enters "draining" state for this target
       - new requests routed to other targets (or rejected if last)
       - in-flight connections continue to old target

T+0~45 uvicorn graceful shutdown:
       - accept() refused
       - in-flight requests run to completion (≤ 40s)
       - lifespan post-yield block runs (logging only)

T+45   uvicorn exits normally → container exits → ECS marks STOPPED

T+60   ALB deregistration_delay expires → target fully removed
       (typically nothing left to drain because uvicorn finished at T+45)

T+60   ECS would have SIGKILL'd if uvicorn hadn't exited — never reached
       in normal operation, only fires if uvicorn is buggy.
```

## Consequences

**Positive:**
- No connection-reset on rolling deploy, scale-in, or Spot reclaim for any in-budget request.
- Deploys complete within ~60s of the last in-flight request, not 5 minutes.
- All four tiers documented in one place — future contributor changing one timer must check the others (single ADR, single math).

**Negative:**
- Task takedown is bounded at 60s for *every* request type, not just the worst-case prime compute. A `/health` call gets the same drain envelope as a 40s prime request. Acceptable: `/health` is sub-ms, finishes before SIGTERM is even processed.
- The 60s `deregistration_delay` is shorter than AWS's recommended default for high-traffic public services (where 300s helps with TCP keepalive and slow clients). Acceptable: this service is VPN-gated to known clients (ADR-0006), not the open internet, and the client list is operator + ground-station — both modern stacks with sub-second connection close.

## Alternatives considered

**A. Lameduck `/health` flag** — App sets a flag on SIGTERM; `/health` returns 503 until exit. ALB health check (interval 30s, unhealthy_threshold 3) sees 503 and starts deregister sooner than waiting for the ECS-side deregister. **Deferred** to Phase 1.8 — adds ~30 lines of signal-handling code and provides marginal benefit on top of the four-tier alignment above (saves at most one health-check interval, ~30s). Worth doing once the deploy automation exists; not worth doing for the case-study deliverable.

**B. Keep ALB `deregistration_delay` at 300s** — Conservative default, friendlier to slow clients. **Rejected** because (a) clients are VPN-known, not slow public users; (b) the 5-minute deploy stall is the more visible operational problem in a small-team context.

**C. Match uvicorn timeout to compute timeout (30s) instead of 45s** — Tighter coupling, but breaks the invariant: a request started at T-1s finishes at T+39s, uvicorn would force-kill at T+30s. **Rejected** — the 5s slack on top of the 40s ceiling is what makes "every legitimate request finishes" actually true.

## Related
- ADR-0020 — three-layer timeout stack (compute 30s, audit 10s, ALB idle 45s)
- ADR-0021 — pre-flight cost estimator that enforces the 30s compute ceiling
- ADR-0006 — VPN-gated reachability (informs the "trusted clients only" assumption above)

## Verification
The drain semantics are configuration-only (Dockerfile CMD + Terraform attributes); behavioural verification requires an actual ECS deployment, which is out of scope per ADR-0015. A future ADR-0023-deferred phase that flips the `apply` switch should add an end-to-end drain test (start a long `/primes`, trigger `terraform apply` for a deploy, assert the request returns 200).
