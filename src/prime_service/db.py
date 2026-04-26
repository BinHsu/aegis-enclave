"""Async database layer — SQLAlchemy 2.x + asyncpg.

The service writes one audit row per `/primes` invocation (write-heavy workload
per ADR-0009). The schema mirrors `db/init.sql` exactly; we keep the SQL file
authoritative for first-boot of the postgres container, while this module is
authoritative for the application's view of the same table.

Connection pool sizing is left at SQLAlchemy defaults (pool_size=5,
max_overflow=10) for the case-study scale. Tuning lives outside Phase 1 scope.
"""

from __future__ import annotations

import os
from collections.abc import AsyncIterator
from datetime import datetime

from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy import DateTime, Integer, String, select, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.pool import NullPool
from sqlalchemy.sql import func

from prime_service.schemas import Status


class Settings(BaseSettings):
    """Environment-driven configuration.

    Values are read from the process environment (and `.env` if present in
    the working directory). Production deployments source secrets from AWS
    Secrets Manager — see ADR-0016.
    """

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
    )

    POSTGRES_USER: str = "primes_app"
    # Local-dev sentinel; production sources from AWS Secrets Manager.
    POSTGRES_PASSWORD: str = "changeme_local_dev_only"  # noqa: S105
    POSTGRES_DB: str = "primes"
    POSTGRES_HOST: str = "db"
    POSTGRES_PORT: int = 5432

    @property
    def database_url(self) -> str:
        return (
            f"postgresql+asyncpg://{self.POSTGRES_USER}:{self.POSTGRES_PASSWORD}"
            f"@{self.POSTGRES_HOST}:{self.POSTGRES_PORT}/{self.POSTGRES_DB}"
        )


settings = Settings()

# DATABASE_POOL_CLASS=null switches to NullPool (no connection reuse).
# Required for the worker process which calls asyncio.run() multiple times
# per message: the default QueuePool retains connections bound to the closed
# event loop, causing RuntimeError on the next asyncio.run() invocation.
# The app (uvicorn) runs a single event loop and benefits from QueuePool;
# the worker sets DATABASE_POOL_CLASS=null in its container env.
_pool_class = NullPool if os.environ.get("DATABASE_POOL_CLASS", "").lower() == "null" else None

_engine_kwargs: dict[str, object] = {
    "echo": False,
    # Per-statement timeout enforced at the asyncpg driver level (ADR-0020).
    "connect_args": {
        "command_timeout": 10,
        "timeout": 10,  # connection-establish timeout
    },
}
if _pool_class is NullPool:
    # NullPool creates a fresh connection per checkout — no pre-ping needed.
    _engine_kwargs["poolclass"] = NullPool
else:
    _engine_kwargs["pool_pre_ping"] = True

engine = create_async_engine(settings.database_url, **_engine_kwargs)

async_session_maker = async_sessionmaker(
    engine,
    class_=AsyncSession,
    expire_on_commit=False,
)


class Base(DeclarativeBase):
    """Declarative base for ORM models."""


class Execution(Base):
    """One row per `/primes` call — the audit trail.

    Mirrors `db/init.sql`. CHECK constraints are defined on the SQL side as
    a defence-in-depth boundary against application-level validation drift.

    The status column tracks the async job lifecycle:
        queued → running → done | failed
    """

    __tablename__ = "executions"

    id: Mapped[int] = mapped_column(primary_key=True)
    range_start: Mapped[int] = mapped_column(Integer, nullable=False)
    range_end: Mapped[int] = mapped_column(Integer, nullable=False)
    primes_count: Mapped[int] = mapped_column(Integer, nullable=False)
    primes: Mapped[list[int] | None] = mapped_column(JSONB, nullable=True)
    duration_ms: Mapped[int] = mapped_column(Integer, nullable=False)
    created_at: Mapped[datetime] = mapped_column(
        nullable=False,
        server_default=func.now(),
    )
    status: Mapped[str] = mapped_column(
        String,
        nullable=False,
        default="done",
        server_default="done",
    )
    started_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    completed_at: Mapped[datetime | None] = mapped_column(DateTime(timezone=True), nullable=True)
    error_message: Mapped[str | None] = mapped_column(nullable=True)


async def get_session() -> AsyncIterator[AsyncSession]:
    """FastAPI dependency yielding a session bound to one request."""
    async with async_session_maker() as session:
        yield session


async def insert_execution(
    session: AsyncSession,
    *,
    range_start: int,
    range_end: int,
    primes: list[int],
    duration_ms: int,
    status: str = "done",
) -> int:
    """Insert a single audit row and return its id."""
    row = Execution(
        range_start=range_start,
        range_end=range_end,
        primes_count=len(primes),
        primes=primes,
        duration_ms=duration_ms,
        status=status,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row.id


async def insert_queued_execution(
    session: AsyncSession,
    *,
    range_start: int,
    range_end: int,
) -> int:
    """Insert an audit row in 'queued' state for the async worker path.

    Returns the execution id for enqueueing into SQS.
    """
    row = Execution(
        range_start=range_start,
        range_end=range_end,
        primes_count=0,
        primes=None,
        duration_ms=0,
        status=Status.queued.value,
    )
    session.add(row)
    await session.commit()
    await session.refresh(row)
    return row.id


async def get_execution(session: AsyncSession, execution_id: int) -> Execution | None:
    """Fetch one audit row by id, or None if absent."""
    stmt = select(Execution).where(Execution.id == execution_id)
    result = await session.execute(stmt)
    return result.scalar_one_or_none()


async def count_active_executions(session: AsyncSession) -> int:
    """Count rows with status='queued' or 'running' for backpressure checks.

    This is a cheap proxy for queue depth — avoids an SQS API call on every
    POST. Slightly stale is acceptable for backpressure; worst case is a
    momentary over-admission that the worker handles.
    """
    result = await session.execute(
        text("SELECT COUNT(*) FROM executions WHERE status IN ('queued', 'running')")
    )
    return int(result.scalar_one() or 0)


async def health_check(session: AsyncSession) -> bool:
    """Run `SELECT 1` and return True iff the round-trip succeeds."""
    result = await session.execute(text("SELECT 1"))
    return bool(result.scalar_one() == 1)
