# ADR-0004: 90/10 generic / buyer-specific reusability split

## Status
Accepted (2026-04-25)

## Context
The repo serves two audiences simultaneously: the current cycle's recipient and future portfolio reuse across subsequent case-study cycles. Each cycle has a different buyer with different framing language — domain analogies, business context, growth axes, contact info, submission process. The engineering core (FastAPI, Postgres, WireGuard, Terraform composition, runbook spec format) is invariant across cycles; the top-layer framing is not.

Without an explicit split, two failure modes follow. First, top-layer framing leaks into committed artifacts and the repo becomes single-cycle disposable — awkward post-rejection, unusable for the next buyer without a rewrite. Second, attempting to keep the repo fully generic strips the "speaks to me" effect from the current submission, weakening conversion signal.

The split must therefore be drawn deliberately and enforced mechanically (gitignore + commit hygiene), not left to per-commit judgement. ADR-0001 chose a buyer-agnostic repo name partly to support this split; this ADR defines the operational rule the name relies on.

## Decision
Structure the repo so **~90 % is generic (committed)** and **~10 % is buyer-specific top-layer framing (gitignored)**.

**Generic (committed):**
- All source code, tests, container configs, Terraform code
- `README.md`, `CLAUDE.md`, `docs/ADR/*`, `docs/design_doc.md` (kept buyer-neutral), `docs/deployment_guide.md`, `docs/migration_runbook.md`
- Architecture diagram, smoke-test sequence

**Buyer-specific (gitignored):**
- `<buyer>_steps.md` — domain analogies, business framing language, contact info, cycle-specific submission process
- `cover_note.md` — recipient-addressed letter
- `case_study/*.pdf` — copyrighted source brief
- `strategy.md` — current cycle's time budget, cuts, mitigation

The split is enforced by `.gitignore` and by `CLAUDE.md` § 5 (no company name, address, person, or buyer-specific framing in committed files, period).

## Alternatives Considered

| Candidate | Why not |
|---|---|
| 100 % buyer-tailored | Locks the repo to one cycle; awkward post-rejection; loses portfolio compounding across cycles. |
| 100 % generic with no buyer framing | Current cycle's submission lacks the "speaks to me" effect; weaker conversion signal; cover note and steps still need to exist somewhere. |
| Branch-per-cycle (committed buyer files in branches) | Branch namespace clutter; doesn't actually isolate cycles in the repo URL or `main` history; merging back becomes a chore. |

## Consequences
- Per-cycle setup time drops to ~30–60 min for V2/V3 (refresh gitignored files; tweak narrative analogies in the design doc only where carefully scoped).
- Committed history stays clean for eventual public release.
- Pre-public-ise verification: `git log -p | grep -i <buyer-name>` should return nothing. If it does, the leak gets stripped before flipping public.
- Discipline burden: every commit must filter out buyer language. Enforced by `CLAUDE.md` § 5 and by the commit-hygiene checklist.
- The 10 % top layer is a one-shot artifact per cycle — no investment in it carries forward except as a reusable shape (cover-note structure, steps-file headings).
- Reuse compounds: each cycle's ADRs become permanent assets, the engineering core hardens, only the framing layer churns.

## Related ADRs
- ADR-0001 (buyer-agnostic repo name `aegis-enclave` that this split operationally supports)
