"""Prime number generation in a bounded range.

Algorithm choice (layered cache + compute):
    Layer 1 — lookup table:
        Pre-computed sorted list of primes up to _TABLE_BOUND, built once at
        module load via Sieve of Eratosthenes. Range queries fully within the
        table bound are answered with bisect (O(log n) for the range ends) +
        a list slice (O(k) for the output), avoiding per-call sieve allocation.
    Layer 1.5 — partial overlap:
        When the query straddles _TABLE_BOUND, the cached prefix is taken from
        the table and the tail is computed on demand. This is the textbook
        "covered prefix + uncovered suffix" pattern.
    Layer 2 — Sieve of Eratosthenes (per-call):
        For ranges with end <= _SIEVE_THRESHOLD entirely above the table.
        Memory: O(end) booleans (~125 KB at 10**6); time: O(end * log log end).
    Layer 3 — trial division (6k±1):
        For end > _SIEVE_THRESHOLD. No sieve allocation;
        time: O(sqrt(n)) per candidate.

Bounds:
    - start >= 2 (1 is not prime by mathematical convention; reject explicitly
      rather than silently shifting to 2).
    - end - start <= 10_000_000 (memory and latency ceiling).

Edge cases handled:
    - Single prime (start == end == prime): returns [prime].
    - Single non-prime (start == end == composite): returns [].
    - Empty range (start > end): raises ValueError.
    - Partial overlap with table (start <= _TABLE_BOUND < end): cached prefix
      concatenated with freshly-computed tail.

Trade-offs:
    A segmented sieve would be optimal for large ranges with end > 10**6,
    but adds implementation complexity. The 6k±1 fallback is sufficient for
    the case-study scope and is easier to reason about. The lookup table
    pays a one-time module-load cost (~5-15 ms for _TABLE_BOUND = 10**5)
    and amortises across all subsequent in-range queries.
"""

from bisect import bisect_left, bisect_right
from collections.abc import Iterator

_TABLE_BOUND = 10**5
_SIEVE_THRESHOLD = 10**6
_RANGE_CEILING = 10_000_000


def _build_prime_table(bound: int) -> list[int]:
    """Build a sorted list of primes up to `bound` via Sieve of Eratosthenes.

    Called once at module load — see _PRIME_TABLE below.
    """
    is_prime = bytearray([1]) * (bound + 1)
    is_prime[0] = 0
    is_prime[1] = 0
    p = 2
    while p * p <= bound:
        if is_prime[p]:
            for multiple in range(p * p, bound + 1, p):
                is_prime[multiple] = 0
        p += 1
    return [n for n in range(2, bound + 1) if is_prime[n]]


# Pre-computed at module load — amortises sieve allocation across all queries
# whose range is fully (or partially) covered by [2, _TABLE_BOUND].
_PRIME_TABLE: list[int] = _build_prime_table(_TABLE_BOUND)


def primes_in_range(start: int, end: int) -> list[int]:
    """Return primes in the inclusive range [start, end].

    Layered strategy:
        Layer 1   — pre-computed table for [2, _TABLE_BOUND]
        Layer 1.5 — table prefix + computed suffix when the range straddles
        Layer 2   — Sieve of Eratosthenes for end <= _SIEVE_THRESHOLD
        Layer 3   — trial division (6k±1) for end > _SIEVE_THRESHOLD

    Raises:
        ValueError: if start < 2, start > end, or end - start > _RANGE_CEILING.
    """
    _validate(start, end)

    # Layer 1: fully within the lookup table
    if end <= _TABLE_BOUND:
        return _lookup_in_table(start, end)

    # Layer 1.5: partial overlap — table prefix + computed suffix
    if start <= _TABLE_BOUND:
        cached = _lookup_in_table(start, _TABLE_BOUND)
        computed = _compute(_TABLE_BOUND + 1, end)
        return cached + computed

    # Layer 2 / Layer 3: range entirely above the table — compute on demand
    return _compute(start, end)


def _validate(start: int, end: int) -> None:
    if start < 2:
        raise ValueError(f"start must be >= 2 (1 is not prime); got start={start}")
    if start > end:
        raise ValueError(f"start ({start}) must be <= end ({end})")
    if end - start > _RANGE_CEILING:
        raise ValueError(
            f"range size ({end - start}) exceeds ceiling ({_RANGE_CEILING}); "
            "split the request into smaller windows"
        )


def _lookup_in_table(start: int, end: int) -> list[int]:
    """Slice the precomputed prime table for the inclusive range [start, end].

    O(log n) per range bound via bisect; O(k) for the slice copy.
    """
    lo = bisect_left(_PRIME_TABLE, start)
    hi = bisect_right(_PRIME_TABLE, end)
    return _PRIME_TABLE[lo:hi]


def _compute(start: int, end: int) -> list[int]:
    """Runtime computation when the table doesn't cover the range.

    Picks Sieve vs trial division based on `_SIEVE_THRESHOLD`.
    """
    if end <= _SIEVE_THRESHOLD:
        return list(_sieve_eratosthenes(end, start))
    return list(_trial_division_6k(start, end))


def _sieve_eratosthenes(upper: int, start: int) -> Iterator[int]:
    """Sieve of Eratosthenes up to `upper`, yielding primes >= start."""
    is_prime = bytearray([1]) * (upper + 1)
    is_prime[0] = 0
    is_prime[1] = 0

    p = 2
    while p * p <= upper:
        if is_prime[p]:
            for multiple in range(p * p, upper + 1, p):
                is_prime[multiple] = 0
        p += 1

    for n in range(max(start, 2), upper + 1):
        if is_prime[n]:
            yield n


def _trial_division_6k(start: int, end: int) -> Iterator[int]:
    """Trial division using 6k±1 candidate generation, no sieve allocation."""
    for n in range(start, end + 1):
        if _is_prime_6k(n):
            yield n


def _is_prime_6k(n: int) -> bool:
    """Check primality using 6k±1: every prime > 3 has form 6k-1 or 6k+1."""
    if n < 2:
        return False
    if n < 4:  # 2, 3
        return True
    if n % 2 == 0 or n % 3 == 0:
        return False

    i = 5
    while i * i <= n:
        if n % i == 0 or n % (i + 2) == 0:
            return False
        i += 6
    return True
