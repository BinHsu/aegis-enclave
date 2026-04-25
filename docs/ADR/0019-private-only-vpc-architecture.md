# ADR-0019: Private-only VPC — no NAT, no public subnets, AWS service egress via VPC Endpoints (PrivateLink)

## Status
Accepted (2026-04-25)

## Context
Earlier iterations of `terraform/main.tf` provisioned a "mixed" VPC: workload in private subnets, NAT gateway in public subnets, IGW for the NAT to reach the internet. This is the AWS reference architecture for a typical web service that needs **public-internet egress** (e.g., calling third-party SaaS APIs, fetching public packages, sending outbound webhooks).

This deliverable's service does **not need public-internet egress**:

- Container image pull: AWS ECR (PrivateLink available)
- Database password: AWS Secrets Manager (PrivateLink available)
- Log shipping: AWS CloudWatch Logs (PrivateLink available)
- ECS agent communication: AWS ECS / ECS-Agent endpoints (PrivateLink available)
- IAM role assumption (IRSA): AWS STS (PrivateLink available)
- Connecting to RDS: same-VPC private connection
- ECR layer storage: AWS S3 (gateway endpoint available)

Every egress path is to an AWS service, and every AWS service needed has a VPC Endpoint (PrivateLink) equivalent. There is no third-party API call, no public package fetch, no outbound webhook in the application's data plane.

The mixed-VPC pattern (NAT + public subnets) was therefore **unjustified architectural cruft** — it provisioned infrastructure for a need that does not exist. Per ADR-0018 (managed-default), the right default is to NOT provision capability that's unused.

The case-study brief asks for **VPN-only access** (Task 2 — about ingress) but says nothing about egress. Removing public subnets and NAT tightens the security posture (no internet egress at all → reduced lateral-movement and exfiltration surface) without violating any brief requirement.

## Decision
The VPC composition removes public subnets, the Internet Gateway, and the NAT gateway. AWS service egress is routed through VPC Endpoints (PrivateLink). The composition becomes:

| Resource | Configuration |
|---|---|
| `module "vpc"` | `private_subnets` only (across two AZs); `database_subnets` only; **no `public_subnets`, no `enable_nat_gateway`**; no IGW |
| Interface VPC Endpoints (in private subnets, in both AZs) | `ecr.api`, `ecr.dkr`, `secretsmanager`, `logs`, `ecs`, `ecs-agent`, `ecs-telemetry`, `sts` |
| Gateway VPC Endpoint | `s3` (no per-AZ cost; ECR uses S3 for layer storage) |
| Security group for VPC endpoints | Allow inbound 443 from VPC CIDR |

Result: the VPC has zero connection to the public internet. Every egress path is on the AWS backbone via PrivateLink. Ingress is still gated by AWS Client VPN endpoint (per ADR-0006) — both ingress and egress are private now.

This is the L2 / "fully private VPC" pattern in standard AWS terminology. Trigger to revert to L1 (mixed VPC with NAT) is documented under Alternatives below; none of the triggers are met for this deliverable.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **Keep NAT + public subnets ("L1 — workload private, NAT egress")** | Provisions infrastructure for a need that does not exist (no public-internet egress in the data plane). Adds an IGW (one more attack vector to defend), a NAT (~$33/month), and unused public subnets. Per ADR-0018, the managed-default is to not provision unused capability. |
| **Use a NAT instance instead of NAT gateway** ("self-hosted NAT") | Cheaper than NAT gateway but adds operational burden (instance patching, AZ failover) for a service that doesn't need NAT at all. The right answer is no NAT, not a self-hosted one. |
| **Public-facing ALB + IAM-authenticated request signing** ("skip the VPN entirely") | Brief Task 2 explicitly requires VPN-only access. A public ALB with request signing satisfies authentication but violates the network-perimeter requirement. Out of brief scope. |
| **PrivateLink + a single public-facing bastion for emergency operator access** | Adds a public endpoint for an exceptional case. The Client VPN endpoint already covers operator access; a bastion duplicates that path. |
| **Hybrid — public subnets present "in case we need NAT later"** | Provisioned-just-in-case infrastructure ages into legacy quickly. If a future requirement appears for public-internet egress, the upgrade is straightforward (add public subnets + NAT in a follow-up Terraform change); leaving them un-provisioned now is the right cost-hygiene posture. |

## Triggers to revert to L1 (mixed VPC with NAT)

Documented for future reference. Add NAT + public subnets back when **any** of these become true:

- The application data plane needs to call a third-party SaaS API not reachable via PrivateLink (e.g., a customer's webhook endpoint on the public internet)
- The application needs to fetch a public package or container image at runtime (not at build time — build can use ECR replication or a private mirror)
- An outbound notification / metric / log destination outside AWS (Datadog SaaS, PagerDuty, etc.) is on the data path
- Federal compliance (FedRAMP High) requires explicit egress logging through a NAT for traffic that isn't AWS-internal

None of these are met by the prime-number generator deliverable. The application is fully self-contained on AWS-managed primitives.

## Consequences
- Smaller attack surface: no IGW, no public subnets, no NAT — the VPC has no path to or from the public internet for any data-plane traffic. Lateral movement and exfiltration scenarios both lose a class of attack vector.
- Architectural consistency with the brief's "VPN-only" theme: ingress is VPN-gated (ADR-0006), egress is PrivateLink-only (this ADR). Both directions are off the public internet.
- Hypothetical cost shift (the deliverable is plan-only per ADR-0015, so no real cost): NAT gateway (~$33/month) is removed; ~5 interface endpoints in 2 AZs at ~$7/month each (~$70/month) are added. Net cost is higher at low data volumes, lower at high data volumes (NAT charges $0.045/GB; PrivateLink charges $0.01/GB). For PoC scope the difference is rounding error; for production scale PrivateLink wins economically as well as architecturally.
- Terraform composition is slightly more complex (a few VPC endpoint resources) but removes the IGW + NAT plumbing — net code-line count comparable.
- Operational debugging gets simpler: there is no NAT gateway connection-tracking limit to hit, no public subnet to mis-route through, no NAT IP pool to manage. PrivateLink is point-to-point per service.
- Future buyers without managed PrivateLink-equivalent (e.g., IONOS) can fall back to L1 in their cloud (NAT + public subnets) — the migration runbook (ADR-0012) Track 1 captures this where the destination cloud's service catalogue dictates.
- The "VPN-only access" claim in the design doc and cover note becomes architecturally exact rather than half-true: the network has no public internet path at all.
- **Build vs runtime separation is a hard architectural boundary, not a workaround.** This decision applies to **runtime egress only**. Container image construction (`docker build`, `pip install`) happens outside this VPC — typically in a separate build account / VPC / CI runner / developer machine that has unrestricted public-internet access for fetching packages from PyPI, ECR base images, etc. The built image is pushed to ECR; this private-only VPC pulls from ECR via the `ecr.api` and `ecr.dkr` PrivateLink endpoints (S3 gateway endpoint covers ECR layer storage). Cross-account ECR access is an IAM concern, not a networking concern — no network bridge between build and runtime environments is required. Production VPC stays fully private; build environment networking is intentionally a separate decision recorded elsewhere when CI/CD is added (out of case-study scope per ADR-0015).

## Related ADRs
- ADR-0006 (VPN three-tier — ingress story; this ADR completes the picture for egress)
- ADR-0010 (VPN ownership boundary — case-study self-contained vs production)
- ADR-0012 (migration runbook spec — Track 1 destination clouds may not have PrivateLink-equivalent)
- ADR-0015 (no real apply — this ADR is documented in code, not applied)
- ADR-0016 (community Terraform modules — the VPC module supports private-only configuration via the `enable_nat_gateway = false` flag and absent `public_subnets`)
- ADR-0018 (managed-default tool selection — this ADR is the network-egress instance of the principle)
