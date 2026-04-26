# ADR-0038: DLQ handling is alarm + manual triage, not a polling auto-retry worker

## Status
Accepted (2026-04-26)

## Context

The async architecture (ADR-0029) wires the SQS main queue (`aegis-enclave-primes`) with a `redrive_policy` pointing at a dead-letter queue (`aegis-enclave-primes-dlq`) with `maxReceiveCount = 3`. After three failed receive cycles on the main queue without a successful `delete-message` (ack), SQS automatically moves the message to the DLQ.

The remaining design gap was: **what happens to messages once they reach the DLQ?**

A common but mis-applied pattern is to add a "DLQ retry worker" — a long-running consumer that polls the DLQ and re-enqueues messages back to the main queue. This was an item on the V2 polish list and was initially scoped as such.

On reconsideration during Phase 2.5 polish, this pattern is incorrect for our deployment shape. The reasoning:

1. **DLQ messages are not transient failures.** A message reaches the DLQ only after `maxReceiveCount` (3) main-queue receive cycles all failed without `delete-message`. The current worker (`src/prime_service/worker.py`) only fails to ack when:
   - The worker process crashed mid-message (SIGKILL, OOM, kernel panic)
   - The handler raised an exception that the outer `run_worker` loop caught (logged as `handler_error`, not acked)
   - The worker received SIGTERM mid-message and entered the 5-second grace window without finishing
   All other failure modes (`TimeoutError`, `ValueError`, unexpected exception inside `handle_message`) explicitly call `_mark_failed` and `queue.ack(message)` — these messages never reach the DLQ at all; they are already terminal-state failed in the database.

2. **Auto-retry on the DLQ produces thrashing.** A polling worker that re-enqueues DLQ messages to the main queue creates a feedback loop: the main queue worker hits the same crash condition (the underlying bug or infrastructure problem hasn't changed), `maxReceiveCount` is exhausted again, the message lands back in the DLQ. Without operator intervention to identify and fix the root cause, the message bounces main ↔ DLQ until the 14-day `message_retention_seconds` expires. The polling worker burns Fargate task time and SQS API calls for zero progress.

3. **The correct production-shape pattern is alarm + triage.** Industry references (AWS Well-Architected Framework Reliability Pillar, Amazon SQS developer guide, "Distributed Systems Observability" / Charity Majors) all converge on this: the DLQ is an **observability surface**, not an automated reprocessor. Operator action is the loop closure, because root-cause diagnosis is the load-bearing step.

## Decision

DLQ handling consists of three components, none of which is an auto-retry worker:

1. **CloudWatch metric alarm** on `AWS/SQS / ApproximateNumberOfMessagesVisible` for the DLQ. Threshold: > 0 (zero-tolerance — any DLQ message is a real failure). Period: 60s. `treat_missing_data = "notBreaching"`. Implemented in `terraform/main.tf` as `aws_cloudwatch_metric_alarm.dlq_depth`.

2. **Operator triage script** (`scripts/dlq-triage.sh`):
   - List DLQ messages (with `VisibilityTimeout = 300s` so triage gets a 5-minute window).
   - Decode each message body (JSON: `execution_id`, `start`, `end`).
   - Print the `execution_id` so the operator can cross-reference the `executions` table for the recorded `error_message` (the `_mark_failed` payload — though for messages reaching DLQ via worker crash, no `error_message` exists because `_mark_failed` never ran).
   - Per-message confirmation gate before any replay (`y / N / q`). Bulk replay is intentionally not exposed.
   - Optional `--purge` for "operator has triaged, the messages are unrecoverable, free the queue".

3. **ADR + deployment guide reference** so a forker reading the codebase understands that the DLQ is alarm-monitored but manually triaged.

The alarm has empty `alarm_actions = []` in the case-study composition. A production adoption adds an SNS topic ARN to wire up email/Slack/PagerDuty notification (a one-line operator change after they have an existing notification topic).

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **Polling DLQ worker that auto-re-enqueues** | The originally-listed V2 item. Rejected on reconsideration because of thrashing (point 2 above). Burns Fargate cycles + SQS API charges for zero throughput when the underlying failure is persistent. |
| **DLQ → Lambda processor** | An EventBridge rule on DLQ depth could fire a Lambda that reads + re-enqueues. Same thrashing problem as the polling worker, just with Lambda billing instead of Fargate. Worse: Lambda scales out on DLQ depth, so a sudden DLQ spike (worker bug deploying broadly) triggers Lambda concurrency the operator hasn't budgeted for. |
| **DLQ → Step Functions retry with exponential backoff** | A Step Functions workflow could implement back-off-then-retry-then-give-up. This is the right pattern for *transient* failures (network blip, temporary downstream unavailable). It is the wrong pattern for our case: we don't reach DLQ for transient failures; we already mark-failed-and-ack those. DLQ here means catastrophic worker failure, where back-off retry doesn't help. |
| **Alarm + auto-replay if DLQ count is low** | A "best-effort" pattern: if DLQ depth is 1-3, try replay once; if higher, hold for operator. Adds conditional complexity for marginal benefit — operator still has to triage anyway. Simpler to make manual triage the only path. |
| **Skip DLQ entirely (use redrive to /dev/null)** | Setting `maxReceiveCount = 0` would discard messages that fail repeatedly. Loses forensic data — the failed message body and metadata are valuable for debugging the worker bug or infrastructure problem. 14-day retention is cheap; discarding is irreversible. |

## Consequences

- A new top-level Terraform resource `aws_cloudwatch_metric_alarm.dlq_depth` is added. No new IAM, no new SNS, no new Lambda. The alarm exists in three states (OK, ALARM, INSUFFICIENT_DATA) and the state transitions are visible in the AWS Console, CloudWatch Events, and EventBridge.
- A new operator script `scripts/dlq-triage.sh` is added. It is interactive by default; `--list-only` mode is read-only; `--purge` requires typing the literal word `purge`.
- The script depends on VPN connectivity (DLQ + RDS are private) and a workstation with `aws + jq + terraform` in PATH. Same operator surface as `cloud-evidence.sh`.
- Production adopters fork the alarm and add `alarm_actions = [aws_sns_topic.ops_alerts.arn]` to their composition. The triage script is reusable as-is; only the SNS wiring is environment-specific.
- The `bootstrap.py` worker code is unchanged. The DLQ change is entirely operational tooling + alarm wiring, not application logic.
- This ADR explicitly supersedes the prior V2-list item that scoped a DLQ retry worker. That item is removed from V2 because the design is wrong, not because the timing is wrong.

## Related ADRs
- ADR-0029 (async POST + SQS + worker pool — the architecture that produces DLQ messages)
- ADR-0033 (async drain semantics — defines worker behaviour around SQS ack/no-ack, which determines what reaches DLQ)
- ADR-0003 (PoC scope, prod hygiene calibration — alarm without notification target is the calibrated PoC stance; adding SNS subscriber is the production-add)
- ADR-0037 (secrets rotation — same pattern: case-study composition wires the resource but defers the operational subscriber to a forker-add)
