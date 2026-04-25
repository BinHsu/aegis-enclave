"""aegis-enclave prime service — VPN-gated FastAPI application.

Reachability: this service is reachable only through the VPN gateway in
`docker-compose.yml` (Phase 1.2) or behind AWS Client VPN endpoint in
production (per ADR-0006). No direct host-port exposure.
"""

from __future__ import annotations

import logging
import time
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

import structlog
from fastapi import Depends, FastAPI, HTTPException, status
from sqlalchemy.exc import OperationalError, SQLAlchemyError
from sqlalchemy.ext.asyncio import AsyncSession

from prime_service import __version__
from prime_service.db import get_session, get_execution, health_check, insert_execution
from prime_service.primes import primes_in_range
from prime_service.schemas import (
    ExecutionDetail,
    HealthResponse,
    PrimeRangeRequest,
    PrimeRangeResponse,
)

# Structured JSON logging
structlog.configure(
    processors=[
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


@app.post("/primes", response_model=PrimeRangeResponse)
async def compute_primes(
    req: PrimeRangeRequest,
    session: AsyncSession = Depends(get_session),
) -> PrimeRangeResponse:
    started = time.perf_counter()
    try:
        primes = primes_in_range(req.start, req.end)
    except ValueError as exc:
        raise HTTPException(status_code=status.HTTP_400_BAD_REQUEST, detail=str(exc)) from exc
    duration_ms = int((time.perf_counter() - started) * 1000)

    try:
        execution_id = await insert_execution(
            session,
            range_start=req.start,
            range_end=req.end,
            primes=primes,
            duration_ms=duration_ms,
        )
    except SQLAlchemyError as exc:
        log.error("insert_execution_failed", error=str(exc))
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="audit log unavailable",
        ) from exc

    log.info(
        "primes_computed",
        execution_id=execution_id,
        count=len(primes),
        duration_ms=duration_ms,
    )
    return PrimeRangeResponse(primes=primes, count=len(primes), execution_id=execution_id)


@app.get("/executions/{execution_id}", response_model=ExecutionDetail)
async def fetch_execution(
    execution_id: int,
    session: AsyncSession = Depends(get_session),
) -> ExecutionDetail:
    row = await get_execution(session, execution_id)
    if row is None:
        raise HTTPException(
            status_code=status.HTTP_404_NOT_FOUND,
            detail=f"execution {execution_id} not found",
        )
    return ExecutionDetail(
        id=row.id,
        range_start=row.range_start,
        range_end=row.range_end,
        primes_count=row.primes_count,
        primes=row.primes or [],
        duration_ms=row.duration_ms,
        created_at=row.created_at,
    )
