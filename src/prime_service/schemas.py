"""Pydantic v2 request/response models for the prime service API."""

from datetime import datetime
from enum import StrEnum
from typing import Literal

from pydantic import BaseModel, Field, model_validator

# Single-source the absolute range ceiling (#9 item 3): primes.py owns
# _RANGE_CEILING because the cap is correctness-driven (the static
# `_SMALL_PRIMES` table is sized to sqrt(_RANGE_CEILING) at import time;
# raising the schema cap without resizing the table would silently
# mis-classify composites). Schema imports it rather than dual-writing
# `10_000_000` to keep the two in lockstep.
from prime_service.primes import _RANGE_CEILING


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

    Absolute caps on both start and end (`le=_RANGE_CEILING`) bind the
    schema contract to the static `_SMALL_PRIMES` table's mathematical
    validity range (sqrt(10^7) = 3163; trial division by primes ≤ 3163 is
    correct only for n ≤ 10^7). Without the absolute cap, a request like
    [10^9, 10^9 + 100] would have valid range size but trial division
    against the static table would silently mis-classify composite n as
    prime — a correctness bug, not a performance question.
    """

    start: int = Field(
        ge=2,
        le=_RANGE_CEILING,
        description="Inclusive lower bound (2 <= start <= _RANGE_CEILING).",
    )
    end: int = Field(
        ge=2,
        le=_RANGE_CEILING,
        description="Inclusive upper bound (2 <= end <= _RANGE_CEILING).",
    )

    @model_validator(mode="after")
    def _check_range(self) -> "PrimeRangeRequest":
        # The previous redundant `end - start > 10^7` defense-in-depth check
        # is dropped (#9 item 4): with `ge=2` + `le=_RANGE_CEILING` on both
        # fields, the maximum reachable width is _RANGE_CEILING - 2, so the
        # check can never fire — keeping it was misleading-by-implication
        # (suggesting two independent constraints when there is one).
        if self.start > self.end:
            raise ValueError(f"start ({self.start}) must be <= end ({self.end})")
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
