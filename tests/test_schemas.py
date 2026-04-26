"""Comprehensive unit tests for prime_service.schemas — Pydantic v2 BVA.

Strategy
--------
- **Boundary Value Analysis (BVA)** at every numeric threshold (start >= 2,
  end >= 2, end - start <= 10_000_000) — three points per boundary (B-1, B, B+1).
  This is the same BVA discipline applied to ``primes.py`` (see ADR-0017
  "Prime Computation Strategy" for the layered-validation rationale).
- **Equivalence partitioning** for invalid input classes (negative, zero,
  string, float, missing field, wrong type for Literal).
- **Per-model coverage**: each Pydantic model has its own test class.

The schemas module is pure declarative validation; there is no async or I/O.
Tests use ``pytest.raises(ValidationError)`` from pydantic to assert rejection
paths, with ``match=`` to verify the error message anchors on the right field.
"""

from datetime import UTC, datetime

import pytest
from pydantic import ValidationError

from prime_service.schemas import (
    ExecutionDetail,
    HealthResponse,
    PrimeRangeRequest,
    PrimeRangeResponse,
)

_RANGE_CEILING = 10_000_000


# ───────────────────────────────────────────────────────────────────────────
# PrimeRangeRequest — has the most validation logic; most thorough coverage
# ───────────────────────────────────────────────────────────────────────────


class TestPrimeRangeRequestBoundaries:
    """BVA on the start/end field constraints and the range-size invariant."""

    # BVA at start = 2 (lower field bound)
    @pytest.mark.parametrize("start", [-5, 0, 1])
    def test_start_below_2_rejected(self, start: int) -> None:
        with pytest.raises(ValidationError, match="start"):
            PrimeRangeRequest(start=start, end=100)

    @pytest.mark.parametrize("start", [2, 3, 100])
    def test_start_at_or_above_2_accepted(self, start: int) -> None:
        req = PrimeRangeRequest(start=start, end=start + 10)
        assert req.start == start

    # BVA at end = 2 (lower field bound)
    @pytest.mark.parametrize("end", [-5, 0, 1])
    def test_end_below_2_rejected(self, end: int) -> None:
        with pytest.raises(ValidationError, match="end"):
            PrimeRangeRequest(start=2, end=end)

    # BVA at start <= end ordering
    def test_start_equals_end(self) -> None:
        req = PrimeRangeRequest(start=7, end=7)
        assert req.start == 7
        assert req.end == 7

    def test_start_one_above_end_rejected(self) -> None:
        with pytest.raises(ValidationError, match="must be <= end"):
            PrimeRangeRequest(start=8, end=7)

    def test_start_far_above_end_rejected(self) -> None:
        with pytest.raises(ValidationError, match="must be <= end"):
            PrimeRangeRequest(start=1_000_000, end=2)

    # BVA at range-size ceiling
    def test_range_size_well_below_ceiling_accepted(self) -> None:
        req = PrimeRangeRequest(start=2, end=1_000_000)
        assert req.end - req.start == 999_998

    def test_range_size_one_below_ceiling_accepted(self) -> None:
        req = PrimeRangeRequest(start=2, end=2 + _RANGE_CEILING - 1)
        assert req.end - req.start == _RANGE_CEILING - 1

    def test_range_size_at_ceiling_accepted(self) -> None:
        req = PrimeRangeRequest(start=2, end=2 + _RANGE_CEILING)
        assert req.end - req.start == _RANGE_CEILING

    def test_range_size_one_above_ceiling_rejected(self) -> None:
        with pytest.raises(ValidationError, match="range size"):
            PrimeRangeRequest(start=2, end=2 + _RANGE_CEILING + 1)


class TestPrimeRangeRequestTypeCoercion:
    """Pydantic v2 default strict-but-coercing behaviour for primitive types."""

    def test_string_int_coerced(self) -> None:
        # Pydantic v2 default is "lax" coercion for primitive types.
        req = PrimeRangeRequest(start="10", end="20")  # type: ignore[arg-type]
        assert req.start == 10
        assert req.end == 20

    def test_float_with_no_fraction_coerced(self) -> None:
        # 10.0 is integer-valued; Pydantic coerces to int 10.
        req = PrimeRangeRequest(start=10.0, end=20.0)  # type: ignore[arg-type]
        assert req.start == 10

    def test_float_with_fraction_rejected(self) -> None:
        with pytest.raises(ValidationError):
            PrimeRangeRequest(start=10.5, end=20)  # type: ignore[arg-type]

    def test_none_rejected(self) -> None:
        with pytest.raises(ValidationError):
            PrimeRangeRequest(start=None, end=10)  # type: ignore[arg-type]

    def test_missing_start_field(self) -> None:
        with pytest.raises(ValidationError, match="start"):
            PrimeRangeRequest(end=10)  # type: ignore[call-arg]

    def test_missing_end_field(self) -> None:
        with pytest.raises(ValidationError, match="end"):
            PrimeRangeRequest(start=2)  # type: ignore[call-arg]

    def test_extra_field_default_behaviour(self) -> None:
        # Pydantic v2 default is "ignore extra fields"; if model_config sets
        # extra="forbid" later, this test will surface it.
        req = PrimeRangeRequest(start=2, end=10, extra_field="ignored")  # type: ignore[call-arg]
        assert req.start == 2


# ───────────────────────────────────────────────────────────────────────────
# PrimeRangeResponse — structural; no custom validators
# ───────────────────────────────────────────────────────────────────────────


class TestPrimeRangeResponse:
    """Structural coverage for the 202 Accepted response (async path).

    PrimeRangeResponse is now {execution_id, status} — the synchronous
    {primes, count} fields moved to ExecutionResponse (GET /primes/{id}).
    """

    def test_minimal_execution_id_and_status(self) -> None:
        resp = PrimeRangeResponse(execution_id=1, status="queued")
        assert resp.execution_id == 1
        assert resp.status == "queued"

    def test_default_status_is_queued(self) -> None:
        resp = PrimeRangeResponse(execution_id=42)
        assert resp.status == "queued"

    def test_execution_id_required(self) -> None:
        with pytest.raises(ValidationError):
            PrimeRangeResponse()  # type: ignore[call-arg]

    def test_execution_id_negative_accepted(self) -> None:
        # No constraint on execution_id polarity; test documents current contract.
        resp = PrimeRangeResponse(execution_id=-1)
        assert resp.execution_id == -1

    def test_serialise_roundtrip(self) -> None:
        original = PrimeRangeResponse(execution_id=7, status="queued")
        round_tripped = PrimeRangeResponse.model_validate_json(original.model_dump_json())
        assert round_tripped == original

    # BVA on execution_id boundary (any int accepted, no schema constraint)
    def test_execution_id_bva_at_0(self) -> None:
        resp = PrimeRangeResponse(execution_id=0)
        assert resp.execution_id == 0

    def test_execution_id_bva_at_1(self) -> None:
        resp = PrimeRangeResponse(execution_id=1)
        assert resp.execution_id == 1

    def test_execution_id_bva_at_2(self) -> None:
        resp = PrimeRangeResponse(execution_id=2)
        assert resp.execution_id == 2


# ───────────────────────────────────────────────────────────────────────────
# HealthResponse — Literal type enforcement
# ───────────────────────────────────────────────────────────────────────────


class TestHealthResponse:
    """Literal type enforcement on the health endpoint contract."""

    @pytest.mark.parametrize(
        ("status", "db"),
        [
            ("ok", "reachable"),
            ("degraded", "unreachable"),
            ("ok", "unreachable"),  # observed in fault scenarios
            ("degraded", "reachable"),  # uncommon but type-valid
        ],
    )
    def test_valid_literal_combinations(self, status: str, db: str) -> None:
        h = HealthResponse(status=status, db=db, version="1.0.0")  # type: ignore[arg-type]
        assert h.status == status
        assert h.db == db

    def test_invalid_status_rejected(self) -> None:
        with pytest.raises(ValidationError, match="status"):
            HealthResponse(status="up", db="reachable", version="1.0")  # type: ignore[arg-type]

    def test_invalid_db_rejected(self) -> None:
        with pytest.raises(ValidationError, match="db"):
            HealthResponse(status="ok", db="online", version="1.0")  # type: ignore[arg-type]

    def test_version_field_required(self) -> None:
        with pytest.raises(ValidationError, match="version"):
            HealthResponse(status="ok", db="reachable")  # type: ignore[call-arg]


# ───────────────────────────────────────────────────────────────────────────
# ExecutionDetail — structural; verifies datetime handling
# ───────────────────────────────────────────────────────────────────────────


class TestExecutionDetail:
    """Structural coverage + datetime coercion for execution-history records."""

    def test_minimal(self) -> None:
        d = ExecutionDetail(
            id=1,
            range_start=2,
            range_end=10,
            primes_count=4,
            primes=[2, 3, 5, 7],
            duration_ms=12,
            created_at=datetime(2026, 4, 25, 10, 30, 0, tzinfo=UTC),
        )
        assert d.id == 1
        assert d.primes_count == 4

    def test_datetime_iso_string_coerced(self) -> None:
        d = ExecutionDetail(
            id=1,
            range_start=2,
            range_end=10,
            primes_count=4,
            primes=[2, 3, 5, 7],
            duration_ms=12,
            created_at="2026-04-25T10:30:00+00:00",  # type: ignore[arg-type]
        )
        assert d.created_at.year == 2026

    def test_invalid_datetime_string_rejected(self) -> None:
        with pytest.raises(ValidationError, match="created_at"):
            ExecutionDetail(
                id=1,
                range_start=2,
                range_end=10,
                primes_count=4,
                primes=[2, 3, 5, 7],
                duration_ms=12,
                created_at="not-a-date",  # type: ignore[arg-type]
            )

    def test_serialise_roundtrip(self) -> None:
        original = ExecutionDetail(
            id=42,
            range_start=2,
            range_end=100,
            primes_count=25,
            primes=[
                2,
                3,
                5,
                7,
                11,
                13,
                17,
                19,
                23,
                29,
                31,
                37,
                41,
                43,
                47,
                53,
                59,
                61,
                67,
                71,
                73,
                79,
                83,
                89,
                97,
            ],
            duration_ms=8,
            created_at=datetime(2026, 4, 25, 12, 0, 0, tzinfo=UTC),
        )
        round_tripped = ExecutionDetail.model_validate_json(original.model_dump_json())
        assert round_tripped == original
