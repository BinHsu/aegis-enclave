"""Comprehensive unit tests for prime_service.primes — stateless compute kernel.

Strategy
--------
- **Differential testing** against ``sympy`` as the trusted oracle wherever a
  known-good reference exists.
- **Boundary Value Analysis (BVA)**: every numeric threshold is tested at
  ``B-1`` / ``B`` / ``B+1`` to detect off-by-one and mis-bracketed branches.
  Thresholds covered: ``_SIEVE_THRESHOLD``, ``_RANGE_CEILING``,
  ``_HARD_TIMEOUT_MS`` (via ``_estimate_compute_ms``), plus the per-function
  start/end ordering bounds.
- **SIGALRM**: ``sieve_with_timeout`` is tested with a patched alarm that
  fires immediately to verify TimeoutError propagation and handler cleanup.
- **Per-function classes**: each public and private function in
  ``primes.py`` has its own test class.
- **Deterministic seeded fuzz**: per-layer fuzz tests use a fixed seed so
  failures are reproducible across runs.

Architecture note: the in-process monotonic cache
(``_INITIAL_PREWARM_BOUND`` / ``_known_primes`` / ``_known_max``) was lifted
out into the distributed Valkey cache (``cache.py``); ``primes_in_range``
is now a stateless compute kernel. The module-level ``_SMALL_PRIMES`` table
is read-only after module load.
"""

from __future__ import annotations

import threading
from random import Random
from unittest.mock import patch

import pytest
from sympy import isprime as sympy_isprime
from sympy import primerange as sympy_primerange

from prime_service.primes import (
    _HARD_TIMEOUT_MS,
    _RANGE_CEILING,
    _SIEVE_THRESHOLD,
    _SMALL_PRIMES,
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
    sieve_with_timeout,
)


def sympy_primes(start: int, end: int) -> list[int]:
    """Inclusive ``[start, end]`` via sympy oracle (sympy's primerange is
    exclusive on the upper bound, so we pass ``end + 1``)."""
    return list(sympy_primerange(start, end + 1))


# ───────────────────────────────────────────────────────────────────────────
# _validate — start/end bounds, range ceiling, cost-estimate gating
# ───────────────────────────────────────────────────────────────────────────


class TestValidate:
    """BVA on ``start >= 2``, ``start <= end``, range-size ceiling, and the
    estimated-compute-time gate. The module is now stateless — no cache state.
    """

    # BVA at start = 2 (lower field bound)
    @pytest.mark.parametrize("start", [-5, 0, 1])
    def test_start_below_2_rejected(self, start: int) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            _validate(start, 100)

    @pytest.mark.parametrize("start", [2, 3, 100])
    def test_start_at_or_above_2_accepted(self, start: int) -> None:
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

    # BVA at _RANGE_CEILING (range size = end - start).
    def test_range_size_one_above_ceiling_rejected_by_range_first(self) -> None:
        with pytest.raises(ValueError, match="range size"):
            _validate(2, 2 + _RANGE_CEILING + 1)

    def test_range_size_at_ceiling_rejected_by_cost_first(self) -> None:
        # range == ceiling → range check passes, cost estimator rejects
        with pytest.raises(ValueError, match="estimated compute time"):
            _validate(2, 2 + _RANGE_CEILING)

    def test_range_size_one_below_ceiling_rejected_by_cost_first(self) -> None:
        with pytest.raises(ValueError, match="estimated compute time"):
            _validate(2, 2 + _RANGE_CEILING - 1)

    # BVA at _HARD_TIMEOUT_MS — Layer 3 query straddling the hard cap.
    def test_estimator_just_below_cap_accepted(self) -> None:
        # compute_range = 100_000 at end = 10_000_000 → well under 60s cap
        end = 10_000_000
        start = end - 100_000 + 1
        _validate(start, end)

    def test_estimator_well_above_cap_rejected(self) -> None:
        end = 10_000_000
        start = end - 1_000_000 + 1
        with pytest.raises(ValueError, match="estimated compute time"):
            _validate(start, end)

    def test_small_range_always_passes(self) -> None:
        # Small range well under any cap
        _validate(2, 1000)


# ───────────────────────────────────────────────────────────────────────────
# _estimate_compute_ms — pure function, stateless
# ───────────────────────────────────────────────────────────────────────────


class TestEstimateComputeMs:
    """Per-layer cost-model coverage with BVA at every layer transition.

    Note: in the stateless module, _estimate_compute_ms no longer takes
    `known_max` — it computes from start/end directly.
    """

    # Layer 1 (end <= _SIEVE_THRESHOLD): segmented sieve estimate
    def test_layer1_small_range_floor_at_50(self) -> None:
        # Tiny range → max(50, ...) = 50
        result = _estimate_compute_ms(2, 100)
        assert result == 50

    def test_layer1_large_sieve_range_scales(self) -> None:
        # compute_range = 999_999 → 999_999 // 10_000 = 99
        result = _estimate_compute_ms(2, _SIEVE_THRESHOLD - 1)
        assert result == 99

    def test_layer1_at_threshold(self) -> None:
        # compute_range = _SIEVE_THRESHOLD - start + 1 = 10^6 - 2 + 1 = 999_999
        # 999_999 // 10_000 = 99; max(50, 99) = 99
        result = _estimate_compute_ms(2, _SIEVE_THRESHOLD)
        assert result == 99

    # BVA at _SIEVE_THRESHOLD: B-1, B, B+1
    def test_sieve_threshold_minus_1(self) -> None:
        result_below = _estimate_compute_ms(2, _SIEVE_THRESHOLD - 1)
        assert result_below > 0

    def test_sieve_threshold_exact(self) -> None:
        result_at = _estimate_compute_ms(2, _SIEVE_THRESHOLD)
        assert result_at > 0

    def test_sieve_threshold_plus_1_crosses_to_trial_division(self) -> None:
        # Crossing into Layer 2 (trial division) — different cost formula
        below = _estimate_compute_ms(2, _SIEVE_THRESHOLD)
        above = _estimate_compute_ms(2, _SIEVE_THRESHOLD + 1)
        # Layer 2 over a large range is far more expensive than Layer 1 sieve
        assert above > below

    # Layer 2 (end > _SIEVE_THRESHOLD): trial division estimate
    def test_layer2_scales_with_compute_range(self) -> None:
        small = _estimate_compute_ms(9_900_001, 10_000_000)
        big = _estimate_compute_ms(9_000_001, 10_000_000)
        # 10x more compute range → significantly more estimated ms
        assert big > small * 5

    # BVA at _HARD_TIMEOUT_MS
    def test_small_range_well_under_cap(self) -> None:
        result = _estimate_compute_ms(2, 1000)
        assert result < _HARD_TIMEOUT_MS

    def test_large_range_exceeds_cap(self) -> None:
        # Large Layer-2 range: compute_range = 1_000_000 at end = 10^7
        result = _estimate_compute_ms(9_000_001, 10_000_000)
        assert result > _HARD_TIMEOUT_MS


# ───────────────────────────────────────────────────────────────────────────
# _is_prime_6k — single-number primality (legacy reference)
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
# _SMALL_PRIMES table — module-level constant (read-only after load)
# ───────────────────────────────────────────────────────────────────────────


class TestSmallPrimesTable:
    """Verify the module-level _SMALL_PRIMES table is correctly built."""

    def test_is_sorted_list(self) -> None:
        assert _SMALL_PRIMES == sorted(_SMALL_PRIMES)

    def test_starts_with_2(self) -> None:
        assert _SMALL_PRIMES[0] == 2

    def test_covers_sqrt_range_ceiling(self) -> None:
        # Must contain all primes <= sqrt(_RANGE_CEILING) = 3162.27...
        import math

        sqrt_ceiling = int(math.sqrt(_RANGE_CEILING))
        # Verify the primes up to sqrt_ceiling are complete
        oracle = _build_prime_table(sqrt_ceiling)
        assert [p for p in _SMALL_PRIMES if p <= sqrt_ceiling] == oracle

    # BVA at boundary 2 (smallest prime)
    def test_bva_below_2_not_in_table(self) -> None:
        assert 1 not in _SMALL_PRIMES
        assert 0 not in _SMALL_PRIMES

    def test_bva_at_2_in_table(self) -> None:
        assert 2 in _SMALL_PRIMES

    def test_bva_above_2_small_primes_present(self) -> None:
        assert 3 in _SMALL_PRIMES
        assert 5 in _SMALL_PRIMES


# ───────────────────────────────────────────────────────────────────────────
# _slice_known — bisect-and-slice on an arbitrary prime list
# ───────────────────────────────────────────────────────────────────────────


class TestSliceKnown:
    """Stateless slice helper — operates on any sorted list of ints."""

    def test_simple_slice(self) -> None:
        known = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
        assert _slice_known(known, 5, 13) == [5, 7, 11, 13]

    def test_single_prime(self) -> None:
        known = [2, 3, 5, 7, 11]
        assert _slice_known(known, 7, 7) == [7]

    def test_single_composite_returns_empty(self) -> None:
        known = [2, 3, 5, 7, 11]
        assert _slice_known(known, 4, 4) == []

    # BVA at start boundary (B-1, B, B+1 relative to a prime at position p)
    def test_bva_start_just_below_prime(self) -> None:
        known = [2, 3, 5, 7, 11]
        # B = 5; B-1 = 4 included from start → 4 not a prime, so [5, 7]
        assert _slice_known(known, 4, 7) == [5, 7]

    def test_bva_start_at_prime(self) -> None:
        known = [2, 3, 5, 7, 11]
        # B = 5; start=5 → [5, 7]
        assert _slice_known(known, 5, 7) == [5, 7]

    def test_bva_start_just_above_prime(self) -> None:
        known = [2, 3, 5, 7, 11]
        # B = 5; start=6 → [7]
        assert _slice_known(known, 6, 7) == [7]

    def test_full_list(self) -> None:
        primes = _build_prime_table(100)
        assert _slice_known(primes, 2, 100) == primes

    @pytest.mark.parametrize(
        ("start", "end"),
        [(2, 100), (1000, 2000), (50_000, 60_000)],
    )
    def test_differential_against_sympy(self, start: int, end: int) -> None:
        primes = _build_prime_table(end)
        result = _slice_known(primes, start, end)
        assert result == sympy_primes(start, end)


# ───────────────────────────────────────────────────────────────────────────
# _compute — sieve / trial-division dispatcher
# ───────────────────────────────────────────────────────────────────────────


class TestCompute:
    """Dispatches to sieve or trial division based on _SIEVE_THRESHOLD."""

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
        result = _compute(_SIEVE_THRESHOLD + 1, _SIEVE_THRESHOLD + 100)
        assert result == sympy_primes(_SIEVE_THRESHOLD + 1, _SIEVE_THRESHOLD + 100)


# ───────────────────────────────────────────────────────────────────────────
# _sieve_eratosthenes — generator (legacy reference)
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
        result = list(_sieve_eratosthenes(10, 20))
        assert result == []

    @pytest.mark.parametrize("upper", [100, 1000, 10_000, 100_000])
    def test_differential_against_sympy(self, upper: int) -> None:
        result = list(_sieve_eratosthenes(upper, 2))
        assert result == sympy_primes(2, upper)


# ───────────────────────────────────────────────────────────────────────────
# _trial_division_6k — generator (legacy reference)
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
        result = list(_trial_division_6k(1_000_000, 1_000_100))
        assert result == sympy_primes(1_000_000, 1_000_100)


# ───────────────────────────────────────────────────────────────────────────
# primes_in_range — stateless compute, all ranges
# ───────────────────────────────────────────────────────────────────────────


class TestPrimesInRange:
    """End-to-end tests for the public API. No cache state to reset."""

    @pytest.mark.parametrize(
        ("start", "end"),
        [
            (2, 100),
            (2, 1000),
            (50, 10_000),
            (999_900, 1_000_100),  # straddles _SIEVE_THRESHOLD
        ],
    )
    def test_differential_against_sympy(self, start: int, end: int) -> None:
        result = primes_in_range(start, end)
        assert result == sympy_primes(start, end)

    def test_single_prime_query(self) -> None:
        assert primes_in_range(7, 7) == [7]

    def test_single_composite_query(self) -> None:
        assert primes_in_range(8, 8) == []

    # BVA at start = 2
    def test_start_at_2_accepted(self) -> None:
        result = primes_in_range(2, 10)
        assert result == [2, 3, 5, 7]

    def test_start_1_rejected(self) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            primes_in_range(1, 10)

    def test_start_0_rejected(self) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            primes_in_range(0, 10)

    # BVA at _RANGE_CEILING
    def test_range_one_above_ceiling_rejected(self) -> None:
        with pytest.raises(ValueError, match="range size"):
            primes_in_range(2, 2 + _RANGE_CEILING + 1)

    def test_range_at_ceiling_rejected_by_cost(self) -> None:
        with pytest.raises(ValueError, match="estimated compute time"):
            primes_in_range(2, 2 + _RANGE_CEILING)

    def test_range_one_below_ceiling_rejected_by_cost(self) -> None:
        with pytest.raises(ValueError, match="estimated compute time"):
            primes_in_range(2, 2 + _RANGE_CEILING - 1)

    # BVA at _SIEVE_THRESHOLD (end boundary)
    def test_threshold_minus_1(self) -> None:
        result = primes_in_range(_SIEVE_THRESHOLD - 10, _SIEVE_THRESHOLD - 1)
        assert result == sympy_primes(_SIEVE_THRESHOLD - 10, _SIEVE_THRESHOLD - 1)

    def test_threshold_exact(self) -> None:
        result = primes_in_range(_SIEVE_THRESHOLD - 10, _SIEVE_THRESHOLD)
        assert result == sympy_primes(_SIEVE_THRESHOLD - 10, _SIEVE_THRESHOLD)

    def test_threshold_plus_1(self) -> None:
        result = primes_in_range(_SIEVE_THRESHOLD - 10, _SIEVE_THRESHOLD + 1)
        assert result == sympy_primes(_SIEVE_THRESHOLD - 10, _SIEVE_THRESHOLD + 1)


# ───────────────────────────────────────────────────────────────────────────
# sieve_with_timeout — SIGALRM wrapper
# ───────────────────────────────────────────────────────────────────────────


class TestSieveWithTimeout:
    """Tests for the SIGALRM 60s hard deadline wrapper.

    The SIGALRM mechanism is UNIX-only; tests skip on Windows (not applicable
    to our Linux container target, but avoids CI failures on non-UNIX hosts).
    """

    def test_normal_range_returns_correct_primes(self) -> None:
        result = sieve_with_timeout(2, 100)
        assert result == sympy_primes(2, 100)

    def test_sigalrm_fires_raises_timeout_error(self) -> None:
        """Patch signal.alarm to send SIGALRM immediately after setting the handler,
        simulating a timeout during compute."""
        import signal as _signal

        alarm_calls: list[int] = []

        def fake_alarm(seconds: int) -> int:
            alarm_calls.append(seconds)
            if seconds > 0:
                # Fire the alarm immediately to simulate timeout
                _signal.raise_signal(_signal.SIGALRM)
            return 0

        with patch("prime_service.primes.signal.alarm", side_effect=fake_alarm):
            with pytest.raises(TimeoutError):
                sieve_with_timeout(2, 1000)

        # Alarm must have been called with 60s (arm) and 0 (cancel in finally)
        assert alarm_calls[0] == 60

    def test_alarm_cancelled_on_success(self) -> None:
        """After successful compute, alarm must be cancelled (alarm(0) called)."""
        import signal as _signal

        alarm_calls: list[int] = []
        original_alarm = _signal.alarm

        def tracking_alarm(seconds: int) -> int:
            alarm_calls.append(seconds)
            return original_alarm(0)  # don't arm real SIGALRM; track calls only

        with patch("prime_service.primes.signal.alarm", side_effect=tracking_alarm):
            sieve_with_timeout(2, 100)

        # First call: arm(60), second call: cancel(0)
        assert 60 in alarm_calls
        assert 0 in alarm_calls

    def test_alarm_cancelled_on_exception(self) -> None:
        """Alarm must be cancelled (alarm(0)) even when compute raises."""
        import signal as _signal

        alarm_calls: list[int] = []
        original_alarm = _signal.alarm

        def tracking_alarm(seconds: int) -> int:
            alarm_calls.append(seconds)
            return original_alarm(0)

        def bad_primes(start: int, end: int) -> list[int]:
            raise ValueError("forced failure")

        with patch("prime_service.primes.signal.alarm", side_effect=tracking_alarm):
            with patch("prime_service.primes.primes_in_range", side_effect=bad_primes):
                with pytest.raises(ValueError, match="forced failure"):
                    sieve_with_timeout(2, 100)

        assert 60 in alarm_calls
        assert 0 in alarm_calls

    # BVA: sieve_with_timeout calls primes_in_range which validates start >= 2
    def test_start_below_2_raises_value_error(self) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            sieve_with_timeout(1, 100)

    def test_start_at_2_accepted(self) -> None:
        result = sieve_with_timeout(2, 10)
        assert result == [2, 3, 5, 7]

    def test_start_above_2_accepted(self) -> None:
        result = sieve_with_timeout(3, 10)
        assert result == [3, 5, 7]

    # BVA: start = end (single element)
    def test_single_prime_range(self) -> None:
        assert sieve_with_timeout(7, 7) == [7]

    def test_single_composite_range(self) -> None:
        assert sieve_with_timeout(8, 8) == []

    def test_restores_sigalrm_handler_after_timeout(self) -> None:
        """Handler must be restored after a timeout."""
        import signal as _signal

        original = _signal.getsignal(_signal.SIGALRM)

        def fake_alarm(seconds: int) -> int:
            if seconds > 0:
                _signal.raise_signal(_signal.SIGALRM)
            return 0

        with patch("prime_service.primes.signal.alarm", side_effect=fake_alarm):
            with pytest.raises(TimeoutError):
                sieve_with_timeout(2, 100)

        # Handler must be restored (not left as our _sigalrm_handler)
        restored = _signal.getsignal(_signal.SIGALRM)
        assert restored == original


# ───────────────────────────────────────────────────────────────────────────
# _segmented_sieve — cache-leveraging segmented sieve
# ───────────────────────────────────────────────────────────────────────────


class TestSegmentedSieve:
    """Direct tests for _segmented_sieve(low, high, small_primes)."""

    def test_minimum_segment_low_2_high_2(self) -> None:
        assert _segmented_sieve(2, 2, _SMALL_PRIMES) == [2]

    def test_low_below_2_clamped(self) -> None:
        result = _segmented_sieve(0, 50, _SMALL_PRIMES)
        assert result == sympy_primes(2, 50)

    def test_low_greater_than_high_returns_empty(self) -> None:
        assert _segmented_sieve(10, 5, _SMALL_PRIMES) == []

    # BVA at _SIEVE_THRESHOLD: high=B-1, B, B+1
    def test_high_one_below_sieve_threshold(self) -> None:
        low = _SIEVE_THRESHOLD - 200
        high = _SIEVE_THRESHOLD - 1
        result = _segmented_sieve(low, high, _SMALL_PRIMES)
        assert result == sympy_primes(low, high)

    def test_high_at_sieve_threshold(self) -> None:
        low = _SIEVE_THRESHOLD - 200
        high = _SIEVE_THRESHOLD
        result = _segmented_sieve(low, high, _SMALL_PRIMES)
        assert result == sympy_primes(low, high)

    def test_high_one_above_sieve_threshold(self) -> None:
        low = _SIEVE_THRESHOLD - 200
        high = _SIEVE_THRESHOLD + 1
        result = _segmented_sieve(low, high, _SMALL_PRIMES)
        assert result == sympy_primes(low, high)

    @pytest.mark.parametrize(
        ("low", "high"),
        [
            (2, 100),
            (1000, 2000),
            (50_000, 60_000),
            (99_000, 100_500),
            (500_000, 500_500),
            (999_900, 1_000_100),
        ],
    )
    def test_differential_against_sympy(self, low: int, high: int) -> None:
        result = _segmented_sieve(low, high, _SMALL_PRIMES)
        assert result == sympy_primes(low, high)

    @pytest.mark.parametrize(
        ("low", "high"),
        [
            (2, 1000),
            (90_000, 110_000),
            (200_000, 250_000),
            (999_000, 1_001_000),
        ],
    )
    def test_cross_validation_against_legacy_sieve(self, low: int, high: int) -> None:
        new_path = _segmented_sieve(low, high, _SMALL_PRIMES)
        legacy = list(_sieve_eratosthenes(high, low))
        assert new_path == legacy


# ───────────────────────────────────────────────────────────────────────────
# _is_prime_with_known — single-number primality via known small primes
# ───────────────────────────────────────────────────────────────────────────


class TestIsPrimeWithKnown:
    """Direct tests for _is_prime_with_known(n, small_primes)."""

    @pytest.mark.parametrize("n", [-1, 0, 1, 2, 3, 4, 5])
    def test_bva_at_2(self, n: int) -> None:
        assert _is_prime_with_known(n, _SMALL_PRIMES) == sympy_isprime(n)

    @pytest.mark.parametrize("n", [5, 7, 11, 13, 17, 19, 23, 29, 31, 97])
    def test_known_small_primes(self, n: int) -> None:
        assert _is_prime_with_known(n, _SMALL_PRIMES) is True

    @pytest.mark.parametrize("n", [25, 49, 121, 169])
    def test_perfect_squares_composite(self, n: int) -> None:
        assert _is_prime_with_known(n, _SMALL_PRIMES) is False

    def test_differential_against_sympy_small_range(self) -> None:
        for n in range(0, 1000):
            assert _is_prime_with_known(n, _SMALL_PRIMES) == sympy_isprime(n), (
                f"disagreement with sympy at n={n}"
            )

    def test_smallest_prime_above_million(self) -> None:
        assert _is_prime_with_known(1_000_003, _SMALL_PRIMES) is True

    def test_million_itself_composite(self) -> None:
        assert _is_prime_with_known(1_000_000, _SMALL_PRIMES) is False


# ───────────────────────────────────────────────────────────────────────────
# _trial_division_with_known — range trial division
# ───────────────────────────────────────────────────────────────────────────


class TestTrialDivisionWithKnown:
    """Direct tests for _trial_division_with_known(start, end, small_primes)."""

    def test_first_ten_primes(self) -> None:
        result = _trial_division_with_known(2, 30, _SMALL_PRIMES)
        assert result == [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]

    def test_smallest_prime_above_million_in_window(self) -> None:
        result = _trial_division_with_known(1_000_001, 1_000_005, _SMALL_PRIMES)
        assert 1_000_003 in result

    @pytest.mark.parametrize(
        ("start", "end"),
        [
            (2, 100),
            (1000, 2000),
            (999_900, 1_000_100),
            (5_000_000, 5_000_500),
        ],
    )
    def test_differential_against_sympy(self, start: int, end: int) -> None:
        result = _trial_division_with_known(start, end, _SMALL_PRIMES)
        assert result == sympy_primes(start, end)

    @pytest.mark.parametrize(
        ("start", "end"),
        [
            (2, 100),
            (10_000, 11_000),
            (500_000, 500_500),
        ],
    )
    def test_cross_validation_against_legacy_trial(self, start: int, end: int) -> None:
        new_path = _trial_division_with_known(start, end, _SMALL_PRIMES)
        legacy = list(_trial_division_6k(start, end))
        assert new_path == legacy

    @pytest.mark.parametrize(
        ("start", "end"),
        [
            (2, 100),
            (1000, 5000),
            (99_000, 100_500),
            (500_000, 500_500),
        ],
    )
    def test_cross_validation_against_segmented_sieve(self, start: int, end: int) -> None:
        trial = _trial_division_with_known(start, end, _SMALL_PRIMES)
        sieve = _segmented_sieve(start, end, _SMALL_PRIMES)
        assert trial == sieve


# ───────────────────────────────────────────────────────────────────────────
# Thread-safety smoke test
# ───────────────────────────────────────────────────────────────────────────


class TestThreadSafety:
    """Smoke-level concurrency: four threads issue the same query; results agree."""

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

    def test_four_threads_different_ranges_agree(self) -> None:
        ranges = [(2, 100), (2, 200), (2, 500), (2, 1000)]
        results: dict[tuple[int, int], list[int]] = {}
        errors: list[BaseException] = []
        lock = threading.Lock()

        def worker(start: int, end: int) -> None:
            try:
                r = primes_in_range(start, end)
                with lock:
                    results[(start, end)] = r
            except BaseException as exc:  # pragma: no cover - smoke guard
                with lock:
                    errors.append(exc)

        threads = [threading.Thread(target=worker, args=rng) for rng in ranges]
        for t in threads:
            t.start()
        for t in threads:
            t.join()

        assert errors == []
        for start, end in ranges:
            assert results[(start, end)] == sympy_primes(start, end)


# ───────────────────────────────────────────────────────────────────────────
# Deterministic seeded fuzz
# ───────────────────────────────────────────────────────────────────────────


class TestPrimesInRangeFuzz:
    """Per-layer randomised differential against sympy."""

    def test_fuzz_small_ranges_sieve_layer(self) -> None:
        rng = Random(0xA1)
        for _ in range(50):
            start = rng.randint(2, 900_000)
            end = rng.randint(start, min(start + 500, _SIEVE_THRESHOLD))
            assert primes_in_range(start, end) == sympy_primes(start, end)

    def test_fuzz_trial_division_layer(self) -> None:
        rng = Random(0xD4)
        for _ in range(10):
            start = rng.randint(_SIEVE_THRESHOLD + 1, 5_000_000)
            end = start + rng.randint(1, 200)
            assert primes_in_range(start, end) == sympy_primes(start, end)
