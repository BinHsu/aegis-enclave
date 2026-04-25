"""Async database layer — SQLAlchemy 2.x + asyncpg.

The service writes one audit row per `/primes` invocation (write-heavy workload
per ADR-0009). The schema mirrors `db/init.sql` exactly; we keep the SQL file
authoritative for first-boot of the postgres container, while this module is
authoritative for the application's view of the same table.

Connection pool sizing is left at SQLAlchemy defaults (pool_size=5,
max_overflow=10) for the case-study scale. Tuning lives outside Phase 1 scope.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from datetime import datetime
from typing import Any

from pydantic_settings import BaseSettings, SettingsConfigDict
from sqlalchemy import Integer, select, text
from sqlalchemy.dialects.postgresql import JSONB
from sqlalchemy.ext.asyncio import (
    AsyncSession,
    async_sessionmaker,
    create_async_engine,
)
from sqlalchemy.orm import DeclarativeBase, Mapped, mapped_column
from sqlalchemy.sql import func


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
    POSTGRES_PASSWORD: str = "changeme_local_dev_only"
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

engine = create_async_engine(
    settings.database_url,
    echo=False,
    pool_pre_ping=True,
)

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
) -> int:
    """Insert a single audit row and return its id."""
    row = Execution(
        range_start=range_start,
        range_end=range_end,
        primes_count=len(primes),
        primes=primes,
        duration_ms=duration_ms,
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


async def health_check(session: AsyncSession) -> bool:
    """Run `SELECT 1` and return True iff the round-trip succeeds."""
    result = await session.execute(text("SELECT 1"))
    return result.scalar_one() == 1
