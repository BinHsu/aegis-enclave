# ADR-0049: Cross-region result availability via recompute-on-miss (supersedes the CRR decision of ADR-0048)

## Status
Accepted (2026-05-30). **Supersedes the cross-region replication decision of ADR-0048** (bidirectional S3 Cross-Region Replication). ADR-0048's *size* decision — large result lists live in a per-region S3 bucket, not in the DynamoDB item, with only an `s3_key` pointer in the row — **remains in force**. Implementation deferred (scoped with the ADR-0048 result-store work / issue #14); the current bidirectional-CRR terraform keeps working until the recompute path lands.

## Context

ADR-0048 bundled two independent gaps under one decision:

1. **Size gap** — a result list above DynamoDB's 400 KB item limit (π(10⁷) = 664,579 primes ≈ 6 MB, ~15× over the cap) cannot live in the audit row. Solved by storing the list in S3 and keeping only an `s3_key` pointer in DynamoDB.
2. **Cross-region gap** — a client may POST in one region and poll in another (Route53 weighted active-active; DNS re-resolution mid-poll; region-death failover). The result must be readable in the polling region. Solved by **bidirectional S3 CRR** so each region serves from its local replica.

The size decision is sound and stays. The cross-region decision — bidirectional CRR — is the one this ADR reverses. Two forces made CRR the wrong tool.

**1. The `envs/` split (ADR-0046, issue #12) makes bidirectional CRR structurally expensive.** Splitting the single root state into per-region states removes the single-DAG ordering that makes the two `aws_s3_bucket_replication_configuration` resources "just work" today. Bidirectional CRR then forces:
- a **2-phase cold-start** — the S3 API requires the destination bucket to pre-exist and be versioned before `PutBucketReplication` ("Both source and destination buckets must have versioning enabled"), so a circular pre-exist appears across the two per-region states;
- a **single-config-per-bucket clobber hazard at N≥3** — `aws_s3_bucket_replication_configuration` manages a bucket's whole replication config as one resource, so two peer states cannot each own a rule on the same bucket;
- an **O(N²) mesh** outside the enable-catalog's "add a region = one line" promise.

The sibling `aegis-platform-aws` never hits this: its ECR replication is one-directional and auto-creates destination repositories (`ecr:CreateRepository`), so it has no pre-exist ordering. S3 has neither property — different service semantics, not a design defect on our side.

**2. The result is a cheap, deterministic recompute, and the client is meant to be dumb.** A prime range is a pure function of `(start, end)`; regenerating it is the same bounded compute (≤ 60 s SIGALRM budget, ADR-0033) as the original job. The founding API contract is a *brainless client*: POST, poll, retry on 503 — no region awareness. CRR honours the dumb client but pays the replication-infra cost above. Region affinity (pin the client to its write region) would remove the infra but pushes region-awareness onto the client, breaking the dumb-client contract.

The reframe that resolves it: cross-region availability does not require the *result* to be present in every region — only the *means to produce it*. The DynamoDB Global Table already replicates the metadata, including `range_start` / `range_end`. Any region can regenerate a missing result from the replicated range, on demand.

## Decision

**Replace bidirectional S3 CRR with recompute-on-cross-region-miss.** Each region's S3 bucket is independent — no replication between buckets. The DynamoDB Global Table continues to replicate metadata (status, range, `s3_key`).

GET `/primes/{id}` read path:

```
1. local S3 get_object(row.s3_key)    ← THIS region's bucket
2. on NoSuchKey while DDB says done:
     re-enqueue a compute for (range_start, range_end) on THIS region's queue;
     return 503 + Retry-After.
   The client's existing dumb retry loop polls again; by then the local
   worker has written the result to this region's S3 → served.
```

The Valkey cache (ADR-0031) is the **worker's** compute-avoidance layer — the
worker checks `get_covering_slice` before sieving and writes back on a miss —
**not** a GET read tier. The GET handler reads S3 directly by `s3_key`; the
recompute path re-runs the worker, which consults the cache as usual.

- **S3 stays — per region, local-only.** It solves the *size* gap (lists > 400 KB) and gives durability so an expensive range is computed once, not re-recomputed on every cache eviction. CRR is removed; the bucket is neither a replication source nor destination.
- **DynamoDB Global Table stays.** Metadata (status + range + `s3_key`) replicates so any region knows a job exists and what range to regenerate. It becomes the *only* cross-region resource.
- **The client is unchanged and stays dumb.** POST to the weighted endpoint, poll, retry on 503. No region pin, no re-POST logic, no held URL. The cross-region miss is invisible to it — the same 503 + `Retry-After` it already handled for the (now-removed) replication-lag case now triggers a local recompute instead.
- **Region death** is handled by the existing Route53 health failover: the GET lands on a surviving region, finds no local result, recomputes from the replicated range, and serves. The client never knew.

This dissolves issue #12's "where does the bidirectional CRR config live after the `envs/` split" sub-decision entirely — there is no cross-region S3 resource to place. The per-region bucket lives in `envs/regional` like any other regional resource.

## Alternatives Considered

| Alternative | Why not |
|---|---|
| **Bidirectional S3 CRR (ADR-0048's choice)** | Keeps the client dumb and the result physically present in every region. Reversed because under the `envs/` split it forces a 2-phase cold-start (S3 destination-must-pre-exist), a single-config-per-bucket clobber at N≥3, and an O(N²) mesh outside the enable-catalog's unbounded-N promise. Recompute-on-miss gives the same dumb-client cross-region availability with zero replication infra, because the result is cheap to regenerate from the replicated range. |
| **S3 Multi-Region Access Points (MRAP)** | A managed global endpoint with health-based routing + failover. Rejected: (a) it does **not** replace CRR — AWS docs are explicit ("having buckets connected to a Multi-Region Access Point does not affect how replication works… configure S3 Cross-Region Replication"), so the pairwise mesh would still exist underneath; (b) VPC access requires a `com.amazonaws.s3-global.accesspoint` PrivateLink interface endpoint — the free S3 Gateway Endpoint (ADR-0019) cannot reach it; (c) member buckets are fixed at creation (add a region = delete + recreate). For a region-pinned-compute topology where Route53 + "read local" already handle failover, MRAP adds cost and rigidity for no net benefit. The original ADR-0048 cost objection ("~$33/mo per MRAP") used monthly-idle framing; the real disqualifier is topology fit, not dollars. |
| **Client-side region affinity** (POST returns a region-pinned poll URL; client polls its write region) | Zeroes cross-region reads, so no CRR — but makes the **client smart** (hold a region-pinned URL, re-POST on region death), breaking the founding dumb-client contract. Recompute-on-miss achieves no-CRR while keeping the client dumb, so it strictly dominates affinity for this deliverable. (Affinity also needs per-region addressable hostnames the current Route53 set — one weighted name shared by both regions — does not provide.) |
| **Valkey-served only (drop S3 too)** | The Valkey cache (ADR-0031) can hold a 6 MB value, so DDB-metadata-only + cache-served would close the 400 KB gap with no S3, and recompute-on-miss would even rehabilitate this option's cross-region story (the reason ADR-0048 rejected it). Rejected because an expensive near-ceiling range would then recompute on **every** cache eviction (up to the full 60 s budget). S3's durability computes such a range once. S3 is kept for *size + durability*, which is orthogonal to the cross-region question. |

## Consequences

**Positive**
- **Issue #12's CRR-placement sub-decision dissolves.** No cross-region S3 resource to route under the `envs/` split; the per-region bucket is an ordinary regional resource. The N≥3 clobber / cold-start / 2-phase-flag complexity disappears with it.
- **The client stays dumb** — the founding contract is preserved. No region awareness, no SDK affinity logic, no re-POST path.
- **Fewer moving parts in steady state** — no replication IAM role, no replication metadata, no replication-lag window. The GET handler's 503 path becomes "regenerating locally" instead of "waiting for replication" — a guarantee bounded by compute, not by an SLA-less async replication.
- **Cost** — no CRR transfer charges, no MRAP, no PrivateLink interface endpoint. The private-only VPC (ADR-0019, free S3 Gateway Endpoint) is preserved intact.

**Negative / costs**
- **A cross-region poll incurs a recompute.** Rare (only DNS re-resolution mid-poll, or region-death failover), but for a near-ceiling range the recompute can consume most of the client's reference retry budget (3 × 20 s = 60 s, ADR-0048 § 5). The smoke / scaling tests should add one cross-region poll on a mid-size range to keep this honest. Acceptable for Tier-2 (RTO 1–4 h, ADR-0008).
- **Duplicate compute across regions** for the same range is possible (computed in region A, separately recomputed in region B). Wasteful but correct (deterministic), and bounded by how often cross-region polls actually happen.
- **The DynamoDB Global Table is now the sole cross-region resource** — ADR-0046's "the single-state layer owns the one cross-region resource" constraint now applies to DDB alone (cleaner: exactly one such resource, not two).
- **Implementation is deferred.** The current bidirectional-CRR terraform + worker/GET code keeps working until the recompute path is built. This ADR records the decision so the contract is honest and item-1 is closed in design. Removing the CRR terraform and adding the re-enqueue-on-miss path is the implementation follow-up (scoped with the ADR-0048 result-store work).

**Future trajectory (recorded, not adopted here)**
- **`execution_id`-encodes-range → de-globalize the DynamoDB table.** If `execution_id` carried (or derived) the range, any region could regenerate a result from the id alone — no replicated metadata needed. The `replica` blocks could then come off the table (ADR-0042), making each region's DynamoDB independent (a regional table per region rather than one synchronized Global Table — the physical table count is unchanged; only the cross-region synchronization is removed). The service would become fully share-nothing per region. This reconsiders ADR-0042's active-active data-layer decision and the deliverable's multi-region-data demonstration value (the Global Table is part of what the portfolio piece shows), and must be weighed against the brief's persistence mandate. It is **out of scope here**, would need its own ADR, and is recorded only so the dependency chain (`id`-encodes-range → de-globalize) is not lost.

## Related ADRs
- **ADR-0048** — large-result store; this ADR supersedes its *cross-region replication* decision (bidirectional CRR → recompute-on-miss); its *size* decision (list in per-region S3, `s3_key` pointer) remains in force.
- **ADR-0042** — DynamoDB Global Tables active-active; after this ADR the Global Table is the *sole* cross-region resource. The future-trajectory note above would reconsider it.
- **ADR-0046** — N-region `envs/` split; this ADR removes the bidirectional-CRR resource that issue #12's CRR-placement sub-decision was about, closing that sub-decision in design.
- **ADR-0031** — Valkey range-coalescing cache; remains the worker's single-region compute-avoidance layer (checked before sieving), not a GET read tier. The GET read path is local S3, then local recompute on a miss.
- **ADR-0019** — private-only VPC; preserved (no MRAP / PrivateLink; the free S3 Gateway Endpoint stays).
- **ADR-0033** — SIGALRM compute budget; the recompute path inherits the same 60 s bound.
- **ADR-0008** — Tier-2 reliability targets; recompute-on-rare-cross-region-miss sits within the RTO 1–4 h envelope.
