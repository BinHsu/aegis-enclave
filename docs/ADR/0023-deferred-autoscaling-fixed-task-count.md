# ADR-0023: ECS worker auto-scaling — target tracking on SQS depth per worker

## Status
Accepted (2026-04-28)

## Context

The worker pool processes async compute jobs from SQS (per ADR-0029). Capacity must follow demand: idle most of the time (~1 req/min baseline), bursting under load (50–100 req/sec for ≤ 30 s), then scaling back down. Static fixed-count provisioning either over-pays at idle or under-serves bursts. Auto-scaling is the canonical answer.

The choice within auto-scaling is the **scaling signal**:

- **CPU utilisation** — typical default for HTTP services. Misleading for queue-consumer workloads: a single 60 s sieve pins one worker's CPU while other workers are idle, so cluster-average CPU misrepresents demand.
- **Queue depth (raw)** — SQS `ApproximateNumberOfMessagesVisible` directly measures backlog. But a flat threshold doesn't account for fleet size: a 100-message backlog with 10 workers is fine, with 1 worker is overload.
- **Queue depth per worker** — the canonical metric for queue-consumer auto-scaling. Backlog ÷ running task count = per-worker load. Constant target value works regardless of fleet size.

Per ADR-0020, the policy values are: worker_count baseline 3, per-task budget 60 s, acceptable p99 queue wait 5 min. The backpressure factor (L2 of ADR-0020's three-layer defense) is **5 × worker_count**, derived from `acceptable_wait / per_task_budget = 300 s / 60 s = 5`. Auto-scaling tracks the same metric so the system scales **before** backpressure fires — backpressure is the safety net, not the steady-state regulator.

## Decision

ECS service auto-scaling on the worker service:

```hcl
resource "aws_appautoscaling_target" "worker" {
  max_capacity       = 9                              # 3× headroom over baseline
  min_capacity       = 3                              # one task per AZ (ADR-0007)
  resource_id        = "service/${cluster}/${worker_service}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
}

resource "aws_appautoscaling_policy" "worker" {
  name               = "worker-sqs-depth-per-task"
  policy_type        = "TargetTrackingScaling"
  resource_id        = aws_appautoscaling_target.worker.resource_id
  scalable_dimension = aws_appautoscaling_target.worker.scalable_dimension
  service_namespace  = aws_appautoscaling_target.worker.service_namespace

  target_tracking_scaling_policy_configuration {
    customized_metric_specification {
      metrics {
        id    = "messages_per_task"
        label = "ApproximateNumberOfMessagesVisible / RunningTaskCount"
        return_data = true
        metric_stat {
          metric { ... }   # math expression: m1 / m2
          stat = "Average"
        }
      }
      # m1 = SQS ApproximateNumberOfMessagesVisible
      # m2 = ECS RunningTaskCount
    }
    target_value       = 5     # = backpressure_threshold_factor (ADR-0020)
    scale_in_cooldown  = 300   # 5 min — conservative scale-in to avoid flapping
    scale_out_cooldown = 60    # 1 min — aggressive scale-out for burst response
  }
}
```

### Constant derivation

| Constant | Value | Source |
|---|---|---|
| `min_capacity` | 3 | One task per AZ baseline (ADR-0007 3-AZ posture) |
| `max_capacity` | 9 | 3× headroom over baseline. Burst profile (50–100 req/sec for ≤ 30 s) at 1 job/60 s = ~50 jobs in flight; 9 workers drain in ~6 min. Above 9, scaling efficiency drops (Fargate task-start latency ~30–60 s eats the next-burst absorbance). |
| `target_value` | 5 | = backpressure_threshold_factor from ADR-0020. Auto-scaling triggers at the same point backpressure would; in practice scaling adds capacity 60 s before the queue would saturate enough to reject. |
| `scale_out_cooldown` | 60 s | Aggressive — burst response priority. |
| `scale_in_cooldown` | 300 s | Conservative — prevent flap when burst tail is uneven. |

All three capacity constants derive from sister ADRs (0007, 0020). Changing one requires revisiting the source ADR.

## Alternatives Considered

| Alternative | Industry context |
|---|---|
| **Scheduled scaling** | Predictable workloads (business-hours batch). aegis-enclave's burst profile is event-driven, not time-of-day. |
| **Step scaling** | Fine-grained control (multiple thresholds with different scale amounts). Configuration overhead; target tracking is simpler and adequate at this scale. |
| **Predictive scaling** (CloudWatch ML) | Useful when workload exhibits learnable diurnal/weekly patterns. aegis-enclave's burst is unpredictable per-burst. |
| **Fixed task count** | Either over-pays at idle (`desired = 9` always) or under-serves bursts (`desired = 3` always). |
| **CPU-utilisation target tracking** | Misleading for queue consumers; covered in Context. |
| **Raw queue-depth target** | Doesn't compose with fleet size; per-worker depth is the canonical metric. |

## Consequences

- **Burst response within ~90 s** (scale-out cooldown 60 s + Fargate task-start ~30 s). The 5 min p99 queue wait SLO has 3.5 min headroom over the scale-out path.
- **Idle cost** at `min_capacity = 3` is the steady-state baseline (per-region ~$0.036/h for 3 worker tasks at 0.25 vCPU / 0.5 GB).
- **Max cost** at `max_capacity = 9` triples the worker cost during sustained burst — bounded, predictable, recovers via scale-in once burst ends.
- **Backpressure is the safety net** — auto-scaling regulates steady-state; backpressure handles the case where burst arrives faster than scale-out (60 s scale-out vs SQS arrival rate). The two layers are complementary, not redundant.
- **Cooldown asymmetry** is deliberate: scale-out fast, scale-in slow. Flapping is more expensive than over-provisioning briefly.

## Related ADRs
- ADR-0007 (per-region 3-AZ posture — supplies `min_capacity = 3` baseline)
- ADR-0008 (reliability targets — the 5 min p99 queue wait that the scale-out latency is calibrated against)
- ADR-0020 (compute load management — supplies the `target_value = 5` derivation; auto-scaling and backpressure share the same threshold by design)
- ADR-0029 (async POST + SQS + worker pool — the architecture this scaling targets)
- ADR-0033 (async drain semantics — workers must drain cleanly during scale-in events)
