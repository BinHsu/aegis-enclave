"""Pydantic v2 request/response models for the prime service API."""

from datetime import datetime
from typing import Literal

from pydantic import BaseModel, Field, model_validator


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
    primes: list[int]
    count: int
    execution_id: int


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
