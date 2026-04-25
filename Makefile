# Declarative ops targets for aegis-enclave. Run `make help` for available actions.
#
# Scope: zero-cost local hygiene + Terraform plan-only (per ADR-0015).
# No `terraform apply` target — the case study delivers code + plan, not real state.

.DEFAULT_GOAL := help

# ---------------------------------------------------------------------------
# Setup
# ---------------------------------------------------------------------------

.PHONY: help
help: ## Show this help (default)
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

.PHONY: install
install: ## Install dev dependencies (uv preferred; falls back to pip)
	uv sync --dev
	# Fallback if uv is unavailable: pip install -e '.[dev]'

.PHONY: pre-commit-install
pre-commit-install: ## One-time setup of pre-commit hooks
	pre-commit install

# ---------------------------------------------------------------------------
# Code quality
# ---------------------------------------------------------------------------

.PHONY: lint
lint: ## Run ruff lint over src + tests
	ruff check src tests

.PHONY: format
format: ## Apply ruff formatter to src + tests
	ruff format src tests

.PHONY: typecheck
typecheck: ## Run mypy over src
	mypy src

.PHONY: check
check: lint typecheck ## Composite: lint + typecheck

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------

.PHONY: test
test: ## Run pytest
	pytest -v

.PHONY: test-cov
test-cov: ## Run pytest with coverage report
	pytest -v --cov=src --cov-report=term-missing

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
tf-apply: ## OPERATOR USE ONLY — apply Terraform via scripts/ts_apply.sh (see docs/production_adoption.md)
	@./scripts/ts_apply.sh

.PHONY: tf-destroy
tf-destroy: ## OPERATOR USE ONLY — destroy Terraform via scripts/ts_teardown.sh (irreversible)
	@./scripts/ts_teardown.sh

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
