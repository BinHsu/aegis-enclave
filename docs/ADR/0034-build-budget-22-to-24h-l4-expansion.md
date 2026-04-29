# ADR-0034: Delivery methodology — PoV/scrum staging with validation gates per architectural increment

## Status
Accepted (2026-04-28)

## Context

Architectural maturation is non-linear. A "single-AZ → multi-AZ → multi-region" progression is not three increments of equal effort; each step asks different questions and validates different assumptions. Staging the work as a single monolithic plan (everything-at-once) compounds risk: an early-stage assumption that turns out wrong (e.g., relational schema fit) carries forward through every dependent decision.

The alternative — **PoV/scrum cadence with validation gates per architectural increment** — staggers commitment. Each stage validates its own feasibility and verifiability before the next stage commits. This methodology is appropriate when:

- The engineer is part-time on the project (multiple parallel commitments).
- Architectural assumptions are unverified at start (greenfield design space, ambiguous requirements).
- Cost of pivoting late on a wrong assumption is large compared to cost of pivoting early.
- Reviewer-facing artifacts must be coherent at every checkpoint, not just at end-state.

## Decision

The delivery methodology for this project is **PoV staging with validation gates**. Each architectural increment is a self-contained Stage with its own:

- Feasibility validation (does this even work in the target environment?)
- Verifiability validation (can a reviewer paste the smoke and see green?)
- Reviewer-facing artifact pass (README + ADRs + design_doc reflect the current end-state, no half-states)
- Resource allocation matched to demonstrated value at the gate

Stages observed in this delivery:

| Stage | Architectural increment | Validation gate |
|---|---|---|
| 1 | Single-AZ Compose stack + smoke test | `make smoke` 6/6 green; security boundary test passes |
| 2 | Multi-AZ cloud composition + Phase 2.5 cloud-acceptance | `make cloud-up` end-to-end + 6/6 cloud-smoke + collateral-free `make cloud-down` |
| 3 | Multi-region active-active + workload-tier reframe | `pivot/dynamodb-multi-region` branch's full doc-and-ADR rewrite reads as senior-architect day-1 design |

Each stage's resource allocation matches the value demonstrated at the prior gate. The "engineer is part-time" constraint forces staging anyway — sequential delivery against parallel commitments cannot collapse into all-at-once even if the methodology preferred it.

### Empirical reference

`evidence/subagent_timing.md` (gitignored) records active vs wall-clock-with-gates split per stage as estimation-discipline reference. The methodology is validated empirically: gates introduce wall-clock latency (~2–4× active time) but reduce rework cost by ~10× over monolithic delivery (rework on a wrong assumption discovered at end-stage = full re-do; rework discovered at gate = stage-local re-do).

## Alternatives Considered

| Alternative | Industry context |
|---|---|
| **Monolithic delivery** (full plan up front, single execution pass) | Right when assumptions are well-understood and the engineer has uninterrupted dedicated time. Wrong when either condition fails. |
| **Continuous delivery** (no stages, ship every commit) | Right for sustained-traffic production services. Doesn't apply to PoC-grade portfolio deliverable where the artifact is the unit of evaluation. |
| **Spike-and-stabilise** (rapid PoC, then production rewrite) | Useful for unknown-feasibility R&D. Doubles the wall-clock for a known-feasibility deliverable. |
| **Waterfall + design-up-front** | Industry tradition. Brittle when architectural assumptions are wrong (cost of late pivot is full restart). |

## Consequences

- The single-AZ → multi-AZ → multi-region progression is **deliberate PoV cadence, not mind change**. Each stage's ADRs read as current-state architecture; supersession history lives in git log + memory, not in portfolio-facing docs (per the "single coherent senior-architect design from day 1" principle that frames the rewrite of this branch).
- Stage transitions are not free — each gate requires validation work (smoke / cloud-up / docs pass). The methodology accepts the gate cost as the price of low-rework risk.
- Forker adopting this methodology should set their stage gates around their own decision-uncertainty, not copy this project's stage boundaries.
- Sister-pair to ADR-0003 (PoC scope, prod hygiene calibration) — both meta-ADRs about methodology vs implementation: ADR-0003 calibrates the *what*; this ADR calibrates the *how*.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene calibration — the *what* sister)
- ADR-0012 (migration runbook — agent-executable schema; runbooks themselves are PoV-cadenced when executed by agents)
- ADR-0013 (deliverable is artifact, not demo — the artifact at every stage gate is reviewer-paste-runnable)
