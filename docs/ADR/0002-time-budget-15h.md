# ADR-0002: Hard-cap the build at 15 hours

## Status
Superseded by ADR-0028 (2026-04-25) — budget revised from 15h to 22h to accommodate HTTPS at the internal ALB (ADR-0027), the Phase 2.3 cloud-acceptance window (ADR-0015 supersession block), async L1-L3 implementation, and distributed cache implementation. The body below preserves the original 15h calibration record; ADR-0028 carries the revised budget and reasoning.

## Context
The case-study brief offers a one-week soft deadline with explicit extension permission ("Feel free to inform the HR team if more time is needed"). The brief itself does not push back on scope. Without a self-imposed hour ceiling, scope creep becomes the dominant risk: every "just one more endpoint", "just add Prometheus", "just include K8s manifests" silently consumes budget against quality elsewhere.

The deliverable also has to read as deliberate engineering, not as a maximalist sprint. A 30-hour build with K8s, observability, CI/CD, and a real `terraform apply` would out-run the brief's "small application" framing and read as overengineered. An 8-hour minimal build would force cutting the smoke-test diagrams, the design doc, or one of {Terraform, runbook}, weakening the senior-level signal the deliverable is meant to convey.

The hour figure must therefore be both visible and load-bearing: visible so the recipient sees calibration, load-bearing so each subsequent ADR can defer to it as the cost frame.

## Decision
Hard-cap the build at **15 hours**. Communicate the budget to the recipient in the cover-note opening sentence. Record every cut as an ADR rather than silently omit.

Cuts taken (saving ~5–7h vs maximalist version):

| Cut | Approx. saved | Recorded in |
|---|---|---|
| No real `terraform apply` | ~2–2.5h | ADR-0015 |
| No K8s manifests | ~1–1.5h | ADR-0015 |
| Community Terraform modules over hand-rolled | ~30 min | ADR-0016 |
| In-container WireGuard verification only — no macOS-native client | ~1–1.5h | ADR-0006 |
| Migration runbook = spec, not Terraform code | ~1–2h | ADR-0012 |
| Consolidated reliability sections (HA + SLO + RTO/RPO + DB topology folded into two design-doc sections) | ~45 min | — |

Net build estimate: **~11–12.5h**. Buffer: **~2.5–4h** reserved for implicit costs (Terraform provider download, debugging, screenshot reruns) and unforeseen issues.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| No explicit budget | Leads to silent scope creep; every addition gets justified individually with no global ceiling. |
| 1-week soft target without an hour figure | Fails to drive cuts. The brief itself offers extension, so the constraint must come from us, not from the deadline. |
| 8-hour minimal budget | Would force cutting smoke-test diagrams, the design doc, or one of {Terraform, runbook}, weakening the senior-level signal. |
| 30-hour maximalist budget | Out-runs the brief's "small application" framing; reads as overengineered; risks signalling poor calibration. |

## Consequences
- The buffer is risk insurance, **not** free-add allowance. New scope requires an explicit ADR (or supersedes this one).
- Communicating the budget upfront converts scope choices into a senior signal rather than an apology — the recipient reads "this person manages scope" instead of "this person ran out of time".
- Each cut is traceable to a numbered ADR, so the recipient can audit the reasoning for any specific omission.
- Future reusers inherit a calibrated cost expectation: the next cycle quotes 15h to the next buyer, not "however long it takes".
- If the build over-runs, the over-run is itself a signal — either the calibration was wrong (record it) or scope crept in unannounced (caught by the ADR discipline).

## Related ADRs
- ADR-0003 (production-shape, PoC-scale calibration that this budget enforces)
- ADR-0015 (no K8s, no real `terraform apply` — two of the largest cuts)
