# ADR-0036: Docker image tag = git short SHA (IMMUTABLE ECR-friendly)

## Status
Accepted (2026-04-26)

## Context

ECR repositories are configured with `image_tag_mutability = "IMMUTABLE"` (ADR-0016 and the ECR module block in `terraform/main.tf`). This is a production-hygiene posture: immutable tags prevent silent overwrites of a deployed image by a subsequent push of the same tag, which would corrupt the audit trail linking "what is running" to "what was built from which commit".

During Phase 2.5 cloud-acceptance, the `:latest` tag strategy caused a concrete failure. After the first successful image push, a subsequent `docker build` (rebuilding after a minor Terraform-only change) produced a slightly different BuildKit manifest due to attestation layer drift — even when the source code was byte-identical. Pushing the new manifest with `--tag :latest` to the IMMUTABLE ECR repository was rejected:

```
Error response from daemon: manifest already exists: IMMUTABLE tag already exists
```

The root cause: BuildKit by default appends provenance (`--provenance=true`) and SBOM (`--sbom=true`) attestation layers to the image manifest. These attestation layers contain timestamps and environment metadata, causing manifest digests to differ across builds even with identical source code. IMMUTABLE ECR rejects a push of a different digest under the same tag.

Three tag strategies were evaluated:

| Strategy | Format | IMMUTABLE-friendly | Human-readable | Audit trail |
|---|---|---|---|---|
| **`:latest` MUTABLE** | `<registry>/<repo>:latest` | No — requires MUTABLE | Yes | None — no link to commit |
| **`:latest` IMMUTABLE** | same, IMMUTABLE | Requires content-identical builds | Yes | Breaks on attestation drift |
| **Git short SHA** | `<registry>/<repo>:<sha>` or `<sha>-dirty-<hash>` | Yes | Readable, linkable to commit | Strong — exact commit visible in image tag |
| **Image content digest** | `<registry>/<repo>@sha256:<digest>` | N/A — digest is the address | No — not human-readable | Strong but opaque |
| **Monotonic counter** | `<registry>/<repo>:<N>` | Yes | Readable | Weak — counter needs external state |

Git short SHA was chosen. The tag format is:

- **Clean tree:** `$(git rev-parse --short HEAD)` — e.g., `97d0135`
- **Dirty tree (uncommitted changes):** `$(git rev-parse --short HEAD)-dirty-$(git diff HEAD | sha256sum | head -c 8)` — e.g., `97d0135-dirty-a3f2c1b0`

The dirty-tree suffix ensures two distinct builds from the same commit with different uncommitted changes get different tags, preventing a dirty build from overwriting a clean one in ECR.

Pre-push optimisation: `make cloud-up` checks `aws ecr describe-images --image-ids imageTag=$TAG` before building. If the tag already exists in ECR, the build and push are skipped entirely — idempotent re-runs of `cloud-up` do not rebuild unnecessarily.

Build flags: `docker buildx build --provenance=false --sbom=false` produces a deterministic manifest digest for a given source tree. Combined with git-SHA tagging, this makes each tag→digest mapping stable and replayable.

## Decision

Docker images are tagged using the git short SHA of the current commit (clean or dirty-suffixed). ECR repositories remain `IMMUTABLE`. The `cloud-up` script:

1. Computes `IMAGE_TAG` from the git state (clean SHA or dirty SHA + content hash).
2. Queries ECR for an existing image with `imageTag=$IMAGE_TAG`.
3. If found: skips build and push; proceeds with Terraform using the existing tag.
4. If not found: builds with `--provenance=false --sbom=false` for deterministic manifest; pushes; proceeds with Terraform.

Terraform receives `IMAGE_TAG` as a variable (`var.image_tag`) and wires it into the ECS task definition's container image URI.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **`:latest` MUTABLE ECR** | Requires changing `image_tag_mutability` to `MUTABLE`. Loses the production-hygiene signal of IMMUTABLE tags. Also loses the audit trail: the ECS task definition references `:latest`, which silently changes meaning every time a new image is pushed — a running task and its source commit are decoupled. Lower portfolio signal for a case-study deliverable. |
| **`:latest` IMMUTABLE with `--no-cache` + forced rebuild** | Does not solve the attestation drift problem unless `--provenance=false --sbom=false` is also added. Even then, a subsequent code change that produces the same binary output (e.g., comment-only diff post-compilation) would collide. Fragile. |
| **Image content digest (`@sha256:<digest>`)** | The digest is computed only after the push; it cannot be known before the push. Terraform var cannot be set pre-push without a two-pass script. More importantly, a SHA256 digest in a task definition is opaque — a reviewer cannot trace it back to a commit without querying ECR metadata. |
| **Monotonic counter** | Needs external persistent state (a counter file, an S3 object, a DynamoDB item) to survive across build environments. Introduces a dependency on external state management for a local build artifact. The git tree is the natural, already-present source of truth for "what changed". |

## Consequences

- `Makefile` and `scripts/cloud-up.sh` compute `IMAGE_TAG` at the start of `make cloud-up`.
- ECS task definitions in `terraform/main.tf` reference `var.image_tag` rather than a hardcoded `:latest`.
- `terraform.tfvars` / `cert-arns.auto.tfvars` gains an `image_tag` variable (set by `cloud-up` before calling `tf-apply`).
- A reviewer inspecting a running ECS task in the console sees the exact git commit the image was built from — the short SHA is visible in the container image URI.
- Dirty-tree builds are identified by the `-dirty-<hash>` suffix. A dirty build in ECR is a deliberate, traceable artifact rather than a silent overwrite.
- The `--provenance=false --sbom=false` flags are case-study-scope only. A production CI pipeline would generate and store attestations in a dedicated registry or storage layer rather than stripping them. The flags are explicitly scoped to the `cloud-up` script, not to the `Dockerfile` itself.

## Related ADRs
- ADR-0016 (community Terraform modules + ECR IMMUTABLE tags — the posture this ADR makes buildable)
- ADR-0029 (async POST + SQS + worker pool — the ECS services whose task definitions consume `var.image_tag`)
- ADR-0031 (Valkey bootstrap task — also receives the image tag via the same Terraform variable)
