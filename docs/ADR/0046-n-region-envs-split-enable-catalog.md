# ADR-0046: N-region scaling — envs/ split + enable-catalog (refines ADR-0044)

## Status
Proposed (2026-05-23)

> Supersedes the regional-layer instantiation decision of **ADR-0044** *on
> acceptance*. Until accepted, ADR-0044 remains the active design and its
> Status is left unchanged (a Proposed ADR does not retroactively supersede an
> Accepted one). This ADR is drafted during the pre-interview freeze
> (≤ 2026-05-27) as a plan only — **no code changes accompany it.**

## Context

ADR-0044 refactored the two-region composition into a `platform` layer (root
`terraform/`: DynamoDB Global Table, Route53, budget, providers) plus a
reusable `region-stack` module instantiated by **explicit module calls** — one
per region — inside a **single config / single state / single apply**. That ADR
explicitly *rejected* the sibling `aegis-stateless` / `aegis-platform` model of
"topology-as-data + a separate `terraform apply` per region", on the grounds
that:

> *"its data layer is a DynamoDB Global Table, which is a single Terraform
> resource (one table with `replica` sub-blocks) and cannot be split across
> per-region applies."*

ADR-0044's consequence is honest about the residual cost:

> *"The regional layer is still bounded by explicit module calls — adding a
> region needs one new module call. This is the irreducible cost of a
> single-config, multi-provider Terraform model."*

Re-opening the question for **three or more regions** surfaces that ADR-0044's
rejection reason was scoped too broadly. The DynamoDB-Global-Table objection is
real, but it constrains **only the data layer**, not the regional infrastructure
layer (VPC / ECS / ALB / Client VPN / Valkey / SQS / ECR / log groups). Those
per-region resources are mutually independent — none of them is a single
Terraform resource that spans regions. The objection was applied to the *whole*
composition when it only binds the *DynamoDB table resource*.

Two further facts, established by surveying the sibling repo `aegis-platform`
(the most mature multi-region implementation in the portfolio):

1. **`provider` `for_each` is still unavailable.** `aegis-platform`'s
   `terraform/envs/regional/providers.tf` records it as *"reserved-but-not-
   implemented in Terraform 1.16-alpha (verified 2026-05-15)"*. So a single
   config genuinely cannot iterate providers; the only ways to reach N regions
   are (a) N hand-wired provider + module-call stanzas, or (b) external
   orchestration that runs one apply per region with one static provider each.

2. **`aegis-platform` already ships the enable-catalog this ADR proposes**, and
   names it **"Pattern X"** (`terraform/envs/platform/ecr.tf`): a `regions`
   `map(object({ enabled = bool, ... }))` held in a single
   `regions.auto.tfvars.json`, with `active_regions = { for r, v in var.regions
   : r => v if v.enabled }`. Disabled entries are *present-but-inactive* —
   "multi-region designed, single-region deployed expressed as a boolean flag,
   not as commented-out code." The `platform` env reads the catalog (for ECR
   replication targeting); a Makefile/CI matrix iterates the **enabled** entries
   and invokes the `regional` env once per region with
   `-var=region=<r>`, each apply landing in its own state key
   (`regional/<region>/terraform.tfstate`) for per-region blast-radius
   isolation.

The crucial distinction between the two sibling repos:

| | aegis-platform (EKS) | aegis-enclave (this repo) |
|---|---|---|
| per-region resources | EKS clusters — mutually independent | VPC/ECS/ALB/VPN/Valkey — mutually independent |
| cross-region stateful resource | none | **DynamoDB Global Table** (one resource, `replica` sub-blocks) |
| can split regional infra into per-region state? | yes | **yes** (same independence) |
| can split the DDB table into per-region state? | n/a | **no** — must stay single-state |

aegis-platform can split *everything* per region because it has no
cross-region single resource. aegis-enclave can split *the regional
infrastructure* the same way, but **must keep the DynamoDB Global Table in one
single-state layer that owns the replica list.** That is the one
enclave-specific constraint, and it maps cleanly onto aegis-platform's own
`platform` (single-state, global) vs `regional` (per-region-state) env split.

## Decision

Adopt the `aegis-platform` **envs/ split + enable-catalog** model, with one
enclave-specific rule for the DynamoDB Global Table. This refines — does not
discard — ADR-0044's platform/regional layer insight: the *layering* was right;
what changes is that the regional layer moves from "explicit module calls in the
platform state" to "a single module behind per-region state, iterated by
external orchestration."

### 1. Single source of truth — the enable-catalog

Repo-root `regions.auto.tfvars.json`, read by both envs:

```hcl
variable "regions" {
  type = map(object({
    enabled         = bool
    vpc_cidr        = string
    vpn_client_cidr = optional(string, "10.20.0.0/16")
    server_cert_arn = string
    client_cert_arn = string
  }))
}
variable "platform_region" { type = string }
```

`enabled = false` entries are **present-but-inactive** (Pattern X): their
vetted CIDRs / cert ARNs stay in version control without being provisioned, and
flip on with a one-line change. `active_regions = { for r, v in var.regions :
r => v if v.enabled }`.

### 2. Two Terraform envs (per-env state)

- **`envs/platform`** — single state, single (default) provider in
  `platform_region`. Owns the **global / cross-region** resources:
  - the **DynamoDB Global Table** *and its `replica` list* (`dynamic "replica"
    { for_each = active peers }`) — **the table resource lives here and only
    here; this layer is the sole owner of the replica set,** satisfying the
    one-resource-cannot-be-split constraint that ADR-0044 correctly identified;
  - all **Route53** resources (hosted-zone lookup, health checks, weighted
    records) — `for_each` over `active_regions` (Route53 records need no
    per-region provider, so they iterate freely);
  - `aws_budgets_budget`, ECR-replication targeting, shared SSM/secrets.
- **`envs/regional`** — **per-region state** (`regional/<region>/terraform.tfstate`),
  one static provider bound to `var.region`. Holds the `region-stack` module
  (VPC, subnets, SGs, VPC endpoints, ALB + self-signed cert, ECS cluster + app +
  worker + bootstrap, task IAM, SQS, ElastiCache Valkey, ECR repo, Client VPN,
  log groups + SLO alarms). A Makefile/CI matrix loops `keys(active_regions)`
  and runs `terraform -chdir=envs/regional apply -var=region=<r>` once per
  enabled region.

### 3. Cross-state wiring

`envs/regional` reads `envs/platform` outputs via a `terraform_remote_state`
data source (the DynamoDB table name/ARN, the Route53 zone id) — mirroring
`aegis-platform`'s `regional/data.tf`. The data flow is one-way: platform is
applied first (creates the table + adds/removes replicas per the catalog),
regional is applied per region afterwards. The regional layer **consumes** the
table; it never declares the table or its replicas.

### 4. Provider wall — solved by living outside Terraform

There are no hand-wired peer provider aliases and no `count`-gated peer module
calls. Each regional apply has exactly one static provider; N-region iteration
is the orchestrator's job (Makefile/CI matrix over `enabled`). Adding the Nth
region is **one catalog entry** (`enabled = true`) — no `.tf` change. This is
the property ADR-0044 could not offer ("one new module call per region").

### 5. Validation (collapsed)

```hcl
# 1. platform_region must be a key — guards the var.regions[platform_region] index.
validation {
  condition     = contains(keys(var.regions), var.platform_region)
  error_message = "platform_region must be one of the keys in the regions map."
}
# 2. the home region cannot be switched off. This single check SUBSUMES the
#    "at least one region enabled" rule: platform_region.enabled = true implies
#    the active set is non-empty. (Check 1 must precede it so the index is safe.)
validation {
  condition     = var.regions[var.platform_region].enabled
  error_message = "platform_region's entry must have enabled = true — the home region cannot be switched off."
}
```

The earlier-proposed "at least one enabled" validation is **dropped as
redundant** — it is logically entailed by check 2.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **Status quo (ADR-0044): single-state, explicit module calls per region** | Caps the regional layer at hand-wired stanzas; each new region is a `.tf` edit (provider alias + module call + Route53/replica may follow automatically, but the module call does not). Fine at N=2; at N≥3 the duplication ADR-0044 set out to kill creeps back into the *root* composition instead of the resource blocks. |
| **Static K-slot + enable-catalog (single-state)** | The interim idea: pre-wire K peer provider+module stanzas, toggle `count` via `enabled`. Keeps single-state (DDB-friendly) but is **bounded** at K, and re-introduces the verbose hand-mirroring at the module-call level. Strictly worse than the envs/ split once we accept that the *regional infra* can be split per-state — the split removes the wall entirely instead of pushing it to K. |
| **Per-region apply for *everything* (incl. the DynamoDB table)** | The model ADR-0044 rejected — and that rejection still holds **for the data layer**. A Global Table is one resource; splitting its `replica` list across per-region states produces ownership ambiguity and drift. This ADR keeps the table single-state and splits *only* the regional infra, which is precisely the refinement ADR-0044 missed. |
| **Wait for `provider` `for_each`** | Reserved-but-unimplemented as of TF 1.16-alpha (verified 2026-05-15 in aegis-platform). Even when it lands, external orchestration still gives per-region state isolation that a single `for_each` apply does not. Not worth blocking on. |

## Consequences

**Positive**
- **Genuinely unbounded N for the regional layer** — adding a region is one
  `enabled = true` line; no `.tf` change, no new provider alias, no module call.
- **Per-region blast-radius isolation** — a botched apply or a corrupt state in
  one region cannot touch another (separate state + lock per region).
- **The DynamoDB constraint is honoured, not fought** — the table + replica
  list stay in one single-state layer that owns them; ADR-0044's correct
  objection is preserved exactly where it applies.
- **Portfolio convergence** — aegis-enclave stops being the odd-one-out and
  adopts the proven `aegis-platform` Pattern X + envs/ split; one mental model
  across siblings.
- **Catalog-as-config** — vetted region configs live in version control without
  being provisioned ("multi-region designed, single-region deployed").

**Negative / costs**
- **Structural refactor**, not an increment: introduce `envs/platform` +
  `envs/regional`, move the DDB table + Route53 + budget into platform, wire
  `terraform_remote_state`, add the Makefile/CI matrix. Touches
  `terraform/`, `Makefile`, `scripts/cloud-up.sh` / `tfvars-init.sh`,
  `smoke.sh`, and the deployment guide.
- **Two apply phases with an ordering contract** — platform first (so the table
  + replicas exist for regional to consume), then the regional matrix.
  cloud-up / cloud-down sequencing and the DR drill must encode this order.
- **DDB replica ownership is a sharp edge** — the replica `for_each` must read
  the *active* catalog and live *only* in platform state. A regional apply must
  never declare a replica. This must be asserted (a comment + a guard) so a
  future edit can't accidentally split it.
- **Cross-state read coupling** — regional depends on platform outputs; a
  platform output rename breaks every regional apply. Manageable, but a new
  coupling that single-state did not have.
- **Migration-runbook + scaling-runbook impact** — both reference the
  single-config apply; both need updating to the two-env, matrix-iterated shape.
- **`moved {}` / state migration** — the case-study repo is plan-only
  (ADR-0015, no committed state), so no `state mv` is needed for the deliverable
  itself; a forker with applied single-state infra needs a documented
  migration (state mv of regional resources into per-region states), which is
  non-trivial and must ship with the change.

**Scope check (workload tier)**
- aegis-enclave is **Tier 2** (ops-support, RTO 1–4 h). Three-plus-region
  active-active is well beyond Tier-2 baseline — it is a *quality-of-
  engineering signal*, not a workload requirement (cf. ADR-0008 / ADR-0042).
  This ADR's value is "the design scales to N cleanly and matches the
  portfolio", not "the workload needs N regions". Implementation should be
  weighed against that: the envs/ refactor is justified as portfolio
  convergence + removing the N=2 cap, not as meeting a reliability mandate.

## Implementation plan (deferred — post-freeze, ≥ 2026-05-28)

1. Add `enabled = bool` to the `regions` object; create repo-root
   `regions.auto.tfvars.json` as the single source of truth; add the two
   validations (§5). Keep the current platform region `enabled = true`.
2. Create `envs/platform`: move DDB table (+ `replica` `for_each` over active
   peers), all Route53 resources (`for_each` active regions), budget, ECR
   replication, providers. Single state.
3. Create `envs/regional`: thin wrapper around the existing `region-stack`
   module, one static `aws` provider on `var.region`, `terraform_remote_state`
   read of platform outputs, S3 backend key templated with the region.
4. Add the Makefile/CI matrix that loops `keys(active_regions)` and runs
   `plan` / `apply` per region; encode the platform-then-regional ordering.
5. Update `scripts/cloud-up.sh`, `cloud-down.sh`, `tfvars-init.sh`, `smoke.sh`,
   `dr-drill.sh`, the migration + scaling runbooks, and `deployment_guide.md`.
6. Provide a forker state-migration note (single-state → two-env per-region
   state) since `moved {}` cannot cross state boundaries.
7. On acceptance: flip ADR-0044 Status to `Superseded by ADR-0046` (regional-
   layer instantiation only — its platform/regional layering insight survives).

## Related ADRs

- **ADR-0044** — region-stack platform/regional split; this ADR refines its
  regional-layer instantiation decision while preserving its layering.
- **ADR-0042** — DynamoDB Global Tables active-active; source of the
  single-state constraint that pins the table to the platform layer.
- **ADR-0040** — multi-region Frankfurt/Ireland + Route53 topology.
- **ADR-0008** — reliability targets; the Tier-2 scope check above.
- **ADR-0015** — plan-only deliverable (no committed state); why the repo itself
  needs no `state mv`.
- Sibling reference: `aegis-platform` `terraform/envs/{platform,regional}` —
  the proven Pattern X + envs/ split implementation this ADR adopts.
```
