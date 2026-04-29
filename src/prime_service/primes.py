"""Prime number generation in a bounded range.

This module is a pure stateless compute kernel — each call to
`primes_in_range` runs the appropriate algorithm from scratch (segmented
sieve or trial division) with no mutable module-level state. Pre-warming
and range-coalescing live in the distributed Valkey cache layer
(`cache.py`) and the one-shot bootstrap task (`bootstrap.py`).

Algorithm selection:
    - end <= _SIEVE_THRESHOLD: segmented Sieve of Eratosthenes — O(n log log n)
    - end > _SIEVE_THRESHOLD: 6k±1 trial division — correct for all n,
      no sieve memory allocation

Compute budget:
    - `_HARD_TIMEOUT_MS = 60_000` — pre-flight estimator in `_validate`
      rejects requests whose estimated wall-clock cost would exceed this.
    - `signal.alarm(60)` SIGALRM wrapper in `sieve_with_timeout` — catches
      CPU-bound infinite loops that `asyncio.wait_for` cannot interrupt.
      RATIONALE: queue redelivery rescues the SQS message, but NOT a stuck
      worker (CPU-bound Python loops hold the GIL and have no OOM path).
      Only SIGALRM interrupts a pure-Python CPU-bound loop. See the memory
      note `feedback_safety_guard_recovery_test.md` (see also ADR-0033).

Bounds:
    - start >= 2 (1 is not prime; reject explicitly)
    - start <= end
    - end - start <= _RANGE_CEILING (memory ceiling)
    - estimated compute time <= _HARD_TIMEOUT_MS (DoS guard)

Legacy reference implementations (`_sieve_eratosthenes`, `_trial_division_6k`,
`_is_prime_6k`) are retained for cross-validation tests and as a reference
fallback; they are NOT called from the production runtime path.
"""

import signal
import threading
from bisect import bisect_left, bisect_right
from collections.abc import Iterator

_SIEVE_THRESHOLD = 10**6
_RANGE_CEILING = 10_000_000
_HARD_TIMEOUT_MS = 60_000

# Small-prime table used by sieve and trial-division paths.
# Built once at module load; covers all primes <= sqrt(_RANGE_CEILING) = 3163.
# This is a module-level constant (read-only after build), not a mutable cache.
_SMALL_PRIMES: list[int] = []


def _build_prime_table(bound: int) -> list[int]:
    """Build a sorted list of primes up to `bound` via Sieve of Eratosthenes.

    Used both at module load (for the small-primes table) and (in tests) to
    construct expected oracle values when sympy is not available.
    """
    if bound < 2:
        return []
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


# Build the small-prime table at module load (covers sqrt(_RANGE_CEILING)).
_SMALL_PRIMES = _build_prime_table(int(_RANGE_CEILING**0.5) + 1)

# Lock guards the small-prime table read in _segmented_sieve / _compute
# when called concurrently. The table itself is read-only after module load,
# but Python list access during iteration is not guaranteed safe under all
# threading models without explicit synchronisation.
_table_lock = threading.Lock()


# ─── SIGALRM timeout wrapper ──────────────────────────────────────────────────

_SIGALRM_SECONDS = 60  # hard compute budget for the worker path


def _sigalrm_handler(signum: int, frame: object) -> None:
    """SIGALRM handler: raise TimeoutError to interrupt CPU-bound compute."""
    raise TimeoutError("sieve computation exceeded SIGALRM budget")


def sieve_with_timeout(start: int, end: int) -> list[int]:
    """Compute primes_in_range under a SIGALRM 60s hard deadline.

    SIGALRM is the only mechanism that can interrupt a CPU-bound Python loop
    (asyncio.wait_for / threading timeouts cannot preempt the GIL holder).
    This function is intended for the worker process (not the async API server).

    On SIGALRM expiry: raises TimeoutError.
    Caller is responsible for catching TimeoutError and writing status=failed.

    NOTE: signal.alarm is process-wide and UNIX-only (not Windows-compatible).
    The worker is expected to run in a Linux container (Fargate/Docker).
    """
    old_handler = signal.signal(signal.SIGALRM, _sigalrm_handler)
    signal.alarm(_SIGALRM_SECONDS)
    try:
        return primes_in_range(start, end)
    finally:
        signal.alarm(0)  # cancel pending alarm
        signal.signal(signal.SIGALRM, old_handler)  # restore prior handler


# ─── Validation & estimation ──────────────────────────────────────────────────


def _estimate_compute_ms(start: int, end: int) -> int:
    """Estimate compute time in milliseconds (stateless, no cache state).

    Calibrated against M4 / Fargate t4g.medium. Conservative — over-estimate
    is fine (we cut early on 'too slow').

    Layer selection mirrors `primes_in_range`:
      - end <= _SIEVE_THRESHOLD: segmented sieve, ~1 ms per 10⁴ compute_range
      - end > _SIEVE_THRESHOLD: trial division, compute_range × sqrt(end) / 6 / 7000
    """
    if end <= _SIEVE_THRESHOLD:
        compute_range = end - start + 1
        return max(50, compute_range // 10_000)

    compute_range = end - start + 1
    sqrt_max = int(end**0.5) + 1
    estimated_ops = compute_range * sqrt_max // 6
    return estimated_ops // 7_000


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
    estimated = _estimate_compute_ms(start, end)
    if estimated > _HARD_TIMEOUT_MS:
        raise ValueError(
            f"estimated compute time {estimated} ms exceeds {_HARD_TIMEOUT_MS} ms "
            f"ceiling; split into smaller windows (start={start}, end={end})"
        )


def primes_in_range(start: int, end: int) -> list[int]:
    """Return primes in the inclusive range [start, end].

    Raises:
        ValueError: if start < 2, start > end, range > _RANGE_CEILING,
            or estimated compute time exceeds the hard timeout.
    """
    _validate(start, end)
    return _compute(start, end)


def _compute(start: int, end: int) -> list[int]:
    """Runtime computation — algorithm chosen by end vs _SIEVE_THRESHOLD.

    Uses the module-level _SMALL_PRIMES table (read-only after module load).
    """
    if end <= _SIEVE_THRESHOLD:
        with _table_lock:
            small = list(_SMALL_PRIMES)
        return _segmented_sieve(start, end, small)
    with _table_lock:
        small = list(_SMALL_PRIMES)
    return _trial_division_with_known(start, end, small)


def _slice_known(known: list[int], start: int, end: int) -> list[int]:
    """Bisect-slice a sorted prime list for the inclusive range [start, end].

    Used by the cache layer (bootstrap/worker) when retrieving a sub-range
    from a cached larger range. Not part of the stateless compute path.
    """
    lo = bisect_left(known, start)
    hi = bisect_right(known, end)
    return known[lo:hi]


def _segmented_sieve(low: int, high: int, small_primes: list[int]) -> list[int]:
    """Segmented Sieve of Eratosthenes over [low, high] using `small_primes`.

    Requires: `small_primes` contains all primes <= sqrt(high).
    Memory: O(high - low + 1) bytearray.
    Time: O((high - low) × log log high).
    """
    if low < 2:
        low = 2
    if low > high:
        return []

    seg_size = high - low + 1
    seg = bytearray([1]) * seg_size

    for p in small_primes:
        if p * p > high:
            break
        first_mult = max(p * p, ((low + p - 1) // p) * p)
        for m in range(first_mult, high + 1, p):
            seg[m - low] = 0

    return [low + i for i in range(seg_size) if seg[i]]


def _is_prime_with_known(n: int, small_primes: list[int]) -> bool:
    """Single primality check via trial division by `small_primes`.

    Requires: `small_primes` contains all primes <= sqrt(n).
    """
    if n < 2:
        return False
    if n < 4:  # 2, 3
        return True
    if n % 2 == 0 or n % 3 == 0:
        return False
    for p in small_primes:
        if p * p > n:
            return True
        if p < 5:  # 2, 3 already filtered above
            continue
        if n % p == 0:
            return False
    return True


def _trial_division_with_known(start: int, end: int, small_primes: list[int]) -> list[int]:
    """Trial division over [start, end] using `small_primes` as divisors."""
    return [n for n in range(start, end + 1) if _is_prime_with_known(n, small_primes)]


# ─── Legacy reference implementations ─────────────────────────────────────────
# These three functions are NOT called from the production runtime path.
# Retained for cross-validation in tests/test_primes.py.


def _sieve_eratosthenes(upper: int, start: int) -> Iterator[int]:
    """Sieve of Eratosthenes up to `upper`, yielding primes >= start.

    LEGACY REFERENCE — not called from production runtime.
    """
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
    """Trial division using 6k±1 candidate generation.

    LEGACY REFERENCE — not called from production runtime.
    """
    for n in range(start, end + 1):
        if _is_prime_6k(n):
            yield n


def _is_prime_6k(n: int) -> bool:
    """Check primality using 6k±1: every prime > 3 has form 6k-1 or 6k+1.

    LEGACY REFERENCE — not called from production runtime.
    """
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
