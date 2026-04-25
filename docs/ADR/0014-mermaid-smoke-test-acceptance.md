# ADR-0014: Mermaid + smoke-test sequence as Initial Acceptance

## Status
Accepted (2026-04-25)

## Context
The brief encourages "visual aids such as diagrams, screenshots, comments, or any other means" — encouraged, not mandatory. Two diagrams have the highest leverage in this deliverable:

- An **architecture diagram** answers "what does the system look like" — Docker Compose layout, VPN flow, network isolation.
- A **smoke-test sequence** answers "how do I verify it works" — the operator → test-client → WG gateway → API → DB happy path, plus the negative test.

More diagrams introduces maintenance burden and splits reviewer attention; fewer diagrams forces the architecture to be conveyed purely in prose, which fails the visual-aid hint in the brief.

Mermaid is version-controllable text, renders natively in GitHub without external tooling, and lives next to the code it describes — a perfect fit for a code-first deliverable. draw.io / Figma / images carry the opposite trade-offs: prettier output, worse maintenance, off-platform dependencies.

The deliverable's reviewer audience comes from a regulated / aerospace-adjacent culture where every release ships with an acceptance-test artefact (Site Acceptance Test — SAT). Naming the smoke test "Initial Acceptance" borrows that vocabulary deliberately — it signals industry-fit before the reviewer has read a single line of code.

## Decision
Ship exactly two Mermaid diagrams:

1. An **architecture flowchart** (`graph TB` / `flowchart LR`) in `docs/deployment_guide.md` showing the Docker Compose layout, the VPN gateway, and the network-isolation boundary.
2. A **smoke-test sequence** (`sequenceDiagram`) in `README.md` showing the operator → test-client → WG gateway → API → DB happy path, ending with a **negative test** (bypass VPN → connection refused) that proves the security boundary, not just the happy path.

The smoke test is named **"Initial Acceptance"** in the README — vocabulary borrowed from aerospace ground-systems acceptance-test culture. Reviewer pastes 5 commands; system passes or fails in two minutes.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| draw.io / Figma / image diagrams | Not version-controllable as text; requires external tools; not native to GitHub render; pretty but unmaintainable. |
| No diagrams (prose only) | Brief encourages visual aids; the network-isolation architecture is hard to convey purely in prose without ambiguity. |
| Many diagrams (per-component, per-flow, per-endpoint) | Scope creep; reviewer attention dilution; maintenance burden grows with diagram count. Two diagrams earns their place; a third would not. |
| Smoke test as plain text only (no sequence diagram) | The sequence diagram is what makes the verification self-explanatory at a glance — text alone forces the reviewer to mentally reconstruct the call graph. |
| Happy-path-only sequence (no negative test) | Proving the system works isn't proving the security boundary. The negative test is the brief's actual ask — VPN-only access. |

## Consequences
- Self-verifying artifact: reviewer doesn't need the candidate's help to confirm the system works (reinforces ADR-0013).
- The "Initial Acceptance" framing signals industry vocabulary alignment with the buyer's domain (aerospace acceptance-test culture) before the reviewer reads any code.
- Two diagrams stays focused, not noisy; each one earns its place.
- Mermaid rendering on GitHub means the README is self-displaying — no download, no external viewer, no rotting links.
- Negative-test inclusion verifies the security boundary, which is the brief's actual ask. This level of test design is often missing from junior submissions and is a senior-tier signal.
- Trade-off accepted: text-based Mermaid diagrams are visually plainer than draw.io output. The compensating gain is that they ship inside the repo and stay in sync with the code.

## Related ADRs
- ADR-0013 (deliverable is an artifact, not a demo session — the smoke test is the verification artifact this ADR specifies)
