# ADR-0015: Container orchestration shape — ECS Fargate cloud + Docker Compose local parity

## Status
Accepted (2026-04-28)

## Context

This case-study uses ECS Fargate matched to workload scope and team size. Multi-account / IAM Identity Center / Organizations setup at production scale lives in the sister `aegis-aws-landing-zone` repo (aegis-* portfolio peer); this repo focuses on the application-shape decisions inside one account.

The orchestration decision has two coupled claims that fall out of the same calibration:

1. **ECS Fargate, not K8s.** The K8s-default reflex assumes a platform team to absorb K8s operational tax: etcd backup, RBAC sprawl, ingress controller, cert-manager, CSI driver, Prometheus operator, EKS control-plane fee. The aegis-enclave workload — small audit-log + async compute service, no service mesh, no operators, no multi-cluster federation — does not justify any of that surface. ECS Fargate provides task scheduling, health-checked rolling deploys, IAM task roles, autoscaling, and CloudWatch integration as managed primitives — sufficient for the workload shape and below the platform-team threshold.

2. **Local Docker Compose parity.** Same Dockerfile + same boto3 client code paths against local ElasticMQ (SQS-shape per ADR-0030), dynamodb-local (DDB-shape per ADR-0042), and Valkey container — so local development matches cloud topology. Fast feedback loop, forker onboarding without an AWS account, integration testing without cloud cost.

These two claims are coupled: ECS Fargate naturally enables Compose parity (plain containers, plain stdout logs, plain env-var config). K8s would force Kind / K3s / Minikube for local parity — much heavier dev setup, with Compose-incompatible primitives (Services, Ingress, ConfigMaps) that don't translate one-for-one.

## Decision

**ECS Fargate** for the cloud target. Two services: `app` (HTTP API, `desired_count = 3` per AZ baseline) and `worker` (SQS consumer, `min = 3 / max = 9` autoscale on SQS depth per ADR-0023). One-shot bootstrap task for cache seeding. All tasks behind an internal ALB in private subnets (per ADR-0019).

**Docker Compose** for local development. `docker-compose.yml` mirrors the production topology: app + worker + bootstrap + ElasticMQ + dynamodb-local + Valkey + WireGuard verification gateway. The forker quick-start path (smoke test, integration tests) runs entirely against Compose — no AWS account required.

Same image, same code paths, same env-var contract across local and cloud. The only difference is endpoint URLs (`http://elasticmq:9324` vs SQS-managed-URL; `http://dynamodb-local:8000` vs DDB endpoint).

## Alternatives Considered

| Alternative | Industry context |
|---|---|
| **EKS** (managed K8s control plane) | Right call for orgs that already run K8s at platform scale. Worker node lifecycle / RBAC / ingress controller / cert-manager / CSI / Prometheus operator still fall on the team — control-plane being managed is only ~5% of the operational tax. Negative ROI for the aegis-enclave workload size. |
| **Self-hosted K8s** (kops, kubeadm, kubespray) | Even more burden; only justified by very specific control requirements (air-gapped, regulated workloads requiring exact K8s version pinning). |
| **Kind / K3s / Minikube for local parity** | Heavier than Compose for the parity target. Forker onboarding cost rises sharply. |
| **EC2 + auto-scaling group + custom AMI** | Pre-Fargate pattern. Requires AMI lifecycle, patching cadence, capacity provisioning. Fargate eliminates this surface. |
| **Lambda + EventBridge** | Right shape for very-short-duration, low-rate, stateless functions. The 60 s SIGALRM compute budget (ADR-0033) and persistent connections to Valkey + DDB favour persistent workers. |

## Consequences

- **Cloud apply happens** (per ADR-0026 OIDC plan + operator's local `make cloud-up` apply). The case-study deliverable includes a real cloud-acceptance window; this is not a "plan-only forever" stance.
- **Forker onboarding without AWS** is the default path. `docker compose up` + `make smoke` exercises the full topology locally. Cloud deployment is opt-in via `make cloud-up`.
- **K8s migration path** lives in `docs/migration_runbook.md` Track 3. ECS → EKS is mechanical (same image, similar IAM-via-IRSA pattern); the runbook records the steps for forkers whose ops team has invested in K8s elsewhere.
- **Coupling to ECS-specific primitives** (task definitions, service discovery via Cloud Map, ECS Exec) is shallow — the application code does not depend on ECS APIs. Migration to another container orchestrator is a Terraform rewrite, not an application rewrite.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene calibration — this ADR's calibration)
- ADR-0019 (private-only VPC — the network this orchestration runs inside)
- ADR-0023 (worker auto-scaling — the dynamic capacity layer over ECS Fargate)
- ADR-0030 (ElasticMQ for local SQS parity — the Compose-equivalence pattern this ADR enables)
- ADR-0042 (data store — DynamoDB Global Tables, with `amazon/dynamodb-local` for Compose parity)
