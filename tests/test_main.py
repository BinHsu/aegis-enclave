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
from unittest.mock import AsyncMock, MagicMock, patch

import asyncio

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


# ───────────────────────────────────────────────────────────────────────────
# Three-layer timeout — compute layer (ADR-0020)
# ───────────────────────────────────────────────────────────────────────────


class TestComputeTimeoutGate:
    """Layer 1 of three: 30s `asyncio.wait_for` around `primes_in_range`.

    The compute layer protects against runaway primality work — either a
    legitimate large query that the estimator under-counted, or a worst-case
    cache state. On timeout, the endpoint maps `asyncio.TimeoutError` to
    HTTP 504 with a detail string that names the seconds budget.
    """

    @pytest.mark.asyncio
    async def test_compute_timeout_returns_504(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Patch `primes_in_range` to sleep beyond a shrunk compute budget.

        Strategy: shrink `_COMPUTE_TIMEOUT_S` to 0.05s and replace
        `primes_in_range` with a function that sleeps 0.5s on the worker
        thread. `asyncio.wait_for` cancels the wait after the budget,
        the endpoint catches `asyncio.TimeoutError`, and returns 504.
        """
        import time as _time

        def _slow_primes(start: int, end: int) -> list[int]:
            _time.sleep(0.5)
            return []

        monkeypatch.setattr("prime_service.main._COMPUTE_TIMEOUT_S", 0.05)
        monkeypatch.setattr("prime_service.main.primes_in_range", _slow_primes)

        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 504
        detail = r.json()["detail"].lower()
        assert "exceeded" in detail
        # Detail must name the seconds budget — the int cast in main.py
        # rounds 0.05 → 0, so we just confirm "s budget" framing is present.
        assert "s budget" in detail or "second" in detail

    @pytest.mark.asyncio
    async def test_compute_within_budget_returns_200(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Fast `primes_in_range` resolves well under the budget → 200."""

        def _fast_primes(start: int, end: int) -> list[int]:
            return [2, 3, 5, 7]

        monkeypatch.setattr("prime_service.main.primes_in_range", _fast_primes)

        session = AsyncMock()
        session.flush = AsyncMock()

        def capture_add(obj: Execution) -> None:
            obj.id = 11

        session.add = MagicMock(side_effect=capture_add)

        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 200
        body = r.json()
        assert body["primes"] == [2, 3, 5, 7]
        assert body["count"] == 4

    @pytest.mark.asyncio
    async def test_compute_timeout_via_wait_for_patch(self) -> None:
        """Belt-and-braces: patch `asyncio.wait_for` itself to raise.

        Ensures the 504 mapping does not depend on the slow-function trick —
        if any future refactor swaps the cancellation mechanism, this still
        catches the contract: TimeoutError from the compute wrap → 504.
        """

        async def _raise_timeout(*args: object, **kwargs: object) -> object:
            raise asyncio.TimeoutError()

        with patch("prime_service.main.asyncio.wait_for", side_effect=_raise_timeout):
            session = AsyncMock()
            async with await make_client(session) as ac:
                r = await ac.post("/primes", json={"start": 2, "end": 10})
            app.dependency_overrides.clear()

        assert r.status_code == 504
        assert "exceeded" in r.json()["detail"].lower()


# ───────────────────────────────────────────────────────────────────────────
# Pre-flight rejection — `_estimate_compute_ms` exceeds `_HARD_TIMEOUT_MS`
# ───────────────────────────────────────────────────────────────────────────


class TestPreflightRejection:
    """Pre-flight cost estimator — `_validate` rejects with ValueError when
    the estimated compute cost exceeds the hard timeout. The endpoint maps
    that to HTTP 400 (already wired for any ValueError from primes logic).
    """

    @pytest.mark.asyncio
    async def test_estimated_too_expensive_returns_400(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Synthetic ValueError from `primes_in_range` → 400 with detail."""

        msg = "estimated compute time 60000 ms exceeds 30000 ms ceiling"

        def _reject(start: int, end: int) -> list[int]:
            raise ValueError(msg)

        monkeypatch.setattr("prime_service.main.primes_in_range", _reject)

        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 400
        assert "estimated compute time" in r.json()["detail"]

    @pytest.mark.asyncio
    async def test_real_far_gap_layer3_query_rejected(self) -> None:
        """End-to-end: a real far-gap query naturally trips the estimator.

        With a freshly-reset cache (`_known_max == _INITIAL_PREWARM_BOUND`),
        a `[2, 10_000_000]` range hits Layer 3 (trial division above the
        sieve threshold) over ~10⁷ candidates. The estimator multiplies
        `compute_range * sqrt(end) / 6 / 3000` → tens of millions of ms,
        well past the 30 000 ms ceiling. `_validate` raises ValueError;
        endpoint maps to 400.

        Cache state matters: any prior test that extended `_known_max`
        past ~10⁷ would make this query *cheap* (cache hit) and break the
        test. We reset cache state explicitly to guarantee determinism.
        """
        # Manual reset — keeps the test self-contained without an autouse
        # fixture that other tests in this module don't need.
        from prime_service import primes as _primes_mod

        with _primes_mod._cache_lock:
            _primes_mod._known_primes = _primes_mod._build_prime_table(
                _primes_mod._INITIAL_PREWARM_BOUND
            )
            _primes_mod._set_known_max(_primes_mod._INITIAL_PREWARM_BOUND)

        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 2, "end": 10_000_000})
        app.dependency_overrides.clear()

        assert r.status_code == 400
        detail = r.json()["detail"]
        assert "estimated compute time" in detail
        assert "ceiling" in detail


# ───────────────────────────────────────────────────────────────────────────
# Three-layer timeout — audit DB layer (ADR-0020)
# ───────────────────────────────────────────────────────────────────────────


class TestAuditTimeoutGate:
    """Layer 2 of three: 10s `asyncio.wait_for` around `insert_execution`.

    Audit DB writes that hang (slow write replica, network partition between
    the enclave and Aurora, lock contention) must not strand the request on
    the event loop. On timeout, 503 with detail `audit log write exceeded`.

    The pre-existing `SQLAlchemyError → 503 'audit log unavailable'` path
    is covered by `TestComputePrimesEndpoint.test_db_failure_returns_503` —
    referenced here so the failure-mode picture stays whole.
    """

    @pytest.mark.asyncio
    async def test_audit_timeout_returns_503(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Slow `insert_execution` past a shrunk audit budget → 503."""

        async def _slow_insert(*args: object, **kwargs: object) -> int:
            await asyncio.sleep(0.5)
            return 1

        monkeypatch.setattr("prime_service.main._AUDIT_TIMEOUT_S", 0.05)
        monkeypatch.setattr("prime_service.main.insert_execution", _slow_insert)

        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 503
        detail = r.json()["detail"].lower()
        assert "audit log write exceeded" in detail

    @pytest.mark.asyncio
    async def test_audit_sqlalchemy_error_still_503(
        self, monkeypatch: pytest.MonkeyPatch
    ) -> None:
        """Preserve the existing failure mode: SQLAlchemyError → 503.

        Distinct detail string from the timeout case ("audit log unavailable"
        vs. "audit log write exceeded") so SREs can distinguish the two from
        the response body alone.
        """

        async def _explode(*args: object, **kwargs: object) -> int:
            raise SQLAlchemyError("audit log failed")

        monkeypatch.setattr("prime_service.main.insert_execution", _explode)

        session = AsyncMock()
        async with await make_client(session) as ac:
            r = await ac.post("/primes", json={"start": 2, "end": 10})
        app.dependency_overrides.clear()

        assert r.status_code == 503
        detail = r.json()["detail"].lower()
        assert "audit log unavailable" in detail
        assert "exceeded" not in detail


# ───────────────────────────────────────────────────────────────────────────
# Cache-state persistence (sanity — not a speed assertion)
# ───────────────────────────────────────────────────────────────────────────


class TestCacheStatePersistence:
    """Two POSTs over the same range return identical primes.

    This is a consistency check, not a performance assertion. We do not
    inspect `_known_max` advancement or measure latency — only that the
    public contract (the prime list) is stable across repeated calls.
    """

    @pytest.mark.asyncio
    async def test_repeated_range_returns_identical_primes(self) -> None:
        session = AsyncMock()
        session.flush = AsyncMock()

        ids = iter([100, 101])

        def capture_add(obj: Execution) -> None:
            obj.id = next(ids)

        session.add = MagicMock(side_effect=capture_add)

        async with await make_client(session) as ac:
            r1 = await ac.post("/primes", json={"start": 2, "end": 50})
            r2 = await ac.post("/primes", json={"start": 2, "end": 50})
        app.dependency_overrides.clear()

        assert r1.status_code == 200
        assert r2.status_code == 200
        assert r1.json()["primes"] == r2.json()["primes"]
        assert r1.json()["count"] == r2.json()["count"]
