# ADR-0003: Production-shape architecture at PoC scale

## Status
Accepted (2026-04-25)

## Context
The brief sends mixed signals. On one side: "small application", "encouraged but not mandatory cloud apply" — PoC-scale framing. On the other: "best practices", "long-term, maintained by several developers" — production-hygiene framing. The deliverable has to satisfy both without picking one and ignoring the other.

The brief's *absences* are equally informative: no CI/CD requirement, no observability stack, no DR drill, no multi-environment promotion, no performance benchmark. Read together, these absences suggest the operations layer is intentionally out of scope — the recipient is evaluating engineering hygiene, not platform completeness.

Without an explicit calibration, every subsequent ADR has to re-derive the boundary between "in" and "out". A single load-bearing decision up front lets later ADRs (no K8s, single-AZ, no Prometheus, in-container verification only) cite this one and stop re-arguing the line.

## Decision
Calibrate the deliverable as **production-grade engineering hygiene at PoC feature surface**. State this calibration explicitly in the design doc top section and in the cover-note manifesto.

| Layer | Stance |
|---|---|
| **Full production grade** | Type hints, critical-path tests, `ruff` lint, `mypy`, multi-stage Docker, non-root container user, healthcheck, structured logging, pinned dependencies, README |
| **PoC scale** | Three endpoints, one DB table, one VPN tunnel, single-AZ in cloud Terraform code, single region |
| **Intentionally absent** (named so the reviewer reads deferral, not forgotten layers) | CI/CD pipelines, observability stack (Prometheus / Grafana), distributed tracing, load testing, DR drills, multi-environment promotion |

The "intentionally absent" list is part of the cover-note manifesto, not a hidden gap. Naming what is *not* shipped is itself a senior signal — it tells the reviewer the omissions are deliberate and the candidate knows what production-grade looks like end-to-end.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Full PoC, no hygiene | Skips the brief's "long-term, multiple developers" signal; reads as careless; loses the engineering-discipline read. |
| Full production grade | Blows past "small application" calibration; reads as overengineered; risks signalling poor calibration. |
| Pure feature-fest with no hygiene | Anti-pattern in 2026 engineering culture; no senior reviewer would accept untyped, untested code as a deliverable. |
| Hybrid with arbitrary cuts | Without explicit framing, every cut looks like an oversight rather than a choice. Needs a stated calibration — hence this ADR. |

## Consequences
- Drives most subsequent ADRs (no K8s, no multi-region, no CI/CD, no observability stack) — they cite this calibration instead of re-arguing scope each time.
- The calibration is stated explicitly in the cover-note manifesto and design doc, so the reviewer reads deliberate choice rather than perceived gap.
- The "intentionally absent" list is a senior signal: the candidate knows the full production stack and is choosing what fits the brief's scope, not stopping where their knowledge ends.
- Any later request to add CI/CD, Prometheus, or "production hardening" must supersede this ADR explicitly — silent upgrades are blocked by `CLAUDE.md` § 4 (Calibration: production-shape, PoC-scale).

## Related ADRs
- ADR-0015 (container orchestration shape — direct consequence of this calibration)
- ADR-0034 (delivery methodology — the *how* sister to this ADR's *what*)
