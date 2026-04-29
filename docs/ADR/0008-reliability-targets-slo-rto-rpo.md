# ADR-0008: Reliability targets — workload-tier-driven SLO / RTO / RPO

## Status
Accepted (2026-04-28)

## Context

Reliability targets are derived from **workload classification**, not chosen as round numbers. Conflating SLA (external contract) / SLO (internal target) / SLI (measurement) / OLA (between-team) is the standard vocabulary error; each term answers a different question. This ADR proposes SLO + SLI + RTO + RPO; SLA and OLA are explicitly out of scope (no contractual surface, no defined team structure to bind).

### Workload-tier framework

Production workloads stratify into four tiers, each with its own industry-acceptable RTO/RPO envelope. The framework determines the calibration ceiling — picking tighter than ceiling is a quality-of-engineering choice; picking looser is sub-tier.

| Tier | Workload type | Industry RTO | Industry RPO | Examples |
|---|---|---|---|---|
| 0 | Mission-critical real-time control | < 1 s | 0 | Launch ops, TT&C, payment authorisation, real-time bidding |
| 1 | Customer-facing production | 5–15 min | < 1 min | Public APIs, e-commerce checkout, B2B SaaS |
| 2 | Operations support (planning, audit, post-flight) | 1–4 h | 5 min – 1 h | Batch dashboards, audit logs, internal tooling, async compute |
| 3 | Analytics / back-office | 24+ h | hours | Reporting, ML training pipelines, archival |

Tier 0 typically does not run on generic public cloud (latency + control-plane shared with other tenants). Tier 1 is the typical "production web service" calibration most reliability literature implicitly targets. Tier 2 and Tier 3 are operationally lower-stakes and use looser envelopes — over-tightening them wastes engineering capacity that has higher-leverage targets elsewhere.

### Workload classification — aegis-enclave

aegis-enclave is a **Tier 2 ops support** workload:

- **Async compute, polling clients.** No real-time user-facing connection blocked on latency. Service contract explicitly states "NOT designed for sub-100 ms user-facing SLA" (per design_doc § 4.0 Service Specification).
- **Audit-log shape.** Status state machine (`queued → running → done | failed`); insert-mostly write pattern; no transactional cross-row reads. The data store is a record of what happened, not a live business state.
- **Operator-driven traffic.** Burst 50–100 RPS for ≤ 30 s, idle baseline ~1 req/min. This is "operators run a batch query at the start of a work window," not sustained customer traffic.
- **No regulated PII, no cardholder data, no financial transaction state.**

Industry-acceptable RTO for Tier 2 is 1–4 h. The targets below are **deliberately tighter than Tier 2 baseline** as a quality-of-engineering signal — not because the workload demands it.

## Decision

| Indicator | Target | Derivation |
|---|---|---|
| Availability SLI | sum(2xx) / sum(non-5xx) over 30d rolling | 99.5% — internal tooling, ~3.6 h/month error budget |
| Latency p99 — POST `/primes` | < 100 ms (HTTP enqueue only) | API tier does no compute; bounded by DB write + SQS enqueue |
| Latency p99 — GET `/primes/{id}` | < 50 ms | DB read only |
| End-to-end p99 — poll-to-done | < 6 min worst case | 5 min queue wait + 60 s compute (per ADR-0020 derivation) |
| Cache hit ratio | > 80% | 30-min rolling window; below threshold triggers alarm |
| 5xx error rate | < 0.5% | Aligned with availability budget; multi-window burn rate alarm at 1.44% (fast) and 0.6% (slow) per Google SRE Workbook (per ADR-0041) |
| **RTO — service** | **≤ 15 min** | Conservative-of-Tier-2 (industry baseline 1–4 h). Met by per-region 3-AZ posture (ADR-0007) + cross-region active-active routing (ADR-0042). DNS-only failover ~60–300 s. |
| **RTO — data corruption (PITR)** | **≤ 1 h** | DynamoDB on-demand backup + PITR continuous (per ADR-0042 data layer). |
| **RPO — durable writes** | **≤ 5 min** | Met natively by DynamoDB Global Tables ~1 s replication lag. |
| **RPO — in-flight transactions** | **< 1 s** | Synchronous local-region commit; cross-region replication async. |

**SLA, OLA — out of scope.** SLA requires a contractual surface (none between deliverable author and recipient). OLA requires a defined team structure (none yet bound).

## Alternatives Considered

Industry-context calibrations for other tiers — for forker reference, not journey-defense:

| Tier | If aegis-enclave were classified as | Calibration would shift to |
|---|---|---|
| Tier 0 | Real-time control (it is not) | Sub-second RTO; on-prem or dedicated cloud; not generic AWS Fargate |
| Tier 1 | Customer-facing prod | Tighter latency p99 (< 200 ms end-to-end); RTO 5 min; multi-region active-active becomes mandate, not signal |
| Tier 3 | Analytics back-office | RTO 24 h+; daily snapshot RPO; single-region acceptable |

Other reliability-modelling alternatives:

- **Skip SLO definition entirely.** Filler-grade. Senior reviewer reads "did not commit to numbers" and moves on.
- **Propose an SLA.** False claim — no contractual surface exists.
- **Multi-tier SLOs by mission window.** Over-engineering for current scope; could be added if traffic profile becomes mission-window-shaped.
- **Drop RTO/RPO, keep SLO only.** RTO/RPO trace directly to data-layer + topology decisions (ADR-0007, ADR-0042); dropping them leaves the topology unsupported by quantitative targets.

## Consequences

- Each row traces to a specific Terraform decision: 3-AZ posture (ADR-0007) underwrites RTO 15 min; DynamoDB Global Tables (ADR-0042) underwrites RPO ≤ 5 min and contributes the cross-region failover path.
- SLI emission via EMF + multi-window burn-rate alarms (ADR-0041) operationalise these targets — the values are not aspirational, they are alarm thresholds in the deployed CloudWatch dashboard.
- Tier 2 classification is the load-bearing context for future calibration choices. A forker promoting aegis-enclave to a Tier 1 customer-facing role should re-tighten the targets *and* revisit ADR-0023 (auto-scaling baseline) and ADR-0042 (active-active vs active-passive cost trade-offs).
- Out-of-scope items (SLA, OLA, mission-window-tier SLOs) are named explicitly so the reviewer reads deliberate scope, not oversight.

## Related ADRs
- ADR-0007 (per-region 3-AZ posture — the in-region compute resilience underwriting RTO 15 min)
- ADR-0020 (compute load management — the per-task budget + queue wait derivation feeding the end-to-end p99)
- ADR-0023 (worker auto-scaling — baseline derived from Tier 2 burst absorbance)
- ADR-0041 (observability backend — SLI emission + multi-window burn-rate alarms operationalising the values above)
- ADR-0042 (data store — DynamoDB Global Tables active-active underwrites the RPO ≤ 5 min target)
