"""Unit tests for prime_service.worker — SQS consumer loop.

Strategy
--------
- All I/O (DynamoDB, SQS, cache) is mocked — worker tests are pure unit tests.
- handle_message is the focal function; idempotency and SIGALRM paths
  are the primary BVA targets.
- BVA on the stale-running threshold (90s): message at 89s, 90s, 91s.
- BVA on handle_message input: valid message, missing body fields,
  orphaned execution, already-done execution.
- run_worker is tested via a shutdown-triggered smoke (sets _shutdown=True
  after one iteration).

DynamoDB pivot (ADR-0042):
- execution_id is now a UUID4 string (not int).
- DB helpers (get_execution, mark_running, mark_done, mark_failed) are
  synchronous boto3 calls; no asyncio.run() wrapping needed.
- Messages carry execution_id as a string UUID.
"""

from __future__ import annotations

import json
import time
import uuid
from datetime import UTC, datetime
from typing import Any
from unittest.mock import MagicMock, patch

from prime_service.worker import (
    _RUNNING_STALE_THRESHOLD_S,
    _SIGTERM_GRACE_S,
    handle_message,
)


def _make_uuid() -> str:
    return str(uuid.uuid4())


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


def _make_message(
    execution_id: str | None = None,
    start: int = 2,
    end: int = 100,
) -> dict[str, Any]:
    eid = execution_id or _make_uuid()
    body = json.dumps({"execution_id": eid, "start": start, "end": end})
    return {"Body": body, "ReceiptHandle": f"rh-{eid}"}


def _make_item(
    execution_id: str | None = None,
    start: int = 2,
    end: int = 100,
    status: str = "queued",
    started_at: int | None = None,
) -> dict[str, Any]:
    eid = execution_id or _make_uuid()
    item: dict[str, Any] = {
        "execution_id": eid,
        "status": status,
        "range_start": start,
        "range_end": end,
        "created_at": 1745654400,
    }
    if started_at is not None:
        item["started_at"] = started_at
    return item


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
        eid = _make_uuid()
        msg = _make_message(execution_id=eid)

        with patch("prime_service.worker.get_execution", return_value=None):
            handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    def test_already_done_acks_and_skips(self) -> None:
        """status='done' → ack + skip without compute."""
        queue = _mock_queue()
        cache = _mock_cache()
        eid = _make_uuid()
        msg = _make_message(execution_id=eid)
        item = _make_item(execution_id=eid, status="done")

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.sieve_with_timeout") as mock_sieve:
                handle_message(msg, queue, cache)

        queue.ack.assert_called_once()
        mock_sieve.assert_not_called()

    def test_queued_proceeds_to_compute(self) -> None:
        """status='queued' → proceeds with compute."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)  # no cache hit
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=2, end=10)
        item = _make_item(execution_id=eid, status="queued")

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_done"):
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
        eid = _make_uuid()
        msg = _make_message(execution_id=eid)
        started_at_epoch = int(time.time()) - (_RUNNING_STALE_THRESHOLD_S - 1)
        item = _make_item(execution_id=eid, status="running", started_at=started_at_epoch)

        with patch("prime_service.worker.get_execution", return_value=item):
            handle_message(msg, queue, cache)

        queue.ack.assert_not_called()

    def test_running_not_stale_at_90s_skips(self) -> None:
        """started_at = 90s ago → age == 90s → age <= threshold → skip.

        Freeze time to guarantee age = exactly 90s.
        """
        queue = _mock_queue()
        cache = _mock_cache()
        eid = _make_uuid()
        msg = _make_message(execution_id=eid)
        frozen_epoch = 1745654400
        started_at_epoch = frozen_epoch - _RUNNING_STALE_THRESHOLD_S  # exactly 90s ago
        item = _make_item(execution_id=eid, status="running", started_at=started_at_epoch)

        class _FrozenDatetime:
            @staticmethod
            def now(tz: Any = None) -> datetime:
                return datetime.fromtimestamp(frozen_epoch, tz=UTC)

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.datetime", _FrozenDatetime):
                handle_message(msg, queue, cache)

        queue.ack.assert_not_called()

    def test_running_stale_at_91s_marks_failed_and_proceeds(self) -> None:
        """started_at = 91s ago → age > 90s → mark failed, then compute."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=2, end=10)
        started_at_epoch = int(time.time()) - (_RUNNING_STALE_THRESHOLD_S + 1)
        item = _make_item(execution_id=eid, status="running", started_at=started_at_epoch)

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_failed") as mock_fail:
                with patch("prime_service.worker.mark_running"):
                    with patch("prime_service.worker.mark_done"):
                        with patch(
                            "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5, 7]
                        ) as mock_sieve:
                            handle_message(msg, queue, cache)

        mock_fail.assert_called_once()
        mock_sieve.assert_called_once()
        queue.ack.assert_called_once()

    def test_running_with_no_started_at_treats_as_stale(self) -> None:
        """started_at = None → treat as stale, proceed with compute."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=2, end=10)
        item = _make_item(execution_id=eid, status="running", started_at=None)

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_failed") as mock_fail:
                with patch("prime_service.worker.mark_running"):
                    with patch("prime_service.worker.mark_done"):
                        with patch(
                            "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5, 7]
                        ) as mock_sieve:
                            handle_message(msg, queue, cache)

        mock_fail.assert_called_once()
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
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=2, end=10)
        item = _make_item(execution_id=eid, status="queued")

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_done"):
                    with patch("prime_service.worker.sieve_with_timeout") as mock_sieve:
                        handle_message(msg, queue, cache)

        mock_sieve.assert_not_called()
        queue.ack.assert_called_once()

    def test_cache_error_falls_through_to_compute(self) -> None:
        """Cache lookup error is non-fatal; falls through to compute."""
        queue = _mock_queue()
        cache = _mock_cache()
        cache.get_covering_slice = MagicMock(side_effect=Exception("cache down"))
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=2, end=10)
        item = _make_item(execution_id=eid, status="queued")

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_done"):
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
    def _setup_compute_test(
        self,
    ) -> tuple[MagicMock, MagicMock, dict[str, Any], dict[str, Any]]:
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=2, end=10)
        item = _make_item(execution_id=eid, status="queued")
        return queue, cache, msg, item

    def test_timeout_error_marks_failed_and_acks(self) -> None:
        """SIGALRM TimeoutError → status=failed, ack."""
        queue, cache, msg, item = self._setup_compute_test()

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_failed") as mock_fail:
                    with patch(
                        "prime_service.worker.sieve_with_timeout",
                        side_effect=TimeoutError("SIGALRM"),
                    ):
                        handle_message(msg, queue, cache)

        queue.ack.assert_called_once()
        mock_fail.assert_called_once()

    def test_value_error_marks_failed_and_acks(self) -> None:
        """Validation ValueError → status=failed, ack."""
        queue, cache, msg, item = self._setup_compute_test()

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_failed") as mock_fail:
                    with patch(
                        "prime_service.worker.sieve_with_timeout",
                        side_effect=ValueError("invalid range"),
                    ):
                        handle_message(msg, queue, cache)

        queue.ack.assert_called_once()
        mock_fail.assert_called_once()

    def test_unexpected_exception_marks_failed_and_acks(self) -> None:
        """Unexpected exception → status=failed, ack."""
        queue, cache, msg, item = self._setup_compute_test()

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_failed") as mock_fail:
                    with patch(
                        "prime_service.worker.sieve_with_timeout",
                        side_effect=MemoryError("OOM"),
                    ):
                        handle_message(msg, queue, cache)

        queue.ack.assert_called_once()
        mock_fail.assert_called_once()

    def test_cache_write_error_is_non_fatal(self) -> None:
        """Cache write error after compute → result still written to DB, ack."""
        queue, cache, msg, item = self._setup_compute_test()
        cache.merge_or_put = MagicMock(side_effect=Exception("cache write failed"))

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_done"):
                    with patch(
                        "prime_service.worker.sieve_with_timeout",
                        return_value=[2, 3, 5, 7],
                    ):
                        handle_message(msg, queue, cache)

        queue.ack.assert_called_once()


# ───────────────────────────────────────────────────────────────────────────
# handle_message — message body BVA (UUID4 execution_id)
# ───────────────────────────────────────────────────────────────────────────


class TestHandleMessageBodyBVA:
    """BVA on execution_id (UUID string), start, end from the message body."""

    # BVA: zero UUID → orphaned (not in table)
    def test_zero_uuid_orphaned(self) -> None:
        """execution_id=zero_uuid → row not found → ack + skip."""
        queue = _mock_queue()
        cache = _mock_cache()
        zero_uuid = "00000000-0000-0000-0000-000000000000"
        msg = _make_message(execution_id=zero_uuid)

        with patch("prime_service.worker.get_execution", return_value=None):
            handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    def test_valid_uuid_found(self) -> None:
        """execution_id=valid UUID → found queued row → proceeds."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=[2, 3, 5, 7])
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=2, end=10)
        item = _make_item(execution_id=eid, status="queued")

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_done"):
                    handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    def test_another_valid_uuid_found(self) -> None:
        """Another UUID → found queued row → proceeds."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=[2, 3, 5, 7])
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=2, end=10)
        item = _make_item(execution_id=eid, status="queued")

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_done"):
                    handle_message(msg, queue, cache)

        queue.ack.assert_called_once()

    # BVA at start = 1, 2, 3 in the message body
    def test_start_1_passes_to_sieve(self) -> None:
        """start=1 in message (bootstrap range) → passed to sieve_with_timeout."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=1, end=100)
        item = _make_item(execution_id=eid, start=1, end=100, status="queued")

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_done"):
                    with patch(
                        "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5]
                    ) as mock_sieve:
                        handle_message(msg, queue, cache)

        mock_sieve.assert_called_once_with(1, 100)

    def test_start_2_passes_to_sieve(self) -> None:
        """start=2 (API minimum) → passed to sieve_with_timeout."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=2, end=100)
        item = _make_item(execution_id=eid, start=2, end=100, status="queued")

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_done"):
                    with patch(
                        "prime_service.worker.sieve_with_timeout", return_value=[2, 3, 5]
                    ) as mock_sieve:
                        handle_message(msg, queue, cache)

        mock_sieve.assert_called_once_with(2, 100)

    def test_start_3_passes_to_sieve(self) -> None:
        """start=3 (B+1) → passed to sieve_with_timeout."""
        queue = _mock_queue()
        cache = _mock_cache(covering_slice=None)
        eid = _make_uuid()
        msg = _make_message(execution_id=eid, start=3, end=100)
        item = _make_item(execution_id=eid, start=3, end=100, status="queued")

        with patch("prime_service.worker.get_execution", return_value=item):
            with patch("prime_service.worker.mark_running"):
                with patch("prime_service.worker.mark_done"):
                    with patch(
                        "prime_service.worker.sieve_with_timeout", return_value=[3, 5, 7]
                    ) as mock_sieve:
                        handle_message(msg, queue, cache)

        mock_sieve.assert_called_once_with(3, 100)

    def test_execution_id_is_string_not_int_coerced(self) -> None:
        """No int() coercion — execution_id stays as string UUID in all calls."""
        queue = _mock_queue()
        cache = _mock_cache()
        eid = _make_uuid()
        msg = _make_message(execution_id=eid)

        captured_eid: list[str] = []

        def capture_get(execution_id: str) -> dict[str, Any] | None:
            captured_eid.append(execution_id)
            return None  # orphaned

        with patch("prime_service.worker.get_execution", side_effect=capture_get):
            handle_message(msg, queue, cache)

        assert len(captured_eid) == 1
        assert isinstance(captured_eid[0], str)
        assert captured_eid[0] == eid


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
            def fake_receive() -> list[Any]:
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
            eid = _make_uuid()
            msg = {
                "Body": json.dumps({"execution_id": eid, "start": 2, "end": 10}),
                "ReceiptHandle": "rh",
            }

            def fake_receive() -> list[Any]:
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
            eid1 = _make_uuid()
            eid2 = _make_uuid()
            msg1 = {
                "Body": json.dumps({"execution_id": eid1, "start": 2, "end": 10}),
                "ReceiptHandle": "rh1",
            }
            msg2 = {
                "Body": json.dumps({"execution_id": eid2, "start": 3, "end": 10}),
                "ReceiptHandle": "rh2",
            }

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
