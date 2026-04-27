# ADR-0034: Build budget revised — 22 hours → 24 hours (L4 expansion)

## Status
Accepted (2026-04-26) — supersedes ADR-0028

## Context

ADR-0028 hard-capped the build at **22 hours**, absorbing the original 15-hour cap's buffer to accommodate HTTPS at the internal ALB (ADR-0027), the Phase 2.5 cloud-acceptance window, async L1-L3 implementation, and a DynamoDB-based distributed cache. That decision was made before the Q&A session (2026-04-26) that closed the cache backend choice.

The Q&A session (§ C in `strategy.md`) closed on `Q8 — Cache backend` with the following selection:

> **ElastiCache Serverless Valkey** + ZSET schema + Lua range-coalescing inline. ADR-0031 records the full decision.

This replaces the ADR-0028 budget line of "DynamoDB-based distributed cache (~2h)" with a materially different scope:

| Component | ADR-0028 estimate | Actual scope after Q8 |
|---|---|---|
| Cache abstraction (`cache.py`) | ~1h | ~1h (unchanged) |
| Cache backend Terraform | ~0.5h | ~0.5h (ElastiCache Serverless resource; comparable to DynamoDB) |
| Range-coalescing (ZSET + Lua) | not in scope | ~1.5h (ZSET key design, Lua merge script, overlap query, BVA tests for merge logic) |
| Bootstrap pattern | not in scope | ~0.5h (one-shot ECS task + Terraform null_resource) |
| **Cache subtotal** | **~2h** | **~3.5h** |
| **Delta** | — | **+1.5h** |

The range-coalescing capability (L4 in the capability layers) requires:
1. **Redis-class sorted data structures (ZSET)** — not available in DynamoDB without substantial client-side simulation. The ZRANGEBYSCORE-over-score overlap query is native to ZSET; replicating it in DynamoDB requires a GSI with scan semantics.
2. **Lua atomicity** — the merge-or-put operation (read overlapping entries, merge, delete originals, write coalesced) must be atomic to prevent concurrent writers from producing duplicates. Redis/Valkey Lua scripts run single-threaded inside the server; equivalent DynamoDB conditional write chaining is substantially more complex.

The demonstrated value of L4 range-coalescing: a burst of requests covering overlapping ranges (common in the "bursty internal-tools" load profile — operators run queries over the same region repeatedly with slight boundary variations) converges to a single superset entry rather than N separate entries. This reduces both cache storage footprint and subsequent lookup cost.

The original ADR-0028 budget absorbed the available buffer. An honest accounting of the L4 scope expansion requires either a further revision or an explicit cut. The scope is bounded and justified; no cut is warranted.

## Decision

The build budget is revised to **24 hours**, with the delta allocated to the range-coalescing expansion:

| Allocation | Hours | Driver |
|---|---|---|
| ADR-0028 named work (all retained) | ~22h | HTTPS + Phase 2.5 cloud-acceptance + async L1-L3 + original cache budget |
| L4 range-coalescing overage | +2h | ZSET key design + Lua merge script + bootstrap task + BVA test coverage for overlap matrix |
| **Hard ceiling** | **24h** | New cap. No buffer. |

The 24h figure is the result of an explicit allocation table, not a comfortable round number. The same discipline ADR-0028 imposed on 22h applies here: crossing 24h requires either another superseding ADR or an explicit cut.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **Implement DynamoDB exact-match cache (stay at 22h)** | DynamoDB exact-match cache at ~2h is within the existing budget. But it eliminates range-coalescing — every distinct `(start, end)` pair is a separate cache entry. For the bursty internal-tools load profile, this gives a materially lower cache-hit rate than the ZSET overlap lookup. The deliverable would demonstrate a distributed cache without the L4 architectural narrative. |
| **Defer range-coalescing to L5** | Range-coalescing is the design differentiator for a prime-range cache. Without it, the cache is a key-value lookup — nothing architecturally interesting over an application-level Redis `SET`. Moving it to L5 degrades the design doc and ADR narrative. The +2h investment is justified by the quality of the architectural story. |
| **Raise to 26h or 28h** | Not justified by the scope delta. The +2h accounts for all identified L4 work. Larger buffer invites scope creep. 24h is a hard ceiling for the reasons stated above. |

## Consequences

- **No buffer.** ADR-0028 already consumed the original buffer. The 24h revision absorbs the L4 overage with zero remaining slack. Any further unforeseen issues eat directly into delivery quality.
- **Future scope additions trigger another supersession.** The same discipline applies: a new "just one more thing" requires an ADR superseding this one or an equivalent cut. Silent drift is blocked.
- **Cover-note framing.** The cover note (gitignored) references 24h. The reader receives the revised number, not the obsolete 22h.
- **Reader consistency.** All forward-facing budget references (`docs/design_doc.md` § Scope and calibration, README budget mentions) update to 24h. ADR-0028's and ADR-0002's bodies preserve their original decisions as historical records; their Status fields point forward. (Note: 04/27 layer-review moved the cycle-internal 24h-budget rule from CLAUDE.md to memory `feedback_cycle_internal_disciplines.md` since the build-budget concept binds the original case-study cycle, not a forker.)

## Related ADRs
- ADR-0028 (the 22h cap this ADR supersedes; body preserved as historical record)
- ADR-0002 (the original 15h cap; body preserved)
- ADR-0031 (Valkey + ZSET + Lua range-coalescing — the scope expansion that drives this revision)
- ADR-0003 (PoC scope, prod hygiene — calibration that the 24h budget continues to enforce)
- ADR-0029 (async POST + SQS + worker pool — the L1-L3 work whose budget is inherited from ADR-0028)
