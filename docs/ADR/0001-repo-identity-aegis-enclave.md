# ADR-0001: Repo identity and naming — `aegis-enclave`

## Status
Accepted (2026-04-25)

## Context
The repository must serve two audiences simultaneously:

1. The current case-study cycle's recipient (a specific buyer evaluating the candidate)
2. Future portfolio reuse across subsequent case-study cycles

The repo name carries weight in both audiences:

- **Brand alignment** with the existing `aegis-*` portfolio (`aegis-aws-landing-zone`, `aegis-core`)
- **Buyer-agnostic** so the URL doesn't broadcast which company received this submission
- **Cloud / tool agnostic** so it doesn't bind to AWS or WireGuard or any specific stack
- **Concept-conveying** so the name itself signals the architecture (private network with controlled access)

A buyer-tied name (e.g., `<buyer>-case-study` or `<recipient>-deliverable`) locks the repo to one cycle and creates social-awkwardness if the cycle ends in rejection. A purely generic name (e.g., `microservice-template`) loses brand value.

## Decision
Use **`aegis-enclave`**.

- **"Enclave"** evokes a protected, isolated zone with controlled access — exactly the architecture this deliverable demonstrates (VPN-gated cloud microservice with strict access boundaries).
- The `aegis-*` prefix completes a portfolio trio:
  - `aegis-aws-landing-zone` — governance / multi-account layer
  - `aegis-core` — systems / C++20 layer
  - `aegis-enclave` — application / private-network layer
- Cloud-agnostic, vendor-agnostic, buyer-agnostic.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| `aegis-segment` | "Segment" doubles as network segment + ground segment (aerospace cultural fit). Rejected because the double meaning is lost in non-aerospace cycles, weakening reuse. |
| `aegis-sovereign` | Strongest single architectural thesis (EU sovereignty + cross-cloud portability). Rejected because the political framing risks reading as ideological rather than architectural. Senior interviewers read sovereignty arguments as buy-build judgement, not identity statement. |
| `aegis-private-stack` | Accurate but generic; weaker memorability than `aegis-enclave`. |
| `<buyer>-case-study` | Locks the repo to a single cycle; awkward post-rejection; loses portfolio compounding. |
| New top-level prefix outside `aegis-*` | Dilutes the existing brand built on two repos already pinned at `binhsu.org`. |

## Consequences

- **Reusable** across cycles by swapping the gitignored top layer (see ADR-0004).
- **Brand-consistent** for visitors arriving at the `aegis-*` family via portfolio links.
- **Minor overlap** with AWS Nitro Enclaves (confidential computing service). "Enclave" is a generic English word, and AWS Nitro Enclaves is a niche AWS product not central to typical reviewer awareness. Risk judged low; acceptable.
- The README opens with the architectural concept, not the brand, so visitors arriving without the `aegis-*` context still understand the repo immediately.

## Related ADRs
- ADR-0004 (90/10 reusability split — what makes the name buyer-agnostic operationally)
