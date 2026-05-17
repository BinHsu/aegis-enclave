# ADR-0043: FinOps scope — ship an opt-in, forker-tunable budget guardrail

## Status
Accepted (2026-05-17)

## Context

The FinOps scope was originally stated as "cost attribution + per-hour cost
estimate only": the AWS provider's `default_tags` make every resource
queryable in Cost Explorer, and the README carries a per-hour cost table.
`aws_budgets_budget` was explicitly listed as NOT included — a forker-add
item documented in `production_adoption.md`.

That exclusion rested on one concern: a committed budget with a hard-coded
dollar figure is presumptuous — a forker deploys into their own account with
their own budget posture, and a baked-in cap could surprise them.

Reviewing the sibling `aegis-stateless` repo (which commits an
`aws_budgets_budget`) surfaced the counter-point: a deployment with no cost
backstop relies entirely on the operator remembering to tear down. The
case-study's own cost-control is a ~3h apply-then-destroy discipline; a
forgotten teardown compounds silently. AWS Budgets is free.

The presumptuous-default concern is resolved not by excluding the resource
but by **framing** it: ship the budget as explicitly opt-in, forker-tunable
scaffolding — the same category as the `default_tags` FinOps scaffolding the
repo already ships — rather than as a prescriptive cap.

## Decision

Ship `terraform/budget.tf` — a monthly, account-wide `aws_budgets_budget` —
as opt-in, forker-tunable scaffolding:

- `monthly_budget_usd` (default 25) — a conservative starting point sized for
  the ~3h acceptance window, documented as "set this to your own estimate".
- `budget_notification_email` (default "") — until set, the budget is a
  silent cost tracker; setting it arms 80%-actual + 100%-forecasted alerts.
  Mirrors the opt-in shape of the existing `alarm_email` SNS wiring.
- Account-wide (no tag cost-filter) — a guardrail should also catch resources
  that escaped tagging, and a tag filter depends on the tag being activated
  as a cost-allocation tag in the Billing console first.
- The file is self-contained: a forker running cost governance elsewhere
  deletes it with no other change.

The FinOps scope statement becomes "cost attribution + per-hour estimate +
opt-in budget guardrail". `README.md` and `production_adoption.md` are
updated to match — the budget is no longer in their NOT-included lists.

## Alternatives Considered

- **Keep `aws_budgets_budget` excluded (status quo).** Leaves a forked
  deployment with no automated cost backstop. The exclusion's rationale
  (presumptuous default) is fully addressed by the opt-in framing, so the
  exclusion no longer earns its keep.
- **Commit a hard cap with a low fixed limit and no opt-out.** This IS the
  presumptuous default the original exclusion rightly avoided. Rejected.
- **N-region / per-account budget map (à la `aegis-stateless`
  topology-as-data).** Over-engineered for a fixed two-region case-study; a
  single account-wide budget is the right grain here.

## Consequences

- A forked deployment has a cost backstop from `terraform apply` onward.
- The default ($25, no email) is inert-but-present: it tracks cost silently
  until a forker opts into notifications — no unsolicited mail.
- One more resource in the plan; `aws_budgets_budget` is free.
- `production_adoption.md` still carries the anomaly-detection forker-add
  guidance; only the budget-cap item moved from "add this" to "tune this".

## Related ADRs

- ADR-0006, ADR-0015 — cost analysis the FinOps scope builds on.
- ADR-0039 — supply-chain rigor; this ADR follows the same "ship sane
  defaults, document the tuning knobs" posture.
