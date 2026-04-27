"""aegis-enclave prime service — VPN-gated FastAPI application.

Reachability: this service is reachable only through the VPN gateway in
`docker-compose.yml` (Phase 1.2) or behind AWS Client VPN endpoint in
production (per ADR-0006). No direct host-port exposure.

Async flow (Phase 2.3):
    POST /primes → 202 Accepted + execution_id (job enqueued in SQS)
    GET  /primes/{exec_id} → {status, result?, error_message?}

Backpressure:
    If queue depth > backpressure_threshold (default 5 × worker_count),
    POST returns 503 + Retry-After: 60.

GZip:
    GZipMiddleware(minimum_size=1000) reduces 7 MB max raw response
    to ~1.5-2 MB over the wire, fitting comfortably within ALB limits.
"""

from __future__ import annotations

import logging
import os
import time
import uuid
from collections.abc import AsyncIterator, Callable, Coroutine
from contextlib import asynccontextmanager
from typing import Any

import structlog
from fastapi import Depends, FastAPI, HTTPException, Request, Response, status
from fastapi.middleware.gzip import GZipMiddleware
from sqlalchemy.exc import OperationalError, SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from prime_service import __version__
from prime_service.db import (
    Execution,
    get_execution,
    get_session,
    health_check,
    insert_queued_execution,
)
from prime_service.queue import PrimeQueue
from prime_service.schemas import (
    ExecutionResponse,
    HealthResponse,
    PrimeRangeRequest,
    PrimeRangeResponse,
    Status,
)

# Backpressure: max queue depth = BACKPRESSURE_FACTOR × worker count.
# Configurable via env; defaults mirror strategy.md § D (5 × worker_count).
_BACKPRESSURE_FACTOR = int(os.environ.get("BACKPRESSURE_FACTOR", "5"))
_WORKER_COUNT = int(os.environ.get("WORKER_COUNT", "1"))
_BACKPRESSURE_THRESHOLD = _BACKPRESSURE_FACTOR * _WORKER_COUNT

# Structured JSON logging.
# `merge_contextvars` pulls contextvars (set by the request_id middleware
# below) into every log line emitted in the request scope — so request_id
# attaches to ALL logs from a request, not just the middleware's own emit.
# This is the basic-tier substitute for OpenTelemetry trace_id propagation
# (no APM stack in case-study scope per design_doc § 3).
structlog.configure(
    processors=[
        structlog.contextvars.merge_contextvars,
        structlog.stdlib.add_log_level,
        structlog.processors.TimeStamper(fmt="iso"),
        structlog.processors.JSONRenderer(),
    ],
    wrapper_class=structlog.stdlib.BoundLogger,
    logger_factory=structlog.stdlib.LoggerFactory(),
)
logging.basicConfig(level=logging.INFO, format="%(message)s")
log = structlog.get_logger()


@asynccontextmanager
async def lifespan(app: FastAPI) -> AsyncIterator[None]:
    log.info("startup", version=__version__)
    yield
    log.info("shutdown")


app = FastAPI(
    title="aegis-enclave prime service",
    version=__version__,
    description="VPN-gated prime number generator with audit trail. See README for architecture.",
    docs_url="/docs",
    lifespan=lifespan,
)

app.add_middleware(GZipMiddleware, minimum_size=1000)


# ─── Request-ID middleware (correlation across logs within a request) ────────
# Every HTTP request gets a UUID4 bound into structlog contextvars so all
# subsequent log lines emitted while handling that request automatically
# include `request_id`. Also returned to the client via X-Request-ID header
# for client-side correlation. This handles the cases that execution_id
# can't cover: 422 validation rejections, 503 backpressure rejections, and
# any failure before insert_queued_execution assigns an execution_id.


@app.middleware("http")
async def request_id_middleware(
    request: Request,
    call_next: Callable[[Request], Coroutine[Any, Any, Response]],
) -> Response:
    """Bind a UUID4 request_id into structlog contextvars + emit start/end events."""
    request_id = request.headers.get("x-request-id") or str(uuid.uuid4())
    structlog.contextvars.bind_contextvars(request_id=request_id)
    started = time.perf_counter()
    log.info("request_received", method=request.method, path=request.url.path)
    try:
        response = await call_next(request)
    finally:
        duration_ms = int((time.perf_counter() - started) * 1000)
    log.info(
        "request_completed",
        method=request.method,
        path=request.url.path,
        status_code=response.status_code,
        duration_ms=duration_ms,
    )
    response.headers["X-Request-ID"] = request_id
    structlog.contextvars.clear_contextvars()
    return response


# ─── Backpressure middleware ──────────────────────────────────────────────────


@app.middleware("http")
async def backpressure_middleware(
    request: Request,
    call_next: Callable[[Request], Coroutine[Any, Any, Response]],
) -> Response:
    """Reject POST /primes with 503 if queue depth exceeds threshold."""
    if request.method == "POST" and request.url.path == "/primes":
        try:
            queue = PrimeQueue()
            depth = queue.queue_depth()
            if depth > _BACKPRESSURE_THRESHOLD:
                log.warning(
                    "backpressure_triggered",
                    depth=depth,
                    threshold=_BACKPRESSURE_THRESHOLD,
                )
                return Response(
                    content='{"detail":"queue full — retry later"}',
                    status_code=503,
                    media_type="application/json",
                    headers={"Retry-After": "60"},
                )
        except Exception:  # noqa: BLE001, S110
            # If SQS is unreachable, don't block the request.
            pass
    return await call_next(request)


# ─── Endpoints ────────────────────────────────────────────────────────────────


@app.get("/health", response_model=HealthResponse)
async def health(session: AsyncSession = Depends(get_session)) -> HealthResponse:
    try:
        ok = await health_check(session)
    except (OperationalError, SQLAlchemyError):
        ok = False
    return HealthResponse(
        status="ok" if ok else "degraded",
        db="reachable" if ok else "unreachable",
        version=__version__,
    )


@app.post("/primes", response_model=PrimeRangeResponse, status_code=202)
async def compute_primes(
    req: PrimeRangeRequest,
    session: AsyncSession = Depends(get_session),
) -> PrimeRangeResponse:
    """Accept a prime-range request, enqueue it, and return 202 + execution_id.

    The computation is performed asynchronously by the worker container.
    Poll GET /primes/{execution_id} to retrieve the result.
    """
    try:
        execution_id = await insert_queued_execution(
            session,
            range_start=req.start,
            range_end=req.end,
        )
    except SQLAlchemyError as exc:
        log.error("insert_queued_failed", error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="audit log unavailable",
        ) from exc

    # Bind execution_id into contextvars — all subsequent logs in this request
    # auto-include it via the merge_contextvars processor. Avoids the
    # forget-to-pass-execution_id bug class on new log lines.
    structlog.contextvars.bind_contextvars(execution_id=execution_id)

    try:
        queue = PrimeQueue()
        queue.enqueue(execution_id=execution_id, start=req.start, end=req.end)
    except Exception as exc:  # noqa: BLE001
        log.error("enqueue_failed", error=str(exc))
        # Queue is unavailable — still return 202 so the client can poll.
        # The worker will pick up the job when the queue recovers (or the
        # operator can manually re-enqueue). The audit row exists as the record.

    log.info("job_queued", start=req.start, end=req.end)
    return PrimeRangeResponse(execution_id=execution_id, status=Status.queued)


@app.get("/primes/{execution_id}", response_model=ExecutionResponse)
async def get_primes_result(
    execution_id: int,
    session: AsyncSession = Depends(get_session),
) -> ExecutionResponse:
    """Return the current state of a queued prime-computation job."""
    structlog.contextvars.bind_contextvars(execution_id=execution_id)
    row: Execution | None = await get_execution(session, execution_id)
    if row is None:
        log.info("job_query_not_found")
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"execution {execution_id} not found",
        )
    log.info("job_query", status=row.status)
    return ExecutionResponse(
        id=row.id,
        status=Status(row.status),
        result=row.primes if row.status == Status.done.value else None,
        error_message=row.error_message,
    )


@app.get("/executions/{execution_id}")
async def fetch_execution(
    execution_id: int,
    session: AsyncSession = Depends(get_session),
) -> dict:  # type: ignore[type-arg]
    """Legacy: return raw execution audit detail by id."""
    structlog.contextvars.bind_contextvars(execution_id=execution_id)
    row = await get_execution(session, execution_id)
    if row is None:
        log.info("execution_query_not_found")
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"execution {execution_id} not found",
        )
    log.info("execution_query", status=row.status)
    return {
        "id": row.id,
        "range_start": row.range_start,
        "range_end": row.range_end,
        "primes_count": row.primes_count,
        "primes": row.primes or [],
        "duration_ms": row.duration_ms,
        "created_at": row.created_at.isoformat() if row.created_at else None,
        "status": row.status,
        "error_message": row.error_message,
    }
