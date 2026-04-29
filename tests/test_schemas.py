"""Comprehensive unit tests for prime_service.schemas — Pydantic v2 BVA.

Strategy
--------
- **Boundary Value Analysis (BVA)** at every numeric threshold:
    * start >= 2 (lower field bound)
    * start <= 10^7 (upper field bound, absolute cap)
    * end >= 2 (lower field bound)
    * end <= 10^7 (upper field bound, absolute cap)
    * start <= end (ordering)
    * end - start <= 10^7 (redundant range-size guard, mathematically
      unreachable given absolute caps but kept as explicit defense)
  Three points per boundary (B-1, B, B+1).
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

    # BVA at end absolute cap = 10^7 (upper field bound)
    def test_end_one_below_absolute_cap_accepted(self) -> None:
        req = PrimeRangeRequest(start=2, end=_RANGE_CEILING - 1)
        assert req.end == _RANGE_CEILING - 1

    def test_end_at_absolute_cap_accepted(self) -> None:
        req = PrimeRangeRequest(start=2, end=_RANGE_CEILING)
        assert req.end == _RANGE_CEILING

    def test_end_one_above_absolute_cap_rejected(self) -> None:
        # New: absolute cap binds correctness — static _SMALL_PRIMES table
        # only covers sqrt(10^7) = 3163; trial division for n > 10^7 would
        # silently mis-classify composites. Schema cap closes that bug.
        with pytest.raises(ValidationError, match="end"):
            PrimeRangeRequest(start=2, end=_RANGE_CEILING + 1)

    # BVA at start absolute cap = 10^7 (upper field bound)
    def test_start_one_below_absolute_cap_accepted(self) -> None:
        req = PrimeRangeRequest(start=_RANGE_CEILING - 1, end=_RANGE_CEILING - 1)
        assert req.start == _RANGE_CEILING - 1

    def test_start_at_absolute_cap_accepted(self) -> None:
        req = PrimeRangeRequest(start=_RANGE_CEILING, end=_RANGE_CEILING)
        assert req.start == _RANGE_CEILING

    def test_start_one_above_absolute_cap_rejected(self) -> None:
        with pytest.raises(ValidationError, match="start"):
            PrimeRangeRequest(start=_RANGE_CEILING + 1, end=_RANGE_CEILING + 1)

    # BVA at range size — values now constrained by absolute caps to be
    # mathematically <= 10^7 - 2; the redundant guard is unreachable.
    def test_range_size_max_under_absolute_caps(self) -> None:
        # Maximum achievable range size given le=10^7 on both fields:
        # start=2, end=10^7 → range size = 10^7 - 2
        req = PrimeRangeRequest(start=2, end=_RANGE_CEILING)
        assert req.end - req.start == _RANGE_CEILING - 2

    def test_range_size_well_below_ceiling_accepted(self) -> None:
        req = PrimeRangeRequest(start=2, end=1_000_000)
        assert req.end - req.start == 999_998


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

    PrimeRangeResponse is now {execution_id: str (UUID4), status}.
    DynamoDB pivot (ADR-0042): execution_id changed from int to UUID4 string.
    """

    def test_minimal_execution_id_and_status(self) -> None:
        eid = "550e8400-e29b-41d4-a716-446655440000"
        resp = PrimeRangeResponse(execution_id=eid, status="queued")
        assert resp.execution_id == eid
        assert resp.status == "queued"

    def test_default_status_is_queued(self) -> None:
        eid = "550e8400-e29b-41d4-a716-446655440001"
        resp = PrimeRangeResponse(execution_id=eid)
        assert resp.status == "queued"

    def test_execution_id_required(self) -> None:
        with pytest.raises(ValidationError):
            PrimeRangeResponse()  # type: ignore[call-arg]

    def test_execution_id_is_string(self) -> None:
        """execution_id must be a string (UUID4); int is rejected (ADR-0042)."""
        with pytest.raises(ValidationError):
            PrimeRangeResponse(execution_id=1)  # type: ignore[arg-type]

    def test_serialise_roundtrip(self) -> None:
        eid = "550e8400-e29b-41d4-a716-446655440007"
        original = PrimeRangeResponse(execution_id=eid, status="queued")
        round_tripped = PrimeRangeResponse.model_validate_json(original.model_dump_json())
        assert round_tripped == original

    # BVA on execution_id: UUID string at boundary values
    # B-1: empty string (invalid — must be non-empty)
    def test_execution_id_bva_empty_string(self) -> None:
        """B-1: empty string is a valid Python string; accepted by Pydantic str field."""
        # Pydantic str doesn't reject empty strings at schema level — acceptable.
        resp = PrimeRangeResponse(execution_id="")
        assert resp.execution_id == ""

    # B: a minimal single-char UUID string
    def test_execution_id_bva_single_char(self) -> None:
        """B: single-char string is valid string type."""
        resp = PrimeRangeResponse(execution_id="a")
        assert resp.execution_id == "a"

    # B+1: full UUID4 string
    def test_execution_id_bva_uuid4_string(self) -> None:
        """B+1: a full UUID4 string is the canonical form for execution_id."""
        import uuid

        eid = str(uuid.uuid4())
        resp = PrimeRangeResponse(execution_id=eid)
        assert resp.execution_id == eid


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
    """Structural coverage + datetime coercion for execution-history records.

    DynamoDB pivot (ADR-0042): id is now str (UUID4), not int.
    """

    def test_minimal(self) -> None:
        d = ExecutionDetail(
            id="550e8400-e29b-41d4-a716-446655440000",
            range_start=2,
            range_end=10,
            primes_count=4,
            primes=[2, 3, 5, 7],
            duration_ms=12,
            created_at=datetime(2026, 4, 25, 10, 30, 0, tzinfo=UTC),
        )
        assert d.id == "550e8400-e29b-41d4-a716-446655440000"
        assert d.primes_count == 4

    def test_datetime_iso_string_coerced(self) -> None:
        d = ExecutionDetail(
            id="550e8400-e29b-41d4-a716-446655440001",
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
                id="550e8400-e29b-41d4-a716-446655440002",
                range_start=2,
                range_end=10,
                primes_count=4,
                primes=[2, 3, 5, 7],
                duration_ms=12,
                created_at="not-a-date",  # type: ignore[arg-type]
            )

    def test_serialise_roundtrip(self) -> None:
        original = ExecutionDetail(
            id="550e8400-e29b-41d4-a716-44665544002a",
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
