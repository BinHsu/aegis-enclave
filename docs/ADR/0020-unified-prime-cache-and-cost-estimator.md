# ADR-0020: Unified monotonic prime cache + cost-aware pre-flight reject + three-layer timeout

## Status
Superseded by ADR-0032 (2026-04-26). The cost-estimator component is removed; schema cap + backpressure + worker timeout provide equivalent defence without the estimator's complexity. The unified monotonic cache decision is itself superseded by the distributed Valkey cache (ADR-0031). Partially supersedes ADR-0017 (the immutable-tuple `_PRIME_TABLE` posture; lock-protected mutability is required for monotonic cache extension).

## Context
ADR-0017 documented the original prime-computation strategy: a static `_PRIME_TABLE` tuple pre-built at module load, with sieve and trial-division fallbacks for ranges above the table. The tuple was deliberately immutable — accidental `.append` / `.sort` / item-assignment would raise `TypeError` instead of silently corrupting subsequent lookups.

Three follow-up concerns surfaced during Phase 1.5 review and SLO discussion:

1. **The static table and any per-query LRU were two caches with different semantics.** The static table covers `[2, 100_000]`; an LRU caches arbitrary `(start, end) → list[int]` pairs. A query like `(50_000, 200_000)` would miss the LRU but the static table covers half — the deliverable would benefit from a single source of truth.

2. **The `_RANGE_CEILING = 10**7` is a memory bound, not a latency bound.** A query like `(1_000_001, 11_000_001)` is structurally legal but takes minutes via trial division — a real DoS risk if any operator-facing endpoint is exposed.

3. **No service-level timeout exists.** uvicorn has no built-in per-request timeout; FastAPI's asyncio runtime would happily block a worker indefinitely. Combined with `(2)`, a single malicious or careless client could pin all uvicorn workers.

These three concerns share a root: the cache, the validator, and the request lifecycle were each making assumptions in isolation, and the assumptions did not compose.

## Decision
Three coupled changes, treated as one architectural shift:

**1. Unified monotonic cache.** Replace the static `_PRIME_TABLE: tuple` with a mutable `_known_primes: list[int]` plus `_known_max: int`, guarded by `threading.Lock`. The cache is pre-warmed at module load with primes up to `_INITIAL_PREWARM_BOUND = 10**5` (~9,592 primes, ~5–15 ms). Queries either hit the cache (`end <= _known_max` → bisect-and-slice), extend it (`start <= _known_max + _GAP_THRESHOLD` → compute the gap, append, return slice), or compute standalone for far-gap queries (no cache pollution).

**2. Cost-aware pre-flight rejection.** `_validate` now invokes `_estimate_compute_ms(start, end, _known_max)` and rejects with `ValueError` when the estimate exceeds `_HARD_TIMEOUT_MS = 30_000`. The estimator factors current cache state — as `_known_max` grows, more queries become free. The estimator is conservative; over-estimates result in unnecessary 400s, never under-estimated 504s.

**3. Three-layer timeout defence at the request lifecycle.** `main.py` wraps `primes_in_range` in `asyncio.wait_for(timeout=30)` and `insert_execution` in `asyncio.wait_for(timeout=10)`. `db.py` sets `command_timeout=10` on the asyncpg engine (driver-level enforcement). Terraform sets ALB `idle_timeout = 45` so the client sees the application's 504 rather than an ALB connection reset.

The three changes compose: pre-flight rejects DoS shapes; the cache makes repeated work fast; the timeouts catch edge cases the estimator misses.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Keep static `_PRIME_TABLE` + add separate LRU for outputs | Two caches with different semantics; LRU keyed on `(start, end)` doesn't handle overlapping queries (the most common pattern). The unified cache handles half-hits naturally and gives a single source of truth for the estimator. |
| Async + queue audit decoupling (write to queue, return immediately, audit in background) | Architecturally cleaner for a real production service but introduces consistency questions (client gets `execution_id`, immediately polls `/executions/{id}`, sees 404). Out of case-study scope; documented as Phase 2 in `docs/migration_runbook.md`. |
| Fixed compute-time ceiling per query (no estimator) — e.g., reject any query above 10⁶ outright | Simpler but coarse. A `(2, 10⁶)` query is fine (~3s sieve); a `(10⁶, 11×10⁶)` query is not (minutes via trial division). The estimator separates "size" from "shape". |
| Cross-worker shared cache via Redis | Phase 2 concern. Per-worker cache costs ~5–15 ms cold-start per worker; cross-worker shared cache eliminates that but adds a new infrastructure dependency (out of ADR-0003 PoC scope). |
| Skip cache eviction (cache grows monotonically) ← chosen | Bounded by `_RANGE_CEILING = 10⁷` to ~664k primes ≈ 18 MB per worker. Cheaper to let the cache grow than to track LRU recency under a lock. |

## Consequences
- **DoS-by-input-shape is closed.** The pre-flight estimator catches the worst-case `(start, end)` shapes (~5–15 minutes of trial division) before any compute runs. The estimator is fast (microseconds) so it adds no measurable latency to legitimate queries.
- **Cache state amplifies over time.** As queries arrive and extend `_known_max`, subsequent estimates tighten — the same query that was rejected at cache-cold can become trivially cheap once a related query has warmed the cache to its tail. Predictable for production traffic; non-deterministic for adversarial.
- **Three independent timeout layers.** Compute (30s), audit (10s), and ALB idle (45s) form a defence-in-depth; any one failing leaves the others as guards. The 30+10s app sum is below the 45s ALB so clients see explicit application 504/503 rather than ALB resets.
- **ADR-0017's tuple-immutability claim is partially superseded.** `_known_primes` is now a mutable list. The hygiene goal (preventing accidental mutation) is now satisfied by `_cache_lock` plus module-level access discipline (no public re-export of `_known_primes`). Tests reset cache state via an autouse fixture so test ordering doesn't matter.
- **Per-worker cache cold-starts on each uvicorn worker boot.** ~5–15 ms per worker; for 4 workers, ~60 ms aggregate paid in parallel during startup. Acceptable for ECS Fargate task lifecycle.
- **Standalone compute path for far-gap queries** (e.g., `start=10**8, end=10**8+100`, far above `_known_max + _GAP_THRESHOLD`) returns correctly but doesn't extend the cache. Keeps `_known_primes` contiguous; avoids ballooning to a multi-GB cache for an isolated query.
- **SLO calibration tightens.** With the cache, p99 latency for in-range queries drops from "sieve allocation cost" to "bisect + slice ≈ sub-millisecond". ADR-0008's `p99 < 500ms` becomes generous rather than tight.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene — calibration this ADR sits inside)
- ADR-0008 (reliability targets — SLO/RTO/RPO; cache + timeout layers improve p99 budget)
- ADR-0009 (DB topology — `command_timeout = 10` enforces at driver layer)
- ADR-0015 (no real apply — Terraform `idle_timeout` is plan-only)
- ADR-0017 (prime strategy — partially superseded by this ADR; tuple-immutability claim no longer holds)
- ADR-0018 (managed-default — same shape: pick simplest, upgrade on trigger; cross-worker shared cache via Redis is the upgrade path)
