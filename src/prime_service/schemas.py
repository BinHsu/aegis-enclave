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
    """Inclusive range to generate primes within."""

    start: int = Field(ge=2, description="Inclusive lower bound (>= 2).")
    end: int = Field(ge=2, description="Inclusive upper bound (>= start).")

    @model_validator(mode="after")
    def _check_range(self) -> "PrimeRangeRequest":
        if self.start > self.end:
            raise ValueError(f"start ({self.start}) must be <= end ({self.end})")
        if self.end - self.start > 10_000_000:
            raise ValueError("range size exceeds 10^7 — split into smaller windows")
        return self


class PrimeRangeResponse(BaseModel):
    """202 Accepted response body for POST /primes (async path)."""

    execution_id: int
    status: Status = Status.queued


class ExecutionResponse(BaseModel):
    """GET /primes/{exec_id} — current state of a job."""

    id: int
    status: Status
    result: list[int] | None = None
    error_message: str | None = None


class HealthResponse(BaseModel):
    status: Literal["ok", "degraded"]
    db: Literal["reachable", "unreachable"]
    version: str


class ExecutionDetail(BaseModel):
    id: int
    range_start: int
    range_end: int
    primes_count: int
    primes: list[int]
    duration_ms: int
    created_at: datetime
