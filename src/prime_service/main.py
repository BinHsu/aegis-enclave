"""aegis-enclave prime service — VPN-gated FastAPI application.

Reachability: this service is reachable only through the WireGuard gateway
in `docker-compose.yml` (local-stack verification harness) or behind the
AWS Client VPN endpoint in cloud deployments (per ADR-0006). No direct
host-port exposure.

Async flow (per ADR-0029):
    POST /primes → 202 Accepted + execution_id (job enqueued in SQS)
    GET  /primes/{exec_id} → {status, result?, error_message?}

Backpressure:
    If queue depth > backpressure_threshold (default 5 × worker_count),
    POST returns 503 + Retry-After: 60.

GZip:
    GZipMiddleware(minimum_size=1000) reduces 7 MB max raw response
    to ~1.5-2 MB over the wire, fitting comfortably within ALB limits.

Data layer (ADR-0042):
    DynamoDB single-table executions row keyed by execution_id (UUID4 string).
    No ORM session — db.py exposes plain sync functions over boto3.
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
from botocore.exceptions import ClientError
from fastapi import FastAPI, HTTPException, Request, Response, status
from fastapi.middleware.gzip import GZipMiddleware

from prime_service import __version__, s3_store
from prime_service.db import (
    get_execution,
    health_check,
    insert_queued_execution,
    mark_failed,
)
from prime_service.metrics import emit_count, emit_latency_ms
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
    """Bind a UUID4 request_id + emit SLI metrics for every HTTP request.

    SLI metrics (per ADR-0041 + ADR-0008):
        request_total           Count, dimension=path
        request_errors          Count, dimensions=path + error_class (only on 4xx/5xx)
        request_latency_ms      Milliseconds, dimension=path
    The 4xx/5xx split lets the SLO dashboard distinguish client errors
    (path-specific input validation) from server errors (real fault budget
    consumption). Burn-rate alarms in terraform watch error_class=5xx only.
    """
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
    # SLI emission — minimal-cardinality aggregate metrics for the SLO
    # alarms in terraform/main.tf to query without metric-math SEARCH
    # expressions (which can flicker into INSUFFICIENT_DATA). Path-level
    # breakdown stays available via CloudWatch Logs Insights queries on
    # the `request_completed` structlog event (which carries path +
    # status_code + duration_ms in the same line).
    emit_count("request_total")
    emit_latency_ms("request_latency_ms", float(duration_ms))
    if response.status_code >= 500:
        emit_count("request_errors_5xx")  # SLO numerator (server errors only)
    elif response.status_code >= 400:
        emit_count("request_errors_4xx")  # tracked but not in SLO error budget
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
        except Exception as exc:  # noqa: BLE001
            # Backpressure preflight failed (queue unreachable, throttled, etc).
            # We fall through to the handler — which now returns a real 503 +
            # rolls the audit row to `failed` if its enqueue also fails (per
            # issue #10). Logging the warning preserves the signal so SRE
            # alerts can tell "depth check broken" from "depth below threshold".
            log.warning("backpressure_check_failed", error=str(exc))
    return await call_next(request)


# ─── Endpoints ────────────────────────────────────────────────────────────────


@app.get("/health", response_model=HealthResponse)
async def health() -> HealthResponse:
    ok = health_check()
    return HealthResponse(
        status="ok" if ok else "degraded",
        db="reachable" if ok else "unreachable",
        version=__version__,
    )


@app.post("/primes", response_model=PrimeRangeResponse, status_code=202)
async def compute_primes(
    req: PrimeRangeRequest,
) -> PrimeRangeResponse:
    """Accept a prime-range request, enqueue it, and return 202 + execution_id.

    The computation is performed asynchronously by the worker container.
    Poll GET /primes/{execution_id} to retrieve the result.
    execution_id is a UUID4 string (ADR-0042).
    """
    execution_id = str(uuid.uuid4())

    try:
        insert_queued_execution(
            execution_id=execution_id,
            range_start=req.start,
            range_end=req.end,
        )
    except ClientError as exc:
        log.error("insert_queued_failed", error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="audit log unavailable",
        ) from exc

    # Bind execution_id into contextvars — all subsequent logs in this request
    # auto-include it via the merge_contextvars processor.
    structlog.contextvars.bind_contextvars(execution_id=execution_id)

    try:
        queue = PrimeQueue()
        queue.enqueue(execution_id=execution_id, start=req.start, end=req.end)
    except Exception as exc:  # noqa: BLE001
        # The previous design swallowed enqueue failures and returned 202 —
        # which produced "orphan" rows: the audit row says `queued` but no
        # worker will ever pick it up, so the client polls forever. Per
        # issue #10, roll the row back to `failed` and return 503. The
        # client retries; on recovery the next request goes through cleanly.
        log.error("enqueue_failed", error=str(exc))
        try:
            mark_failed(execution_id, error_message=f"queue unavailable: {exc}")
        except Exception as roll_exc:  # noqa: BLE001
            # Roll back itself failed — log and still return 503; the orphan
            # row will TTL out per the audit-retention policy.
            log.error("rollback_after_enqueue_fail_failed", error=str(roll_exc))
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="queue unavailable",
            headers={"Retry-After": "60"},
        ) from exc

    log.info("job_queued", start=req.start, end=req.end)
    return PrimeRangeResponse(execution_id=execution_id, status=Status.queued)


@app.get("/primes/{execution_id}", response_model=ExecutionResponse)
async def get_primes_result(
    execution_id: str,
) -> ExecutionResponse:
    """Return the current state of a queued prime-computation job.

    For status=done, the primes list is fetched from the local-region S3
    bucket via the row's `s3_key` (ADR-0048). The server is **stateless**
    on retries: on S3 NoSuchKey it distinguishes replication lag (transient
    → 503 + Retry-After: 20) from lifecycle expiry (genuine loss → 410)
    by comparing the row's `completed_at` against `s3_store._LIFECYCLE_TTL_S`.
    The client owns its retry budget (reference: 3 × 20 s = 60 s).
    """
    structlog.contextvars.bind_contextvars(execution_id=execution_id)
    row = get_execution(execution_id)
    if row is None:
        log.info("job_query_not_found")
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"execution {execution_id} not found",
        )
    row_status = row["status"]
    log.info("job_query", status=row_status)

    primes: list[int] | None = None
    if row_status == Status.done.value:
        s3_key = row.get("s3_key")
        if not s3_key:
            # Defensive: a `done` row without s3_key shouldn't exist after
            # ADR-0048, but old rows from before the migration might.
            log.warning("done_row_missing_s3_key")
            raise HTTPException(
                status_code=status.HTTP_410_GONE,
                detail="result pointer missing (pre-ADR-0048 audit row?)",
            )
        try:
            primes = s3_store.get_primes(str(s3_key))
        except ClientError as exc:
            err_code = exc.response.get("Error", {}).get("Code", "")
            if err_code not in ("NoSuchKey", "404"):
                # Genuine S3 failure (auth, network, etc.). Surface it.
                log.error("s3_get_failed", error=str(exc), code=err_code)
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail="result store unreachable",
                    headers={"Retry-After": "20"},
                ) from exc
            # NoSuchKey — either replication has not yet arrived or the
            # lifecycle policy has removed the object. Distinguish by the
            # audit row's `completed_at` age (per ADR-0048 § 5).
            completed_at_raw = row.get("completed_at")
            now_epoch = int(time.time())
            if completed_at_raw is None:
                # `done` row without completed_at is anomalous; treat as 503.
                log.warning("done_row_missing_completed_at")
                raise HTTPException(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    detail="result not yet replicated to this region; retry",
                    headers={"Retry-After": "20"},
                ) from exc
            age_s = now_epoch - int(completed_at_raw)
            if age_s > s3_store._LIFECYCLE_TTL_S:
                # The S3 lifecycle policy has deleted the payload; the row
                # outlived it. Genuine, permanent loss — client re-POSTs.
                log.info("s3_lifecycle_expired", age_s=age_s)
                raise HTTPException(
                    status_code=status.HTTP_410_GONE,
                    detail="result expired per retention policy",
                ) from exc
            # Replication has not yet caught up. Retry-After is advisory;
            # the client owns its retry budget (ADR-0048 § 5).
            log.info("s3_replication_lag", age_s=age_s)
            raise HTTPException(
                status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                detail="result not yet replicated to this region; retry",
                headers={"Retry-After": "20"},
            ) from exc

    return ExecutionResponse(
        id=execution_id,
        status=Status(row_status),
        result=primes,
        error_message=row.get("error_message"),
    )


@app.get("/executions/{execution_id}")
async def fetch_execution(
    execution_id: str,
) -> dict[str, Any]:
    """Legacy: return raw execution audit detail by id.

    Per ADR-0048 the primes list lives in S3, not DDB; this audit endpoint
    returns the metadata + s3_key pointer only. Use GET /primes/{id} to
    fetch the actual primes list (it handles cache + S3 + replication-lag
    response codes properly).
    """
    structlog.contextvars.bind_contextvars(execution_id=execution_id)
    row = get_execution(execution_id)
    if row is None:
        log.info("execution_query_not_found")
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"execution {execution_id} not found",
        )
    log.info("execution_query", status=row["status"])
    return {
        "id": row["execution_id"],
        "range_start": int(row.get("range_start", 0)),
        "range_end": int(row.get("range_end", 0)),
        "primes_count": int(row.get("primes_count", 0)),
        "s3_key": row.get("s3_key"),
        "duration_ms": int(row.get("duration_ms", 0)),
        "created_at": str(row.get("created_at", "")),
        "status": row["status"],
        "error_message": row.get("error_message"),
    }
