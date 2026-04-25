"""Mock-based unit tests for prime_service.db.

Strategy
--------
This module's I/O surface is async SQLAlchemy against PostgreSQL with JSONB
columns. Unit tests use AsyncMock / MagicMock to verify the call patterns
without spinning up a real database. Real DB integration is verified via the
end-to-end smoke test (``make smoke``, Phase 1.5) — see CLAUDE.md § 8b for the
two-layer verification approach.

What these tests cover:

- ``Settings`` defaults and env-var override + ``database_url`` composition
- ``Execution`` model has the expected schema attributes
- ``insert_execution`` adds the row, commits, refreshes, and returns the
  assigned id
- ``get_execution`` issues a SELECT and returns the model or ``None``
- ``health_check`` returns ``True`` on ``SELECT 1`` success; propagates
  SQLAlchemy errors to the caller (per ``main.py`` health-endpoint contract)

What these tests DO NOT cover (intentionally):

- Real PostgreSQL JSONB serialisation behaviour
- Connection pool / transaction isolation semantics
- Multi-AZ failover behaviour (a Phase 1.5 / production concern; see
  ADR-0009 for topology rationale)

Those belong in the smoke test or in production-grade integration suites
that are explicitly out of case-study scope per ADR-0003.
"""

from __future__ import annotations

import os
from datetime import datetime, timezone
from unittest.mock import AsyncMock, MagicMock, patch

import pytest
from sqlalchemy.exc import OperationalError, SQLAlchemyError

from prime_service.db import (
    Base,
    Execution,
    Settings,
    get_execution,
    health_check,
    insert_execution,
)


# ───────────────────────────────────────────────────────────────────────────
# Settings — pydantic-settings env loading
# ───────────────────────────────────────────────────────────────────────────

class TestSettings:
    """Verify Settings default values and env-var override behaviour."""

    def test_built_in_defaults(self) -> None:
        """With no env vars present, the model-declared defaults apply.

        ``Settings`` declares safe local-dev defaults so the module imports
        cleanly in test environments (production secrets come from AWS
        Secrets Manager per ADR-0016).
        """
        # Clear any env vars that would override defaults.
        keys = (
            "POSTGRES_USER",
            "POSTGRES_PASSWORD",
            "POSTGRES_DB",
            "POSTGRES_HOST",
            "POSTGRES_PORT",
        )
        with patch.dict(os.environ, {k: "" for k in keys}, clear=False):
            for k in keys:
                os.environ.pop(k, None)
            settings = Settings(_env_file=None)  # type: ignore[call-arg]
            assert settings.POSTGRES_USER == "primes_app"
            assert settings.POSTGRES_DB == "primes"
            assert settings.POSTGRES_HOST == "db"
            assert settings.POSTGRES_PORT == 5432

    def test_env_overrides_defaults(self) -> None:
        env = {
            "POSTGRES_USER": "u",
            "POSTGRES_PASSWORD": "p",
            "POSTGRES_DB": "d",
            "POSTGRES_HOST": "h",
            "POSTGRES_PORT": "6543",
        }
        with patch.dict(os.environ, env, clear=False):
            settings = Settings(_env_file=None)  # type: ignore[call-arg]
            assert settings.POSTGRES_USER == "u"
            assert settings.POSTGRES_PASSWORD == "p"
            assert settings.POSTGRES_DB == "d"
            assert settings.POSTGRES_HOST == "h"
            assert settings.POSTGRES_PORT == 6543

    def test_database_url_composition(self) -> None:
        env = {
            "POSTGRES_USER": "primes_app",
            "POSTGRES_PASSWORD": "secret",
            "POSTGRES_DB": "primes",
            "POSTGRES_HOST": "db",
            "POSTGRES_PORT": "5432",
        }
        with patch.dict(os.environ, env, clear=False):
            settings = Settings(_env_file=None)  # type: ignore[call-arg]
            url = settings.database_url
            assert url.startswith("postgresql+asyncpg://")
            assert "primes_app" in url
            assert "secret" in url
            assert "@db:5432/" in url
            assert url.endswith("/primes")

    def test_database_url_uses_asyncpg_driver(self) -> None:
        """ADR-0009 mandates async SQLAlchemy → asyncpg driver, not psycopg2."""
        settings = Settings(_env_file=None)  # type: ignore[call-arg]
        assert "+asyncpg" in settings.database_url


# ───────────────────────────────────────────────────────────────────────────
# Execution model — schema mapping mirrors db/init.sql
# ───────────────────────────────────────────────────────────────────────────

class TestExecutionModel:
    """Verify the SQLAlchemy declarative mapping matches db/init.sql."""

    def test_table_name(self) -> None:
        assert Execution.__tablename__ == "executions"

    def test_required_columns_present(self) -> None:
        column_names = {c.name for c in Execution.__table__.columns}
        expected = {
            "id",
            "range_start",
            "range_end",
            "primes_count",
            "primes",
            "duration_ms",
            "created_at",
        }
        assert expected.issubset(column_names)

    def test_id_is_primary_key(self) -> None:
        pk_columns = [c.name for c in Execution.__table__.primary_key]
        assert pk_columns == ["id"]

    def test_inherits_base(self) -> None:
        assert issubclass(Execution, Base)

    def test_primes_column_is_nullable(self) -> None:
        """JSONB list column may legitimately be NULL (vs empty list)."""
        primes_col = Execution.__table__.columns["primes"]
        assert primes_col.nullable is True

    def test_non_null_columns(self) -> None:
        """Audit-row invariants: every range / count / duration is required."""
        for col_name in ("range_start", "range_end", "primes_count", "duration_ms"):
            col = Execution.__table__.columns[col_name]
            assert col.nullable is False, f"{col_name} should be NOT NULL"


# ───────────────────────────────────────────────────────────────────────────
# insert_execution — verify add / commit / refresh / return id pattern
# ───────────────────────────────────────────────────────────────────────────

class TestInsertExecution:
    """Async unit tests for ``insert_execution`` using AsyncMock session.

    The implementation pattern is: ``session.add(row)`` →
    ``await session.commit()`` → ``await session.refresh(row)`` →
    ``return row.id``. Mocks verify each step occurs and the returned id
    matches the DB-assigned identity.
    """

    async def test_returns_assigned_id(self) -> None:
        session = AsyncMock()
        added: list[Execution] = []

        def capture_add(obj: Execution) -> None:
            added.append(obj)

        async def fake_refresh(obj: Execution) -> None:
            # Simulate the DB assigning an identity on commit/refresh.
            obj.id = 42

        session.add = MagicMock(side_effect=capture_add)
        session.commit = AsyncMock()
        session.refresh = AsyncMock(side_effect=fake_refresh)

        result = await insert_execution(
            session,
            range_start=2,
            range_end=10,
            primes=[2, 3, 5, 7],
            duration_ms=5,
        )

        assert result == 42
        assert len(added) == 1
        assert added[0].range_start == 2
        assert added[0].range_end == 10
        assert added[0].primes_count == 4
        assert added[0].primes == [2, 3, 5, 7]
        assert added[0].duration_ms == 5
        session.add.assert_called_once()
        session.commit.assert_awaited_once()
        session.refresh.assert_awaited_once()

    async def test_primes_count_derived_from_list_length(self) -> None:
        """``primes_count`` must be derived from ``len(primes)``, not a
        caller-supplied parameter — guards against drift."""
        session = AsyncMock()
        added: list[Execution] = []

        def capture_add(obj: Execution) -> None:
            added.append(obj)

        async def fake_refresh(obj: Execution) -> None:
            obj.id = 1

        session.add = MagicMock(side_effect=capture_add)
        session.commit = AsyncMock()
        session.refresh = AsyncMock(side_effect=fake_refresh)

        await insert_execution(
            session,
            range_start=2,
            range_end=30,
            primes=[2, 3, 5, 7, 11, 13, 17, 19, 23, 29],
            duration_ms=1,
        )
        assert added[0].primes_count == 10

    async def test_empty_primes_persisted_with_zero_count(self) -> None:
        session = AsyncMock()
        added: list[Execution] = []

        def capture_add(obj: Execution) -> None:
            added.append(obj)

        async def fake_refresh(obj: Execution) -> None:
            obj.id = 7

        session.add = MagicMock(side_effect=capture_add)
        session.commit = AsyncMock()
        session.refresh = AsyncMock(side_effect=fake_refresh)

        result = await insert_execution(
            session,
            range_start=14,
            range_end=16,
            primes=[],
            duration_ms=0,
        )
        assert result == 7
        assert added[0].primes_count == 0
        assert added[0].primes == []

    async def test_propagates_commit_error(self) -> None:
        """A failed ``commit`` must propagate so FastAPI can return 5xx —
        silently swallowing would hide DB outages."""
        session = AsyncMock()
        session.add = MagicMock()
        session.commit = AsyncMock(side_effect=SQLAlchemyError("commit failed"))
        session.refresh = AsyncMock()

        with pytest.raises(SQLAlchemyError, match="commit failed"):
            await insert_execution(
                session,
                range_start=2,
                range_end=10,
                primes=[2, 3, 5, 7],
                duration_ms=5,
            )
        session.refresh.assert_not_awaited()

    async def test_propagates_refresh_error(self) -> None:
        session = AsyncMock()
        session.add = MagicMock()
        session.commit = AsyncMock()
        session.refresh = AsyncMock(side_effect=SQLAlchemyError("refresh failed"))

        with pytest.raises(SQLAlchemyError, match="refresh failed"):
            await insert_execution(
                session,
                range_start=2,
                range_end=10,
                primes=[2, 3, 5, 7],
                duration_ms=5,
            )


# ───────────────────────────────────────────────────────────────────────────
# get_execution — SELECT by id, returns model or None
# ───────────────────────────────────────────────────────────────────────────

class TestGetExecution:
    """Verify the ``select() → execute() → scalar_one_or_none()`` pattern."""

    async def test_returns_model_when_found(self) -> None:
        session = AsyncMock()
        expected = Execution(
            id=42,
            range_start=2,
            range_end=10,
            primes_count=4,
            primes=[2, 3, 5, 7],
            duration_ms=5,
            created_at=datetime(2026, 4, 25, 12, 0, 0, tzinfo=timezone.utc),
        )
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = expected
        session.execute = AsyncMock(return_value=result_obj)

        got = await get_execution(session, 42)

        assert got is expected
        assert got is not None
        assert got.id == 42
        session.execute.assert_awaited_once()
        result_obj.scalar_one_or_none.assert_called_once()

    async def test_returns_none_when_not_found(self) -> None:
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one_or_none.return_value = None
        session.execute = AsyncMock(return_value=result_obj)

        got = await get_execution(session, 99999)

        assert got is None
        session.execute.assert_awaited_once()

    async def test_propagates_query_error(self) -> None:
        """A SELECT failure must propagate — the caller (``main.py``) maps
        DB errors to 500 explicitly; silent ``None`` would mask outages."""
        session = AsyncMock()
        session.execute = AsyncMock(side_effect=SQLAlchemyError("select failed"))

        with pytest.raises(SQLAlchemyError, match="select failed"):
            await get_execution(session, 1)


# ───────────────────────────────────────────────────────────────────────────
# health_check — True on SELECT 1 success; errors propagate
# ───────────────────────────────────────────────────────────────────────────

class TestHealthCheck:
    """Verify the ``SELECT 1`` round-trip pattern.

    The implementation has no try/except — it relies on SQLAlchemy raising
    ``OperationalError`` on connectivity failures. ``main.py``'s health
    endpoint catches the exception and maps it to a non-OK status.
    """

    async def test_returns_true_on_successful_select_1(self) -> None:
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one.return_value = 1
        session.execute = AsyncMock(return_value=result_obj)

        ok = await health_check(session)

        assert ok is True
        session.execute.assert_awaited_once()

    async def test_returns_false_when_unexpected_value(self) -> None:
        """If the DB ever returns something other than 1, treat as unhealthy.

        This is defence-in-depth — a misbehaving driver / proxy that returns
        a wrong scalar should not be silently reported as healthy.
        """
        session = AsyncMock()
        result_obj = MagicMock()
        result_obj.scalar_one.return_value = 0
        session.execute = AsyncMock(return_value=result_obj)

        ok = await health_check(session)

        assert ok is False

    async def test_propagates_operational_error(self) -> None:
        """Connection failures bubble up so the caller can map to 503."""
        session = AsyncMock()
        session.execute = AsyncMock(
            side_effect=OperationalError("conn refused", None, Exception())
        )

        with pytest.raises(OperationalError):
            await health_check(session)

    async def test_propagates_generic_sqlalchemy_error(self) -> None:
        session = AsyncMock()
        session.execute = AsyncMock(side_effect=SQLAlchemyError("query failed"))

        with pytest.raises(SQLAlchemyError, match="query failed"):
            await health_check(session)
