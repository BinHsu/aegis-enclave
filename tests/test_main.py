"""Endpoint tests for prime_service.main — FastAPI TestClient with mocked DB.

Strategy
--------
- `httpx.AsyncClient` against the ASGI app via `ASGITransport` for async tests.
- `app.dependency_overrides[get_session]` swaps the real DB session for an
  AsyncMock — endpoint tests are pure HTTP-layer verification.
- Real DB integration is verified by `make smoke` (Phase 1.5).

Endpoints under test:
- GET /health        — degraded behaviour, version reporting
- POST /primes       — happy path, validation, business-rule errors, audit failure
- GET /executions/{id} — found / not-found

Cross-cutting:
- ValidationError → 422 (FastAPI default)
- ValueError from prime logic → 400 (handled by main.py)
- SQLAlchemyError on insert → 503 (handled by main.py)
- Missing audit row → 404
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import AsyncIterator
from unittest.mock import AsyncMock, MagicMock

import pytest
from httpx import ASGITransport, AsyncClient
from sqlalchemy.exc import SQLAlchemyError

from prime_service.db import Execution, get_session
from prime_service.main import app


# ───────────────────────────────────────────────────────────────────────────
# Fixtures
# ───────────────────────────────────────────────────────────────────────────


@pytest.fixture
def mock_session() -> AsyncMock:
    """A fresh AsyncMock session — tests configure its methods per scenario."""
    return AsyncMock()


@pytest.fixture
def client(mock_session: AsyncMock) -> AsyncIterator[AsyncClient]:
    """AsyncClient with `get_session` overridden to yield the mock_session."""
    async def _override() -> AsyncIterator[AsyncMock]:
        yield mock_session

    app.dependency_overrides[get_session] = _override
    transport = ASGITransport(app=app)

    async def _make() -> AsyncClient:
        return AsyncClient(transport=transport, base_url="http://test")

    # async generator — yields a configured AsyncClient
    return _make()  # type: ignore[return-value]


# Async fixtures need `pytest-asyncio` "auto" mode (already configured in pyproject.toml).
# Use a helper to construct the AsyncClient inside each test (avoids ASGITransport leakage).

async def make_client(mock_session: AsyncMock) -> AsyncClient:
    async def _override() -> AsyncIterator[AsyncMock]:
        yield mock_session
    app.dependency_overrides[get_session] = _override
    return AsyncClient(transport=ASGITransport(app=app), base_url="http://test")


# ───────────────────────────────────────────────────────────────────────────
# /health
# ───────────────────────────────────────────────────────────────────────────

class TestHealthEndpoint:
    @pytest.mark.asyncio
    async def test_ok_when_db_reachable(self) -> None:
        session = AsyncMock()
        # health_check uses session.execute → result.scalar() == 1
        result_obj = MagicMock()
        result_obj.scalar.return_value = 1
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

        # Per ADR-0006 / main.py docstring: /health always returns 200,
        # status field reflects degraded mode. ALB target health uses the
        # status field, not the HTTP code.
        assert r.status_code == 200
        body = r.json()
        assert body["status"] == "degraded"
        assert body["db"] == "unreachable"


# ───────────────────────────────────────────────────────────────────────────
# POST /primes
# ───────────────────────────────────────────────────────────────────────────

class TestComputePrimesEndpoint:
    @pytest.mark.asyncio
    async def test_happy_path(self) -> None:
        session = AsyncMock()
        session.flush = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 7

        session.add = MagicMock(side_effect=capture_add)

        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["primes"] == [2, 3, 5, 7]
        assert body["count"] == 4
        assert body["execution_id"] == 7

    @pytest.mark.asyncio
    @pytest.mark.parametrize(
        "payload, expected_status",
        [
            ({"start": 1, "end": 10}, 422),       # start < 2 → Pydantic 422
            ({"start": -5, "end": 10}, 422),      # negative start
            ({"start": 10, "end": 5}, 422),       # start > end → Pydantic model_validator
            ({"start": 2, "end": 100_000_000}, 422),  # range > ceiling → Pydantic
            ({"start": "abc", "end": 10}, 422),  # invalid type
            ({"end": 10}, 422),                  # missing start
            ({"start": 2}, 422),                 # missing end
            ({}, 422),                           # empty payload
        ],
    )
    async def test_validation_errors_return_422(
        self, payload: dict[str, object], expected_status: int
    ) -> None:
        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.post("/primes", json=payload)
        app.dependency_overrides.clear()
        assert r.status_code == expected_status

    @pytest.mark.asyncio
    async def test_db_failure_returns_503(self) -> None:
        session = AsyncMock()
        session.add = MagicMock()
        session.flush = AsyncMock(side_effect=SQLAlchemyError("audit log failed"))

        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 503
        assert "audit" in r.json()["detail"].lower()

    @pytest.mark.asyncio
    async def test_single_point_range(self) -> None:
        session = AsyncMock()
        session.flush = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 1

        session.add = MagicMock(side_effect=capture_add)

        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 7, "end": 7})
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["primes"] == [7]
        assert body["count"] == 1

    @pytest.mark.asyncio
    async def test_start_below_2_explicit(self) -> None:
        """Boundary: start=1 must be rejected by Pydantic (ge=2)."""
        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 1, "end": 10})
        app.dependency_overrides.clear()
        assert r.status_code == 422

    @pytest.mark.asyncio
    async def test_start_greater_than_end_explicit(self) -> None:
        """Boundary: start>end must be rejected by model_validator."""
        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 100, "end": 50})
        app.dependency_overrides.clear()
        assert r.status_code == 422


# ───────────────────────────────────────────────────────────────────────────
# GET /executions/{id}
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
            created_at=datetime(2026, 4, 25, 12, 0, 0, tzinfo=timezone.utc),
        )
        session.get = AsyncMock(return_value=row)

        async with await make_client(session) as ac:
            r = await ac.get("/executions/42")
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["id"] == 42
        assert body["primes_count"] == 4
        assert body["primes"] == [2, 3, 5, 7]

    @pytest.mark.asyncio
    async def test_returns_404_when_not_found(self) -> None:
        session = AsyncMock()
        session.get = AsyncMock(return_value=None)

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

        # FastAPI returns 422 for path param type coercion failure.
        assert r.status_code == 422


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
        # 200 if docs_url is enabled (it is in main.py — `docs_url="/docs"`).
        assert r.status_code == 200
