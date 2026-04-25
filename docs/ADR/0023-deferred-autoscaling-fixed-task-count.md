# ADR-0023: Defer ECS auto-scaling — fixed task count for Phase 1, target-tracking deferred to Phase 2

## Status
Accepted (2026-04-25)

## Context
The current ECS service definition (`terraform/main.tf` `module.ecs.services.app`) declares a single task at `cpu = 256 / memory = 512`. There is no `aws_appautoscaling_target` and no `aws_appautoscaling_policy` resource — the service runs at fixed `desired_count = 1` (the `terraform-aws-modules/ecs/aws` module default).

Adding ECS service auto-scaling is two extra resources and well within Terraform's vocabulary. The question is when, not how. There are three reasons not to add it in Phase 1.

1. **No real load to calibrate `target_value` against.** Target-tracking auto-scaling is a closed-loop controller — it scales replicas to keep an average metric near a target value. Picking `60%` or `70%` without a real load profile is guessing. The case study has zero production traffic; any threshold chosen now is a fiction that future-Phase-2-load may or may not validate.

2. **Auto-scaling is another moving part to debug.** A misconfigured `scale_in_cooldown` can flap; a misconfigured `target_value` can over-provision (cost) or under-provision (latency). For a deliverable that is read more than it is run (per ADR-0013, the artifact-not-demo posture), introducing a controller that won't actually fire adds review surface without operational return.

3. **ADR-0015 plan-only stance.** The repo never `terraform apply`s during the case-study cycle. Auto-scaling rules that never get exercised are documentation, not behaviour. Better to write the documentation as an ADR (this one) and leave the resource definitions for the phase that actually applies.

## Decision

**Phase 1: keep `desired_count = 1`, no `aws_appautoscaling_*` resources.**

Single task, fixed replica count. The Multi-AZ posture lives in RDS (ADR-0009) and the VPC subnets (ADR-0007) — the application tier intentionally does not yet match that resilience because nothing is exercising it.

**Phase 2 (when `terraform apply` switches on): add target-tracking auto-scaling with these starting values:**

```hcl
resource "aws_appautoscaling_target" "app" {
  max_capacity       = 10
  min_capacity       = 2          # Multi-AZ HA — one task per AZ
  resource_id        = "service/${cluster_name}/${app_service_name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "cpu-target-tracking"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.app.resource_id
  scalable_dimension = aws_appautoscaling_target.app.scalable_dimension
  service_namespace  = aws_appautoscaling_target.app.service_namespace

  target_tracking_scaling_policy_configuration {
    predefined_metric_specification {
      predefined_metric_type = "ECSServiceAverageCPUUtilization"
    }
    target_value       = 60
    scale_in_cooldown  = 300       # 5 min — be conservative scaling down
    scale_out_cooldown = 60        # 1 min — be aggressive scaling up
  }
}
```

Rationale for the chosen values:

- **`min_capacity = 2`, not 1.** Once the service is real, single-AZ failure must not take the workload offline. Two tasks across the two private subnets (declared in ADR-0007) is the minimum for AZ-spread.
- **`target_value = 60` on CPU.** The prime service is CPU-bound on the worst path (10⁷ trial division). 60% leaves 40% headroom for the ~30s Fargate cold start before a scale-out task is healthy. For an I/O-bound workload 70% would be more appropriate; this service is not that.
- **`ALBRequestCountPerTarget` is the better second-axis metric** — a single slow `/primes` call pins one task's CPU while the other tasks see no load, which CPU-utilisation alone misrepresents. Worth adding as a second target-tracking policy in Phase 2.5; not in the minimum.
- **`scale_in_cooldown = 300, scale_out_cooldown = 60`** — asymmetric on purpose. Scaling out fast keeps users happy; scaling in slow avoids flapping when traffic is spiky.

## Consequences

**Positive:**
- Phase 1 deliverable stays small. The 21 ADRs cover decisions; not every decision needs a Terraform implementation.
- The Phase 2 upgrade is one block of HCL, copy-pasted from this ADR. No design work required.
- Future readers can audit the auto-scaling story by reading this ADR rather than reverse-engineering policy parameters from the Terraform.

**Negative:**
- Phase 1 cannot demonstrate horizontal scaling. The `terraform apply` story remains "spin up one task" until Phase 2.
- Reviewers familiar with ECS may flag the missing `aws_appautoscaling_*` as an oversight on first read. Hence this ADR — the absence is intentional, not an oversight.

## Alternatives considered

**A. Add `aws_appautoscaling_*` now with placeholder values.** Documents the intention in code, not just prose. **Rejected** because (1) the placeholder values are still fiction without real load, (2) `terraform plan` would show a controller that never gets exercised, which is misleading to a reviewer who reads the plan output.

**B. Use ECS Service Connect or App Mesh instead of ALB target groups for routing, so scaling decisions can incorporate request-level signals.** **Rejected** as out of scope. Adds a service-mesh dependency that doesn't pay back at PoC scale.

**C. Use Spot capacity with auto-scaling to control cost rather than load.** **Rejected** because Spot reclaim semantics interact with the drain story (ADR-0022) — worth doing in Phase 2 once the four-tier drain alignment is verified end-to-end on regular Fargate, not before.

## Future direction — beyond Phase 1 plan-only

The Phase 1 deliverable is plan-only per ADR-0015. The post-Phase-1 ambition is to actually `terraform apply` this stack from a real AWS account and reach the service through the Client VPN endpoint declared in `terraform/main.tf:330-359`. When that switch flips:

1. Apply the auto-scaling block above (this ADR's Phase 2 section).
2. Provision the Client VPN server certificate and client root certificate (currently passed as `var.server_cert_arn` / `var.client_cert_arn`).
3. Bootstrap the ECR image (`make build-push` or equivalent — out of repo scope today).
4. Verify the four-tier drain semantics (ADR-0022) end-to-end with an actual rolling deploy.

That sequence is what the migration runbook (`docs/migration_runbook.md`, ADR-0012) is structured to support. The order in this ADR — auto-scaling first, then VPN cert provisioning, then image bootstrap, then drain verification — is the order of decreasing controllability. Auto-scaling is pure config; VPN cert needs an out-of-band CA decision; image bootstrap needs CI/CD plumbing; drain verification needs all of the above plus a load generator.

## Related
- ADR-0009 — DB topology (Multi-AZ standby) — sets the resilience floor that the app tier must eventually match
- ADR-0015 — no real apply during case-study cycle (the stance this ADR partially defers against)
- ADR-0022 — drain semantics — the Phase 2 auto-scaling story builds on this
- ADR-0012 — migration runbook (agent-executable) — the Phase 2 apply path
