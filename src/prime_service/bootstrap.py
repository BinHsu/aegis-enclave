"""One-shot cache pre-warm task — seeds primes[1, 100000] if absent.

Invocation:
    python -m prime_service.bootstrap

Design:
    - Idempotent: checks cache before writing; exits 0 if already seeded.
    - Uses `cache.put_if_absent` (SET NX) so concurrent bootstrap tasks are safe.
    - Logs success/skip clearly for CloudWatch evidence (Phase 2.5).
    - Returns exit code 0 on success or skip; non-zero on unexpected error.

Bootstrap range:
    [1, 100000] — seeds the small-prime range that covers sqrt(_RANGE_CEILING).
    The range key uses start=1 rather than 2 to signal this is the bootstrap
    entry (Valkey validation accepts 1 as a start for cached ranges, even
    though the API enforces start >= 2).
"""

from __future__ import annotations

import asyncio
import logging
import sys

import structlog

from prime_service.cache import _BOOTSTRAP_END, _BOOTSTRAP_START, PrimeCache
from prime_service.db import Base, engine
from prime_service.primes import _build_prime_table

structlog.configure(
    processors=[
        # Symmetry with main.py + worker.py: merge contextvars-bound fields
        # (request_id, execution_id, etc.) into every log line. bootstrap is
        # a one-shot lifecycle task with no per-request context to bind today,
        # but the consistent processor chain means future contextvars work
        # without each module needing a re-config.
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


async def _ensure_schema() -> None:
    """Idempotently create the executions table from SQLAlchemy models.

    AWS RDS does not run db/init.sql automatically (no postgres
    docker-entrypoint hook). Without this, the app's first INSERT into
    executions hits UndefinedTableError. SQLAlchemy create_all uses
    CREATE TABLE IF NOT EXISTS semantics, so re-runs are no-ops.

    Trade-off: the schema is generated from the SQLAlchemy model definitions,
    not from db/init.sql. The init.sql remains canonical for local
    docker-compose (where Postgres entrypoint runs it). Schema drift between
    the two is an accepted Phase 2.5 trade-off; V2 cycle should add a
    proper migration tool (Alembic) and use init.sql as single source of truth.
    """
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)


def run_bootstrap(cache: PrimeCache | None = None) -> int:
    """Pre-warm the cache with primes in [_BOOTSTRAP_START, _BOOTSTRAP_END].

    Also ensures the RDS schema exists (idempotent CREATE TABLE IF NOT EXISTS
    via SQLAlchemy). Schema migration runs before cache seeding so a fresh
    RDS instance gets bootstrapped end-to-end by this single one-shot task.

    Returns:
        0 on success (written or already present, schema ensured).
        1 on unexpected error (cache or schema).
    """
    start = _BOOTSTRAP_START
    end = _BOOTSTRAP_END

    try:
        log.info("schema_ensure_start")
        asyncio.run(_ensure_schema())
        log.info("schema_ensured")

        if cache is None:
            cache = PrimeCache()
        # Check first (avoids compute if already seeded).
        if cache.exists(start, end):
            log.info("bootstrap_skip", start=start, end=end, reason="already_cached")
            return 0

        log.info("bootstrap_computing", start=start, end=end)
        # _build_prime_table gives primes starting from 2; start=_BOOTSTRAP_START=1
        # so no trimming is needed (all primes from 2..end are within [1, end]).
        primes = _build_prime_table(end)

        written = cache.put_if_absent(start, end, primes)
        if written:
            log.info("bootstrap_written", start=start, end=end, count=len(primes))
        else:
            log.info("bootstrap_skip", start=start, end=end, reason="concurrent_write")
        return 0

    except Exception as exc:  # noqa: BLE001
        log.error("bootstrap_error", error=str(exc), exc_info=True)
        return 1


if __name__ == "__main__":
    sys.exit(run_bootstrap())
