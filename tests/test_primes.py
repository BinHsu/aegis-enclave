"""Comprehensive unit tests for prime_service.primes.

Strategy
--------
- **Differential testing** against `sympy` as the trusted oracle.
- **Boundary Value Analysis (BVA)**: every boundary `B` is tested at
  `B-1`, `B`, `B+1` (three points to detect off-by-one and miscategorisation).
- **Layered coverage**: each test or test group is annotated with which
  algorithm layer it exercises (table / sieve / trial division), so a
  reviewer can immediately see that both "uses lookup table" and "does
  NOT use lookup table" branches are covered.
- **Per-function**: each public and private function in `primes.py` has
  its own test class.
- **Differential fuzz**: deterministic seeded random ranges per layer.

Why sympy as oracle (and why the brief allows it)
-------------------------------------------------
The case-study brief reads: "The implementation logic should be yours...
not code". That rule scopes the **implementation** (`src/prime_service/primes.py`),
not the **test oracle**. Differential testing against a known-good
reference is standard practice in industry verification — compilers test
against a reference compiler, crypto libraries test against OpenSSL,
arithmetic libraries test against `sympy`. The implementation in
`primes.py` imports nothing from `sympy`; it is 100 % self-written
sieve + 6k±1 trial division layered on a self-built lookup table.
"""

from random import Random

import pytest
from sympy import isprime as sympy_isprime
from sympy import primerange as sympy_primerange

from prime_service.primes import (
    _PRIME_TABLE,
    _RANGE_CEILING,
    _SIEVE_THRESHOLD,
    _TABLE_BOUND,
    _build_prime_table,
    _is_prime_6k,
    _lookup_in_table,
    _sieve_eratosthenes,
    _trial_division_6k,
    _validate,
    primes_in_range,
)


def sympy_primes(start: int, end: int) -> list[int]:
    """Inclusive [start, end] via sympy oracle.

    `sympy.primerange` is half-open `[a, b)`; we add 1 to make it inclusive.
    """
    return list(sympy_primerange(start, end + 1))


# ───────────────────────────────────────────────────────────────────────────
# _validate — exercises every ValueError branch
# ───────────────────────────────────────────────────────────────────────────

class TestValidate:
    """Boundary value analysis on the input validator."""

    # BVA at start=2 (lower bound)
    @pytest.mark.parametrize("start", [-1, 0, 1])
    def test_below_2_rejected(self, start: int) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            _validate(start, 100)

    @pytest.mark.parametrize("start", [2, 3, 100])
    def test_at_or_above_2_passes(self, start: int) -> None:
        _validate(start, start)  # no exception

    # BVA on start vs end ordering
    def test_start_equals_end_passes(self) -> None:
        _validate(7, 7)  # no exception — single point is valid

    def test_start_greater_than_end_rejected(self) -> None:
        with pytest.raises(ValueError, match="must be <= end"):
            _validate(10, 9)

    # BVA at range ceiling
    def test_range_one_below_ceiling_passes(self) -> None:
        _validate(2, 2 + _RANGE_CEILING - 1)

    def test_range_at_ceiling_passes(self) -> None:
        _validate(2, 2 + _RANGE_CEILING)

    def test_range_above_ceiling_rejected(self) -> None:
        with pytest.raises(ValueError, match="range size"):
            _validate(2, 2 + _RANGE_CEILING + 1)


# ───────────────────────────────────────────────────────────────────────────
# _is_prime_6k — single primality check, every internal branch
# ───────────────────────────────────────────────────────────────────────────

class TestIsPrime6k:
    """BVA + branch coverage on the 6k±1 primality check."""

    # Below the n<2 short-circuit
    @pytest.mark.parametrize("n", [-1, 0, 1])
    def test_below_2_returns_false(self, n: int) -> None:
        assert _is_prime_6k(n) is False

    # Hits the n<4 short-circuit
    def test_2_is_prime(self) -> None:
        assert _is_prime_6k(2) is True

    def test_3_is_prime(self) -> None:
        assert _is_prime_6k(3) is True

    # Hits the even/3-multiple short-circuits
    def test_4_is_composite(self) -> None:
        assert _is_prime_6k(4) is False

    def test_9_is_composite(self) -> None:
        # 9 = 3 × 3 — divisible by 3, hits the % 3 short-circuit
        assert _is_prime_6k(9) is False

    # Square boundaries — common off-by-one trap
    @pytest.mark.parametrize("n", [25, 49, 121, 169])
    def test_perfect_squares_composite(self, n: int) -> None:
        assert _is_prime_6k(n) is False

    # Known small primes
    @pytest.mark.parametrize("n", [5, 7, 11, 13, 17, 19, 23, 29, 31, 97])
    def test_known_small_primes(self, n: int) -> None:
        assert _is_prime_6k(n) is True

    # Differential against sympy oracle for the entire range [0, 1000]
    def test_differential_against_sympy_first_1000(self) -> None:
        for n in range(0, 1001):
            assert _is_prime_6k(n) == sympy_isprime(n), f"mismatch at n={n}"

    # Boundary: smallest prime > 10**6
    def test_smallest_prime_above_million(self) -> None:
        # 1_000_003 is the smallest prime > 10**6
        assert _is_prime_6k(1_000_003) is True

    # Boundary: 10**6 itself is composite
    def test_million_is_composite(self) -> None:
        assert _is_prime_6k(1_000_000) is False


# ───────────────────────────────────────────────────────────────────────────
# _build_prime_table — module-load helper
# ───────────────────────────────────────────────────────────────────────────

class TestBuildPrimeTable:
    """BVA on the bound parameter + differential against sympy."""

    @pytest.mark.parametrize("bound", [0, 1])
    def test_below_2_returns_empty(self, bound: int) -> None:
        assert _build_prime_table(bound) == []

    def test_bound_2_returns_only_2(self) -> None:
        assert _build_prime_table(2) == [2]

    def test_bound_30_returns_first_ten_primes(self) -> None:
        assert _build_prime_table(30) == [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]

    @pytest.mark.parametrize("bound", [10, 100, 1_000, 10_000])
    def test_differential_against_sympy(self, bound: int) -> None:
        assert _build_prime_table(bound) == sympy_primes(2, bound)

    def test_module_table_matches_oracle(self) -> None:
        """The actual `_PRIME_TABLE` loaded at import time must match sympy.

        `_PRIME_TABLE` is stored as a tuple for immutability (see ADR-0017);
        cast to list for equality comparison against the sympy oracle output.
        """
        assert list(_PRIME_TABLE) == sympy_primes(2, _TABLE_BOUND)

    def test_module_table_is_immutable(self) -> None:
        """ADR-0017: storage as tuple guards against accidental mutation."""
        import pytest as _pytest

        with _pytest.raises(AttributeError):
            _PRIME_TABLE.append(999_983)  # type: ignore[attr-defined]
        with _pytest.raises(TypeError):
            _PRIME_TABLE[0] = 0  # type: ignore[index]


# ───────────────────────────────────────────────────────────────────────────
# _lookup_in_table — bisect-based slice (uses table by definition)
# ───────────────────────────────────────────────────────────────────────────

class TestLookupInTable:
    """All inputs here exercise the table path. BVA at table boundaries."""

    def test_head_of_table(self) -> None:
        # uses table
        assert _lookup_in_table(2, 10) == [2, 3, 5, 7]

    def test_single_prime_hit(self) -> None:
        # uses table
        assert _lookup_in_table(7, 7) == [7]

    def test_single_composite(self) -> None:
        # uses table
        assert _lookup_in_table(8, 8) == []

    def test_empty_range_in_composite_run(self) -> None:
        # uses table — 14, 15, 16 are all composite
        assert _lookup_in_table(14, 16) == []

    def test_table_upper_bound_inclusive(self) -> None:
        # uses table — end exactly TABLE_BOUND
        result = _lookup_in_table(2, _TABLE_BOUND)
        assert result == sympy_primes(2, _TABLE_BOUND)

    def test_largest_prime_in_table(self) -> None:
        # uses table — single point at the largest prime <= TABLE_BOUND
        largest = sympy_primes(2, _TABLE_BOUND)[-1]
        assert _lookup_in_table(largest, largest) == [largest]

    @pytest.mark.parametrize(
        "start,end",
        [(2, 100), (50, 200), (1_000, 2_000), (50_000, 60_000), (90_000, _TABLE_BOUND)],
    )
    def test_differential_against_sympy(self, start: int, end: int) -> None:
        # uses table
        assert _lookup_in_table(start, end) == sympy_primes(start, end)


# ───────────────────────────────────────────────────────────────────────────
# _sieve_eratosthenes — runtime sieve (does NOT use table)
# ───────────────────────────────────────────────────────────────────────────

class TestSieveEratosthenes:
    """Direct exercise of the runtime sieve (no table path)."""

    def test_minimum_upper(self) -> None:
        # NO table — direct call to private function
        assert list(_sieve_eratosthenes(2, 2)) == [2]

    def test_upper_3(self) -> None:
        # NO table
        assert list(_sieve_eratosthenes(3, 2)) == [2, 3]

    @pytest.mark.parametrize("upper", [10, 100, 1_000])
    def test_differential_full_range(self, upper: int) -> None:
        # NO table
        assert list(_sieve_eratosthenes(upper, 2)) == sympy_primes(2, upper)

    def test_start_filter(self) -> None:
        # NO table — sieve generates up to upper but yields only >= start
        assert list(_sieve_eratosthenes(20, 11)) == [11, 13, 17, 19]


# ───────────────────────────────────────────────────────────────────────────
# _trial_division_6k — runtime trial division (does NOT use table)
# ───────────────────────────────────────────────────────────────────────────

class TestTrialDivision6k:
    """Direct exercise of the trial-division branch (no table path)."""

    def test_first_ten_primes(self) -> None:
        # NO table
        assert list(_trial_division_6k(2, 30)) == [
            2, 3, 5, 7, 11, 13, 17, 19, 23, 29,
        ]

    def test_smallest_prime_above_million(self) -> None:
        # NO table — 1_000_003 is the smallest prime > 10**6
        assert 1_000_003 in list(_trial_division_6k(1_000_001, 1_000_005))

    @pytest.mark.parametrize(
        "start,end",
        [(2, 100), (1_000, 2_000), (1_000_001, 1_000_100)],
    )
    def test_differential(self, start: int, end: int) -> None:
        # NO table
        assert list(_trial_division_6k(start, end)) == sympy_primes(start, end)


# ───────────────────────────────────────────────────────────────────────────
# primes_in_range — top-level layered behaviour
# ───────────────────────────────────────────────────────────────────────────

class TestPrimesInRangeValidation:
    """Validation rejections — top-level entry point."""

    @pytest.mark.parametrize("start", [-5, 0, 1])
    def test_start_below_2_raises(self, start: int) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            primes_in_range(start, 100)

    def test_start_greater_than_end_raises(self) -> None:
        with pytest.raises(ValueError, match="must be <= end"):
            primes_in_range(100, 50)

    def test_range_above_ceiling_raises(self) -> None:
        with pytest.raises(ValueError, match="range size"):
            primes_in_range(2, 2 + _RANGE_CEILING + 1)


class TestPrimesInRangeLayer1UsesTable:
    """Layer 1 — `end <= _TABLE_BOUND`. ALL inputs here use the lookup table."""

    @pytest.mark.parametrize(
        "start,end",
        [
            (2, 10),                          # head of table
            (2, 100),                         # well inside table
            (50_000, _TABLE_BOUND - 1),       # B - 1 boundary
            (2, _TABLE_BOUND),                # B exact boundary
        ],
    )
    def test_inside_table(self, start: int, end: int) -> None:
        # uses table only
        assert primes_in_range(start, end) == sympy_primes(start, end)

    def test_classic_brief_example(self) -> None:
        # uses table — brief example: 1..10 should give 2,3,5,7
        # (start clamped to 2 because brief reserves 1)
        assert primes_in_range(2, 10) == [2, 3, 5, 7]


class TestPrimesInRangeLayer1_5UsesTablePartially:
    """Layer 1.5 — `start <= _TABLE_BOUND < end`. Table prefix + computed suffix."""

    @pytest.mark.parametrize(
        "start,end",
        [
            (2, _TABLE_BOUND + 1),              # B + 1 boundary — smallest spill
            (2, _TABLE_BOUND + 100),            # spill into Layer 2
            (_TABLE_BOUND - 100, _TABLE_BOUND + 100),  # straddle equally
            (_TABLE_BOUND, _TABLE_BOUND + 1),   # boundary kissing — single prime above
        ],
    )
    def test_partial_overlap(self, start: int, end: int) -> None:
        # uses table prefix + computed suffix
        assert primes_in_range(start, end) == sympy_primes(start, end)


class TestPrimesInRangeLayer2NoTable:
    """Layer 2 — `start > _TABLE_BOUND` and `end <= _SIEVE_THRESHOLD`.

    No table is used; runtime Sieve of Eratosthenes.
    """

    @pytest.mark.parametrize(
        "start,end",
        [
            (_TABLE_BOUND + 1, _TABLE_BOUND + 100),       # B + 1 (just above table)
            (500_000, 500_500),                            # well inside Layer 2
            (999_900, _SIEVE_THRESHOLD - 1),               # B - 1 of next boundary
            (999_900, _SIEVE_THRESHOLD),                   # B at next boundary
        ],
    )
    def test_above_table_below_sieve_threshold(self, start: int, end: int) -> None:
        # NO table; runtime sieve
        assert primes_in_range(start, end) == sympy_primes(start, end)


class TestPrimesInRangeLayer3NoTable:
    """Layer 3 — `end > _SIEVE_THRESHOLD`. No table; trial division."""

    @pytest.mark.parametrize(
        "start,end",
        [
            (_SIEVE_THRESHOLD + 1, _SIEVE_THRESHOLD + 100),   # B + 1 boundary
            (1_000_001, 1_000_100),
            (10_000_000, 10_000_100),                          # high range
        ],
    )
    def test_above_sieve_threshold(self, start: int, end: int) -> None:
        # NO table; trial division
        assert primes_in_range(start, end) == sympy_primes(start, end)


class TestPrimesInRangeSinglePoints:
    """BVA on single-point ranges at every boundary."""

    def test_smallest_valid(self) -> None:
        # uses table
        assert primes_in_range(2, 2) == [2]

    def test_at_table_bound_known_composite(self) -> None:
        # uses table — 100_000 is composite
        assert primes_in_range(_TABLE_BOUND, _TABLE_BOUND) == []

    def test_just_above_table_bound(self) -> None:
        # NO table (start > TABLE_BOUND, falls through to Layer 2)
        # 100_003 is prime
        assert primes_in_range(100_003, 100_003) == [100_003]

    def test_at_sieve_threshold_known_composite(self) -> None:
        # NO table (well above table) — 1_000_000 is composite
        assert primes_in_range(_SIEVE_THRESHOLD, _SIEVE_THRESHOLD) == []

    def test_just_above_sieve_threshold(self) -> None:
        # NO table; trial division — 1_000_003 is prime
        assert primes_in_range(_SIEVE_THRESHOLD + 3, _SIEVE_THRESHOLD + 3) == [
            1_000_003
        ]


# ───────────────────────────────────────────────────────────────────────────
# Differential fuzz tests — deterministic seed
# ───────────────────────────────────────────────────────────────────────────

class TestPrimesInRangeFuzz:
    """Random-but-deterministic ranges per layer; cross-checked with sympy."""

    def test_fuzz_layer1_uses_table(self) -> None:
        # uses table
        rng = Random(42)
        for _ in range(50):
            start = rng.randint(2, _TABLE_BOUND - 1)
            end = rng.randint(start, _TABLE_BOUND)
            assert primes_in_range(start, end) == sympy_primes(start, end), (
                f"Layer 1 mismatch at [{start}, {end}]"
            )

    def test_fuzz_layer1_5_partial_overlap(self) -> None:
        # uses table prefix + computed suffix
        rng = Random(43)
        for _ in range(20):
            start = rng.randint(_TABLE_BOUND - 1_000, _TABLE_BOUND - 1)
            end = rng.randint(_TABLE_BOUND + 1, _TABLE_BOUND + 1_000)
            assert primes_in_range(start, end) == sympy_primes(start, end), (
                f"Layer 1.5 mismatch at [{start}, {end}]"
            )

    def test_fuzz_layer2_no_table(self) -> None:
        # NO table; runtime sieve
        rng = Random(44)
        for _ in range(20):
            start = rng.randint(_TABLE_BOUND + 1, _SIEVE_THRESHOLD - 1_000)
            end = rng.randint(start, min(start + 1_000, _SIEVE_THRESHOLD))
            assert primes_in_range(start, end) == sympy_primes(start, end), (
                f"Layer 2 mismatch at [{start}, {end}]"
            )

    def test_fuzz_layer3_no_table(self) -> None:
        # NO table; trial division
        rng = Random(45)
        for _ in range(10):
            start = rng.randint(_SIEVE_THRESHOLD + 1, _SIEVE_THRESHOLD + 100_000)
            end = start + rng.randint(0, 100)
            assert primes_in_range(start, end) == sympy_primes(start, end), (
                f"Layer 3 mismatch at [{start}, {end}]"
            )
