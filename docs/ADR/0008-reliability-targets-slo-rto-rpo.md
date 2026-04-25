# ADR-0008: Reliability targets — SLO/RTO/RPO defined; SLA/OLA out of scope

## Status
Accepted (2026-04-25)

## Context
The brief makes no quantitative reliability requirement. The role JD only mentions "maximize availability" qualitatively. A senior deliverable proposes explicit numbers anyway, because numbers force trade-off conversations — qualitative reliability claims read as either filler or evasion.

Four terms are commonly conflated in industry vocabulary, and precise distinction is itself a senior signal:

- **SLA** — external contract with penalties. None in scope here; no contractual surface between the candidate and the buyer.
- **SLO** — internal target the team commits to. Proposable.
- **SLI** — measurement method (the indicator behind the SLO). Proposable alongside.
- **OLA** — between-team agreement (e.g., platform team ↔ application team). Needs a defined team structure that the case study doesn't yet have.

The deliverable should propose SLO + SLI + RTO + RPO and explicitly mark SLA and OLA as out of scope. Each number must be traceable to a specific Terraform decision elsewhere in the deliverable — the table's value is the trace, not the digits.

A complication worth noting but not folding into the public table: the production-grade RPO mechanism for spacecraft telemetry actually lives at the edge (ground-station buffering), not in the cloud database. That framing belongs in the gitignored `<buyer>_steps.md`, not in the committed reliability section, because it depends on buyer-specific operational facts.

## Decision
Propose explicit SLO, RTO, and RPO targets for the case-study scope. Do **not** propose SLA (no external contractual surface) or OLA (no defined team structure to bind).

| Indicator | Target | Rationale |
|---|---|---|
| Availability SLI | sum(2xx) / sum(non-5xx) over 30d rolling | 99.5 % — internal tooling, ~3.6h/month error budget |
| Latency p99 (`/primes` endpoint, range ≤ 10⁶) | < 500 ms | Bounded by computation; not real-time |
| Error rate | < 0.5 % | Aligned with availability budget |
| Database write success | INSERT to `executions` table | 99.9 % — loss = audit gap |
| RTO — service | ≤ 15 min | Multi-AZ ECS / RDS auto-failover ~2–5 min + manual buffer |
| RTO — data corruption (PITR) | ≤ 1 hour | RDS PITR restore takes ~30–60 min |
| RPO — DB writes | ≤ 5 min | RDS automated backup + transaction log |
| RPO — in-flight transactions | < 1 min | Synchronous commit to multi-AZ replica |

The design doc's Reliability section presents this table with each row's trace back to the Terraform decision that supports it (multi-AZ → RTO 15min via auto-failover, RDS automated backups → RPO 5min, etc.).

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Skip the reliability section entirely | Reads as lack of SRE thinking. The cost of writing the table is ~15–20 min; the signal is disproportionate. |
| Propose an SLA (e.g., 99.9 % uptime contract) | False claim — no contractual surface exists between candidate and buyer. SLA is a vendor-customer construct, not a design artifact. |
| Multi-tier SLOs by mission window (tighter during orbital passes, looser otherwise) | Over-engineering for case-study scope. Lives in the design doc as a "production reality" framing footnote, not as a committed SLO table. |
| Qualitative reliability prose only ("we aim for high availability") | Filler. A senior reviewer reads "didn't want to commit to numbers" and moves on. |
| Drop RTO/RPO and keep SLO only | RTO/RPO trace directly back to the multi-AZ topology (ADR-0007, ADR-0009). Dropping them would leave the topology choice unsupported by quantitative targets. |

## Consequences
- The reliability section signals SRE thinking at minimal time cost. The table itself reads in 30 seconds; the rationale column does the heavy lifting.
- Each RTO/RPO target traces back to a specific Terraform decision. Multi-AZ RDS standby → 15min RTO via auto-failover. RDS automated backup window → 5min RPO. The trace is the value, not the digits.
- Out-of-scope items (region-level DR, mission-window-tier SLOs, OLA contracts) are named explicitly so the reviewer sees deliberate deferral rather than oversight.
- The "edge buffering at the ground station" framing — that the production-grade RPO mechanism for telemetry actually lives at the edge, not in the cloud — is preserved in the gitignored `<buyer>_steps.md` as a production-reality footnote. Committed files stay buyer-agnostic.
- If the buyer requests an SLA proposal during a follow-up conversation, the SLO table becomes the input to that conversation — the numbers are already defended.

## Related ADRs
- ADR-0007 (single-region multi-AZ — the topology underpinning RTO 15min and RPO 5min)
- ADR-0009 (DB topology — Multi-AZ standby specifics for write-success and in-flight transaction RPO)
