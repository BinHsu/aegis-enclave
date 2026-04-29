"""Pydantic v2 request/response models for the prime service API."""

from datetime import datetime
from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, Field, model_validator


class Status(StrEnum):
    """Lifecycle states for an async prime-computation job.

    State machine: queued → running → done | failed.
    """

    queued = "queued"
    running = "running"
    done = "done"
    failed = "failed"


class PrimeRangeRequest(BaseModel):
    """Inclusive range to generate primes within.

    Absolute caps on both start and end (le=10^7) bind the schema contract
    to the static `_SMALL_PRIMES` table's mathematical validity range
    (sqrt(10^7) = 3163; trial division by primes <= 3163 is correct only
    for n <= 10^7). Without the absolute cap, a request like
    [10^9, 10^9 + 100] would have valid range size but trial division
    against the static table would silently mis-classify composite n
    as prime — a correctness bug, not just a performance question.
    """

    start: int = Field(
        ge=2,
        le=10_000_000,
        description="Inclusive lower bound (2 <= start <= 10^7).",
    )
    end: int = Field(
        ge=2,
        le=10_000_000,
        description="Inclusive upper bound (2 <= end <= 10^7).",
    )

    @model_validator(mode="after")
    def _check_range(self) -> "PrimeRangeRequest":
        if self.start > self.end:
            raise ValueError(f"start ({self.start}) must be <= end ({self.end})")
        # Range size cap is redundant given le=10^7 on both fields,
        # kept as explicit defense-in-depth guard.
        if self.end - self.start > 10_000_000:
            raise ValueError("range size exceeds 10^7 — split into smaller windows")
        return self


class PrimeRangeResponse(BaseModel):
    """202 Accepted response body for POST /primes (async path)."""

    execution_id: str
    status: Status = Status.queued


class ExecutionResponse(BaseModel):
    """GET /primes/{exec_id} — current state of a job."""

    id: str
    status: Status
    result: list[int] | None = None
    error_message: str | None = None


class HealthResponse(BaseModel):
    status: Literal["ok", "degraded"]
    db: Literal["reachable", "unreachable"]
    version: str


class ExecutionDetail(BaseModel):
    id: str
    range_start: int
    range_end: int
    primes_count: int
    primes: list[int]
    duration_ms: int
    created_at: datetime
