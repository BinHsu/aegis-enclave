# syntax=docker/dockerfile:1.7
ARG PYTHON_VERSION=3.12

# Base image pinned to its multi-arch index digest, not just the floating
# `-slim` tag — a tag can be repointed upstream, a digest cannot, so the
# build is reproducible and supply-chain auditable. The tag is kept for
# human readability; Docker resolves on the digest.
# Refresh when bumping PYTHON_VERSION:
#   docker buildx imagetools inspect python:<ver>-slim --format '{{.Manifest.Digest}}'
# Pinned 2026-05-17 — python:3.12-slim.
ARG PYTHON_BASE_DIGEST=sha256:401f6e1a67dad31a1bd78e9ad22d0ee0a3b52154e6bd30e90be696bb6a3d7461

# ─── Builder stage ──────────────────────────────────────────────────────────
FROM python:${PYTHON_VERSION}-slim@${PYTHON_BASE_DIGEST} AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    PIP_DISABLE_PIP_VERSION_CHECK=1

WORKDIR /build

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc \
    && rm -rf /var/lib/apt/lists/*

COPY pyproject.toml README.md ./
COPY src/ ./src/

RUN python -m venv /opt/venv \
    && /opt/venv/bin/pip install --upgrade pip \
    && /opt/venv/bin/pip install .

# ─── Runtime stage ──────────────────────────────────────────────────────────
FROM python:${PYTHON_VERSION}-slim@${PYTHON_BASE_DIGEST} AS runtime

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH"

# Non-root user (uid 1000 to align with common host uid expectations)
RUN groupadd --system --gid 1000 app \
    && useradd --system --uid 1000 --gid app --shell /usr/sbin/nologin app

# Minimal runtime tools (curl needed for healthcheck)
RUN apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && rm -rf /var/lib/apt/lists/*

COPY --from=builder /opt/venv /opt/venv
WORKDIR /app

USER app

EXPOSE 8000

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD curl --fail --silent http://localhost:8000/health || exit 1

# --timeout-graceful-shutdown 45 — uvicorn lets in-flight requests finish on
# SIGTERM up to 45s before force-killing. Aligned with the four-tier drain
# semantics in ADR-0022:
#   uvicorn 45s  ≤  ECS stop_timeout 60s  <  ALB idle 45s budget+15s
# The 45s ceiling matches the longest legitimate compute (30s prime budget +
# 10s audit + 5s slack) so an in-flight `/primes` call always gets to finish.
CMD ["uvicorn", "prime_service.main:app", \
     "--host", "0.0.0.0", \
     "--port", "8000", \
     "--timeout-graceful-shutdown", "45"]
