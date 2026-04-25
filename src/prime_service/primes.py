"""Prime number generation in a bounded range.

Algorithm choice:
    - For end <= 10**6: Sieve of Eratosthenes.
      Memory: O(end) booleans (~125 KB at 10**6); time: O(end * log log end).
    - For end > 10**6: Trial division using the 6k±1 optimisation per candidate.
      No sieve allocation; time: O(sqrt(n)) per candidate.

Bounds:
    - start >= 2 (1 is not prime by mathematical convention; reject explicitly
      rather than silently shifting to 2).
    - end - start <= 10_000_000 (memory and latency ceiling).

Edge cases handled:
    - Single prime (start == end == prime): returns [prime].
    - Single non-prime (start == end == composite): returns [].
    - Empty range (start > end): raises ValueError.

Trade-offs:
    A segmented sieve would be optimal for large ranges with end > 10**6,
    but adds implementation complexity. The 6k±1 fallback is sufficient for
    the case-study scope and is easier to reason about.
"""

from collections.abc import Iterator

_SIEVE_THRESHOLD = 10**6
_RANGE_CEILING = 10_000_000


def primes_in_range(start: int, end: int) -> list[int]:
    """Return primes in the inclusive range [start, end].

    Raises:
        ValueError: if start < 2, start > end, or end - start > _RANGE_CEILING.
    """
    _validate(start, end)

    if end <= _SIEVE_THRESHOLD:
        return list(_sieve_eratosthenes(end, start))

    return list(_trial_division_6k(start, end))


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
