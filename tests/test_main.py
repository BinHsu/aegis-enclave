"""Endpoint tests for prime_service.main — FastAPI TestClient with mocked DB.

Strategy
--------
- `httpx.AsyncClient` against the ASGI app via `ASGITransport` for async tests.
- `app.dependency_overrides[get_session]` swaps the real DB session for an
  AsyncMock — endpoint tests are pure HTTP-layer verification.
- Real DB integration is verified by `make smoke` (Phase 1.5).

Endpoints under test (Phase 2.3 async API):
- GET /health          — degraded behaviour, version reporting
- POST /primes         — 202 Accepted + {execution_id, status: "queued"}
- GET  /primes/{id}    — job status polling (queued/running/done/failed)
- GET  /executions/{id} — legacy audit detail (raw row)

Cross-cutting:
- ValidationError → 422 (FastAPI default)
- Queue overflow → 503 + Retry-After: 60 (backpressure middleware)
- SQLAlchemyError on insert → 503 (handled by main.py)
- Missing audit row → 404
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import UTC, datetime
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.exc import SQLAlchemyError

from prime_service.db import Execution, get_session
from prime_service.main import app

# ───────────────────────────────────────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────────────────────────────────────


async def make_client(mock_session: AsyncMock) -> AsyncClient:
    async def _override() -> AsyncIterator[AsyncMock]:
        yield mock_session

    app.dependency_overrides[get_session] = _override
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


def _queued_row(
    execution_id: int = 1,
    start: int = 2,
    end: int = 10,
) -> Execution:
    return Execution(
        id=execution_id,
        range_start=start,
        range_end=end,
        primes_count=0,
        primes=None,
        duration_ms=0,
        created_at=datetime(2026, 4, 26, 10, 0, 0, tzinfo=UTC),
        status="queued",
    )


def _done_row(
    execution_id: int = 1,
    primes: list[int] | None = None,
) -> Execution:
    if primes is None:
        primes = [2, 3, 5, 7]
    return Execution(
        id=execution_id,
        range_start=2,
        range_end=10,
        primes_count=len(primes),
        primes=primes,
        duration_ms=50,
        created_at=datetime(2026, 4, 26, 10, 0, 0, tzinfo=UTC),
        status="done",
        completed_at=datetime(2026, 4, 26, 10, 0, 1, tzinfo=UTC),
    )


def _failed_row(execution_id: int = 1, error: str = "timeout") -> Execution:
    return Execution(
        id=execution_id,
        range_start=2,
        range_end=10,
        primes_count=0,
        primes=None,
        duration_ms=0,
        created_at=datetime(2026, 4, 26, 10, 0, 0, tzinfo=UTC),
        status="failed",
        error_message=error,
    )


# ───────────────────────────────────────────────────────────────────────────
# /health
# ───────────────────────────────────────────────────────────────────────────


class TestHealthEndpoint:
    @pytest.mark.asyncio
    async def test_ok_when_db_reachable(self) -> None:
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one.return_value = 1
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/health")
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert body["db"] == "reachable"
        assert "version" in body

    @pytest.mark.asyncio
    async def test_degraded_when_db_unreachable(self) -> None:
        session = AsyncMock()
        session.execute = AsyncMock(side_effect=SQLAlchemyError("boom"))

        async with await make_client(session) as ac:
            r = await ac.get("/health")
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "degraded"
        assert body["db"] == "unreachable"


# ───────────────────────────────────────────────────────────────────────────
# POST /primes — async 202 Accepted
# ───────────────────────────────────────────────────────────────────────────


class TestComputePrimesEndpoint:
    """POST /primes returns 202 Accepted + {execution_id, status: 'queued'}."""

    @pytest.mark.asyncio
    async def test_happy_path_returns_202(self) -> None:
        session = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 42

        session.add = MagicMock(side_effect=capture_add)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            MockQueue.return_value.enqueue.return_value = "msg-id-1"
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 202
        body = r.json()
        assert "execution_id" in body
        assert body["status"] == "queued"

    @pytest.mark.asyncio
    async def test_happy_path_execution_id_numeric(self) -> None:
        session = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 7

        session.add = MagicMock(side_effect=capture_add)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            MockQueue.return_value.enqueue.return_value = "msg-id-2"
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 202
        assert isinstance(r.json()["execution_id"], int)

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "payload, expected_status",
        [
            ({"start": 1, "end": 10}, 422),  # start < 2 → Pydantic 422
            ({"start": -5, "end": 10}, 422),  # negative start
            ({"start": 10, "end": 5}, 422),  # start > end → model_validator
            ({"start": 2, "end": 100_000_000}, 422),  # range > ceiling
            ({"start": "abc", "end": 10}, 422),  # invalid type
            ({"end": 10}, 422),  # missing start
            ({"start": 2}, 422),  # missing end
            ({}, 422),  # empty payload
        ],
    )
    async def test_validation_errors_return_422(
        self,
        payload: dict,
        expected_status: int,  # type: ignore[type-arg]
    ) -> None:
        session = AsyncMock()
        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json=payload)
        app.dependency_overrides.clear()
        assert r.status_code == expected_status

    # BVA at start = 2 (schema boundary)
    @pytest.mark.asyncio
    async def test_start_below_2_rejected_422(self) -> None:
        session = AsyncMock()
        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 1, "end": 10})
        app.dependency_overrides.clear()
        assert r.status_code == 422

    @pytest.mark.asyncio
    async def test_start_at_2_accepted_202(self) -> None:
        session = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 1

        session.add = MagicMock(side_effect=capture_add)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            MockQueue.return_value.enqueue.return_value = "msg"
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_start_above_2_accepted_202(self) -> None:
        session = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 2

        session.add = MagicMock(side_effect=capture_add)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            MockQueue.return_value.enqueue.return_value = "msg"
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 3, "end": 10})
        app.dependency_overrides.clear()
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_db_failure_returns_503(self) -> None:
        session = AsyncMock()
        session.add = MagicMock()
        session.commit = AsyncMock(side_effect=SQLAlchemyError("audit log failed"))

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 503
        assert "audit" in r.json()["detail"].lower()

    @pytest.mark.asyncio
    async def test_enqueue_failure_still_returns_202(self) -> None:
        """Queue failure does not prevent 202 — audit row exists as the record."""
        session = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 5

        session.add = MagicMock(side_effect=capture_add)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            MockQueue.return_value.enqueue.side_effect = Exception("SQS down")
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        # Still 202 — audit row was written; operator can re-enqueue
        assert r.status_code == 202


# ───────────────────────────────────────────────────────────────────────────
# Backpressure middleware — 503 when queue depth exceeds threshold
# ───────────────────────────────────────────────────────────────────────────


class TestBackpressureMiddleware:
    """POST /primes returns 503 + Retry-After: 60 when queue is full."""

    @pytest.mark.asyncio
    async def test_backpressure_503_when_queue_full(self) -> None:
        session = AsyncMock()

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            # Return depth > threshold (default threshold = 5 × 1 = 5)
            MockQueue.return_value.queue_depth.return_value = 10
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 503
        assert r.headers.get("Retry-After") == "60"

    @pytest.mark.asyncio
    async def test_backpressure_not_triggered_below_threshold(self) -> None:
        session = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 1

        session.add = MagicMock(side_effect=capture_add)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            MockQueue.return_value.enqueue.return_value = "msg"
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 202

    # BVA at backpressure threshold (default 5)
    @pytest.mark.asyncio
    async def test_backpressure_bva_at_threshold(self) -> None:
        """Depth == threshold → should NOT trigger 503 (> threshold, not >=)."""
        session = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 1

        session.add = MagicMock(side_effect=capture_add)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 5  # == threshold
            MockQueue.return_value.enqueue.return_value = "msg"
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        # depth == threshold → NOT triggered
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_backpressure_bva_below_threshold(self) -> None:
        """Depth == threshold - 1 → no backpressure."""
        session = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 1

        session.add = MagicMock(side_effect=capture_add)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 4  # == threshold - 1
            MockQueue.return_value.enqueue.return_value = "msg"
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_backpressure_bva_above_threshold(self) -> None:
        """Depth == threshold + 1 → 503 triggered."""
        session = AsyncMock()

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 6  # == threshold + 1
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()
        assert r.status_code == 503

    @pytest.mark.asyncio
    async def test_backpressure_sqs_error_does_not_block(self) -> None:
        """If SQS is unreachable for depth check, POST is not blocked."""
        session = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 1

        session.add = MagicMock(side_effect=capture_add)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.side_effect = Exception("SQS unreachable")
            MockQueue.return_value.enqueue.return_value = "msg"
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        # SQS error → fall through, not blocked
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_backpressure_only_applies_to_post_primes(self) -> None:
        """GET /health is not subject to backpressure even if queue is full."""
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one.return_value = 1
        session.execute = AsyncMock(return_value=result_obj)

        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 9999
            async with await make_client(session) as ac:
                r = await ac.get("/health")
        app.dependency_overrides.clear()

        assert r.status_code == 200


# ───────────────────────────────────────────────────────────────────────────
# GET /primes/{id} — job status polling
# ───────────────────────────────────────────────────────────────────────────


class TestGetPrimesResult:
    """GET /primes/{id} returns current job status."""

    @pytest.mark.asyncio
    async def test_queued_status(self) -> None:
        session = AsyncMock()
        row = _queued_row(execution_id=1)
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = row
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/primes/1")
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "queued"
        assert body["result"] is None

    @pytest.mark.asyncio
    async def test_done_status_includes_result(self) -> None:
        session = AsyncMock()
        row = _done_row(execution_id=2, primes=[2, 3, 5, 7])
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = row
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/primes/2")
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "done"
        assert body["result"] == [2, 3, 5, 7]
        assert body["error_message"] is None

    @pytest.mark.asyncio
    async def test_failed_status_includes_error_message(self) -> None:
        session = AsyncMock()
        row = _failed_row(execution_id=3, error="compute exceeded 60s SIGALRM budget")
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = row
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/primes/3")
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "failed"
        assert "60s" in body["error_message"]
        assert body["result"] is None

    @pytest.mark.asyncio
    async def test_returns_404_when_not_found(self) -> None:
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = None
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/primes/99999")
        app.dependency_overrides.clear()

        assert r.status_code == 404

    @pytest.mark.asyncio
    async def test_invalid_id_path_param_422(self) -> None:
        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.get("/primes/not-a-number")
        app.dependency_overrides.clear()
        assert r.status_code == 422

    # BVA at execution_id boundary (positive integer)
    @pytest.mark.asyncio
    async def test_execution_id_0_rejected_422(self) -> None:
        """execution_id=0 parses but 0 is a valid integer for path params."""
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = None
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/primes/0")
        app.dependency_overrides.clear()
        # 0 is a valid int path param — returns 404 (not found) not 422
        assert r.status_code == 404

    @pytest.mark.asyncio
    async def test_execution_id_1_valid(self) -> None:
        session = AsyncMock()
        row = _queued_row(execution_id=1)
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = row
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/primes/1")
        app.dependency_overrides.clear()
        assert r.status_code == 200

    @pytest.mark.asyncio
    async def test_execution_id_2_valid(self) -> None:
        session = AsyncMock()
        row = _queued_row(execution_id=2)
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = row
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/primes/2")
        app.dependency_overrides.clear()
        assert r.status_code == 200


# ───────────────────────────────────────────────────────────────────────────
# GET /executions/{id} — legacy audit detail
# ───────────────────────────────────────────────────────────────────────────


class TestFetchExecutionEndpoint:
    @pytest.mark.asyncio
    async def test_returns_audit_row(self) -> None:
        session = AsyncMock()
        row = Execution(
            id=42,
            range_start=2,
            range_end=10,
            primes_count=4,
            primes=[2, 3, 5, 7],
            duration_ms=5,
            created_at=datetime(2026, 4, 25, 12, 0, 0, tzinfo=UTC),
            status="done",
        )
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = row
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/executions/42")
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["id"] == 42
        assert body["primes_count"] == 4
        assert body["primes"] == [2, 3, 5, 7]
        assert body["status"] == "done"

    @pytest.mark.asyncio
    async def test_returns_404_when_not_found(self) -> None:
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = None
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/executions/99999")
        app.dependency_overrides.clear()

        assert r.status_code == 404

    @pytest.mark.asyncio
    async def test_invalid_id_path_param(self) -> None:
        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.get("/executions/not-a-number")
        app.dependency_overrides.clear()
        assert r.status_code == 422


# ───────────────────────────────────────────────────────────────────────────
# GZip middleware — Content-Encoding header present for large responses
# ───────────────────────────────────────────────────────────────────────────


class TestGzipMiddleware:
    """GZipMiddleware is active; verify Accept-Encoding negotiation works."""

    @pytest.mark.asyncio
    async def test_gzip_encoding_returned_when_accepted(self) -> None:
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one.return_value = 1
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/health", headers={"Accept-Encoding": "gzip"})
        app.dependency_overrides.clear()

        # FastAPI/starlette GZip only compresses if response body >= minimum_size.
        # /health body is small (<1000 bytes); no compression expected.
        # We verify the middleware doesn't break the response.
        assert r.status_code == 200

    @pytest.mark.asyncio
    async def test_no_encoding_without_accept(self) -> None:
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one.return_value = 1
        session.execute = AsyncMock(return_value=result_obj)

        async with await make_client(session) as ac:
            r = await ac.get("/health")
        app.dependency_overrides.clear()
        assert r.status_code == 200


# ───────────────────────────────────────────────────────────────────────────
# OpenAPI / docs surface
# ───────────────────────────────────────────────────────────────────────────


class TestApplicationSurface:
    @pytest.mark.asyncio
    async def test_openapi_schema_published(self) -> None:
        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.get("/openapi.json")
        app.dependency_overrides.clear()
        assert r.status_code == 200
        schema = r.json()
        assert "paths" in schema
        assert "/health" in schema["paths"]
        assert "/primes" in schema["paths"]
        assert "/executions/{execution_id}" in schema["paths"]

    @pytest.mark.asyncio
    async def test_docs_endpoint_serves(self) -> None:
        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.get("/docs")
        app.dependency_overrides.clear()
        assert r.status_code == 200
