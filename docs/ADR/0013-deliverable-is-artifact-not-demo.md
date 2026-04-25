# ADR-0013: Deliverable is an artifact, not a demo session

## Status
Accepted (2026-04-25)

## Context
The case-study brief lists deliverables as: application source code, containerization and orchestration scripts, cloud deployment guidelines + description + scripts, and deployment screenshots **(if any)**. The "(if any)" qualifier on screenshots is explicit — visual evidence is optional, not required. The brief never asks for a demo, walkthrough, video, or live presentation.

The default mental model many candidates adopt is: "show me you built it" — record a video, narrate the architecture, drive the reviewer through a screen-share. That model treats the deliverable as a presentation the candidate performs.

The model this repo adopts is the inverse: the deliverable is something the reviewer brings up themselves and verifies, on their schedule, without the candidate present. The artifact proves itself.

This framing inverts a common case-study anti-pattern. It also matches the buyer's industry vocabulary — regulated systems and aerospace ground-segment work has acceptance-test culture, not pitch-deck culture. A reviewer in that culture trusts a paste-and-run smoke test more than a polished demo recording.

## Decision
The submission is a self-contained artifact — code + scripts + documentation + smoke test — verifiable by the reviewer independently. No video walkthrough, no recorded demo, no screenshots required. The verification path is the smoke test in `README.md` (see ADR-0014): five paste-and-run commands, two minutes, pass/fail visible. The cover note carries a one-line framing: "the submission is an artifact, not a demo session." If the buyer later wants a conversation about it, that conversation is downstream of acceptance, not a precondition for it.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Record a demo video walkthrough | ~1-2h cost for a deliverable not asked for; introduces presentation polish where the brief asks for engineering polish; reviewer-time-asymmetric (they have to watch when the candidate could have written a smoke test instead). |
| Take screenshots of running system | Brief explicitly marks screenshots "(if any)"; live screenshots leak account IDs / IPs / ARNs; gitignored anyway; lower signal than a working smoke test. |
| Provide markdown-only (nothing runnable) | Brief requires "containerization and orchestration scripts" + the system must run as two independent services; markdown alone fails the brief. |
| Include a Loom link in the README | Adds external dependency, breaks if the link rots, splits reviewer attention between the repo and a hosted video. |

## Consequences
- The smoke test (ADR-0014) becomes the reviewer-verification artifact — five paste-and-run commands, two minutes, pass/fail visible without the candidate's involvement.
- Reviewer-time minimised: no scheduling, no video to watch, no live session to coordinate.
- The cover-note manifesto explicitly frames the submission as an artifact. The reviewer reads the framing once and the rest of the experience reinforces it.
- Aligns with the buyer's industry vocabulary (acceptance-test culture in regulated / aerospace systems). The smoke test is named "Initial Acceptance" deliberately — see ADR-0014.
- Trade-off accepted: a candidate who pitches well loses one channel for performing. The compensating gain is that the artifact-first delivery selects for buyers who reward engineering substance over presentation polish.

## Related ADRs
- ADR-0014 (Mermaid + smoke-test sequence as Initial Acceptance — the verification artifact)
