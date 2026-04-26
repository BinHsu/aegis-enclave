# ADR-0037: Secrets Manager rotation deferred to V2 — manual rotation procedure as interim

## Status
Accepted (2026-04-26)

## Context

The RDS module is configured with `manage_master_user_password = true`, which provisions an AWS-managed Secrets Manager secret holding the RDS master password. The secret is KMS-encrypted, IAM-scoped, and injected into ECS task definitions via `valueFrom = "${arn}:password::"` (the JSON key pointer pattern recorded in commit `4b7a8e1`). No plaintext password appears anywhere in code or tfvars.

The remaining gap: **the secret has no rotation policy**. Once provisioned, the master password sits unchanged indefinitely. Production-shape secrets management requires periodic rotation (typically 30–90 days for database master credentials, per most compliance frameworks: SOC 2, ISO 27001, PCI-DSS for cardholder-data DBs).

The canonical AWS pattern for RDS master password rotation is:
1. A Secrets Manager rotation Lambda that, on schedule, generates a new password, calls `ALTER USER ... PASSWORD ...` on RDS, updates the secret to the new value, and verifies app connectivity using the new password before retiring the old one.
2. The rotation Lambda runs in the same VPC + subnets as RDS to reach it privately.
3. A KMS key permission grant to the Lambda execution role.
4. A CloudWatch alarm + SNS topic to alert if rotation fails.

This pattern adds ~150–250 lines of Terraform (Lambda function + IAM + KMS grant + Secrets Manager rotation schedule + CloudWatch alarm + SNS) plus the Lambda function source code itself (Python with the AWS-provided `secrets_manager_rotation` library). It also adds Lambda + CloudWatch + SNS as new architectural surfaces, each with its own security posture (IAM least-privilege, KMS access, deletion controls).

## Decision

**Rotation Lambda is deferred to V2. The PoC ships with an indefinite-lifetime master password and a documented manual rotation procedure.**

The interim manual procedure (recorded in `docs/deployment_guide.md`):

1. Operator runs `aws secretsmanager rotate-secret --secret-id <arn>` from a workstation with the appropriate IAM role.
2. The operator-triggered rotation uses Secrets Manager's built-in flow: generate new password → call RDS `ModifyDBInstance` with the new master password → wait for `available` state → update the secret value.
3. ECS service tasks pick up the new secret value at next task start (rolling deploy via `aws ecs update-service --force-new-deployment`).
4. The manual procedure is logged via CloudTrail (Secrets Manager API calls) and RDS event subscription.

This procedure is acceptable for the case-study PoC because:
- The deployment is bounded (~3-hour Phase 2.5 cloud-acceptance window per ADR-0034) — the password's lifetime is shorter than any reasonable rotation interval.
- A production adoption (anyone forking and running this beyond the case-study) is explicitly told in the deployment guide to add rotation before going live.

## Alternatives Considered

| Candidate | Why not now |
|---|---|
| **Implement Secrets Manager rotation Lambda now** | The right production answer, but adds ~150–250 lines of Terraform + Lambda Python source + new IAM scope (Lambda execution role can rotate the master password) + KMS key access grant + CloudWatch alarm + SNS topic. Estimated 3–4 hours of work that competes with the 24h budget cap (per ADR-0028 superseded ceiling). The PoC value of demonstrating rotation works for one cycle is lower than the value of the time spent on the other Phase-2.5 fixes (cloud-evidence dimensions, smoke cache assertion, terraform supply-chain pinning). Forking organisations adding rotation will spend the same effort whether they start from this PoC or from scratch. |
| **Manual rotation only, no documentation** | Rejected. Without the documented procedure, a forker has no signal that rotation is the next obvious step — the absence of a rotation Lambda could read as "we forgot" instead of "we explicitly deferred". The documentation makes the deferral legible. |
| **Rotate via terraform taint + apply** | This works mechanically (taint the RDS module's secret resource → re-apply → new password generated) but is destructive: ECS tasks holding the old password will start failing connections on the next request, and the rolling deploy of new task definitions takes 2–3 minutes. Not acceptable for a production rotation; only useful in the PoC if the password is suspected compromised. |
| **Use long-lived IAM database authentication instead of password** | RDS supports `iam_database_authentication = true` so apps connect via short-lived IAM tokens instead of master passwords. This is a stronger pattern than rotation. Rejected for V2 scoping: requires schema changes to grant `rds_iam` role to the application user, and changes the worker/app DB connection code to obtain tokens via `aws rds generate-db-auth-token`. ~6–8 hours work. The right V2 upgrade — recorded here so V2 has a flag to consider it instead of just bolting on rotation. |

## Consequences

- The PoC ships with a static master password held in Secrets Manager. CloudTrail logs every secret access (not the value, just the API call), so audit trail exists.
- `docs/deployment_guide.md` § "Production hardening checklist" lists rotation as the first item under "before going live" with the exact `aws secretsmanager rotate-secret` invocation.
- A V2 ADR will document the rotation Lambda implementation, OR the IAM database authentication migration (which would supersede this ADR by removing the master-password rotation requirement entirely).
- The ECS task definitions reference the secret via ARN + `:password::` JSON pointer — when rotation does happen (manual or V2 Lambda), the task pickup of the new value requires a `force-new-deployment`. This is documented in the deployment guide alongside the rotation procedure.
- No Lambda, KMS rotation grant, SNS topic, or CloudWatch rotation alarm exists in the current Terraform composition. Forkers who add rotation must add all four.

## Related ADRs
- ADR-0018 (managed-default tool selection — chose Secrets Manager over Vault; this ADR records the missing rotation piece of that choice)
- ADR-0028 (24h time budget — the budget pressure that pushes rotation Lambda to V2)
- ADR-0034 (Phase 2.5 cloud-acceptance window — the bounded apply-then-destroy that makes indefinite password lifetime acceptable for the PoC)
