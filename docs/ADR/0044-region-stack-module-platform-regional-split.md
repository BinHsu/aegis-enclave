# ADR-0044: Region-stack module — platform / regional layer separation

## Status
Accepted (2026-05-17)

> A Proposed refinement of this ADR's regional-layer instantiation exists:
> **ADR-0046** (N-region envs/ split + enable-catalog). It does **not** supersede
> this ADR until accepted; this ADR remains the active design until then.
> ADR-0046 keeps this ADR's platform/regional *layering* and changes only how
> the regional layer is instantiated (per-region state + external orchestration
> instead of explicit single-state module calls).

## Context

The multi-region composition in `terraform/main.tf` was built by hand-mirroring:
every per-region resource existed as a primary block plus a `count`-gated
`secondary_*` block. By the time the composition was complete this meant ~5
duplicated security groups, duplicated VPC + subnets + route tables, duplicated
ECS / SQS / Valkey / ECR / Client VPN / log groups — a primary copy and a
near-identical secondary copy of each, in a single 2,300-line file.

Three problems followed:

1. **Duplication.** Every change to a regional resource had to be made twice,
   in two places, kept in sync by hand. A `tfsec` annotation pass had to touch
   five separate secondary security groups that were copies of one another.
2. **Structurally capped at two regions.** A third region would mean a third
   hand-written copy of every resource.
3. **Misleading vocabulary.** "primary / secondary" implies a writer / standby
   asymmetry. ADR-0042 chose DynamoDB Global Tables **active-active
   multi-master** — every region accepts writes; "failover" is a Route53
   weight change, not a promotion. There is no secondary region at runtime.

The sibling repo `aegis-stateless` was surveyed for its multi-region design:
a `platform_region` scalar (the one region hosting singleton resources) plus a
`regions` map of peers. That repo achieves N-region scaling via external
orchestration (a Makefile/CI loop running a separate `terraform apply` per
region). aegis-enclave **cannot** adopt that orchestration: its data layer is a
DynamoDB Global Table, which is a single Terraform resource (one table with
`replica` sub-blocks) and cannot be split across per-region applies. aegis-enclave
is therefore committed to a single config / single apply / single state, with
`provider "aws"` + provider aliases for the additional region(s).

## Decision

Refactor the composition into two layers, still within one Terraform config:

- **Platform layer** — stays in root `terraform/`: the DynamoDB Global Table,
  all Route53 resources, `aws_budgets_budget`, providers, root variables /
  locals / outputs. These are global or single-instance and run under one
  provider, so they can iterate the region set freely.
- **Regional layer** — extracted into a reusable module `modules/region-stack/`:
  VPC, subnets, route tables, security groups, VPC endpoints, ALB + its
  self-signed TLS cert, ECS (cluster + app + worker + bootstrap), task IAM
  roles, SQS, ElastiCache Valkey, ECR, Client VPN, CloudWatch log groups +
  alarms. Instantiated once per region.

Replace the `primary` / `secondary` rank vocabulary with the `aegis-stateless`
framing, named by role rather than rank:

- `platform_region` — the home region: the default `provider "aws"`, and where
  the DynamoDB table resource, Route53, and the budget are anchored.
- `regions` — a `map(object(...))` keyed by AWS region name. Every entry is a
  peer that runs one `region-stack` instance; the platform region is also an
  entry. This replaces the flat `region` / `secondary_region` / `vpc_cidr` /
  `secondary_*` variables.

The platform-layer resources iterate the `regions` map: the DynamoDB `replica`
blocks are generated for `regions − platform_region`; Route53 weighted records
and health checks are generated per region. Adding a region to the map makes
both appear automatically.

The `region-stack` module is instantiated with **explicit module calls**, one
per region — not `for_each`. Terraform cannot pass a per-instance provider to a
`for_each`/`count`-iterated module, and each region needs its own provider
(default `aws` for the platform region, an alias for each peer). Adding a third
region is therefore one map entry (platform layer follows automatically) plus
one explicit module call (the only manual step the provider model forces).

`moved {}` blocks map the old resource addresses to the new module addresses so
a forker who has already applied gets a clean plan. The case-study repo itself
is plan-only (ADR-0015, no committed state), so no `terraform state mv` is
needed for the deliverable.

## Alternatives Considered

- **Keep the hand-mirrored primary/secondary blocks.** Rejected: the
  duplication, the two-region structural cap, and the misleading vocabulary are
  the problem being solved.
- **Adopt `aegis-stateless`'s topology-as-data + per-region `terraform apply`
  orchestration.** Rejected: incompatible with DynamoDB Global Tables (one
  Terraform resource cannot be applied per-region), and full N-region
  orchestration is over-engineering for a fixed two-region case study.
- **`for_each` the `region-stack` module over the `regions` map.** Rejected:
  Terraform does not allow a per-instance provider to be passed to a `for_each`
  module. `aegis-stateless` only avoids this because it runs a separate apply
  per region with a single provider each — which aegis-enclave cannot do.
- **Keep flat per-region variables, assemble the map in `locals`.** Rejected
  once "drop primary/secondary" was decided: the flat variables are named
  `secondary_*`, so genuinely dropping the vocabulary means the input interface
  itself becomes the `regions` map.

## Consequences

- Each regional resource is defined once, in the module; a change applies to
  every region.
- Parity fix riding along: the pre-refactor secondary region was only a
  partial mirror (no worker autoscaling, no SLO alarms / dashboard / SNS, no
  cache-bootstrap task). Instantiating one identical module per region closes
  that gap — a multi-region deployment now runs the full stack in every
  region. A multi-region `terraform plan` therefore shows more peer-region
  resources than the pre-refactor composition; this is intended.
- The platform layer (DynamoDB replicas, Route53 records) is genuinely
  N-region: one map entry adds a region's data replica and DNS record.
- The regional layer is still bounded by explicit module calls — adding a
  region needs one new module call. This is the irreducible cost of a
  single-config, multi-provider Terraform model.
- The input interface changes: `terraform.tfvars` now carries a `regions` map
  and `platform_region` instead of flat `region` / `secondary_region` /
  `vpc_cidr` / `secondary_*` variables. `terraform.tfvars.example`,
  `scripts/tfvars-init.sh`, and `scripts/cloud-up.sh` are updated to match.
- `moved {}` blocks keep the refactor non-destructive for forkers with state.
- The composition reads as platform-layer-then-`module`-calls rather than a
  2,300-line flat file.

## Related ADRs

- ADR-0042 — DynamoDB Global Tables active-active; the basis for dropping the
  "primary/secondary" vocabulary and for the single-config constraint.
- ADR-0040 — multi-region Frankfurt/Ireland topology.
- ADR-0016 — community `terraform-aws-modules`; `region-stack` composes them.
- ADR-0007 — 3-AZ per-region posture, preserved inside the module.
