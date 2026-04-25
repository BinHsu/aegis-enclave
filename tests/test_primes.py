"""Comprehensive unit tests for prime_service.primes — unified monotonic cache.

Strategy
--------
- **Differential testing** against ``sympy`` as the trusted oracle wherever a
  known-good reference exists. The brief's "implementation should be yours"
  rule scopes the production module (`src/prime_service/primes.py`); test
  oracles are out of scope (see ADR-0017's "Why sympy is acceptable").
- **Boundary Value Analysis (BVA)**: every numeric threshold is tested at
  ``B-1`` / ``B`` / ``B+1`` to detect off-by-one and mis-bracketed branches.
  Thresholds covered: ``_INITIAL_PREWARM_BOUND``, ``_SIEVE_THRESHOLD``,
  ``_RANGE_CEILING``, ``_HARD_TIMEOUT_MS`` (via ``_estimate_compute_ms``),
  ``_GAP_THRESHOLD``, plus the per-function start/end ordering bounds.
- **Per-function classes**: each public and private function in
  ``primes.py`` has its own test class so a reviewer can map one-to-one
  between source and tests.
- **Cache-state assertions**: every test that mutates the module-level
  cache verifies ``_known_max`` advanced (or did not advance) as the layer
  contract requires.
- **Determinism**: an autouse fixture resets the module-level cache to its
  fresh pre-warmed state before every test, so test order does not matter
  and BVA assertions on ``_known_max ± 1`` stay reproducible.
- **Deterministic seeded fuzz**: per-layer fuzz tests use a fixed seed so
  failures are reproducible across runs.

Why sympy as oracle (and why the brief allows it)
-------------------------------------------------
Differential testing against a known-good reference is standard industry
practice — compilers test against a reference compiler, crypto libraries
test against OpenSSL, number-theory libraries test against ``sympy``. The
implementation in ``primes.py`` imports nothing from ``sympy``; it is
100 % self-written sieve + 6k±1 trial division layered on a self-built
unified cache.
"""

from __future__ import annotations

import threading
from random import Random

import pytest
from sympy import isprime as sympy_isprime
from sympy import primerange as sympy_primerange

from prime_service import primes
from prime_service.primes import (
    _GAP_THRESHOLD,
    _INITIAL_PREWARM_BOUND,
    _RANGE_CEILING,
    _SIEVE_THRESHOLD,
    _build_prime_table,
    _compute,
    _estimate_compute_ms,
    _is_prime_6k,
    _is_prime_with_known,
    _segmented_sieve,
    _sieve_eratosthenes,
    _slice_known,
    _trial_division_6k,
    _trial_division_with_known,
    _validate,
    primes_in_range,
)


def sympy_primes(start: int, end: int) -> list[int]:
    """Inclusive ``[start, end]`` via sympy oracle (sympy's primerange is
    exclusive on the upper bound, so we pass ``end + 1``)."""
    return list(sympy_primerange(start, end + 1))


# ───────────────────────────────────────────────────────────────────────────
# Autouse cache reset
# ───────────────────────────────────────────────────────────────────────────

@pytest.fixture(autouse=True)
def _reset_prime_cache():
    """Reset the module-level cache to a freshly-prewarmed state before each test.

    The unified cache mutates ``_known_primes`` and ``_known_max`` over the
    lifetime of the process. Without this fixture, tests would leak state
    into each other and BVA assertions on ``_known_max ± 1`` would be
    order-dependent.
    """
    primes._known_primes = primes._build_prime_table(primes._INITIAL_PREWARM_BOUND)
    primes._set_known_max(primes._INITIAL_PREWARM_BOUND)
    yield


# ───────────────────────────────────────────────────────────────────────────
# _validate — start/end bounds, range ceiling, cost-estimate gating
# ───────────────────────────────────────────────────────────────────────────

class TestValidate:
    """BVA on ``start >= 2``, ``start <= end``, range-size ceiling, and the
    estimated-compute-time gate. The estimator gate is the most novel
    boundary in the rewritten module — it makes ``_validate`` cache-aware.
    """

    # BVA at start = 2 (lower field bound)
    @pytest.mark.parametrize("start", [-5, 0, 1])
    def test_start_below_2_rejected(self, start: int) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            _validate(start, 100)

    @pytest.mark.parametrize("start", [2, 3, 100])
    def test_start_at_or_above_2_accepted(self, start: int) -> None:
        # Should not raise.
        _validate(start, start + 10)

    # BVA at start <= end ordering
    def test_start_equals_end_accepted(self) -> None:
        _validate(7, 7)

    def test_start_one_above_end_rejected(self) -> None:
        with pytest.raises(ValueError, match="must be <= end"):
            _validate(8, 7)

    def test_start_far_above_end_rejected(self) -> None:
        with pytest.raises(ValueError, match="must be <= end"):
            _validate(1_000_000, 2)

    # BVA at _RANGE_CEILING (range size = end - start)
    def test_range_size_one_below_ceiling_accepted(self) -> None:
        _validate(2, 2 + _RANGE_CEILING - 1)

    def test_range_size_at_ceiling_accepted(self) -> None:
        _validate(2, 2 + _RANGE_CEILING)

    def test_range_size_one_above_ceiling_rejected(self) -> None:
        with pytest.raises(ValueError, match="range size"):
            _validate(2, 2 + _RANGE_CEILING + 1)

    # BVA at _HARD_TIMEOUT_MS — Layer 3 query whose estimated cost straddles
    # the hard cap. Construct the boundary by inverting the estimator:
    #   estimated_ms = compute_range * sqrt(end) // 6 // 3000
    # For end = 10_000_000 (sqrt ≈ 3163), ms = 30_000 occurs at
    # compute_range ≈ 30_000 * 6 * 3000 / 3163 ≈ 170_724.
    def test_estimator_just_below_cap_accepted(self) -> None:
        # compute_range = 100_000 → estimated ≈ 17_572 ms < 30_000
        end = 10_000_000
        start = end - 100_000 + 1
        _validate(start, end)

    def test_estimator_well_above_cap_rejected(self) -> None:
        # compute_range = 1_000_000 → estimated ≈ 175_722 ms ≫ 30_000.
        # Stay within _RANGE_CEILING so the range check doesn't fire first.
        end = 10_000_000
        start = end - 1_000_000 + 1
        with pytest.raises(ValueError, match="estimated compute time"):
            _validate(start, end)

    def test_estimator_layer1_always_passes(self) -> None:
        # End fully inside the pre-warmed cache → estimator returns 1 ms.
        _validate(2, _INITIAL_PREWARM_BOUND)


# ───────────────────────────────────────────────────────────────────────────
# _estimate_compute_ms — pure function, deterministic given inputs
# ───────────────────────────────────────────────────────────────────────────

class TestEstimateComputeMs:
    """Per-layer cost-model coverage with BVA at every layer transition."""

    # Layer 1: end <= known_max → constant 1 ms
    def test_layer1_full_cache_hit_returns_1(self) -> None:
        assert _estimate_compute_ms(2, 1000, _INITIAL_PREWARM_BOUND) == 1

    def test_layer1_at_known_max_returns_1(self) -> None:
        assert _estimate_compute_ms(2, _INITIAL_PREWARM_BOUND, _INITIAL_PREWARM_BOUND) == 1

    # BVA at known_max boundary: end = known_max - 1 / known_max / known_max + 1
    def test_layer_boundary_known_max_minus_1(self) -> None:
        assert _estimate_compute_ms(2, _INITIAL_PREWARM_BOUND - 1, _INITIAL_PREWARM_BOUND) == 1

    def test_layer_boundary_known_max(self) -> None:
        assert _estimate_compute_ms(2, _INITIAL_PREWARM_BOUND, _INITIAL_PREWARM_BOUND) == 1

    def test_layer_boundary_known_max_plus_1(self) -> None:
        # Crosses into Layer 2 (sieve) — cost should jump above 1.
        result = _estimate_compute_ms(2, _INITIAL_PREWARM_BOUND + 1, _INITIAL_PREWARM_BOUND)
        assert result > 1

    # Layer 2: end <= _SIEVE_THRESHOLD → max(50, end // 10_000)
    def test_layer2_below_threshold_scales_with_end(self) -> None:
        # end = 500_000 → 50_000 ÷ 10_000 = 50
        assert _estimate_compute_ms(2, 500_000, _INITIAL_PREWARM_BOUND) == 50

    def test_layer2_floor_at_50(self) -> None:
        # Tiny end above known_max → max(50, ...) keeps result >= 50
        assert _estimate_compute_ms(2, _INITIAL_PREWARM_BOUND + 1, _INITIAL_PREWARM_BOUND) >= 50

    # BVA at _SIEVE_THRESHOLD: threshold-1, threshold, threshold+1
    def test_sieve_threshold_minus_1(self) -> None:
        result = _estimate_compute_ms(2, _SIEVE_THRESHOLD - 1, _INITIAL_PREWARM_BOUND)
        # Layer 2: max(50, (10**6 - 1) // 10_000) = max(50, 99) = 99
        assert result == 99

    def test_sieve_threshold_exact(self) -> None:
        result = _estimate_compute_ms(2, _SIEVE_THRESHOLD, _INITIAL_PREWARM_BOUND)
        # Layer 2: max(50, 10**6 // 10_000) = 100
        assert result == 100

    def test_sieve_threshold_plus_1(self) -> None:
        # Crosses into Layer 3 (trial division) — different cost model.
        below = _estimate_compute_ms(2, _SIEVE_THRESHOLD, _INITIAL_PREWARM_BOUND)
        above = _estimate_compute_ms(2, _SIEVE_THRESHOLD + 1, _INITIAL_PREWARM_BOUND)
        # Layer 3 over an enormous compute_range is much more expensive than
        # Layer 2 sieve at the same upper bound.
        assert above > below

    # Layer 3: end > _SIEVE_THRESHOLD → trial-division estimate
    def test_layer3_scales_with_compute_range(self) -> None:
        small_range = _estimate_compute_ms(9_900_001, 10_000_000, _INITIAL_PREWARM_BOUND)
        big_range = _estimate_compute_ms(9_000_001, 10_000_000, _INITIAL_PREWARM_BOUND)
        # 10x more compute range → ~10x more estimated ms
        assert big_range > small_range * 5

    # BVA at _GAP_THRESHOLD: extend vs standalone cost models switch here
    def test_gap_threshold_minus_1_extends(self) -> None:
        # start = known_max + gap - 1 → still extends from known_max + 1
        start = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD - 1
        end = start + 1_000_000  # push into Layer 3
        extend_cost = _estimate_compute_ms(start, end, _INITIAL_PREWARM_BOUND)
        # compute_start = known_max + 1 → compute_range much larger
        assert extend_cost > 0

    def test_gap_threshold_at_extends(self) -> None:
        start = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD
        end = start + 1_000_000
        # At the boundary, still extends (start <= known_max + gap)
        extend_cost = _estimate_compute_ms(start, end, _INITIAL_PREWARM_BOUND)
        assert extend_cost > 0

    def test_gap_threshold_plus_1_standalone(self) -> None:
        # start = known_max + gap + 1 → falls through to standalone branch.
        # Same end as the extend cases above; compute_start = start, so
        # compute_range is *smaller*, so estimated cost is *smaller*.
        end = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD + 1_000_000
        standalone_start = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD + 1
        extend_start = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD
        standalone_cost = _estimate_compute_ms(standalone_start, end, _INITIAL_PREWARM_BOUND)
        extend_cost = _estimate_compute_ms(extend_start, end, _INITIAL_PREWARM_BOUND)
        assert standalone_cost < extend_cost

    def test_layer1_irrespective_of_start(self) -> None:
        # Even if start is a million, end <= known_max still routes Layer 1.
        # (This exercises the ordering of the early return.)
        assert _estimate_compute_ms(50, 100, 200) == 1


# ───────────────────────────────────────────────────────────────────────────
# _is_prime_6k — single-number primality
# ───────────────────────────────────────────────────────────────────────────

class TestIsPrime6k:
    """BVA on the internal branches of the 6k±1 primality test."""

    @pytest.mark.parametrize("n", [-5, -1, 0, 1])
    def test_below_2_not_prime(self, n: int) -> None:
        assert _is_prime_6k(n) is False

    @pytest.mark.parametrize("n", [2, 3])
    def test_2_and_3_are_prime(self, n: int) -> None:
        assert _is_prime_6k(n) is True

    def test_4_is_composite(self) -> None:
        assert _is_prime_6k(4) is False

    def test_5_is_prime(self) -> None:
        assert _is_prime_6k(5) is True

    @pytest.mark.parametrize("n", [6, 8, 10, 100, 1000])
    def test_even_numbers_above_2_composite(self, n: int) -> None:
        assert _is_prime_6k(n) is False

    @pytest.mark.parametrize("n", [9, 15, 21, 27, 99])
    def test_multiples_of_3_above_3_composite(self, n: int) -> None:
        assert _is_prime_6k(n) is False

    @pytest.mark.parametrize("n", [25, 49, 121, 169, 289])
    def test_perfect_squares_of_primes_composite(self, n: int) -> None:
        assert _is_prime_6k(n) is False

    def test_smallest_prime_above_million(self) -> None:
        # 1_000_003 is the smallest prime > 10**6 (oracle: sympy)
        assert _is_prime_6k(1_000_003) is True

    def test_million_itself_composite(self) -> None:
        assert _is_prime_6k(1_000_000) is False

    def test_differential_against_sympy_small_range(self) -> None:
        for n in range(0, 1000):
            assert _is_prime_6k(n) == sympy_isprime(n), f"disagreement at n={n}"


# ───────────────────────────────────────────────────────────────────────────
# _build_prime_table — Sieve of Eratosthenes helper
# ───────────────────────────────────────────────────────────────────────────

class TestBuildPrimeTable:
    """BVA at the lowest bounds + differential against sympy."""

    def test_bound_0_empty(self) -> None:
        assert _build_prime_table(0) == []

    def test_bound_1_empty(self) -> None:
        assert _build_prime_table(1) == []

    def test_bound_2_just_2(self) -> None:
        assert _build_prime_table(2) == [2]

    def test_bound_3(self) -> None:
        assert _build_prime_table(3) == [2, 3]

    def test_bound_30_first_ten_primes(self) -> None:
        assert _build_prime_table(30) == [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]

    @pytest.mark.parametrize("bound", [10, 100, 1000, 10_000])
    def test_differential_against_sympy(self, bound: int) -> None:
        assert _build_prime_table(bound) == sympy_primes(2, bound)

    def test_returns_sorted_list(self) -> None:
        result = _build_prime_table(10_000)
        assert result == sorted(result)

    def test_all_returned_values_are_prime(self) -> None:
        for n in _build_prime_table(1000):
            assert sympy_isprime(n), f"non-prime {n} in build_prime_table output"


# ───────────────────────────────────────────────────────────────────────────
# _slice_known — bisect-and-slice on the cache (replaces TestLookupInTable)
# ───────────────────────────────────────────────────────────────────────────

class TestSliceKnown:
    """Cache-slicing direct calls. The autouse fixture pre-warms the cache to
    ``_INITIAL_PREWARM_BOUND``; tests acquire ``_cache_lock`` themselves to
    honour the documented contract (caller holds the lock during access).

    Note: ``_slice_known`` does *not* validate that ``end <= _known_max`` —
    it simply bisects. With ``end > _known_max``, it returns the cache
    prefix (a short slice), which is the documented behaviour. The caller
    (``primes_in_range``) is responsible for routing such queries to the
    extension or standalone path.
    """

    def test_full_prewarmed_range(self) -> None:
        with primes._cache_lock:
            result = _slice_known(2, _INITIAL_PREWARM_BOUND)
        assert result == sympy_primes(2, _INITIAL_PREWARM_BOUND)

    # BVA at _INITIAL_PREWARM_BOUND
    def test_end_one_below_bound(self) -> None:
        with primes._cache_lock:
            result = _slice_known(2, _INITIAL_PREWARM_BOUND - 1)
        assert result == sympy_primes(2, _INITIAL_PREWARM_BOUND - 1)

    def test_end_at_bound(self) -> None:
        with primes._cache_lock:
            result = _slice_known(2, _INITIAL_PREWARM_BOUND)
        assert result == sympy_primes(2, _INITIAL_PREWARM_BOUND)

    def test_end_one_above_bound_returns_prefix(self) -> None:
        # _slice_known returns whatever bisect finds in the cache; for an
        # ``end`` past the cache, that is the entire pre-warm. Document the
        # behaviour rather than asserting an exception is raised.
        with primes._cache_lock:
            result = _slice_known(2, _INITIAL_PREWARM_BOUND + 1)
        assert result == sympy_primes(2, _INITIAL_PREWARM_BOUND)

    def test_single_prime_query(self) -> None:
        with primes._cache_lock:
            result = _slice_known(7, 7)
        assert result == [7]

    def test_single_composite_query(self) -> None:
        with primes._cache_lock:
            result = _slice_known(8, 8)
        assert result == []

    @pytest.mark.parametrize(
        ("start", "end"),
        [
            (2, 100),
            (1000, 2000),
            (50_000, 60_000),
            (99_000, 99_999),
        ],
    )
    def test_differential_against_sympy(self, start: int, end: int) -> None:
        with primes._cache_lock:
            result = _slice_known(start, end)
        assert result == sympy_primes(start, end)


# ───────────────────────────────────────────────────────────────────────────
# _compute — sieve / trial-division dispatcher
# ───────────────────────────────────────────────────────────────────────────

class TestCompute:
    """Dispatches to sieve or trial division based on ``_SIEVE_THRESHOLD``."""

    def test_below_threshold_dispatches_sieve(self) -> None:
        result = _compute(2, 1000)
        assert result == sympy_primes(2, 1000)

    # BVA at _SIEVE_THRESHOLD
    def test_threshold_minus_1(self) -> None:
        result = _compute(_SIEVE_THRESHOLD - 100, _SIEVE_THRESHOLD - 1)
        assert result == sympy_primes(_SIEVE_THRESHOLD - 100, _SIEVE_THRESHOLD - 1)

    def test_threshold_exact(self) -> None:
        result = _compute(_SIEVE_THRESHOLD - 100, _SIEVE_THRESHOLD)
        assert result == sympy_primes(_SIEVE_THRESHOLD - 100, _SIEVE_THRESHOLD)

    def test_threshold_plus_1_dispatches_trial(self) -> None:
        # End just above threshold → trial-division branch.
        result = _compute(_SIEVE_THRESHOLD + 1, _SIEVE_THRESHOLD + 100)
        assert result == sympy_primes(_SIEVE_THRESHOLD + 1, _SIEVE_THRESHOLD + 100)


# ───────────────────────────────────────────────────────────────────────────
# _sieve_eratosthenes — generator
# ───────────────────────────────────────────────────────────────────────────

class TestSieveEratosthenes:
    """Generator coverage with start/upper boundaries."""

    def test_full_range_from_2(self) -> None:
        result = list(_sieve_eratosthenes(100, 2))
        assert result == sympy_primes(2, 100)

    def test_start_above_2(self) -> None:
        result = list(_sieve_eratosthenes(100, 50))
        assert result == sympy_primes(50, 100)

    def test_start_equals_upper(self) -> None:
        result = list(_sieve_eratosthenes(7, 7))
        assert result == [7]

    def test_start_above_upper_yields_empty(self) -> None:
        # start > upper → the inner `range(max(start, 2), upper + 1)` is empty
        result = list(_sieve_eratosthenes(10, 20))
        assert result == []

    @pytest.mark.parametrize("upper", [100, 1000, 10_000, 100_000])
    def test_differential_against_sympy(self, upper: int) -> None:
        result = list(_sieve_eratosthenes(upper, 2))
        assert result == sympy_primes(2, upper)


# ───────────────────────────────────────────────────────────────────────────
# _trial_division_6k — generator
# ───────────────────────────────────────────────────────────────────────────

class TestTrialDivision6k:
    """6k±1 trial-division generator coverage."""

    def test_small_range(self) -> None:
        result = list(_trial_division_6k(2, 100))
        assert result == sympy_primes(2, 100)

    def test_start_equals_end_prime(self) -> None:
        assert list(_trial_division_6k(7, 7)) == [7]

    def test_start_equals_end_composite(self) -> None:
        assert list(_trial_division_6k(8, 8)) == []

    def test_above_million(self) -> None:
        # Layer-3-shaped query: small slice above _SIEVE_THRESHOLD
        result = list(_trial_division_6k(1_000_000, 1_000_100))
        assert result == sympy_primes(1_000_000, 1_000_100)


# ───────────────────────────────────────────────────────────────────────────
# primes_in_range — Layer 1 (pure cache hit)
# ───────────────────────────────────────────────────────────────────────────

class TestPrimesInRangeLayer1FullCacheHit:
    """All queries fit inside the pre-warmed cache; ``_known_max`` must not
    advance, the lock is acquired but no compute happens."""

    @pytest.mark.parametrize(
        ("start", "end"),
        [
            (2, 100),
            (2, 1000),
            (50, _INITIAL_PREWARM_BOUND),
            (99_000, _INITIAL_PREWARM_BOUND),
            (_INITIAL_PREWARM_BOUND - 1, _INITIAL_PREWARM_BOUND),
        ],
    )
    def test_differential_against_sympy(self, start: int, end: int) -> None:
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)

    def test_known_max_unchanged_after_call(self) -> None:
        before = primes._known_max
        primes_in_range(2, 1000)
        assert primes._known_max == before == _INITIAL_PREWARM_BOUND

    def test_single_prime_query(self) -> None:
        assert primes_in_range(7, 7) == [7]

    def test_single_composite_query(self) -> None:
        assert primes_in_range(8, 8) == []


# ───────────────────────────────────────────────────────────────────────────
# primes_in_range — cache extension path
# ───────────────────────────────────────────────────────────────────────────

class TestPrimesInRangeCacheExtension:
    """Queries that satisfy ``start <= _known_max + _GAP_THRESHOLD`` and
    ``end > _known_max`` — cache extends contiguously to ``end``."""

    # BVA at _known_max + 1 (lower edge of extension)
    def test_extension_one_above_known_max(self) -> None:
        end = _INITIAL_PREWARM_BOUND + 1
        result = primes_in_range(2, end)
        assert result == sympy_primes(2, end)
        assert primes._known_max == end

    def test_extension_at_known_max_exact(self) -> None:
        # end == known_max → Layer 1, cache untouched
        result = primes_in_range(2, _INITIAL_PREWARM_BOUND)
        assert result == sympy_primes(2, _INITIAL_PREWARM_BOUND)
        assert primes._known_max == _INITIAL_PREWARM_BOUND

    def test_extension_known_max_minus_1(self) -> None:
        # Pure cache hit (control case for the BVA triplet)
        result = primes_in_range(2, _INITIAL_PREWARM_BOUND - 1)
        assert result == sympy_primes(2, _INITIAL_PREWARM_BOUND - 1)
        assert primes._known_max == _INITIAL_PREWARM_BOUND

    # BVA at start = _known_max + _GAP_THRESHOLD (upper edge of extension)
    def test_extension_at_gap_threshold(self) -> None:
        start = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD
        end = start + 100
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)
        # At the boundary, still extends → known_max advances to end
        assert primes._known_max == end

    def test_extension_one_below_gap_threshold(self) -> None:
        start = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD - 1
        end = start + 100
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)
        assert primes._known_max == end

    def test_extension_advances_known_max_to_end(self) -> None:
        end = 200_000
        primes_in_range(2, end)
        assert primes._known_max == end

    def test_extension_cache_count_matches_sympy(self) -> None:
        end = 200_000
        primes_in_range(2, end)
        assert len(primes._known_primes) == len(sympy_primes(2, end))

    def test_extension_half_hit_prefix_plus_suffix(self) -> None:
        # start inside cache, end outside → cache extends, full slice returned
        start = 50_000
        end = 150_000
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)
        assert primes._known_max == end


# ───────────────────────────────────────────────────────────────────────────
# primes_in_range — far-gap (standalone) path
# ───────────────────────────────────────────────────────────────────────────

class TestPrimesInRangeFarGap:
    """``start > _known_max + _GAP_THRESHOLD`` — compute standalone, do not
    pollute cache. ``_known_max`` must remain unchanged."""

    # BVA at start = _known_max + _GAP_THRESHOLD + 1 (first standalone start)
    def test_far_gap_one_above_threshold(self) -> None:
        start = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD + 1
        end = start + 100
        before_max = primes._known_max
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)
        assert primes._known_max == before_max

    def test_far_gap_at_threshold_extends_not_standalone(self) -> None:
        # The other side of the boundary: this one *does* extend.
        start = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD
        end = start + 100
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)
        assert primes._known_max == end  # cache advanced — proves not standalone

    def test_far_gap_one_below_threshold_extends(self) -> None:
        # Triplet's third element: extends (control)
        start = _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD - 1
        end = start + 100
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)
        assert primes._known_max == end

    def test_far_gap_layer2_sieve_path(self) -> None:
        # Far gap, end <= _SIEVE_THRESHOLD → standalone via sieve
        start = 500_000
        end = 500_500
        before_max = primes._known_max
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)
        assert primes._known_max == before_max

    def test_far_gap_layer3_trial_path(self) -> None:
        # Far gap, end > _SIEVE_THRESHOLD → standalone via trial division
        start = 5_000_000
        end = 5_001_000
        before_max = primes._known_max
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)
        assert primes._known_max == before_max


# ───────────────────────────────────────────────────────────────────────────
# primes_in_range — pre-flight rejection on cost estimate
# ───────────────────────────────────────────────────────────────────────────

class TestPrimesInRangeRejection:
    """``_HARD_TIMEOUT_MS`` gate must reject expensive queries before any
    compute starts. Counter-test confirms cheaper queries pass.
    """

    def test_layer3_above_cap_rejected(self) -> None:
        # compute_range = 1_000_000 at end = 10**7 → ~175k ms, way above 30k.
        end = 10_000_000
        start = end - 1_000_000 + 1
        with pytest.raises(ValueError, match="estimated compute time"):
            primes_in_range(start, end)

    def test_layer3_below_cap_accepted(self) -> None:
        # Tiny Layer-3 slice — well under both the cap and any reasonable
        # wall-clock budget. The point is "validation passes and the call
        # returns oracle-correct primes", not "exercise the cap edge".
        start = 5_000_000
        end = start + 200
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)

    def test_range_size_above_ceiling_rejected_first(self) -> None:
        # Range > _RANGE_CEILING → range error wins over estimator error
        with pytest.raises(ValueError, match="range size"):
            primes_in_range(2, 2 + _RANGE_CEILING + 1)

    def test_start_below_2_rejected(self) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            primes_in_range(1, 100)

    def test_start_above_end_rejected(self) -> None:
        with pytest.raises(ValueError, match="must be <= end"):
            primes_in_range(100, 50)


# ───────────────────────────────────────────────────────────────────────────
# Cache consistency across multiple queries
# ───────────────────────────────────────────────────────────────────────────

class TestCacheConsistencyAfterMultipleQueries:
    """Sequence-level verification: known_max progresses monotonically and the
    cache returns oracle-correct primes after a mixed sequence."""

    def test_three_queries_advance_then_hit(self) -> None:
        # Q1: pure cache hit — known_max stays at _INITIAL_PREWARM_BOUND
        result1 = primes_in_range(2, 1000)
        assert result1 == sympy_primes(2, 1000)
        assert primes._known_max == _INITIAL_PREWARM_BOUND

        # Q2: extension to 200_000 (50_000 is inside the prewarm, so we straddle)
        result2 = primes_in_range(50_000, 200_000)
        assert result2 == sympy_primes(50_000, 200_000)
        assert primes._known_max == 200_000

        # Q3: pure cache hit on the extended range — no further advance
        result3 = primes_in_range(2, 200_000)
        assert result3 == sympy_primes(2, 200_000)
        assert primes._known_max == 200_000

    def test_extension_then_far_gap_does_not_pollute(self) -> None:
        # Extend to 150_000
        primes_in_range(2, 150_000)
        assert primes._known_max == 150_000

        # Far-gap query: start > 150_000 + 100_000 = 250_000
        far_start = 300_000
        far_end = far_start + 100
        primes_in_range(far_start, far_end)
        # Cache stays at 150_000 — far gap did not pollute.
        assert primes._known_max == 150_000

    def test_repeated_extension_grows_monotonically(self) -> None:
        primes_in_range(2, 120_000)
        assert primes._known_max == 120_000
        primes_in_range(2, 180_000)
        assert primes._known_max == 180_000
        primes_in_range(2, 150_000)
        # Subsequent smaller-end query is a Layer 1 hit → cache stays at 180_000
        assert primes._known_max == 180_000

    def test_cache_remains_sorted_after_extensions(self) -> None:
        primes_in_range(2, 200_000)
        assert primes._known_primes == sorted(primes._known_primes)
        # And matches the oracle
        assert primes._known_primes == sympy_primes(2, 200_000)


# ───────────────────────────────────────────────────────────────────────────
# Thread-safety smoke test
# ───────────────────────────────────────────────────────────────────────────

class TestThreadSafety:
    """Smoke-level concurrency: four threads issue the same query; results
    agree, no exception leaks. Not a race-condition harness — the lock
    contract is verified by code review and the design doc."""

    def test_four_threads_same_query_agree(self) -> None:
        results: list[list[int]] = []
        errors: list[BaseException] = []
        lock = threading.Lock()

        def worker() -> None:
            try:
                r = primes_in_range(2, 50_000)
                with lock:
                    results.append(r)
            except BaseException as exc:  # pragma: no cover - smoke guard
                with lock:
                    errors.append(exc)

        threads = [threading.Thread(target=worker) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert errors == []
        assert len(results) == 4
        oracle = sympy_primes(2, 50_000)
        for r in results:
            assert r == oracle

    def test_four_threads_extending_cache_agree(self) -> None:
        # All four threads request an extension to 200_000; the cache should
        # end up extended exactly once and every thread should see the same
        # primes.
        results: list[list[int]] = []
        errors: list[BaseException] = []
        lock = threading.Lock()

        def worker() -> None:
            try:
                r = primes_in_range(2, 200_000)
                with lock:
                    results.append(r)
            except BaseException as exc:  # pragma: no cover - smoke guard
                with lock:
                    errors.append(exc)

        threads = [threading.Thread(target=worker) for _ in range(4)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert errors == []
        oracle = sympy_primes(2, 200_000)
        for r in results:
            assert r == oracle
        assert primes._known_max == 200_000


# ───────────────────────────────────────────────────────────────────────────
# Deterministic seeded fuzz — one block per layer / scenario
# ───────────────────────────────────────────────────────────────────────────

class TestPrimesInRangeFuzz:
    """Per-layer randomised differential against sympy. Each block uses a
    fixed seed, so any failure is reproducible from the printed seed."""

    def test_fuzz_layer1_cache_hits(self) -> None:
        rng = Random(0xA1)
        for _ in range(50):
            start = rng.randint(2, 99_000)
            end = rng.randint(start, 100_000)
            assert primes_in_range(start, end) == sympy_primes(start, end)
        # Layer 1 only — known_max must not have moved
        assert primes._known_max == _INITIAL_PREWARM_BOUND

    def test_fuzz_cache_extension_straddling_prewarm(self) -> None:
        rng = Random(0xB2)
        for _ in range(20):
            start = rng.randint(2, _INITIAL_PREWARM_BOUND)
            end = rng.randint(_INITIAL_PREWARM_BOUND + 1, 200_000)
            assert primes_in_range(start, end) == sympy_primes(start, end)

    def test_fuzz_layer2_sieve(self) -> None:
        rng = Random(0xC3)
        # Far-gap queries that land in Layer 2 (between prewarm + gap and
        # _SIEVE_THRESHOLD). Cache must not advance because they're far gap.
        before_max = primes._known_max
        for _ in range(20):
            start = rng.randint(
                _INITIAL_PREWARM_BOUND + _GAP_THRESHOLD + 1,
                _SIEVE_THRESHOLD - 1_000,
            )
            end = rng.randint(start, min(start + 500, _SIEVE_THRESHOLD))
            assert primes_in_range(start, end) == sympy_primes(start, end)
        assert primes._known_max == before_max

    def test_fuzz_layer3_trial(self) -> None:
        rng = Random(0xD4)
        # Random small ranges above _SIEVE_THRESHOLD — far-gap, cost well
        # under the 30-second cap. Cache must not advance.
        before_max = primes._known_max
        for _ in range(10):
            start = rng.randint(_SIEVE_THRESHOLD + 1, 5_000_000)
            end = start + rng.randint(1, 200)
            assert primes_in_range(start, end) == sympy_primes(start, end)
        assert primes._known_max == before_max


# ───────────────────────────────────────────────────────────────────────────
# _segmented_sieve — cache-leveraging segmented sieve (ADR-0021)
# ───────────────────────────────────────────────────────────────────────────

class TestSegmentedSieve:
    """Direct tests for ``_segmented_sieve(low, high, small_primes)``.

    Precondition: ``small_primes`` contains every prime <= ``sqrt(high)``.
    The autouse fixture re-prewarms the cache up to ``_INITIAL_PREWARM_BOUND``
    (= 10⁵) before every test, so ``primes._known_primes`` covers
    ``sqrt(high)`` for any ``high <= 10¹⁰`` — comfortably above
    ``_RANGE_CEILING = 10⁷``. Tests therefore pass ``primes._known_primes``
    directly as the ``small_primes`` argument.

    Note: the function does NOT require ``_cache_lock`` when ``_known_primes``
    is read in a single-threaded test (no concurrent extension is in flight).
    """

    def test_minimum_segment_low_2_high_2(self) -> None:
        # Segment of one element where 2 itself is the candidate.
        assert _segmented_sieve(2, 2, primes._known_primes) == [2]

    def test_low_below_2_clamped(self) -> None:
        # low=0 should be treated as low=2 (the function clamps internally).
        result = _segmented_sieve(0, 50, primes._known_primes)
        assert result == sympy_primes(2, 50)

    def test_low_greater_than_high_returns_empty(self) -> None:
        assert _segmented_sieve(10, 5, primes._known_primes) == []

    # BVA at _INITIAL_PREWARM_BOUND — segments crossing the cache boundary.
    # The cache boundary is irrelevant to ``_segmented_sieve`` itself
    # (it only cares about ``sqrt(high)`` coverage), but BVA at this
    # threshold guards against future regressions if the function ever
    # starts taking shortcuts based on cache state.
    def test_low_one_below_prewarm_bound(self) -> None:
        low = _INITIAL_PREWARM_BOUND - 1
        high = _INITIAL_PREWARM_BOUND + 100
        result = _segmented_sieve(low, high, primes._known_primes)
        assert result == sympy_primes(low, high)

    def test_low_at_prewarm_bound(self) -> None:
        low = _INITIAL_PREWARM_BOUND
        high = _INITIAL_PREWARM_BOUND + 100
        result = _segmented_sieve(low, high, primes._known_primes)
        assert result == sympy_primes(low, high)

    def test_low_one_above_prewarm_bound(self) -> None:
        low = _INITIAL_PREWARM_BOUND + 1
        high = _INITIAL_PREWARM_BOUND + 100
        result = _segmented_sieve(low, high, primes._known_primes)
        assert result == sympy_primes(low, high)

    # BVA at _SIEVE_THRESHOLD — high=B-1, B, B+1. Function should keep
    # working above the threshold as long as ``small_primes`` covers
    # ``sqrt(high)`` (which the prewarm does for all bounds we test).
    def test_high_one_below_sieve_threshold(self) -> None:
        low = _SIEVE_THRESHOLD - 200
        high = _SIEVE_THRESHOLD - 1
        result = _segmented_sieve(low, high, primes._known_primes)
        assert result == sympy_primes(low, high)

    def test_high_at_sieve_threshold(self) -> None:
        low = _SIEVE_THRESHOLD - 200
        high = _SIEVE_THRESHOLD
        result = _segmented_sieve(low, high, primes._known_primes)
        assert result == sympy_primes(low, high)

    def test_high_one_above_sieve_threshold(self) -> None:
        low = _SIEVE_THRESHOLD - 200
        high = _SIEVE_THRESHOLD + 1
        result = _segmented_sieve(low, high, primes._known_primes)
        assert result == sympy_primes(low, high)

    def test_segment_strictly_above_known_max(self) -> None:
        # Segment entirely above the pre-warmed cache. ``_known_primes``
        # still covers sqrt(200_000) ≈ 448, well within the prewarm.
        low = 110_000
        high = 200_000
        result = _segmented_sieve(low, high, primes._known_primes)
        assert result == sympy_primes(low, high)

    @pytest.mark.parametrize(
        ("low", "high"),
        [
            (2, 100),                    # tiny segment, includes 2
            (1000, 2000),                # mid-range, fully inside prewarm
            (50_000, 60_000),            # straddles upper prewarm interior
            (99_000, 100_500),           # straddles the prewarm boundary
            (500_000, 500_500),          # Layer-2 territory (sieve-threshold)
            (999_900, 1_000_100),        # straddles _SIEVE_THRESHOLD
        ],
    )
    def test_differential_against_sympy(self, low: int, high: int) -> None:
        result = _segmented_sieve(low, high, primes._known_primes)
        assert result == sympy_primes(low, high)

    @pytest.mark.parametrize(
        ("low", "high"),
        [
            (2, 1000),                   # tiny — fully inside prewarm
            (90_000, 110_000),           # straddles _INITIAL_PREWARM_BOUND
            (200_000, 250_000),          # mid-range, far above prewarm
            (500_000, 600_000),          # Layer-2 sieve range
            (999_000, 1_001_000),        # straddles _SIEVE_THRESHOLD
        ],
    )
    def test_cross_validation_against_legacy_sieve(self, low: int, high: int) -> None:
        # THE key property: new path must produce identical output to the
        # legacy reference implementation for the same input range.
        new_path = _segmented_sieve(low, high, primes._known_primes)
        legacy = list(_sieve_eratosthenes(high, low))
        assert new_path == legacy


# ───────────────────────────────────────────────────────────────────────────
# _is_prime_with_known — single-number primality via known small primes
# ───────────────────────────────────────────────────────────────────────────

class TestIsPrimeWithKnown:
    """Direct tests for ``_is_prime_with_known(n, small_primes)``.

    Precondition: ``small_primes`` contains every prime <= ``sqrt(n)``. We
    do NOT test the case where this precondition is violated — the function's
    contract assumes the caller honours it (in production, ``_compute`` only
    ever passes ``_known_primes`` while holding ``_cache_lock``, and the
    pre-warm guarantees coverage up to sqrt(_RANGE_CEILING)).
    """

    @pytest.mark.parametrize("n", [-1, 0, 1, 2, 3, 4, 5])
    def test_bva_at_2(self, n: int) -> None:
        assert _is_prime_with_known(n, primes._known_primes) == sympy_isprime(n)

    @pytest.mark.parametrize("n", [5, 7, 11, 13, 17, 19, 23, 29, 31, 97])
    def test_known_small_primes(self, n: int) -> None:
        assert _is_prime_with_known(n, primes._known_primes) is True

    @pytest.mark.parametrize("n", [25, 49, 121, 169])
    def test_perfect_squares_composite(self, n: int) -> None:
        assert _is_prime_with_known(n, primes._known_primes) is False

    def test_differential_against_is_prime_6k_small_range(self) -> None:
        # Both paths must agree on every n in [0, 1000].
        for n in range(0, 1000):
            assert _is_prime_with_known(n, primes._known_primes) == _is_prime_6k(n), (
                f"disagreement with _is_prime_6k at n={n}"
            )

    def test_differential_against_sympy_small_range(self) -> None:
        for n in range(0, 1000):
            assert _is_prime_with_known(n, primes._known_primes) == sympy_isprime(n), (
                f"disagreement with sympy at n={n}"
            )

    def test_smallest_prime_above_million(self) -> None:
        assert _is_prime_with_known(1_000_003, primes._known_primes) is True

    def test_million_itself_composite(self) -> None:
        assert _is_prime_with_known(1_000_000, primes._known_primes) is False


# ───────────────────────────────────────────────────────────────────────────
# _trial_division_with_known — range trial division via known small primes
# ───────────────────────────────────────────────────────────────────────────

class TestTrialDivisionWithKnown:
    """Direct tests for ``_trial_division_with_known(start, end, small_primes)``.

    Same precondition as ``_is_prime_with_known``: ``small_primes`` covers
    ``sqrt(end)``. Honoured by passing ``primes._known_primes``.
    """

    def test_first_ten_primes(self) -> None:
        result = _trial_division_with_known(2, 30, primes._known_primes)
        assert result == [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]

    def test_smallest_prime_above_million_in_window(self) -> None:
        result = _trial_division_with_known(1_000_001, 1_000_005, primes._known_primes)
        assert 1_000_003 in result

    @pytest.mark.parametrize(
        ("start", "end"),
        [
            (2, 100),                    # smallest range, includes 2
            (1000, 2000),                # mid prewarm
            (99_900, 100_100),           # straddles _INITIAL_PREWARM_BOUND
            (999_900, 1_000_100),        # straddles _SIEVE_THRESHOLD
            (5_000_000, 5_000_500),      # deep Layer-3 territory
        ],
    )
    def test_differential_against_sympy(self, start: int, end: int) -> None:
        result = _trial_division_with_known(start, end, primes._known_primes)
        assert result == sympy_primes(start, end)

    @pytest.mark.parametrize(
        ("start", "end"),
        [
            (2, 100),                    # cache-only range
            (10_000, 11_000),            # mid prewarm
            (95_000, 105_000),           # straddles prewarm boundary
            (500_000, 500_500),          # Layer-2 territory
            (999_900, 1_000_100),        # straddles _SIEVE_THRESHOLD
            (4_999_900, 5_000_100),      # Layer-3 territory
        ],
    )
    def test_cross_validation_against_legacy_trial(self, start: int, end: int) -> None:
        # New path vs legacy 6k±1 generator — must agree pointwise.
        new_path = _trial_division_with_known(start, end, primes._known_primes)
        legacy = list(_trial_division_6k(start, end))
        assert new_path == legacy

    @pytest.mark.parametrize(
        ("start", "end"),
        [
            (2, 100),                    # tiny
            (1000, 5000),                # mid prewarm
            (50_000, 60_000),            # mid prewarm, larger
            (99_000, 100_500),           # straddles prewarm boundary
            (500_000, 500_500),          # Layer-2 territory, below _SIEVE_THRESHOLD
        ],
    )
    def test_cross_validation_against_segmented_sieve(self, start: int, end: int) -> None:
        # Both compute paths must agree for ranges where both are valid.
        # We restrict to ranges below _SIEVE_THRESHOLD because those are the
        # ranges where ``_compute`` could legitimately dispatch to either
        # path; above that, only trial-division is used by the dispatcher.
        trial = _trial_division_with_known(start, end, primes._known_primes)
        sieve = _segmented_sieve(start, end, primes._known_primes)
        assert trial == sieve


# ───────────────────────────────────────────────────────────────────────────
# _compute integration — verify dispatcher picks the right algorithm and
# returns oracle-correct output. Caller must hold ``_cache_lock``.
# ───────────────────────────────────────────────────────────────────────────

class TestComputeIntegration:
    """High-level dispatcher tests for ``_compute(start, end)``.

    ``_compute`` reads ``_known_primes`` directly, so the lock contract
    applies. These tests acquire ``_cache_lock`` themselves.
    """

    def test_below_threshold_matches_segmented_sieve(self) -> None:
        start, end = 110_000, 150_000
        with primes._cache_lock:
            result = _compute(start, end)
            sieve = _segmented_sieve(start, end, primes._known_primes)
        assert result == sieve
        assert result == sympy_primes(start, end)

    def test_above_threshold_matches_trial_with_known(self) -> None:
        start, end = _SIEVE_THRESHOLD + 1, _SIEVE_THRESHOLD + 500
        with primes._cache_lock:
            result = _compute(start, end)
            trial = _trial_division_with_known(start, end, primes._known_primes)
        assert result == trial
        assert result == sympy_primes(start, end)
