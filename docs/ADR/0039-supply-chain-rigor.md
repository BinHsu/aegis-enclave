# ADR-0039: Supply chain rigor — exact-pin + lock + signed-source defaults

## Status
Accepted (2026-04-27)

## Context

The composition has three independent supply-chain surfaces, each with a default that's looser than necessary and a hardened alternative that's a one-flag flip:

1. **Python dependencies** (`pyproject.toml` declares ranges like `fastapi >=0.110`). Default `pip install` resolves to the latest version satisfying the range at the moment of install. Two engineers running `make install` a week apart can land on different package versions.
2. **Terraform community modules** (`source = "terraform-aws-modules/vpc/aws"`). Default `~>` constraints (e.g., `~> 5.8`) accept any later 5.x patch including potentially-breaking changes. The Phase 2.5 cycle hit this concretely: ECS module pinned `~> 5.11` silently pulled 5.12.1, which had a regression in `for_each` over `container_definitions` that broke `terraform plan` mid-cycle.
3. **Container image manifests** (`docker build` + `docker push` to ECR). BuildKit's default attestation embeds build-time metadata (provenance + SBOM attestation) into the manifest. Same source code rebuilt at a different moment produces a different manifest digest. Combined with ECR's `IMAGE_TAG_MUTABILITY = IMMUTABLE` (per ADR-0036), this creates a deployment paradox: re-pushing the same git SHA tag fails because the new manifest digest doesn't match the prior one, even though the application bytes are identical.

A fourth surface is tooling installation — how the operator gets `uv`, `easyrsa`, `pandoc`, etc. The looser default is `curl <url> | sh` (executes a remote script with no signature verification). The hardened alternative is Homebrew (signed bottles via Apple's `notarization` chain on macOS) or distribution package managers (apt/dnf with GPG-signed repos on Linux).

For a deliverable that ships on a private GitHub repo and may be forked to a forker's AWS account or an buyer staging environment, supply-chain attestation matters because:

- **Reproducibility.** A reviewer cloning the repo six months later should land on the same dependency versions that passed the Phase 2.5 acceptance gate — not whatever the package registry has by then.
- **Audit traceability.** Aerospace / defense-adjacent contexts ask "what code is actually running?" The answer should be a content-addressed manifest, not a moving tag.
- **Regression surface.** The 5.11 → 5.12 ECS module regression cost ~45 minutes mid-cycle. The fix (exact-pin) is a 7-character edit per module declaration.

## Decision

Four exact-pin disciplines, each with its mechanism and the looser default it replaces:

### 1. Python — `uv.lock` with sha256 hashes
- `uv lock` (uv 0.11+) generates `uv.lock` with sha256 hashes for every transitive dependency. Committed.
- `make install` honours the lock when uv is present:
  - With `uv.lock`: `uv sync --locked --extra dev` (fails fast on lock-vs-pyproject drift)
  - Without `uv.lock`: `uv sync --extra dev` (resolves fresh, writes lock)
  - Without uv: pip + venv fallback (skips lock, prints supply-chain note suggesting `brew install uv`)
- Resolved: 87 packages, 1050 hash entries.

### 2. Terraform community modules — exact patch pin
- All `source = "terraform-aws-modules/X/aws"` declarations use `version = "5.21.0"` (exact equality, no `~>`) instead of `version = "~> 5.8"`.
- Pinned versions are the ones that passed the Phase 2.5 acceptance gate: `vpc 5.21.0`, `rds 6.13.1`, `ecr 2.4.0`, `alb 9.17.0`, `ecs 5.11.4`, `security-group 5.3.1` (×4 declarations).
- Providers stay on `~>` constraints because `.terraform.lock.hcl` records the exact resolved versions and prevents drift (different mechanism, same effect).

### 3. Container image — deterministic ECR manifests
- `docker build` invocations use `--provenance=false --sbom=false` to suppress BuildKit attestation. Same source code → same manifest digest → ECR `IMMUTABLE` content-addressed semantics work.
- `cloud-up.sh` derives the image tag from `git rev-parse --short=8 HEAD` (clean tree) or `<sha>-dirty-<8-char-content-hash>` (uncommitted changes). Tag-exists pre-check skips push entirely when the same content has already landed (per ADR-0036).

### 4. Tooling installation — signed-source default
- README Prerequisites recommends `brew install uv` (signed Homebrew bottle) over `curl -LsSf https://astral.sh/uv/install.sh | sh` (the upstream-blessed path, but unsigned remote script).
- `bootstrap-vpn-certs.sh` wraps `easy-rsa` (Homebrew package). Override via `EASYRSA_PKI` env var (per memory `feedback_no_destructive_shared_path_recovery.md` — never unconditionally `rm -rf` a system path).
- The case-study report PDF rendering uses `brew install pandoc + brew install --cask basictex` (xelatex via signed Cask).
- Forker-aware: the README explains the trade-off so a forker working in an environment without Homebrew (Linux server, restricted corporate macOS without admin) knows where to substitute distribution-package equivalents.

## Alternatives Considered

| Candidate | Why not (or: where we chose this) |
|---|---|
| **Pure pip ranges, no lock** | The PEP-621 default. Gets you "latest compatible" on every install. Acceptable for libraries (you want consumers to get bug fixes); unacceptable for applications shipping a verified Phase-2.5 acceptance gate. Rejected for the deliverable. |
| **`pip-tools` + `requirements.txt --generate-hashes`** | The pre-uv canonical lockfile pattern. Would work — but requires installing `pip-tools` as an additional dev dependency, and the lock semantics are slightly weaker (no native cross-platform resolution like uv's). Skipped because uv is already preferred for install speed; once uv is in the toolchain, `uv lock` is the natural lock target. |
| **`Pipfile.lock` (Pipenv)** | Older lockfile format; Pipenv development has slowed in 2024–2025. Rejected. |
| **Terraform `version = "~> X.Y.Z"` (patch-line constraint)** | Allows safe-by-semver patches (5.11.0 → 5.11.5) but blocks 5.12+. Half the protection: still vulnerable to a regression released as 5.11.6. Exact-pin closes that gap entirely. Trade-off: forker bumping deliberately is a 7-char edit per module — acceptable. |
| **Module-level `terraform-version` constraint only** | Weak: pins Terraform binary version but not module versions. Doesn't address the actual drift surface. |
| **BuildKit attestation enabled (default)** | Useful for SLSA provenance attestation in upstream supply-chain pipelines (where the manifest moves through a gating system that reads attestation). For our PoC where the consumer of the manifest is just ECS task launch, the attestation adds entropy without value, while breaking the IMMUTABLE re-push idempotency. Rejected. |
| **Skip `--sbom=false`, rely on `trivy fs` post-build** | Trivy scans filesystem-level dependencies, which catches CVEs in installed packages. Doesn't address the manifest-determinism concern (orthogonal). We do both: `--sbom=false` for determinism, `make audit` (pip-audit) for CVEs. |
| **`curl install.sh \| sh` for uv installation** | The astral.sh-blessed path. Gets you the latest uv on any platform without Homebrew. But it's an unsigned remote script execution. For a deliverable that buyer-side or a forker-side reviewer might run, the signed-Homebrew path is the senior default. Recommended in README Prerequisites with the curl option as fallback. |

## Consequences

- **Build reproducibility**: a fresh clone six months later runs `make install` and lands on the exact dependencies that passed the Phase 2.5 gate, sha256-verified.
- **Plan reproducibility**: `terraform plan` against the same tfvars produces the same plan, regardless of when the registry's latest module version was published.
- **Push idempotency**: re-running `cloud-up.sh` with the same git SHA on a clean tree triggers an ECR pre-check, finds the existing manifest, and skips build + push entirely. Cycle time drops from ~5 min (build + push) to ~2 sec (HEAD check).
- **Carrying cost**: pinned versions go stale. The Production hardening checklist § 7 in deployment_guide records Dependabot / Renovate as the V2 forker-add for automated bump PRs. Without that, a long-running fork accumulates stale-pin drift over months.
- **Forker awareness**: the README Prerequisites section signals "supply-chain hardening engaged" by leading with `brew install uv` and noting the pip fallback skips lock-file verification. A forker who reads top-down sees the choice within 30 seconds.
- **Audit traceability**: `git log -p uv.lock` shows every dependency change ever; `git log -p terraform/main.tf` shows module bumps; `cloud-up.sh` log lines record the exact tag used at deploy time. Three separate audit trails for three separate supply-chain layers.

## Related ADRs
- ADR-0016 (community Terraform modules — the upstream choice this ADR hardens)
- ADR-0034 (build budget 22h → 24h — supply-chain hardening was budgeted in the 22 → 24h delta)
- ADR-0036 (image tag git-sha + IMMUTABLE ECR — the determinism mechanism that demands `--provenance=false`)
- ADR-0037 (secrets rotation deferred — same pattern: hardening surfaces explicitly enumerated as deferred V2 items rather than missing-by-oversight)
- ADR-0038 (DLQ alarm + manual triage — same shape: deliberate stop-line + V2 forker-add path)
