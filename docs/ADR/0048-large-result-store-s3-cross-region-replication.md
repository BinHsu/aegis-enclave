# ADR-0048: Large-result store — S3 with cross-region replication + DDB result-pointer

## Status
Accepted (2026-05-29). **Cross-region replication decision (bidirectional S3 CRR) superseded by ADR-0049** — replaced by recompute-on-cross-region-miss. The *size* decision (large result list in a per-region S3 bucket, `s3_key` pointer in the DynamoDB row) **remains in force**; the S3 bucket stays, it just stops being a replication source/destination.

> Decision adopted; implementation deferred to GitHub issue #14. Until that
> lands, the code continues to dual-write the primes list to DynamoDB
> (the latent 400 KB bug remains latent — `make smoke` ranges stay under
> the cap so it does not fire in practice). The decision is recorded now
> so the architectural contract is honest and the design space is closed.

## Context

Two coupled gaps surfaced while planning issue #14 (DDB-400KB):

### The size gap (the original #14)
`db.py mark_done` writes the full primes list directly into the
DynamoDB executions item. DynamoDB has a hard 400 KB per-item limit.
For `end = 10⁷` (π(10⁷) = 664,579 primes), the serialised list is ~6 MB
— about 15× over the cap. Any range whose result blows past 400 KB
fails `mark_done` with `ValidationException`, leaving the audit row
stuck at `running` and the client polling forever. Latent today only
because smoke uses small ranges.

### The cross-region gap (surfaced 2026-05-29 in #14 design review)
The first proposed fix was "DDB metadata-only + serve primes list from
Valkey cache" — exploit the fact that the worker already writes the list
to the range-coalescing cache (ADR-0031), so removing the DDB copy just
drops a duplicate. Sound for a single region. **But it breaks ADR-0042's
active-active contract**: DynamoDB Global Tables replicate the metadata
row across regions in seconds; **ElastiCache Serverless Valkey is regional
and has no cross-region replication**. The asymmetry produces:

```
client POST in eu-central-1 → worker computes there → primes in
  Frankfurt's Valkey + DDB row written.
DDB row replicates to eu-west-1 within seconds.
Route53 weight shifts (or DR drill); client polls in eu-west-1.
Ireland app: DDB says status=done. Reads Ireland's Valkey → MISS.
  → client sees 410 Gone for a job that succeeded.
```

In other words: ADR-0042's "active-active" is *data-layer* truth, but
the **result-layer was implicitly active-passive** (sticky to the write
region). That contract gap has never been written down. The cache-served
approach would entrench it.

### What we need from the result store
1. Per-item size ≫ 400 KB (the trigger for #14 in the first place).
2. **Cross-region replication with predictable bounded lag** — so the
   result-layer matches ADR-0042's active-active claim.
3. Bounded durability (retention should not exceed audit value) — align
   with the existing DDB TTL policy (done = 30 days, failed = 90 days).
4. Costs that fit Tier-2 ops support scope (ADR-0008).

S3 + cross-region replication is the AWS-native primitive that delivers
all four. Valkey delivers (1) but fails (2). DDB delivers (2)/(3)/(4)
but has the 400 KB cap that started #14.

## Decision

**Adopt the AWS-canonical large-item-in-DynamoDB pattern: the audit row
holds metadata + a small pointer; the bulk payload lives in S3 with
bidirectional cross-region replication; each region reads from its own
local bucket.**

### 1. DDB row carries only metadata + an `s3_key` pointer

```
PK execution_id (UUID4)
   status            queued | running | done | failed
   range_start       int
   range_end         int
   primes_count      int
   duration_ms       int
   created_at        epoch
   completed_at      epoch (set on done/failed)
   ttl_at            epoch (existing TTL policy)
   error_message     str  (failed only)
   s3_key            str  (done only) — see § 2
```

`s3_key` is a **bucket-relative key**, not a full `s3://bucket/key`
URI. Critical for cross-region read locality (see § 3).

### 2. S3 layout — one bucket per region, bidirectional CRR

| Region | Bucket | Role |
|---|---|---|
| eu-central-1 | `aegis-enclave-results-eu-central-1` | reads + writes |
| eu-west-1    | `aegis-enclave-results-eu-west-1`    | reads + writes |

- **Bidirectional CRR**: each bucket replicates to the other. AWS prevents
  replication loops via replication metadata. Both regions write locally;
  CRR mirrors. Both regions read locally.
- **Versioning required**: CRR mandates versioning on both source and
  destination.
- **Encryption**: SSE-S3 default (no KMS key management overhead at PoC
  scope; mirrors ADR-0042's posture on DynamoDB).
- **Lifecycle**: align with DDB TTL — 30-day expiration for the `done/`
  prefix, 90-day for the `failed/` prefix. Lifecycle deletes propagate
  via replication metadata so both regions stay in sync.
- **Content encoding**: gzip the payload (`Content-Encoding: gzip`).
  A 6 MB raw list compresses to ~1 MB; bounds storage + replication cost.

### 3. Bucket name derived at runtime, NOT stored in DDB

```python
# in worker.py and main.py GET handler
bucket = f"aegis-enclave-results-{os.environ['AWS_REGION']}"
s3_client.get_object(Bucket=bucket, Key=row["s3_key"])
```

Storing only the key (not the full URI) in DDB is the keystone of the
design: it lets each region read from its local replica regardless of
which region originally wrote the object. Storing a full URI like
`s3://aegis-enclave-results-eu-central-1/abc.json.gz` would defeat CRR
by pinning every read to the original write region.

### 4. Worker write path

```python
# worker.py (sketch)
primes = sieve_with_timeout(start, end)
gzipped = gzip.compress(json.dumps(primes).encode())
s3_key = f"done/{execution_id}.json.gz"
s3_client.put_object(
    Bucket=f"aegis-enclave-results-{os.environ['AWS_REGION']}",
    Key=s3_key,
    Body=gzipped,
    ContentEncoding="gzip",
)
mark_done(execution_id, s3_key=s3_key, primes_count=len(primes), duration_ms=...)
cache.merge_or_put(start, end, primes)   # ADR-0031 cache stays as hot-path optimisation
```

The Valkey cache (ADR-0031) is **not removed** — it stays as the
single-region hot-path optimisation (the typical poll-back-within-minutes
case avoids S3 entirely). S3 is the **durable cross-region fallback**.
Three tiers:

```
GET /primes/{id}:
  1. cache.get_covering_slice(start, end)    ← hot, μs, single-region
  2. if miss: s3.get_object(local bucket, row.s3_key)  ← warm, ms, cross-region OK
  3. if 404: retry-then-410                  ← replication lag handling (§ 5)
```

### 5. GET handler replication-lag handling — stateless server, client-owned retry budget

S3 standard CRR is async with no SLA; **S3 Replication Time Control
(RTC)** gives 99.99% within 15 minutes (extra cost). For Tier-2 RTO
1–4 h, standard CRR is sufficient. But there is a short window where
the DDB row has replicated to the peer region but the S3 object has
not. The GET handler must distinguish this **transient lag** from a
**genuine loss** (S3 lifecycle expired the object, e.g. 30 days after
`completed_at`).

**Design: keep the server stateless; let the client own its retry
budget.** The server does not count retries; on each call it observes
the current truth (cache → S3) and returns either the result, a 503
with a `Retry-After` hint (transient lag), or a 410 (genuine loss).
The client decides how long to keep trying.

```python
# main.py GET /primes/{id} (sketch)
row = get_execution(execution_id)
if row is None:
    raise HTTPException(404, ...)
if row["status"] != "done":
    return existing_metadata_response(row)  # queued / running / failed unchanged

bucket = f"aegis-enclave-results-{os.environ['AWS_REGION']}"
try:
    obj = s3_client.get_object(Bucket=bucket, Key=row["s3_key"])
    return ExecutionResponse(..., result=decompress(obj["Body"]))
except s3_client.exceptions.NoSuchKey:
    age_s = now_epoch() - int(row["completed_at"])
    if age_s > _LIFECYCLE_TTL_S:
        # The S3 lifecycle policy has deleted the payload; the audit row
        # outlived the result (e.g. done=30 days, client polled later).
        # Genuine, permanent loss — tell the client to re-POST.
        raise HTTPException(410, "result expired per retention policy")
    # Replication has not yet caught up. The Retry-After hint suggests
    # 20 s, but it is *advisory* per RFC 9110 — the client owns its
    # retry policy.
    raise HTTPException(
        status_code=503,
        detail="result not yet replicated to this region; retry",
        headers={"Retry-After": "20"},
    )
```

**Reference client retry policy** (recommended for SDKs and the smoke
test): **3 attempts × 20 s interval = 60 s total budget.** The 60 s
number is deliberately in the same family as the worker SIGALRM
budget (60 s, ADR-0020), the SQS visibility timeout (1.5 × 60 = 90 s,
ADR-0033), and the SLO poll-budget arithmetic (300 s SLO / 5 polls =
60 s per attempt, ADR-0008). Coherent, not arbitrary. After 60 s of
persistent 503 the client treats the request as failed and re-POSTs.
After a 410 from the server the client re-POSTs immediately (no retry).

**Why server-stateless + client-owned budget**

| Concern | Server tracks retry count | Client owns retry budget (chosen) |
|---|---|---|
| State store for "this id has been retried N times" | DDB or Redis write per GET | none |
| Two-region consistency on the counter | required (extra coordination) | not applicable |
| Different clients with different policies (aggressive vs conservative) | server-fixed for all | client-tunable per caller |
| HTTP-standard semantics for `Retry-After` | drifts toward server-enforced | matches RFC 9110 (advisory) |
| Failure attribution at debug time | shared (server counter + client trace) | single source of truth (client log) |

This split is also the *only* design that distinguishes lag from
lifecycle expiry honestly: the **age check** (`completed_at` vs
`_LIFECYCLE_TTL_S`) is the server's natural job because the server
holds the time information, and the **retry budget** is the client's
natural job because the client holds the impatience.

## Alternatives Considered

| Alternative | Why not |
|---|---|
| **Valkey-served (the cache-only fork)** | Functionally simplest — Valkey already holds the list via `cache.merge_or_put`, so the fix is "drop the DDB copy". Closes the 400 KB bug at zero new infra. **Rejected because Valkey is regional and breaks ADR-0042's active-active contract**: cross-region polls would 410 even on a successful computation. Would also entrench the unspoken result-layer-is-active-passive gap rather than close it. |
| **Single S3 bucket in `platform_region`, cross-region reads from peer** | Cheapest S3 option; no CRR; peer region pays cross-region GET latency (~50–150 ms) per request. **Rejected**: platform region failure = total result loss (defeats the whole "active-active" point). |
| **S3 Multi-Region Access Points (MRAP)** | AWS-managed global endpoint with automatic routing + failover. Functionally elegant. **Rejected for now**: MRAP has a fixed per-hour cost (~$33/month per MRAP) that does not fit the Tier-2 / 3 h apply-then-destroy cost shape. Stay as a forker promotion path; nothing in the design here blocks promoting later. |
| **DDB-stored with truncation** to first 50,000 primes | Lossy. Audit-grade integrity gone. **Rejected on principle**. |
| **Compress primes list and fit DDB 400 KB** | Even with binary delta encoding, 664,579 primes do not fit reliably under 400 KB at the worst case. Buys ~3× headroom; the trigger range only needs ~4× before we hit the cap again. **Rejected**: kicks the can. |
| **Client-side / `execution_id`-encoded region affinity to bypass the replication lag entirely** | Sticking each client to the region that handled its POST drives the cross-region poll fraction toward 0 % (per `P_cross = 2·w·(1−w)`, even 70/30 only buys ~8 pp over 50/50 — affinity is the only thing that genuinely zeros it). **Rejected**: the same stickiness defeats Route53 failover during region death. A client whose `home_region` died keeps polling the dead region and never reaches the CRR replica in the live peer, even though the result *is* there. For Tier-2 (RTO 1–4 h) the second-order failure (region death + can't reach replica) is materially worse than the first (small lag-hit on freshly-completed jobs polled cross-region). The "affinity + global-endpoint fallback" hybrid that would resolve the trade-off is more client-SDK complexity than the simple 503/410 + client-owned retry path; not worth it for PoC scope. The 503 `Retry-After: 20` + the default DNS TTL (~60 s) already provide a *weak* form of affinity (the same client typically resolves the same region within the retry window) without breaking failover. |

## Consequences

**Positive**
- **Closes the 400 KB latent bug** end-to-end.
- **Result layer becomes genuinely active-active** — both regions read
  their local S3 replica; the asymmetry implicit under ADR-0042 is
  closed honestly.
- **Audit-grade durability** — S3 lifecycle policy aligns with DDB TTL,
  so the *list* survives as long as the *record*. The Valkey-served
  alternative would have made the list lifetime = cache TTL only.
- **Bounded, observable replication lag** — instead of "never
  replicates" (Valkey), it is "seconds to minutes, with RTC option for
  ≤15 min SLA". GET handler's 503/Retry-After path is honest about it.
- **Three-tier read path is performance-coherent** — hot-cache hit stays
  μs; warm S3 read is ms; cross-region replication lag is the only
  degraded path and it has a defined behaviour.

**Negative / costs**
- **New service in the stack**: S3 client wiring + IAM + Terraform.
- **New local-emulation dependency**: `minio/minio` Docker service (S3
  parity in compose, mirrors ElasticMQ-for-SQS + dynamodb-local-for-DDB).
  Adds ~30 MB image + one more service to bring up.
- **New per-service env var**: `AWS_ENDPOINT_URL_S3` (boto3-standard,
  same family as the #9.8 consolidation). Compose, ECS task definitions,
  and test fixtures all need it.
- **Two buckets, CRR replication traffic, lifecycle policies** — every
  region addition adds N-1 replication edges; cost scales O(N²) on
  replication transfer (small absolute $ at PoC scale).
- **Bidirectional CRR is async with no SLA** at standard tier; the GET
  handler's retry-then-410 path is the explicit honesty about that.
- **Worker code path gains an S3 PutObject** before `mark_done` — small
  latency adder (~50 ms p99 with VPC Gateway Endpoint), comfortably
  within the SIGALRM 60 s budget.
- **Terraform IAM additions**: ECS task role gets `s3:PutObject` /
  `s3:GetObject` on the regional bucket; CRR replication role gets its
  own permissions. Private-only VPC stays intact via the **S3 Gateway
  Endpoint** (free, no NAT — preserves ADR-0019).

**Implementation plan (deferred — tracked in issue #14)**
1. **Terraform**: per-region `aws_s3_bucket` with versioning + SSE +
   lifecycle + Gateway Endpoint; bidirectional `aws_s3_bucket_replication_configuration`;
   replication IAM role; ECS task role additions.
2. **docker-compose**: add `minio/minio:latest` service on `internal`
   network (port 9000 HTTP + 9001 console); add `AWS_ENDPOINT_URL_S3`
   env var to app + worker; ddb-bootstrap-style profile task to create
   the local bucket on first up.
3. **`db.py mark_done`**: drop the `primes` column write; add `s3_key`
   parameter + column.
4. **`worker.py`**: gzip-encode + `s3.put_object` before `mark_done`.
5. **`main.py` GET handler**: three-tier read (cache → S3 → 503/410).
6. **`tests/`**: replace `primes-via-DDB-roundtrip` assertions with
   `primes-via-S3-pointer`; add BVA on the 400 KB boundary (mocked);
   add lag-retry tests with mocked NoSuchKey transitions.
7. **`docs/`**: update `design_doc.md` and `deployment_guide.md` to
   describe the three-tier read path + the replication-lag contract.
8. **ADR-0048 Status**: stays Accepted; this ADR governs implementation.
   No new ADR required for the implementation itself.

**Scope check (workload tier)**
aegis-enclave is Tier-2 ops support (RTO 1–4 h per ADR-0008). The
cross-region honesty this ADR delivers is *above* Tier-2 baseline — it
is a quality-of-engineering signal (matching what ADR-0042 already
implicitly promised). The cost is small (S3 storage + replication for
small primes lists). Worth doing because the alternative is a contract
gap that can hide bugs at DR-drill time.

## Related ADRs

- **ADR-0042** — DynamoDB Global Tables active-active. This ADR closes
  the result-layer asymmetry that ADR-0042's contract implicitly
  assumed away.
- **ADR-0031** — Valkey range-coalescing cache. This ADR demotes Valkey
  from "result store" to "single-region hot-path cache" (its actual role).
- **ADR-0019** — Private-only VPC, no IGW/NAT. The S3 Gateway Endpoint
  keeps S3 access inside the private VPC at zero extra cost.
- **ADR-0030** — ElasticMQ local SQS parity. Same pattern as the
  proposed `minio/minio` local S3 parity in this ADR.
- **Issue #14** — implementation tracking.
- **Issue #9 item 8** — `AWS_ENDPOINT_URL_<SERVICE>` per-service env
  consolidation; `AWS_ENDPOINT_URL_S3` is added by this ADR, completing
  the family.
