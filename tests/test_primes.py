"""Unit tests for prime_service.primes — pure logic, no infra."""

import pytest

from prime_service.primes import primes_in_range

# π(1000) — the count of primes up to 1000 — is a well-known constant.
PI_1000 = 168


class TestBasicRanges:
    def test_classic_example(self) -> None:
        # Brief example: user provides 1 and 10 — but our floor is 2.
        # Caller is expected to clamp; we reject start < 2 explicitly.
        assert primes_in_range(2, 10) == [2, 3, 5, 7]

    def test_single_prime(self) -> None:
        assert primes_in_range(7, 7) == [7]

    def test_single_non_prime(self) -> None:
        assert primes_in_range(8, 8) == []

    def test_no_primes_in_range(self) -> None:
        assert primes_in_range(14, 16) == []

    def test_exactly_2(self) -> None:
        assert primes_in_range(2, 2) == [2]


class TestSievePath:
    def test_pi_1000(self) -> None:
        result = primes_in_range(2, 1000)
        assert len(result) == PI_1000
        assert result[0] == 2
        assert result[-1] == 997  # largest prime <= 1000

    def test_first_few_primes(self) -> None:
        expected = [2, 3, 5, 7, 11, 13, 17, 19, 23, 29]
        assert primes_in_range(2, 29) == expected


class TestTrialDivisionPath:
    """End > 10^6 forces the 6k±1 trial division branch."""

    def test_small_window_above_threshold(self) -> None:
        # The smallest prime > 10^6 is 1_000_003.
        result = primes_in_range(1_000_001, 1_000_010)
        assert 1_000_003 in result
        # Verify all returned numbers are actually prime by independent check.
        for n in result:
            assert all(n % d != 0 for d in range(2, int(n**0.5) + 1))

    def test_known_prime_above_threshold(self) -> None:
        # 1_000_033 is prime.
        assert 1_000_033 in primes_in_range(1_000_030, 1_000_040)


class TestValidation:
    def test_start_below_2(self) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            primes_in_range(1, 10)

    def test_negative_start(self) -> None:
        with pytest.raises(ValueError, match="start must be >= 2"):
            primes_in_range(-5, 10)

    def test_start_greater_than_end(self) -> None:
        with pytest.raises(ValueError, match="must be <= end"):
            primes_in_range(10, 5)

    def test_range_too_large(self) -> None:
        with pytest.raises(ValueError, match="range size"):
            primes_in_range(2, 100_000_000)


@pytest.mark.parametrize(
    ("start", "end", "expected"),
    [
        (2, 2, [2]),
        (3, 3, [3]),
        (2, 3, [2, 3]),
        (2, 5, [2, 3, 5]),
        (10, 20, [11, 13, 17, 19]),
        (90, 100, [97]),
        (97, 97, [97]),
        (98, 99, []),
    ],
)
def test_parametrised_ranges(start: int, end: int, expected: list[int]) -> None:
    assert primes_in_range(start, end) == expected
