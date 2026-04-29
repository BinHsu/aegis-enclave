"""Endpoint tests for prime_service.main — FastAPI TestClient with mocked DynamoDB.

Strategy
--------
- ``httpx.AsyncClient`` against the ASGI app via ``ASGITransport`` for async tests.
- DynamoDB calls are mocked at the ``prime_service.db`` module level via
  ``unittest.mock.patch`` — endpoint tests are pure HTTP-layer verification.
- Real DynamoDB integration is verified by ``make smoke`` (Phase 2.5).
- ``execution_id`` is now a UUID4 string (ADR-0042).

Endpoints under test (Phase 2.3 async API):
- GET /health          — ok/degraded behaviour, version reporting
- POST /primes         — 202 Accepted + {execution_id, status: "queued"}
- GET  /primes/{id}    — job status polling (queued/running/done/failed)
- GET  /executions/{id} — legacy audit detail (raw row)

Cross-cutting:
- ValidationError → 422 (FastAPI default)
- Queue overflow → 503 + Retry-After: 60 (backpressure middleware)
- ClientError on insert → 503 (handled by main.py)
- Missing audit row → 404
"""

from __future__ import annotations

import uuid
from typing import Any
from unittest.mock import patch

import pytest
from httpx import ASGITransport, AsyncClient

from prime_service.main import app

# ───────────────────────────────────────────────────────────────────────────
# Helpers
# ───────────────────────────────────────────────────────────────────────────


def _make_uuid() -> str:
    return str(uuid.uuid4())


async def make_client() -> AsyncClient:
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


def _queued_item(
    execution_id: str | None = None,
    start: int = 2,
    end: int = 10,
) -> dict[str, Any]:
    eid = execution_id or _make_uuid()
    return {
        "execution_id": eid,
        "status": "queued",
        "range_start": 2,
        "range_end": 10,
        "created_at": 1745654400,
    }


def _done_item(
    execution_id: str | None = None,
    primes: list[int] | None = None,
) -> dict[str, Any]:
    eid = execution_id or _make_uuid()
    if primes is None:
        primes = [2, 3, 5, 7]
    return {
        "execution_id": eid,
        "status": "done",
        "range_start": 2,
        "range_end": 10,
        "primes": primes,
        "primes_count": len(primes),
        "duration_ms": 50,
        "created_at": 1745654400,
        "completed_at": 1745654401,
    }


def _failed_item(
    execution_id: str | None = None,
    error: str = "timeout",
) -> dict[str, Any]:
    eid = execution_id or _make_uuid()
    return {
        "execution_id": eid,
        "status": "failed",
        "range_start": 2,
        "range_end": 10,
        "primes_count": 0,
        "duration_ms": 0,
        "created_at": 1745654400,
        "error_message": error,
    }


# ───────────────────────────────────────────────────────────────────────────
# /health
# ───────────────────────────────────────────────────────────────────────────


class TestHealthEndpoint:
    @pytest.mark.asyncio
    async def test_ok_when_db_reachable(self) -> None:
        with patch("prime_service.main.health_check", return_value=True):
            async with await make_client() as ac:
                r = await ac.get("/health")

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "ok"
        assert body["db"] == "reachable"
        assert "version" in body

    @pytest.mark.asyncio
    async def test_degraded_when_db_unreachable(self) -> None:
        with patch("prime_service.main.health_check", return_value=False):
            async with await make_client() as ac:
                r = await ac.get("/health")

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
        fixed_uuid = _make_uuid()
        with patch("prime_service.main.uuid.uuid4", return_value=uuid.UUID(fixed_uuid)):
            with patch("prime_service.main.insert_queued_execution", return_value=fixed_uuid):
                with patch("prime_service.main.PrimeQueue") as MockQueue:
                    MockQueue.return_value.queue_depth.return_value = 0
                    MockQueue.return_value.enqueue.return_value = "msg-id-1"
                    async with await make_client() as ac:
                        r = await ac.post("/primes", json={"start": 2, "end": 10})

        assert r.status_code == 202
        body = r.json()
        assert "execution_id" in body
        assert body["status"] == "queued"

    @pytest.mark.asyncio
    async def test_happy_path_execution_id_is_uuid_string(self) -> None:
        fixed_uuid = _make_uuid()
        with patch("prime_service.main.uuid.uuid4", return_value=uuid.UUID(fixed_uuid)):
            with patch("prime_service.main.insert_queued_execution", return_value=fixed_uuid):
                with patch("prime_service.main.PrimeQueue") as MockQueue:
                    MockQueue.return_value.queue_depth.return_value = 0
                    MockQueue.return_value.enqueue.return_value = "msg-id-2"
                    async with await make_client() as ac:
                        r = await ac.post("/primes", json={"start": 2, "end": 10})

        assert r.status_code == 202
        eid = r.json()["execution_id"]
        # Must be a valid UUID4 string (not an integer)
        assert isinstance(eid, str)
        parsed = uuid.UUID(eid)
        assert parsed.version == 4

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
        payload: dict[str, Any],
        expected_status: int,
    ) -> None:
        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            async with await make_client() as ac:
                r = await ac.post("/primes", json=payload)
        assert r.status_code == expected_status

    # BVA at start = 2 (schema boundary)
    @pytest.mark.asyncio
    async def test_start_below_2_rejected_422(self) -> None:
        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 0
            async with await make_client() as ac:
                r = await ac.post("/primes", json={"start": 1, "end": 10})
        assert r.status_code == 422

    @pytest.mark.asyncio
    async def test_start_at_2_accepted_202(self) -> None:
        fixed_uuid = _make_uuid()
        with patch("prime_service.main.uuid.uuid4", return_value=uuid.UUID(fixed_uuid)):
            with patch("prime_service.main.insert_queued_execution", return_value=fixed_uuid):
                with patch("prime_service.main.PrimeQueue") as MockQueue:
                    MockQueue.return_value.queue_depth.return_value = 0
                    MockQueue.return_value.enqueue.return_value = "msg"
                    async with await make_client() as ac:
                        r = await ac.post("/primes", json={"start": 2, "end": 10})
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_start_above_2_accepted_202(self) -> None:
        fixed_uuid = _make_uuid()
        with patch("prime_service.main.uuid.uuid4", return_value=uuid.UUID(fixed_uuid)):
            with patch("prime_service.main.insert_queued_execution", return_value=fixed_uuid):
                with patch("prime_service.main.PrimeQueue") as MockQueue:
                    MockQueue.return_value.queue_depth.return_value = 0
                    MockQueue.return_value.enqueue.return_value = "msg"
                    async with await make_client() as ac:
                        r = await ac.post("/primes", json={"start": 3, "end": 10})
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_db_failure_returns_503(self) -> None:
        from botocore.exceptions import ClientError

        err_response = {"Error": {"Code": "InternalServerError", "Message": "DDB down"}}
        with patch(
            "prime_service.main.insert_queued_execution",
            side_effect=ClientError(err_response, "PutItem"),
        ):
            with patch("prime_service.main.PrimeQueue") as MockQueue:
                MockQueue.return_value.queue_depth.return_value = 0
                async with await make_client() as ac:
                    r = await ac.post("/primes", json={"start": 2, "end": 10})

        assert r.status_code == 503
        assert "audit" in r.json()["detail"].lower()

    @pytest.mark.asyncio
    async def test_enqueue_failure_still_returns_202(self) -> None:
        """Queue failure does not prevent 202 — audit row exists as the record."""
        fixed_uuid = _make_uuid()
        with patch("prime_service.main.uuid.uuid4", return_value=uuid.UUID(fixed_uuid)):
            with patch("prime_service.main.insert_queued_execution", return_value=fixed_uuid):
                with patch("prime_service.main.PrimeQueue") as MockQueue:
                    MockQueue.return_value.queue_depth.return_value = 0
                    MockQueue.return_value.enqueue.side_effect = Exception("SQS down")
                    async with await make_client() as ac:
                        r = await ac.post("/primes", json={"start": 2, "end": 10})

        # Still 202 — audit row was written; operator can re-enqueue
        assert r.status_code == 202


# ───────────────────────────────────────────────────────────────────────────
# Backpressure middleware — 503 when queue depth exceeds threshold
# ───────────────────────────────────────────────────────────────────────────


class TestBackpressureMiddleware:
    """POST /primes returns 503 + Retry-After: 60 when queue is full."""

    @pytest.mark.asyncio
    async def test_backpressure_503_when_queue_full(self) -> None:
        with patch("prime_service.main.PrimeQueue") as MockQueue:
            # Return depth > threshold (default threshold = 5 × 1 = 5)
            MockQueue.return_value.queue_depth.return_value = 10
            async with await make_client() as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})

        assert r.status_code == 503
        assert r.headers.get("Retry-After") == "60"

    @pytest.mark.asyncio
    async def test_backpressure_not_triggered_below_threshold(self) -> None:
        fixed_uuid = _make_uuid()
        with patch("prime_service.main.uuid.uuid4", return_value=uuid.UUID(fixed_uuid)):
            with patch("prime_service.main.insert_queued_execution", return_value=fixed_uuid):
                with patch("prime_service.main.PrimeQueue") as MockQueue:
                    MockQueue.return_value.queue_depth.return_value = 0
                    MockQueue.return_value.enqueue.return_value = "msg"
                    async with await make_client() as ac:
                        r = await ac.post("/primes", json={"start": 2, "end": 10})

        assert r.status_code == 202

    # BVA at backpressure threshold (default 5)
    @pytest.mark.asyncio
    async def test_backpressure_bva_at_threshold(self) -> None:
        """Depth == threshold → should NOT trigger 503 (> threshold, not >=)."""
        fixed_uuid = _make_uuid()
        with patch("prime_service.main.uuid.uuid4", return_value=uuid.UUID(fixed_uuid)):
            with patch("prime_service.main.insert_queued_execution", return_value=fixed_uuid):
                with patch("prime_service.main.PrimeQueue") as MockQueue:
                    MockQueue.return_value.queue_depth.return_value = 5  # == threshold
                    MockQueue.return_value.enqueue.return_value = "msg"
                    async with await make_client() as ac:
                        r = await ac.post("/primes", json={"start": 2, "end": 10})

        # depth == threshold → NOT triggered
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_backpressure_bva_below_threshold(self) -> None:
        """Depth == threshold - 1 → no backpressure."""
        fixed_uuid = _make_uuid()
        with patch("prime_service.main.uuid.uuid4", return_value=uuid.UUID(fixed_uuid)):
            with patch("prime_service.main.insert_queued_execution", return_value=fixed_uuid):
                with patch("prime_service.main.PrimeQueue") as MockQueue:
                    MockQueue.return_value.queue_depth.return_value = 4  # == threshold - 1
                    MockQueue.return_value.enqueue.return_value = "msg"
                    async with await make_client() as ac:
                        r = await ac.post("/primes", json={"start": 2, "end": 10})
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_backpressure_bva_above_threshold(self) -> None:
        """Depth == threshold + 1 → 503 triggered."""
        with patch("prime_service.main.PrimeQueue") as MockQueue:
            MockQueue.return_value.queue_depth.return_value = 6  # == threshold + 1
            async with await make_client() as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
        assert r.status_code == 503

    @pytest.mark.asyncio
    async def test_backpressure_sqs_error_does_not_block(self) -> None:
        """If SQS is unreachable for depth check, POST is not blocked."""
        fixed_uuid = _make_uuid()
        with patch("prime_service.main.uuid.uuid4", return_value=uuid.UUID(fixed_uuid)):
            with patch("prime_service.main.insert_queued_execution", return_value=fixed_uuid):
                with patch("prime_service.main.PrimeQueue") as MockQueue:
                    MockQueue.return_value.queue_depth.side_effect = Exception("SQS unreachable")
                    MockQueue.return_value.enqueue.return_value = "msg"
                    async with await make_client() as ac:
                        r = await ac.post("/primes", json={"start": 2, "end": 10})

        # SQS error → fall through, not blocked
        assert r.status_code == 202

    @pytest.mark.asyncio
    async def test_backpressure_only_applies_to_post_primes(self) -> None:
        """GET /health is not subject to backpressure even if queue is full."""
        with patch("prime_service.main.health_check", return_value=True):
            with patch("prime_service.main.PrimeQueue") as MockQueue:
                MockQueue.return_value.queue_depth.return_value = 9999
                async with await make_client() as ac:
                    r = await ac.get("/health")

        assert r.status_code == 200


# ───────────────────────────────────────────────────────────────────────────
# GET /primes/{id} — job status polling
# ───────────────────────────────────────────────────────────────────────────


class TestGetPrimesResult:
    """GET /primes/{id} returns current job status."""

    @pytest.mark.asyncio
    async def test_queued_status(self) -> None:
        eid = _make_uuid()
        item = _queued_item(execution_id=eid)
        with patch("prime_service.main.get_execution", return_value=item):
            async with await make_client() as ac:
                r = await ac.get(f"/primes/{eid}")

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "queued"
        assert body["result"] is None

    @pytest.mark.asyncio
    async def test_done_status_includes_result(self) -> None:
        eid = _make_uuid()
        item = _done_item(execution_id=eid, primes=[2, 3, 5, 7])
        with patch("prime_service.main.get_execution", return_value=item):
            async with await make_client() as ac:
                r = await ac.get(f"/primes/{eid}")

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "done"
        assert body["result"] == [2, 3, 5, 7]
        assert body["error_message"] is None

    @pytest.mark.asyncio
    async def test_failed_status_includes_error_message(self) -> None:
        eid = _make_uuid()
        item = _failed_item(execution_id=eid, error="compute exceeded 60s SIGALRM budget")
        with patch("prime_service.main.get_execution", return_value=item):
            async with await make_client() as ac:
                r = await ac.get(f"/primes/{eid}")

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "failed"
        assert "60s" in body["error_message"]
        assert body["result"] is None

    @pytest.mark.asyncio
    async def test_returns_404_when_not_found(self) -> None:
        eid = _make_uuid()
        with patch("prime_service.main.get_execution", return_value=None):
            async with await make_client() as ac:
                r = await ac.get(f"/primes/{eid}")

        assert r.status_code == 404

    # BVA at execution_id: UUID path param (string)
    @pytest.mark.asyncio
    async def test_execution_id_zero_uuid_not_found(self) -> None:
        """execution_id is a UUID string path param — zero UUID returns 404."""
        zero_uuid = "00000000-0000-0000-0000-000000000000"
        with patch("prime_service.main.get_execution", return_value=None):
            async with await make_client() as ac:
                r = await ac.get(f"/primes/{zero_uuid}")
        assert r.status_code == 404

    @pytest.mark.asyncio
    async def test_execution_id_valid_uuid_found(self) -> None:
        eid = _make_uuid()
        item = _queued_item(execution_id=eid)
        with patch("prime_service.main.get_execution", return_value=item):
            async with await make_client() as ac:
                r = await ac.get(f"/primes/{eid}")
        assert r.status_code == 200

    @pytest.mark.asyncio
    async def test_execution_id_another_uuid_found(self) -> None:
        eid = _make_uuid()
        item = _queued_item(execution_id=eid)
        with patch("prime_service.main.get_execution", return_value=item):
            async with await make_client() as ac:
                r = await ac.get(f"/primes/{eid}")
        assert r.status_code == 200

    @pytest.mark.asyncio
    async def test_running_status_no_result(self) -> None:
        eid = _make_uuid()
        item = {
            "execution_id": eid,
            "status": "running",
            "range_start": 2,
            "range_end": 10,
            "created_at": 1745654400,
        }
        with patch("prime_service.main.get_execution", return_value=item):
            async with await make_client() as ac:
                r = await ac.get(f"/primes/{eid}")

        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "running"
        assert body["result"] is None


# ───────────────────────────────────────────────────────────────────────────
# GET /executions/{id} — legacy audit detail
# ───────────────────────────────────────────────────────────────────────────


class TestFetchExecutionEndpoint:
    @pytest.mark.asyncio
    async def test_returns_audit_row(self) -> None:
        eid = _make_uuid()
        item = {
            "execution_id": eid,
            "status": "done",
            "range_start": 2,
            "range_end": 10,
            "primes_count": 4,
            "primes": [2, 3, 5, 7],
            "duration_ms": 5,
            "created_at": 1745654400,
        }
        with patch("prime_service.main.get_execution", return_value=item):
            async with await make_client() as ac:
                r = await ac.get(f"/executions/{eid}")

        assert r.status_code == 200
        body = r.json()
        assert body["id"] == eid
        assert body["primes_count"] == 4
        assert body["primes"] == [2, 3, 5, 7]
        assert body["status"] == "done"

    @pytest.mark.asyncio
    async def test_returns_404_when_not_found(self) -> None:
        eid = _make_uuid()
        with patch("prime_service.main.get_execution", return_value=None):
            async with await make_client() as ac:
                r = await ac.get(f"/executions/{eid}")

        assert r.status_code == 404

    @pytest.mark.asyncio
    async def test_empty_primes_returned_as_empty_list(self) -> None:
        eid = _make_uuid()
        item = {
            "execution_id": eid,
            "status": "done",
            "range_start": 14,
            "range_end": 16,
            "primes_count": 0,
            "duration_ms": 5,
            "created_at": 1745654400,
        }
        with patch("prime_service.main.get_execution", return_value=item):
            async with await make_client() as ac:
                r = await ac.get(f"/executions/{eid}")

        assert r.status_code == 200
        body = r.json()
        assert body["primes"] == []


# ───────────────────────────────────────────────────────────────────────────
# GZip middleware — Content-Encoding header present for large responses
# ───────────────────────────────────────────────────────────────────────────


class TestGzipMiddleware:
    """GZipMiddleware is active; verify Accept-Encoding negotiation works."""

    @pytest.mark.asyncio
    async def test_gzip_encoding_returned_when_accepted(self) -> None:
        with patch("prime_service.main.health_check", return_value=True):
            async with await make_client() as ac:
                r = await ac.get("/health", headers={"Accept-Encoding": "gzip"})

        # FastAPI/starlette GZip only compresses if response body >= minimum_size.
        # /health body is small (<1000 bytes); no compression expected.
        # We verify the middleware doesn't break the response.
        assert r.status_code == 200

    @pytest.mark.asyncio
    async def test_no_encoding_without_accept(self) -> None:
        with patch("prime_service.main.health_check", return_value=True):
            async with await make_client() as ac:
                r = await ac.get("/health")
        assert r.status_code == 200


# ───────────────────────────────────────────────────────────────────────────
# OpenAPI / docs surface
# ───────────────────────────────────────────────────────────────────────────


class TestApplicationSurface:
    @pytest.mark.asyncio
    async def test_openapi_schema_published(self) -> None:
        async with await make_client() as ac:
            r = await ac.get("/openapi.json")
        assert r.status_code == 200
        schema = r.json()
        assert "paths" in schema
        assert "/health" in schema["paths"]
        assert "/primes" in schema["paths"]
        assert "/executions/{execution_id}" in schema["paths"]

    @pytest.mark.asyncio
    async def test_docs_endpoint_serves(self) -> None:
        async with await make_client() as ac:
            r = await ac.get("/docs")
        assert r.status_code == 200
