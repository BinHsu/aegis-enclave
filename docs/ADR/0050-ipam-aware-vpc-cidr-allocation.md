# ADR-0050: IPAM-aware VPC CIDR allocation (opt-in, static fallback)

## Status
Accepted (2026-05-31). Extends ADR-0011 (network topology) and ADR-0019 (private-only VPC); does not supersede them. Touches the `regions`-map schema introduced by ADR-0042 / ADR-0046.

## Update (2026-05-31) — preview superseded by explicit allocation
The **implementation below (Decision) is revised.** The first real IPAM cloud deploy proved the `aws_vpc_ipam_preview_next_cidr` **data-source** approach is **not idempotent**: a preview returns the pool's *next-free* CIDR, which shifts the moment a VPC takes one. Across our two-phase apply (pre-deps `-target` then full apply) the preview drifted between phases, so the derived subnets no longer fell inside the VPC's already-allocated CIDR and the apply failed with `InvalidSubnet.Range` (it also showed the VPC's `cidr_block` "forces replacement"). This breaks on any apply after the first allocation, not only a concurrent grab.

The fix **reverses the "Explicit `aws_vpc_ipam_pool_cidr_allocation`" rejection** in *Alternatives* below: the VPC CIDR is now a stateful `aws_vpc_ipam_pool_cidr_allocation` **resource** whose `.cidr` is fixed at first apply and stable across the apply split + re-runs; the VPC consumes it as a plain `cidr_block` (no `use_ipam_pool`). The accepted caveat changes from the "preview predict-vs-actual race" (Consequences) to the "double-counted CIDR in IPAM resource-discovery" (cosmetic) — idempotency was worth that ledger noise. Static-CIDR path unchanged.

## Context

Each region's VPC CIDR is a hand-written string in the `regions` map (`terraform.tfvars`): `eu-central-1 = 10.0.0.0/16`, `eu-west-1 = 10.10.0.0/16`. Non-overlap across regions — required so the VPCs can later be peered via Transit Gateway without collision — is an operator promise enforced only by a comment. At N=2 that is fine; as regions are added (ADR-0046's enable-catalog) it becomes a manual bookkeeping surface where an overlap is a silent setup error until two ranges actually need to route to each other.

The sibling landing-zone (`aegis-landing-zone-aws`) now runs an org-wide **AWS IPAM** (advanced tier), with per-region pools (`eu-central-1` 10.0.0.0/12, `eu-west-1` 10.16.0.0/12) **shared to the whole organization via AWS RAM**. Any member account — including the one this enclave deploys into — can allocate a non-overlapping CIDR from those pools, and IPAM tracks the allocation and refuses overlaps at the API level. The capability the enclave wants (machine-enforced non-overlap, no hand-managed ranges) already exists one tier down; the enclave just is not wired to it.

Two consumers pull in opposite directions:

1. **Our CI deploy** runs inside the governed org where IPAM exists. It should allocate from IPAM — automatic non-overlap, and it scales as regions are added.
2. **A forker** adopting this template runs in *their* AWS account, which almost certainly has **no** IPAM. The repo must still apply with a plain hardcoded CIDR, zero IPAM assumption — the forker is the default audience (CLAUDE.md § 1, ~90% generic core).

So the requirement is "use IPAM when it is there, fall back to a static CIDR when it is not" — per region, and **explicit**, not magic auto-detection (the repo's `explicit-over-implicit` discipline: a silent "is IPAM on?" probe is a debugging black hole, and cross-account pool discovery is fragile).

A mechanical wrinkle drives the implementation. The three private subnets are derived at plan time via `cidrsubnet(vpc_cidr, 8, 1|2|3)`. With IPAM the VPC CIDR is allocated *at apply time* by `use_ipam_pool`, so it is unknown during plan, and feeding the VPC module's own output back into its `private_subnets` input would be circular. The VPC's CIDR cannot be both "allocated by the module" and "known early enough to carve subnets from" through the module alone.

## Decision

**Per-region opt-in. A region sets EITHER `vpc_cidr` (static) OR `ipv4_ipam_pool_id` (IPAM-allocated) — exactly one, enforced by an XOR variable validation.** The `tfvars.example` default stays static (forker-first); our CI supplies the pool id through an `*.auto.tfvars`.

When `ipv4_ipam_pool_id` is set:

- The VPC allocates its CIDR from IPAM via the upstream module's `use_ipam_pool` + `ipv4_ipam_pool_id` + `ipv4_netmask_length` (default `/16`, matching the legacy static size so the `/24` subnet math is unchanged) — **one** IPAM-tracked allocation.
- A `data "aws_vpc_ipam_preview_next_cidr"` previews, at plan time, the CIDR IPAM will hand out at that netmask. A single `local.effective_cidr` resolves to the static CIDR or the previewed CIDR, and **all derivations read it**: the three private subnets, the VPC-endpoints security-group ingress, and the Client VPN authorization rule. This keeps the whole plan resolved (no `known after apply` cascading into `count`/`for_each`) and sidesteps the circularity.

`ipv4_netmask_length` is validated to `16–20`: the subnets are `/(n+8)` (`cidrsubnet` newbits=8), so `n>20` falls below the AWS `/28` subnet minimum and `n<16` exceeds the `/16` VPC maximum.

The static path is byte-for-byte the prior behaviour, so existing tfvars and the forker default need no change.

## Alternatives Considered

- **Auto-detect IPAM (a `data` lookup of RAM-shared pools, switch on presence).** Rejected. Implicit "is IPAM on?" magic violates `explicit-over-implicit`; cross-account pool discovery by tag/region is fragile and turns a missing-share into a confusing plan-time failure rather than an obvious "you didn't set a pool id." Opt-in by supplying the pool id is the senior choice.
- **Explicit `aws_vpc_ipam_pool_cidr_allocation` + plain `cidr_block`.** This avoids the preview's predict-vs-actual gap (the allocation is authoritative and breaks the circularity since it is a separate resource). Rejected because the VPC is then *not* IPAM-managed, so IPAM's resource discovery records the VPC's CIDR a **second** time alongside the manual allocation: the same `/16` is double-counted in pool utilization, the monitoring view flags a false self-overlap, and destroy can need a retry while discovery catches up. `use_ipam_pool` produces exactly one allocation — a clean ledger — at the cost of the preview gap, which we accept (below).
- **IPAM-only; drop the static path.** Rejected — breaks every forker without IPAM, the default audience.
- **Subnet-tier IPAM pools (allocate each subnet from IPAM too).** Rejected — correct but heavyweight for a PoC; the `/24` derivation from one VPC CIDR is sufficient at this scale.

## Consequences

- **Backward-compatible.** Default and forker path unchanged (static CIDR). IPAM is purely additive and per-region.
- **Non-overlap is machine-enforced in our org.** As regions are added, IPAM hands out non-overlapping space instead of an operator picking ranges by hand.
- **Preview predict-vs-actual caveat (accepted).** `aws_vpc_ipam_preview_next_cidr` predicts the next allocation; it does not lock it. If a *concurrent* apply grabbed from the **same** pool between preview and the VPC's allocation, the previewed CIDR (used for subnets/SG/VPN) and the VPC's actual CIDR would diverge — and the apply would **fail loud** (a subnet would fall outside the VPC CIDR), never corrupt silently. Our applies are single-operator / CI-serialized, and each region draws from a *different* regional pool, so in practice preview == actual. This trade was accepted deliberately: a fail-loud race we never trigger beats the always-on ledger noise of the manual-allocation alternative.
- **One extra data source, only in IPAM mode** (`count = ipv4_ipam_pool_id != null ? 1 : 0`). Static deployments plan exactly as before.
- **Deploy wiring.** In our governed org the CI deploy role (the forthcoming `gh-tf-apply-enclave` deploy ADR) injects the region→pool-id mapping via an `*.auto.tfvars`, so the committed `terraform.tfvars.example` never needs a real pool id. Reading the pool id from the landing-zone's RAM-shared pool (its `shared/ipam` outputs / a `data.aws_ec2_ipam_pools` RAM filter) is left to that deploy path, not hardcoded here.

## Related ADRs
- **ADR-0011** — network topology (single VPC, private subnets across AZs): this ADR changes *how the VPC CIDR is sourced*, not the topology.
- **ADR-0019** — private-only VPC: the IPAM-allocated CIDR still backs an IGW/NAT-free VPC; endpoints unchanged.
- **ADR-0042 / ADR-0046** — the `regions` map and N-region scaling whose per-region schema this extends.
- Cross-repo: `aegis-landing-zone-aws` provisions and RAM-shares the IPAM pools this consumes.
