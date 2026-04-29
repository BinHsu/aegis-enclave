"""Long-running SQS consumer for prime-computation jobs.

Invocation:
    python -m prime_service.worker

Design:
    - Single-threaded synchronous consumer loop (boto3 sync, not async).
    - Idempotency-aware retry:
        status='done'    → ack + skip (already computed)
        status='running' and started_at > 90s ago → mark failed, proceed fresh
        status='queued'  → proceed with compute
    - Cache-first: check for a covering Valkey range before computing.
    - Compute: sieve_with_timeout (SIGALRM 60s hard deadline).
    - On TimeoutError or unexpected exception → status=failed + error_message + ack.
    - SIGTERM grace (5s): set _shutdown flag; do not ack in-flight; SQS
      visibility timeout re-delivers after 90s.

Data layer (ADR-0042):
    DynamoDB replaces PostgreSQL. execution_id is a UUID4 string.
    All DB helpers are synchronous boto3 calls; no asyncio.run() wrapping needed.

SIGALRM rationale:
    Queue redelivery rescues the SQS message but NOT a stuck worker. A CPU-bound
    Python loop holds the GIL and has no OOM path. Only SIGALRM can interrupt
    a pure-Python CPU-bound infinite loop (e.g. a pathological sieve bug).
    See memory note feedback_safety_guard_recovery_test.md.
"""

from __future__ import annotations

import logging
import signal
import time
from datetime import UTC, datetime
from decimal import Decimal
from typing import Any

import structlog

from prime_service.cache import PrimeCache
from prime_service.db import get_execution, mark_done, mark_failed, mark_running
from prime_service.metrics import emit_count, emit_latency_ms
from prime_service.primes import sieve_with_timeout
from prime_service.queue import PrimeQueue
from prime_service.schemas import Status

structlog.configure(
    processors=[
        # merge_contextvars pulls vars bound via structlog.contextvars
        # into every log line. handle_message() binds execution_id at entry
        # and clears at exit so all 12+ log calls inside auto-include it
        # without each having to pass execution_id=execution_id manually.
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

# Grace period for SIGTERM — stop accepting new messages but finish the current one.
_SIGTERM_GRACE_S = 5
# If status='running' and started_at is older than this, assume the prior worker
# crashed mid-compute and treat as a fresh retry.
_RUNNING_STALE_THRESHOLD_S = 90

_shutdown = False


def _handle_sigterm(signum: int, frame: object) -> None:
    global _shutdown
    _shutdown = True
    log.info("sigterm_received", grace_s=_SIGTERM_GRACE_S)


signal.signal(signal.SIGTERM, _handle_sigterm)


# ─── Message handler ──────────────────────────────────────────────────────────


def handle_message(
    message: dict[str, Any],
    queue: PrimeQueue,
    cache: PrimeCache,
) -> None:
    """Process one SQS message through the idempotency + compute + cache pipeline."""
    body = PrimeQueue.parse_body(message)
    # execution_id is a UUID4 string in the DynamoDB pivot (ADR-0042).
    execution_id: str = str(body["execution_id"])
    start: int = int(body["start"])
    end: int = int(body["end"])

    # Bind execution_id into contextvars so every log line in this function
    # auto-includes it via merge_contextvars processor. clear in finally so
    # the next message's binding starts clean even if this message raises
    # past the per-exception ack/return paths.
    structlog.contextvars.bind_contextvars(execution_id=execution_id)
    try:
        log.info("message_received", start=start, end=end)

        # ── Idempotency check (ConsistentRead=True in get_execution) ──
        row: dict[str, Any] | None = get_execution(execution_id)

        if row is None:
            # Row missing — ack and skip (orphaned message)
            log.warning("execution_not_found")
            queue.ack(message)
            return

        row_status: str = row["status"]

        if row_status == Status.done.value:
            log.info("already_done")
            queue.ack(message)
            return

        if row_status == Status.running.value:
            # Check if stale (prior worker crashed)
            started_at_raw = row.get("started_at")
            if started_at_raw is not None:
                started_at_epoch = int(started_at_raw)
                now_epoch = int(datetime.now(UTC).timestamp())
                age_s = now_epoch - started_at_epoch
                if age_s <= _RUNNING_STALE_THRESHOLD_S:
                    # Another worker is actively computing — skip without ack.
                    log.info("running_not_stale", age_s=age_s)
                    return
            # Stale running: mark failed, then fall through to fresh compute.
            log.warning("running_stale")
            mark_failed(execution_id, error_message="stale running — prior worker crash")

        # ── Mark running ──
        mark_running(execution_id)
        started = time.perf_counter()

        # ── Cache-first: try to serve from Valkey ──
        try:
            cached = cache.get_covering_slice(start, end)
            if cached is not None:
                duration_ms = int((time.perf_counter() - started) * 1000)
                mark_done(execution_id, primes=cached, duration_ms=duration_ms)
                queue.ack(message)
                log.info("cache_hit", count=len(cached), duration_ms=duration_ms)
                emit_count("cache_hit_count")
                emit_latency_ms("poll_to_done_ms", float(duration_ms))
                return
        except Exception as exc:  # noqa: BLE001
            log.warning("cache_lookup_error", error=str(exc))
            emit_count("cache_lookup_errors")
            # Cache errors are non-fatal; fall through to compute.

        # ── Compute (SIGALRM 60s hard deadline) ──
        try:
            primes = sieve_with_timeout(start, end)
        except TimeoutError as exc:
            err = f"compute exceeded 60s SIGALRM budget: {exc}"
            log.error("compute_timeout", error=err)
            emit_count("compute_errors", error_class="timeout")
            mark_failed(execution_id, error_message=err)
            queue.ack(message)
            return
        except ValueError as exc:
            err = f"validation error: {exc}"
            log.error("compute_validation_error", error=err)
            emit_count("compute_errors", error_class="validation")
            mark_failed(execution_id, error_message=err)
            queue.ack(message)
            return
        except Exception as exc:  # noqa: BLE001
            err = f"unexpected error: {type(exc).__name__}: {exc}"
            log.error("compute_error", error=err)
            emit_count("compute_errors", error_class="generic")
            mark_failed(execution_id, error_message=err)
            queue.ack(message)
            return

        duration_ms = int((time.perf_counter() - started) * 1000)

        # ── Write to cache (range-coalescing via Lua) ──
        try:
            cache.merge_or_put(start, end, primes)
        except Exception as exc:  # noqa: BLE001
            log.warning("cache_write_error", error=str(exc))
            emit_count("cache_write_errors")
            # Cache write errors are non-fatal; result is still persisted to DB.

        # ── Update audit record ──
        mark_done(execution_id, primes=primes, duration_ms=duration_ms)
        queue.ack(message)
        log.info("compute_done", count=len(primes), duration_ms=duration_ms)
        emit_count("cache_miss_count")
        emit_latency_ms("compute_duration_ms", float(duration_ms))
        emit_latency_ms("poll_to_done_ms", float(duration_ms))
    finally:
        structlog.contextvars.clear_contextvars()


# ─── Main consumer loop ───────────────────────────────────────────────────────


def run_worker() -> None:
    """Main consumer loop — runs until SIGTERM."""
    log.info("worker_starting")
    queue = PrimeQueue()
    cache = PrimeCache()

    while not _shutdown:
        try:
            messages = queue.receive()
        except Exception as exc:  # noqa: BLE001
            log.error("receive_error", error=str(exc))
            time.sleep(1)
            continue

        for msg in messages:
            if _shutdown:
                log.info("shutdown_mid_batch")
                break
            try:
                handle_message(msg, queue, cache)
            except Exception as exc:  # noqa: BLE001
                log.error("handler_error", error=str(exc))
                # Do NOT ack — let SQS re-deliver after visibility timeout.

    log.info("worker_stopped")


# Unused import kept for Decimal in module scope (used in type hints via db.py)
_Decimal = Decimal  # noqa: F841


if __name__ == "__main__":
    run_worker()
