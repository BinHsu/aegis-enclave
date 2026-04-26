# Declarative ops targets for aegis-enclave. Run `make help` for available actions.
#
# Scope: zero-cost local hygiene + Terraform plan-only (per ADR-0015).
# No `terraform apply` target — the case study delivers code + plan, not real state.

.DEFAULT_GOAL := help

# Auto-detect Python venv: .venv (uv default / pip canonical) preferred,
# falls back to .venv-test (legacy hand-crafted) if .venv absent.
# Lazy assignment (=, not :=) so re-evaluation happens after _ensure-venv bootstraps.
PYTHON_BIN = $(shell test -d .venv && echo .venv/bin || (test -d .venv-test && echo .venv-test/bin || echo ""))

# Internal helper: any target needing a venv depends on this. Idempotent —
# no-op if a venv already exists; otherwise calls 'make install' which uv-or-pip
# bootstraps .venv. Forkers running 'make test' / 'make lint' for the first time
# get the venv created automatically (rubric P4: zero forker friction).
.PHONY: _ensure-venv
_ensure-venv:
	@test -n "$(PYTHON_BIN)" || { \
		echo "==> No venv detected (.venv or .venv-test); bootstrapping via 'make install'..."; \
		$(MAKE) -s install; \
	}

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

.PHONY: help
help: ## Show this help (default)
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: ## Install dev dependencies (uv preferred → uv.lock with hashes; pip fallback w/o lock)
	@if command -v uv >/dev/null 2>&1; then \
		if [ -f uv.lock ]; then \
			echo "==> uv + uv.lock found, running 'uv sync --locked --extra dev' (reproducible install w/ hashes)"; \
			uv sync --locked --extra dev; \
		else \
			echo "==> uv found but no uv.lock — running 'uv sync --extra dev' (will resolve fresh and write lock)"; \
			uv sync --extra dev; \
		fi; \
	else \
		echo "==> uv not found, falling back to pip + .venv"; \
		echo "    (note: pip path skips uv.lock supply-chain pinning — install uv via 'brew install uv' for hash-verified deps)"; \
		test -d .venv || python3 -m venv .venv; \
		.venv/bin/pip install -e '.[dev]'; \
	fi

.PHONY: pre-commit-install
pre-commit-install: ## One-time setup of pre-commit + pre-push hooks
	pre-commit install
	pre-commit install --hook-type pre-push

# ---------------------------------------------------------------------------
# Code quality
# ---------------------------------------------------------------------------

.PHONY: lint
lint: _ensure-venv ## Run ruff lint + format check over src + tests
	$(PYTHON_BIN)/ruff check src tests
	$(PYTHON_BIN)/ruff format --check src tests

.PHONY: format
format: _ensure-venv ## Apply ruff formatter to src + tests
	$(PYTHON_BIN)/ruff format src tests

.PHONY: typecheck
typecheck: _ensure-venv ## Run mypy over src
	$(PYTHON_BIN)/python -m mypy src

.PHONY: check
check: lint typecheck ## Composite: lint + typecheck

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

.PHONY: test
test: _ensure-venv ## Run pytest
	PYTHONPATH=src $(PYTHON_BIN)/pytest tests/ -v

.PHONY: test-ci
test-ci: _ensure-venv ## Headless pytest for pre-push hook + GitHub Actions (PYTHONPATH-aware, no -v noise)
	@PYTHONPATH=src $(PYTHON_BIN)/pytest tests/ -q --tb=short

.PHONY: test-cov
test-cov: _ensure-venv ## Run pytest with coverage report
	PYTHONPATH=src $(PYTHON_BIN)/pytest tests/ -v --cov=src --cov-report=term-missing

# ---------------------------------------------------------------------------
# Local stack
# ---------------------------------------------------------------------------

.PHONY: up
up: ## Bring the stack up (build + detached)
	docker compose up -d --build

.PHONY: down
down: ## Stop the stack (preserves volumes)
	docker compose down

.PHONY: clean-stack
clean-stack: ## Stop the stack and clear volumes
	docker compose down -v

.PHONY: logs
logs: ## Tail compose logs (last 50 lines, follow)
	docker compose logs -f --tail=50

# ---------------------------------------------------------------------------
# Verification
# ---------------------------------------------------------------------------

.PHONY: smoke
smoke: ## Run smoke test from inside test-client (see README § Initial Acceptance)
	docker compose run --rm test-client ./smoke.sh

.PHONY: negative
negative: ## Negative test — confirm API is unreachable outside the VPN
	curl -m 5 http://localhost:8000/health || echo 'expected: connection refused'

# ---------------------------------------------------------------------------
# Cloud (Terraform plan-only per ADR-0015)
# ---------------------------------------------------------------------------

.PHONY: tf-init
tf-init: ## Init Terraform without remote backend
	cd terraform && terraform init -backend=false

.PHONY: tf-plan
tf-plan: tf-init ## Plan against the example tfvars (no apply target — see ADR-0015)
	cd terraform && terraform plan -var-file=terraform.tfvars.example

.PHONY: tf-fmt
tf-fmt: ## Recursively format Terraform code
	cd terraform && terraform fmt -recursive

.PHONY: tf-validate
tf-validate: tf-init ## Validate Terraform configuration
	cd terraform && terraform validate

.PHONY: tf-apply
tf-apply: ## OPERATOR USE — apply Terraform via scripts/ts_apply.sh (low-level; prefer 'make cloud-up')
	@./scripts/ts_apply.sh

.PHONY: tf-destroy
tf-destroy: ## OPERATOR USE — destroy Terraform via scripts/ts_teardown.sh (low-level; prefer 'make cloud-down')
	@./scripts/ts_teardown.sh

.PHONY: tfvars-init
tfvars-init: ## Generate terraform.tfvars via interactive Q&A (AWS-aware CIDR + region validate)
	@./scripts/tfvars-init.sh

.PHONY: cloud-up
cloud-up: ## Phase 2.5 one-shot deploy — pre-flight + tfvars-init (if missing) + cert + ECR + image push + full apply
	@./scripts/cloud-up.sh

.PHONY: cloud-down
cloud-down: ## Phase 2.5 one-shot teardown — drain ECR + destroy + ACM cleanup + collateral-free verify
	@./scripts/cloud-down.sh

.PHONY: cloud-smoke
cloud-smoke: ## Phase 2.5 cloud-side 6-step smoke (POST + poll + cache hit + 422 + backpressure)
	@./scripts/cloud-smoke.sh

.PHONY: cloud-evidence
cloud-evidence: ## Phase 2.5 evidence capture — CloudWatch metric widgets + worker/bootstrap logs + tf output
	@./scripts/cloud-evidence.sh

# ---------------------------------------------------------------------------
# Supply-chain audit (rubric P1 — pip-audit; install via 'brew install pip-audit')
# ---------------------------------------------------------------------------

.PHONY: audit
audit: _ensure-venv ## Run pip-audit against current venv deps for known CVEs (rubric P1)
	@command -v pip-audit >/dev/null 2>&1 || { echo "pip-audit not installed. Run 'brew install pip-audit'"; exit 1; }
	@TMPFILE=$$(mktemp -t aegis-audit.XXXXXX); \
	 $(PYTHON_BIN)/pip freeze > $$TMPFILE; \
	 pip-audit -r $$TMPFILE; RC=$$?; \
	 rm -f $$TMPFILE; \
	 exit $$RC

.PHONY: tf-bootstrap
tf-bootstrap: ## OPERATOR USE ONLY — provision Phase-2 prerequisites (state backend + GHA OIDC role)
	@cd terraform/bootstrap && terraform init && terraform apply

.PHONY: ts-bootstrap-certs
ts-bootstrap-certs: ## OPERATOR USE ONLY — generate Client VPN PKI + import to ACM (ADR-0024)
	@./scripts/bootstrap-vpn-certs.sh $(if $(OPERATOR),--operator $(OPERATOR),)

.PHONY: tf-apply-plan-only
tf-apply-plan-only: ## OPERATOR USE — run all pre-flight checks then plan; no apply
	@./scripts/ts_apply.sh --plan-only

# ---------------------------------------------------------------------------
# Hygiene
# ---------------------------------------------------------------------------

.PHONY: clean
clean: ## Tear down stack and remove Python caches
	make down && find . -type d \( -name __pycache__ -o -name .pytest_cache -o -name .mypy_cache -o -name .ruff_cache \) -exec rm -rf {} +

.PHONY: pre-push-check
pre-push-check: ## Scan diff vs origin/main for buyer-name leaks (CLAUDE.md § 6)
	@if [ ! -f .leakguard ]; then \
	  echo "Missing .leakguard (gitignored). Create it with one regex pattern per line of buyer-specific tokens to scan for."; \
	  exit 2; \
	fi
	@PATTERN=$$(grep -v '^[[:space:]]*#' .leakguard | grep -v '^[[:space:]]*$$' | tr '\n' '|' | sed 's/|$$//'); \
	if [ -z "$$PATTERN" ]; then \
	  echo "Empty .leakguard — nothing to scan against"; exit 2; \
	fi; \
	if git diff origin/main..HEAD | grep -iE "$$PATTERN"; then \
	  echo 'BUYER-SPECIFIC TOKEN LEAK — DO NOT PUSH'; exit 1; \
	else \
	  echo 'clean'; \
	fi
