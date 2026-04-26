# ADR-0028: Time budget revised — 15 hours → 22 hours

## Status
Superseded by ADR-0034 (2026-04-26) — supersedes ADR-0002. The 22h cap is further revised to 24h to accommodate L4 range-coalescing expansion (ElastiCache Serverless Valkey + ZSET + Lua atomicity, +2h).

## Context

ADR-0002 hard-capped the build at **15 hours** under a "small application + production-shape hygiene" calibration (ADR-0003). That calibration held through Phase 1 (service foundation, container + VPN demo, Terraform code, design doc, deployment guide, smoke test) and through Phase 2.1/2.2 (cross-cloud and scaling runbooks).

Three subsequent decisions widened the deliverable surface beyond what the 15h cap could honestly accommodate:

1. **Phase 2.3 cloud-acceptance window** — the supersession block on ADR-0015 introduced a real `terraform apply` against a personal AWS account inside a ≤ 3-hour window, with end-to-end VPN-from-laptop verification and evidence captured into `docs/deployment_guide.md`. This converts the deliverable from "plan-only Terraform + runbook" into "plan-only Terraform + one bounded real-run receipt + runbook" — adds ~3h of operational work to the build.
2. **HTTPS at the internal ALB** (ADR-0027) — TLS termination on the internal ALB via a self-signed ACM-imported cert, replacing the original HTTP-only listener. Adds ~30min of Terraform changes + cert plumbing + ADR work.
3. **Async L1-L3 implementation** — moving the prime-computation path from sync POST + drop to async POST + SQS queue + worker pool, with worker auto-scaling on queue depth (L2) and admission-control backpressure returning 503 + Retry-After (L3). Plus ElasticMQ for SQS-protocol parity in the local Docker Compose stack so the smoke test still runs self-contained. Estimated at ~6h of code + tests + docs + ADRs.
4. **Distributed cache implementation** — moving the prime cache from in-process memory to a shared store (DynamoDB on-demand with TTL, with DynamoDB Local for parity in the Docker Compose stack), so multiple Fargate worker tasks share cache hits across the cluster. Estimated at ~2h of code + tests + ADR.

Rather than burn through the 15h cap silently, this ADR makes the budget revision explicit and traceable.

## Decision

The build budget is revised to **22 hours**, allocated as:

| Allocation | Hours | Driver |
|---|---|---|
| Original Phase 1 + Phase 2.1/2.2 work | ~13h | Service / container / VPN / Terraform / design doc / migration runbook / scaling runbook (per ADR-0002 ledger; net ~11-12.5h estimate held) |
| HTTPS at internal ALB | ~0.5h | ADR-0027 cert + listener + SG ingress + outputs + ADR text |
| Phase 2.3 cloud-acceptance operational work | ~3h | Bootstrap state backend + cert provisioning → first apply → connect → curl × 3 → evidence capture → teardown |
| Async L1-L3 implementation | ~6h | queue / worker / DB schema migration / async POST + GET / backpressure middleware / docker-compose growth / smoke update / autoscaling Terraform / ADRs |
| Distributed cache implementation | ~2h | DynamoDB cache abstraction + TTL eviction + ECS task IAM + DynamoDB Local in compose + ADR |
| **Net build estimate** | **~24.5h** | _exceeds the 22h cap by 2.5h_ |
| Buffer absorbed from the original 15h cap's allowance | (~2.5h) | The 22h cap absorbs the original 2.5-4h buffer rather than adding to it |
| **Hard ceiling** | **22h** | New cap |

The 22h is a **hard ceiling**, not a soft target. Crossing it requires either a further superseding ADR or an explicit cut from the existing scope — same discipline as ADR-0002 imposed on 15h.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **Keep 15h cap, cut Phase 2.3 / async / cache scope** | Would force dropping the prod-shape architectural narrative just as it gets concrete. The case-study scope already absorbed the brief's "small application" framing; further cuts would make the deliverable read as scaffolding without proof, exactly the opposite of the senior-signal intent. |
| **Raise to a softer cap (25h, 30h)** | Soft caps drift. The 22h figure is the result of an explicit allocation table, not a comfortable round number. Pads built into the original ADR-0002 ledger's buffer absorb honest estimation noise; bigger caps invite scope creep. |
| **Move HTTPS / async / cache out of case-study scope** | They would land as future-feature deferred sections only (similar to ADR-0003's named-but-deferred CI/CD / observability list). That's a defensible call, but the buyer-review-surface gain from "we built it, it runs, here's the smoke + evidence" is substantial and the 7h delta from the original 15h cap is bounded. The trade is "extra time for substantially stronger artifact" — an explicit decision rather than silent drift. |
| **Track only the new scope as a separate "Phase 2.5+ extension budget"** | Bookkeeping fragmentation makes the total invisible. Subsequent agents reading the ADRs would see two caps and have to compose them; the supersession pattern is cleaner for a single load-bearing constraint. |

## Consequences

- **The buffer is gone.** ADR-0002 had a ~2.5-4h buffer for unforeseen issues; the revised 22h budget absorbs that buffer into the named work above. Any further unforeseen costs (debugging, AWS quirks during Phase 2.3, ElasticMQ edge cases, DynamoDB Local API divergence) eat directly into delivery — there is no slack remaining.
- **Future scope additions trigger another supersession.** The same discipline ADR-0002 imposed on 15h applies here: a new "just one more thing" requires either an ADR superseding this one, or an equivalent cut. Silent drift is blocked.
- **Cuts ledger inheritance.** ADR-0002's cuts ledger (no real apply outside Phase 2.3, no K8s, community modules over hand-rolled, in-container WireGuard verification, runbook over parallel Terraform) all remain in force — those cuts are still active under the revised cap. ADR-0028 does not unlock K8s or hand-rolled modules; it unlocks the four specifically-named extensions in the Decision section above.
- **Cover-note framing updates.** The cover note (gitignored) communicates the 22h cap to the recipient — the original 15h pitch needs revision so the recipient reads the revised number, not the obsolete one.
- **Reusability inheritance.** Future case-study cycles starting from this template inherit the 22h cap rather than the 15h one. If a new buyer's brief is materially smaller (e.g., no async demand, no cloud-acceptance ask), the next cycle's strategy.md should re-evaluate; the cap is a current-cycle calibration, not a portable constant.
- **Reader consistency.** All forward-facing budget references (CLAUDE.md § 4, design_doc.md § Scope and calibration, README budget mentions, ADR cross-references in 0003 / 0005 / 0007 / 0012 / 0015) update to 22h. ADR-0002's body preserves the original 15h decision as historical record; its Status field points here.

## Related ADRs
- ADR-0002 (the original 15h cap that this ADR supersedes; body preserved as historical record)
- ADR-0003 (production-shape, PoC-scale calibration that the 22h budget continues to enforce)
- ADR-0015 (no K8s, no real `terraform apply` — Phase 1 stance and the supersession block that introduced the Phase 2.3 cloud-acceptance window)
- ADR-0027 (internal ALB HTTPS — one of the four scope additions in the Decision allocation table)
- ADR-0023 / 0024 / 0025 / 0026 (Phase-2 unblocks — auto-scaling / VPN cert provisioning / state backend / PR-time plan via OIDC; together these constitute the operational substrate the Phase 2.3 cloud-acceptance window uses)
