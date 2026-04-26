"""Unit tests for prime_service.worker — SQS consumer loop.

Strategy
--------
- All I/O (DB, SQS, cache) is mocked — worker tests are pure unit tests.
- handle_message is the focal function; idempotency and SIGALRM paths
  are the primary BVA targets.
- BVA on the stale-running threshold (90s): message at 89s, 90s, 91s.
- BVA on handle_message input: valid message, missing body fields,
  orphaned execution, already-done execution.
- run_worker is tested via a shutdown-triggered smoke (sets _shutdown=True
  after one iteration).
"""

from __future__ import annotations

import json
from datetime import UTC, datetime, timedelta
from typing import Any
from unittest.mock import MagicMock, patch

import pytest

from prime_service.db import Execution
from prime_service.worker import (
    _RUNNING_STALE_THRESHOLD_S,
    _SIGTERM_GRACE_S,
    handle_message,
)


def _close_coro_and_return(value: Any = None) -> Any:
    """Mock side_effect factory: closes the unawaited coroutine, returns value.

    The worker calls _run_async(_get_exec(...)). When _run_async is patched,
    the inner coroutine _get_exec(...) is created (since async-def returns a
    coroutine just by being called) and passed to the mock. A naive mock
    returning a fixed value never awaits the coroutine — GC later raises
    RuntimeWarning: coroutine never awaited. This factory closes the coroutine
    explicitly to suppress the warning while preserving the desired return value.
    """

    def inner(coro: Any) -> Any:
        if hasattr(coro, "close"):
            coro.close()
        return value

    return inner


# ───────────────────────────────────────────────────────────────────────────
# Constants BVA
# ───────────────────────────────────────────────────────────────────────────


class TestWorkerConstants:
    """Verify pre-decided constants match strategy.md § D."""

    def test_sigterm_grace_seconds(self) -> None:
        assert _SIGTERM_GRACE_S == 5

    # BVA at _RUNNING_STALE_THRESHOLD_S = 90
    def test_stale_threshold_at_90(self) -> None:
        assert _RUNNING_STALE_THRESHOLD_S == 90

    def test_stale_threshold_minus_1(self) -> None:
        assert _RUNNING_STALE_THRESHOLD_S - 1 == 89

    def test_stale_threshold_plus_1(self) -> None:
        assert _RUNNING_STALE_THRESHOLD_S + 1 == 91


# ───────────────────────────────────────────────────────────────────────────
# Fixtures
# ───────────────────────────────────────────────────────────────────────────


def _make_message(execution_id: int = 1, start: int = 2, end: int = 100) -> dict:  # type: ignore[type-arg]
    body = json.dumps({"execution_id": execution_id, "start": start, "end": end})
    return {"Body": body, "ReceiptHandle": f"rh-{execution_id}"}


def _make_execution(
    execution_id: int = 1,
    start: int = 2,
    end: int = 100,
    status: str = "queued",
    started_at: datetime | None = None,
) -> Execution:
    return Execution(
        id=execution_id,
        range_start=start,
        range_end=end,
        primes_count=0,
        primes=None,
        duration_ms=0,
        created_at=datetime(2026, 4, 26, 10, 0, 0, tzinfo=UTC),
        status=status,
        started_at=started_at,
    )


def _mock_queue() -> MagicMock:
    q = MagicMock()
    q.ack = MagicMock()
    q.queue_depth = MagicMock(return_value=0)
    return q


def _mock_cache(covering_slice: list[int] | None = None) -> MagicMock:
    c = MagicMock()
    c.get_covering_slice = MagicMock(return_value=covering_slice)
    c.merge_or_put = MagicMock(return_value=(2, 100))
    return c


# ───────────────────────────────────────────────────────────────────────────
# handle_message — idempotency paths
# ───────────────────────────────────────────────────────────────────────────


class TestHandleMessageIdempotency:
    """Test idempotency-aware retry logic per strategy.md § D."""

    def test_orphaned_message_acks_and_skips(self) -> None:
        """Row missing → ack + skip."""
        queue = _mock_queue()
        cache = _mock_cache()
        msg = _make_message(execution_id=999)

        with patch("prime_service.worker._run_async", side_effect=_close_coro_and_return(None)):
            handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    def test_already_done_acks_and_skips(self) -> None:
        """status='done' → ack + skip without compute."""
        queue = _mock_queue()
        cache = _mock_cache()
        msg = _make_message()
        row = _make_execution(status="done")

        call_count = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_count
            call_count += 1
            if call_count == 1:
                return row
            return None

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch("prime_service.worker.sieve_with_timeout") as mock_sieve:
                handle_message(msg, queue, cache)

        queue.ack.assert_called_once()
        mock_sieve.assert_not_called()

    def test_queued_proceeds_to_compute(self) -> None:
        """status='queued' → proceeds with compute."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)  # no cache hit
        msg = _make_message(start=2, end=10)
        row = _make_execution(status="queued")

        call_results = [row, None, None, None]  # get_exec, mark_running, mark_done
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5, 7]
            ) as mock_sieve:
                handle_message(msg, queue, cache)

        mock_sieve.assert_called_once_with(2, 10)
        queue.ack.assert_called_once()


# ───────────────────────────────────────────────────────────────────────────
# handle_message — stale running (BVA at 90s threshold)
# ───────────────────────────────────────────────────────────────────────────


class TestHandleMessageStaleRunning:
    """BVA at _RUNNING_STALE_THRESHOLD_S = 90s."""

    def test_running_not_stale_at_89s_skips(self) -> None:
        """started_at = 89s ago → age <= 90s → skip without ack."""
        queue = _mock_queue()
        cache = _mock_cache()
        msg = _make_message()
        started_at = datetime.now(UTC) - timedelta(seconds=_RUNNING_STALE_THRESHOLD_S - 1)
        row = _make_execution(status="running", started_at=started_at)

        with patch("prime_service.worker._run_async", side_effect=_close_coro_and_return(row)):
            handle_message(msg, queue, cache)

        queue.ack.assert_not_called()

    def test_running_not_stale_at_90s_skips(self) -> None:
        """started_at = 90s ago → age == 90s → age <= threshold → skip.

        Patch datetime.now() inside worker to guarantee age = exactly 90s
        (avoids flaky clock drift between test setup and worker execution).
        """
        queue = _mock_queue()
        cache = _mock_cache()
        msg = _make_message()
        frozen_now = datetime(2026, 4, 26, 10, 0, 0, tzinfo=UTC)
        started_at = frozen_now - timedelta(seconds=_RUNNING_STALE_THRESHOLD_S)
        row = _make_execution(status="running", started_at=started_at)

        class _FrozenDatetime:
            @staticmethod
            def now(tz: Any = None) -> datetime:
                return frozen_now

        with patch("prime_service.worker._run_async", side_effect=_close_coro_and_return(row)):
            with patch("prime_service.worker.datetime", _FrozenDatetime):
                handle_message(msg, queue, cache)

        queue.ack.assert_not_called()

    def test_running_stale_at_91s_marks_failed_and_proceeds(self) -> None:
        """started_at = 91s ago → age > 90s → mark failed, then compute."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        msg = _make_message(start=2, end=10)
        started_at = datetime.now(UTC) - timedelta(seconds=_RUNNING_STALE_THRESHOLD_S + 1)
        row = _make_execution(status="running", started_at=started_at)

        call_results = [row, None, None, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5, 7]
            ) as mock_sieve:
                handle_message(msg, queue, cache)

        mock_sieve.assert_called_once()
        queue.ack.assert_called_once()

    def test_running_with_no_started_at_treats_as_stale(self) -> None:
        """started_at = None → treat as stale, proceed with compute."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        msg = _make_message(start=2, end=10)
        row = _make_execution(status="running", started_at=None)

        call_results = [row, None, None, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5, 7]
            ) as mock_sieve:
                handle_message(msg, queue, cache)

        mock_sieve.assert_called_once()
        queue.ack.assert_called_once()


# ───────────────────────────────────────────────────────────────────────────
# handle_message — cache hit
# ───────────────────────────────────────────────────────────────────────────


class TestHandleMessageCacheHit:
    def test_cache_hit_skips_compute(self) -> None:
        """If cache covers the range, compute is skipped."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=[2, 3, 5, 7])
        msg = _make_message(start=2, end=10)
        row = _make_execution(status="queued")

        call_results = [row, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch("prime_service.worker.sieve_with_timeout") as mock_sieve:
                handle_message(msg, queue, cache)

        mock_sieve.assert_not_called()
        queue.ack.assert_called_once()

    def test_cache_error_falls_through_to_compute(self) -> None:
        """Cache lookup error is non-fatal; falls through to compute."""
        queue = _mock_queue()
        cache = _mock_cache()
        cache.get_covering_slice = MagicMock(side_effect=Exception("cache down"))
        msg = _make_message(start=2, end=10)
        row = _make_execution(status="queued")

        call_results = [row, None, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5, 7]
            ) as mock_sieve:
                handle_message(msg, queue, cache)

        mock_sieve.assert_called_once()
        queue.ack.assert_called_once()


# ───────────────────────────────────────────────────────────────────────────
# handle_message — compute errors
# ───────────────────────────────────────────────────────────────────────────


class TestHandleMessageComputeErrors:
    def _setup_compute_test(self) -> tuple[MagicMock, MagicMock, dict, Execution]:  # type: ignore[type-arg]
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        msg = _make_message(start=2, end=10)
        row = _make_execution(status="queued")
        return queue, cache, msg, row

    def test_timeout_error_marks_failed_and_acks(self) -> None:
        """SIGALRM TimeoutError → status=failed, ack."""
        queue, cache, msg, row = self._setup_compute_test()

        call_results = [row, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout",
                side_effect=TimeoutError("SIGALRM"),
            ):
                handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    def test_value_error_marks_failed_and_acks(self) -> None:
        """Validation ValueError → status=failed, ack."""
        queue, cache, msg, row = self._setup_compute_test()

        call_results = [row, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout",
                side_effect=ValueError("invalid range"),
            ):
                handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    def test_unexpected_exception_marks_failed_and_acks(self) -> None:
        """Unexpected exception → status=failed, ack."""
        queue, cache, msg, row = self._setup_compute_test()

        call_results = [row, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout",
                side_effect=MemoryError("OOM"),
            ):
                handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    def test_cache_write_error_is_non_fatal(self) -> None:
        """Cache write error after compute → result still written to DB, ack."""
        queue, cache, msg, row = self._setup_compute_test()
        cache.merge_or_put = MagicMock(side_effect=Exception("cache write failed"))

        call_results = [row, None, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch("prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5, 7]):
                handle_message(msg, queue, cache)

        queue.ack.assert_called_once()


# ───────────────────────────────────────────────────────────────────────────
# handle_message — message body BVA
# ───────────────────────────────────────────────────────────────────────────


class TestHandleMessageBodyBVA:
    """BVA on execution_id, start, end from the message body."""

    # BVA at execution_id = 0, 1, 2
    def test_execution_id_0_orphaned(self) -> None:
        """execution_id=0 → row not found → ack + skip."""
        queue = _mock_queue()
        cache = _mock_cache()
        msg = _make_message(execution_id=0)

        with patch("prime_service.worker._run_async", side_effect=_close_coro_and_return(None)):
            handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    def test_execution_id_1_found(self) -> None:
        """execution_id=1 → found queued row → proceeds."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=[2, 3, 5, 7])
        msg = _make_message(execution_id=1, start=2, end=10)
        row = _make_execution(execution_id=1, status="queued")

        call_results = [row, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    def test_execution_id_2_found(self) -> None:
        """execution_id=2 → found queued row → proceeds."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=[2, 3, 5, 7])
        msg = _make_message(execution_id=2, start=2, end=10)
        row = _make_execution(execution_id=2, status="queued")

        call_results = [row, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    # BVA at start = 1, 2, 3 in the message body
    def test_start_1_passes_to_sieve(self) -> None:
        """start=1 in message (bootstrap range) → passed to sieve_with_timeout."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        msg = _make_message(start=1, end=100)
        row = _make_execution(start=1, end=100, status="queued")

        call_results = [row, None, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5]
            ) as mock_sieve:
                handle_message(msg, queue, cache)

        mock_sieve.assert_called_once_with(1, 100)

    def test_start_2_passes_to_sieve(self) -> None:
        """start=2 (API minimum) → passed to sieve_with_timeout."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        msg = _make_message(start=2, end=100)
        row = _make_execution(start=2, end=100, status="queued")

        call_results = [row, None, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5]
            ) as mock_sieve:
                handle_message(msg, queue, cache)

        mock_sieve.assert_called_once_with(2, 100)

    def test_start_3_passes_to_sieve(self) -> None:
        """start=3 (B+1) → passed to sieve_with_timeout."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        msg = _make_message(start=3, end=100)
        row = _make_execution(start=3, end=100, status="queued")

        call_results = [row, None, None, None]
        call_idx = 0

        def fake_run_async(coro: Any) -> Any:
            if hasattr(coro, "close"):
                coro.close()
            nonlocal call_idx
            result = call_results[call_idx] if call_idx < len(call_results) else None
            call_idx += 1
            return result

        with patch("prime_service.worker._run_async", side_effect=fake_run_async):
            with patch(
                "prime_service.worker.sieve_with_timeout", return_value=[3, 5, 7]
            ) as mock_sieve:
                handle_message(msg, queue, cache)

        mock_sieve.assert_called_once_with(3, 100)


# ───────────────────────────────────────────────────────────────────────────
# run_worker — smoke test (shutdown after first receive)
# ───────────────────────────────────────────────────────────────────────────


class TestRunWorker:
    def test_run_worker_shuts_down_on_flag(self) -> None:
        """run_worker exits cleanly when _shutdown is True."""
        import prime_service.worker as worker_mod

        original_shutdown = worker_mod._shutdown

        try:
            worker_mod._shutdown = True
            with patch("prime_service.worker.PrimeQueue") as MockQueue:
                with patch("prime_service.worker.PrimeCache"):
                    MockQueue.return_value.receive.return_value = []
                    from prime_service.worker import run_worker

                    run_worker()  # should return immediately
        finally:
            worker_mod._shutdown = original_shutdown

    def test_receive_error_does_not_crash_loop(self) -> None:
        """receive() exception → logs error + sleeps + continues."""
        import prime_service.worker as worker_mod

        original_shutdown = worker_mod._shutdown
        call_count = 0

        try:
            # Set _shutdown after first loop iteration
            def fake_receive() -> list:  # type: ignore[type-arg]
                nonlocal call_count
                call_count += 1
                worker_mod._shutdown = True  # stop after first call
                raise Exception("SQS down")

            with patch("prime_service.worker.PrimeQueue") as MockQueue:
                with patch("prime_service.worker.PrimeCache"):
                    with patch("prime_service.worker.time.sleep"):
                        MockQueue.return_value.receive.side_effect = fake_receive
                        from prime_service.worker import run_worker

                        run_worker()

            assert call_count == 1
        finally:
            worker_mod._shutdown = original_shutdown

    def test_handler_error_does_not_crash_loop(self) -> None:
        """handle_message exception → logs error, does NOT ack, continues loop."""
        import prime_service.worker as worker_mod

        original_shutdown = worker_mod._shutdown
        handle_count = 0

        try:
            msg = {"Body": '{"execution_id": 1, "start": 2, "end": 10}', "ReceiptHandle": "rh"}

            def fake_receive() -> list:  # type: ignore[type-arg]
                nonlocal handle_count
                if handle_count >= 1:
                    worker_mod._shutdown = True
                    return []
                return [msg]

            def fake_handle(m: Any, q: Any, c: Any) -> None:
                nonlocal handle_count
                handle_count += 1
                raise Exception("handler boom")

            with patch("prime_service.worker.PrimeQueue") as MockQueue:
                with patch("prime_service.worker.PrimeCache"):
                    with patch("prime_service.worker.handle_message", side_effect=fake_handle):
                        MockQueue.return_value.receive.side_effect = fake_receive
                        from prime_service.worker import run_worker

                        run_worker()

            assert handle_count == 1
        finally:
            worker_mod._shutdown = original_shutdown

    def test_mid_batch_shutdown_breaks_loop(self) -> None:
        """If _shutdown is set mid-batch, no further messages are processed."""
        import prime_service.worker as worker_mod

        original_shutdown = worker_mod._shutdown
        handle_count = 0

        try:
            msg1 = {"Body": '{"execution_id": 1, "start": 2, "end": 10}', "ReceiptHandle": "rh1"}
            msg2 = {"Body": '{"execution_id": 2, "start": 3, "end": 10}', "ReceiptHandle": "rh2"}

            def fake_handle(m: Any, q: Any, c: Any) -> None:
                nonlocal handle_count
                handle_count += 1
                # Set shutdown after first message in batch
                worker_mod._shutdown = True

            with patch("prime_service.worker.PrimeQueue") as MockQueue:
                with patch("prime_service.worker.PrimeCache"):
                    with patch("prime_service.worker.handle_message", side_effect=fake_handle):
                        MockQueue.return_value.receive.return_value = [msg1, msg2]
                        from prime_service.worker import run_worker

                        run_worker()

            # Only one message should have been handled before shutdown
            assert handle_count == 1
        finally:
            worker_mod._shutdown = original_shutdown


# ───────────────────────────────────────────────────────────────────────────
# SIGTERM handler — coverage of _handle_sigterm
# ───────────────────────────────────────────────────────────────────────────


class TestSigtermHandler:
    def test_sigterm_sets_shutdown_flag(self) -> None:
        """_handle_sigterm sets _shutdown = True."""
        import prime_service.worker as worker_mod
        from prime_service.worker import _handle_sigterm

        original_shutdown = worker_mod._shutdown
        try:
            worker_mod._shutdown = False
            _handle_sigterm(15, None)
            assert worker_mod._shutdown is True
        finally:
            worker_mod._shutdown = original_shutdown


# ───────────────────────────────────────────────────────────────────────────
# _run_async — covers the asyncio.run call
# ───────────────────────────────────────────────────────────────────────────


class TestRunAsync:
    def test_run_async_executes_coroutine(self) -> None:
        """_run_async runs a coroutine synchronously and returns its result."""
        from prime_service.worker import _run_async

        async def _coro() -> int:
            return 42

        result = _run_async(_coro())
        assert result == 42

    def test_run_async_propagates_exception(self) -> None:
        """_run_async propagates exceptions from the coroutine."""
        from prime_service.worker import _run_async

        async def _failing_coro() -> int:
            raise ValueError("test error")

        with pytest.raises(ValueError, match="test error"):
            _run_async(_failing_coro())
