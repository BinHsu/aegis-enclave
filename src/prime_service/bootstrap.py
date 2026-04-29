"""One-shot cache pre-warm task — seeds primes[1, 100000] if absent.

Invocation:
    python -m prime_service.bootstrap

Design:
    - Idempotent: checks cache before writing; exits 0 if already seeded.
    - Uses `cache.put_if_absent` (SET NX) so concurrent bootstrap tasks are safe.
    - Logs success/skip clearly so CloudWatch captures the bootstrap outcome.
    - Returns exit code 0 on success or skip; non-zero on unexpected error.

DynamoDB pivot (ADR-0042):
    The schema migration step (Base.metadata.create_all) is REMOVED.
    DynamoDB tables are terraform-managed; no DDL is needed here.
    This task now only pre-warms the Valkey cache.

Bootstrap range:
    [1, 100000] — query-side cache memoization head start for common
    small-range requests. NOT related to sqrt(_RANGE_CEILING): the static
    `_SMALL_PRIMES` table in primes.py independently covers sqrt(10^7) = 3163
    for sieve and trial-division algorithms. The bootstrap seed is sized
    pragmatically (1% of the request cap) to absorb typical small-range
    queries without recompute on first hit. The range key uses start=1
    rather than 2 to signal this is the bootstrap entry (Valkey validation
    accepts 1 as a start for cached ranges, even though the API enforces
    start >= 2).
"""

from __future__ import annotations

import logging
import sys

import structlog

from prime_service.cache import _BOOTSTRAP_END, _BOOTSTRAP_START, PrimeCache
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


def run_bootstrap(cache: PrimeCache | None = None) -> int:
    """Pre-warm the cache with primes in [_BOOTSTRAP_START, _BOOTSTRAP_END].

    DynamoDB tables are terraform-managed — no schema migration step here
    (greenfield DDB greenfield path per ADR-0042 needs no DDL).

    Returns:
        0 on success (written or already present).
        1 on unexpected error (cache).
    """
    start = _BOOTSTRAP_START
    end = _BOOTSTRAP_END

    try:
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
