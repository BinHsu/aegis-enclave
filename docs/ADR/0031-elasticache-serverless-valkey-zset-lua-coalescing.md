# ADR-0031: ElastiCache Serverless Valkey + ZSET + Lua range-coalescing

## Status
Accepted (2026-04-26)

## Context

Phase 1's prime cache (`_known_primes` in ADR-0020) was in-process per-worker. Each ECS Fargate task cold-starts its own cache (~5–15 ms pre-warm) and worker tasks cannot share cache hits across the cluster. This design works for a single-task deployment but becomes progressively inefficient as the worker pool auto-scales (ADR-0029) to 2–3 tasks:

- Task A warms `[2, 10_000_000]` via a large computation.
- Task B receives a request for `[1_000_000, 5_000_000]` — identical result subset already computed by Task A — and repeats the compute from scratch.

The distributed cache solves this by giving all workers a shared hit pool. The cache layer must satisfy three constraints:

1. **Range-aware lookup.** Prime ranges overlap in non-trivial ways (e.g., a cached `[1, 100_000]` covers the entire `[50_000, 80_000]` request). A key-value lookup by exact `(start, end)` pair misses all overlapping superset entries.
2. **Atomic merge.** When a worker computes `[1, 100_000]` while another has already cached `[1, 50_000]`, the merge must be atomic — two concurrent writers must not produce a corrupted or duplicate entry.
3. **Low-cost serverless posture.** The cache is accessed during the PoC acceptance window (≤ 3 hours per ADR-0034) and must not incur a per-hour provisioned-capacity fee during idle periods.

## Decision

**Backend:** AWS ElastiCache Serverless with engine `valkey` (ElastiCache Serverless supports Valkey 7.2 and Redis OSS 7.x). Valkey is Redis-compatible (Redis 7.2 fork) so all Redis data-type semantics and Lua scripting are available.

**ZSET key design for range index:**
- `primes:{ranges}` — sorted set; member format `{start}:{end}`, score = `start`. The `{ranges}` hash tag keeps the key on a single Valkey shard (required for Lua atomicity — KEYS must be on one shard).
- `primes:{ranges}:range:{start}:{end}` — string key holding the JSON-encoded prime list for the range `[start, end]`. TTL: bootstrap entry has no TTL (permanent warm-up baseline); user-driven entries have 6 h TTL; merged entries inherit `max(ttl_a, ttl_b)` or reset to 6 h on every merge.

**Lookup path (worker):**
1. `ZRANGEBYSCORE primes:{ranges} 0 {end}` — retrieves all cached ranges whose start ≤ end of the request.
2. Filter client-side for entries whose `end ≥ start_of_request` (overlap candidates).
3. If any single entry covers the full request range (`cached_start ≤ request_start AND cached_end ≥ request_end`), slice the JSON list and return without compute.
4. Partial-coverage and miss cases fall through to compute.

**Write path (worker, Lua atomic merge):**
After computing a new range, the worker calls a Lua script (`merge_or_put`) that:
1. Reads the ZSET to find all ranges that overlap or are adjacent to the new range.
2. If overlapping entries exist, merges them into a single superset range (union of start/end bounds, union of prime lists deduplicated + sorted).
3. Atomically deletes the originals and writes the merged entry.
4. Sets the TTL on the merged entry to `max(ttl_a, ttl_b, 6h)`.

The Lua execution is atomic within Valkey's single-thread model — no concurrent writes can interleave. All KEYS accessed by the Lua script are in the `{ranges}` hash tag and thus land on the same shard (ElastiCache Serverless Valkey constraint: cross-shard KEYS are not supported in Lua).

**Bootstrap pattern:**
A one-shot ECS task (`python -m prime_service.bootstrap`) runs after the Valkey endpoint is available (Terraform `null_resource.run_cache_bootstrap` depends on `aws_elasticache_serverless_cache.valkey`). The task checks `EXISTS primes:{ranges}:range:1:100000` — if absent, computes `sieve(1, 100_000)` and writes via `put_if_absent`. This seeds the hot-path baseline (all primes ≤ 100,000) so the first user request is a cache hit rather than a cold compute. The task logs success or skip clearly for CloudWatch evidence capture.

**Local parity:**
`valkey/valkey:7-alpine` in Docker Compose at `valkey:6379`. The `cache.py` abstraction uses `redis-py` with `VALKEY_ENDPOINT` env override; `VALKEY_TLS=false` disables TLS for the local stack (TLS is enabled in cloud via ElastiCache Serverless endpoint, which terminates TLS).

**Cost framing (3h apply-then-destroy):**
ElastiCache Serverless is billed on two dimensions: ECPUs consumed (per 1000 ECPU-seconds) and data stored (per GB-hour). For a 3-hour acceptance window with the bootstrap entry (~100,000 primes ≈ 0.3 MB) and a handful of smoke-test queries, total cost is well under $0.10 — no minimum hourly charge unlike provisioned node types. The alternatives table below uses the same 3-hour framing.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **DynamoDB exact-match cache** | DynamoDB key-value semantics require an exact `(start, end)` lookup. Range-overlap queries require either a scan (expensive, O(n) reads) or a carefully designed GSI. Even with a GSI, the `ZRANGEBYSCORE`-style overlap query (all ranges whose start ≤ X and end ≥ Y) is not a natural DynamoDB access pattern. Read unit cost for the cold-start lookup (one `GetItem`) is ~$0.00000025/call — cheaper per-call than Valkey, but the lack of overlap semantics forces repeated cache misses for every shifted-range request. For a prime-range workload where overlapping queries are the norm, this misses the core value of the cache. |
| **ElastiCache provisioned (Redis / Valkey cluster mode)** | Provisioned nodes are billed by the hour regardless of load. A `cache.t3.micro` node costs ~$0.017/hour; a 3-hour window costs ~$0.05 — acceptable, but the provisioned node must be created and destroyed explicitly. ElastiCache Serverless requires no cluster provisioning, scales to zero between ECPU-second billing events, and the Terraform resource is simpler (no node type, no replica count, no maintenance window). Serverless is the appropriate-complexity primitive for a PoC acceptance window. |
| **Postgres cache table** | Eliminates an extra AWS service. A `prime_cache` table with `(start, end, primes_json, expires_at)` columns could serve the cache role. Range overlap queries via SQL (`WHERE start <= $2 AND end >= $1`) work correctly. **But:** (a) Postgres is the audit-log store — mixing cache data into the same table couples TTL eviction to the audit-log lifecycle and adds write contention; (b) Postgres does not support Lua-atomic merge — the merge operation requires a transaction with locking (`SELECT FOR UPDATE`), which is more expensive and more error-prone than a single Lua script; (c) eviction requires a background job or trigger, not a native TTL. |
| **In-process LRU (per-worker, no network cache)** | Already in production in Phase 1 (ADR-0020). The limitation identified in Context above stands: cross-worker sharing is impossible. With min=1 / max=3 workers (ADR-0029), the cache-hit rate degrades by factor 2–3× whenever auto-scaling adds a task. |
| **Amazon MemoryDB for Redis** | MemoryDB provides Redis-compatible storage with multi-AZ durability (all writes journaled before acknowledgement). For a cache workload, durability is unnecessary — a cache miss is recoverable by recompute, not by durable write. MemoryDB's durability guarantee adds ~1 ms per write latency (journal commit). More importantly, MemoryDB does not offer a serverless variant as of this ADR's writing date; it requires provisioned nodes. The 3-hour acceptance window would cost the same as provisioned ElastiCache, but MemoryDB nodes are ~2–3× more expensive per IOPS than ElastiCache provisioned. |

## Consequences

- **All Fargate worker tasks share the same cache pool.** A range computed by Task A is immediately available to Tasks B and C via the ZSET lookup. Cache effectiveness scales with the cumulative request history rather than per-worker uptime.
- **Range-coalescing reduces storage footprint.** Overlapping ranges are merged into a single superset entry. A series of requests covering `[1, 50k]`, `[40k, 120k]`, `[100k, 200k]` converges to a single `[1, 200k]` entry rather than three separate entries. The ZSET member count stays O(distinct-range-frontier) rather than O(request-count).
- **Lua atomicity is a Valkey single-shard constraint.** All KEYS accessed by the merge Lua script must share the `{ranges}` hash tag. If future scaling demands cross-shard distribution, the Lua merge must be re-architected (e.g., client-side merge with optimistic locking). This is an L5 deferred concern per the service specification.
- **Bootstrap task adds ~5–10 s to cold-start deployment.** The ECS `null_resource` runs the bootstrap task after Valkey is available; the task finishes in < 30 s (sieve of 100k primes is ~5–15 ms, network round-trip ~5–10 ms). This is an ECS task startup cost, not a request-time cost.
- **Local Valkey (Docker Compose) runs without TLS.** The `cache.py` abstraction reads `VALKEY_TLS` from the environment. Cloud deployment enables TLS via ElastiCache Serverless endpoint. The code path diverges only at the `redis.py` client constructor; the rest of the cache logic is identical.
- **ElastiCache Serverless ECPU pricing is opaque on the first run.** ECPU consumption depends on the key count and command complexity. For the PoC acceptance window (handful of reads + writes), cost is well under $0.10. Operators should check AWS Cost Explorer after the 3-hour window closes if they are cost-sensitive.

## Related ADRs
- ADR-0020 (superseded — in-process LRU cache that this distributed cache replaces)
- ADR-0029 (async POST + SQS + worker pool — the worker that writes to this cache)
- ADR-0030 (ElasticMQ — local SQS parity; this ADR is the cache-side local-parity companion)
- ADR-0034 (build budget 22→24h — the +2h is driven by this ADR's range-coalescing scope)
- ADR-0003 (PoC scope, prod hygiene — calibration this ADR sits inside)
- ADR-0018 (managed-default tool selection — ElastiCache Serverless is the managed default for the cache domain)
