"""Prime number generation in a bounded range — unified monotonic cache.

See ADR-0020 (`docs/ADR/0020-unified-prime-cache-and-cost-estimator.md`)
and ADR-0021 (`docs/ADR/0021-cache-leveraging-compute-paths.md`) for the
full rationale; ADR-0017's tuple-immutability posture for the prior
static `_PRIME_TABLE` is partially superseded — see "Trade-offs" below.

Algorithm:
    A single shared `_known_primes` list, pre-warmed at module load with
    primes up to `_INITIAL_PREWARM_BOUND` via Sieve of Eratosthenes. Each
    incoming query either:
      - hits the cache fully (`end <= _known_max`) — bisect-and-slice,
        sub-millisecond
      - extends the cache contiguously (`start <= _known_max + _GAP_THRESHOLD`)
        — compute (`_known_max + 1`, `end`), append, return slice
      - computes standalone (`start > _known_max + _GAP_THRESHOLD`) —
        far-gap query that would balloon the cache; result returned but
        not cached, keeping `_known_primes` contiguous

Compute fallbacks for ranges above the cache:
    - Sieve of Eratosthenes for `end <= _SIEVE_THRESHOLD`
    - 6k±1 trial division for `end > _SIEVE_THRESHOLD`

Cost-aware validation (`_estimate_compute_ms`):
    `_validate` includes a compute-time estimator (in milliseconds, calibrated
    against M4 / Fargate t4g.medium). Queries whose estimated cost exceeds
    `_HARD_TIMEOUT_MS` are rejected at validation — before any expensive
    compute starts. Cache state is part of the estimate: as `_known_max`
    grows, more queries become "free", and the estimator naturally tightens.

Bounds:
    - start >= 2 (1 is not prime; reject explicitly)
    - start <= end
    - end - start <= _RANGE_CEILING (memory ceiling)
    - estimated compute time <= _HARD_TIMEOUT_MS (DoS guard)

Edge cases handled:
    - Single prime (start == end == prime): returns [prime]
    - Single non-prime (start == end == composite): returns []
    - Empty range (start > end): raises ValueError
    - Half-hit (start <= _known_max < end): cache prefix + computed suffix
    - Far-gap query (start > _known_max + _GAP_THRESHOLD): standalone compute,
      cache untouched

Trade-offs:
    - Cache is mutable; thread safety guaranteed by `_cache_lock`.
      ADR-0017's tuple-immutability claim is superseded by the lock +
      module-level access discipline.
    - Cache grows monotonically; bounded by `_RANGE_CEILING` (max ~664k
      primes ≈ 18 MB per uvicorn worker).
    - Lock is held during `_compute` for far-extending queries, serialising
      concurrent extensions. Acceptable at case-study scale; cross-worker
      shared cache (Redis) is the Phase 2 upgrade if concurrency demands it.
    - Per-worker cache; cold on worker restart (re-pays the ~5-15ms pre-warm).

Deadlock-freedom invariants (see ADR-0021):
    - Single lock (`_cache_lock`), acquired exactly once per `primes_in_range`
      call via the `with` statement. No code path inside the with-block
      re-acquires it.
    - `_compute`, `_segmented_sieve`, `_trial_division_with_known`,
      `_slice_known`, and the legacy `_sieve_eratosthenes` / `_trial_division_6k`
      operate on data passed in (or read directly from module state) — none
      call back into `primes_in_range` or attempt to acquire `_cache_lock`
      independently.
    - Future contributors must preserve this. Adding a compute path that
      depends on `primes_in_range` recursively requires either (a) switching
      `_cache_lock` to `threading.RLock`, or (b) pre-snapshotting cache state
      into a parameter and operating on the snapshot. (b) is preferred —
      keeps the lock blast radius small.
"""

import threading
from bisect import bisect_left, bisect_right
from collections.abc import Iterator

_INITIAL_PREWARM_BOUND = 10**5
_SIEVE_THRESHOLD = 10**6
_RANGE_CEILING = 10_000_000
_HARD_TIMEOUT_MS = 30_000
_GAP_THRESHOLD = 100_000


def _build_prime_table(bound: int) -> list[int]:
    """Build a sorted list of primes up to `bound` via Sieve of Eratosthenes.

    Used both at module load (for the pre-warm) and (in tests) to construct
    expected oracle values when sympy is not available.
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


# ─── Mutable cache state — guarded by `_cache_lock` ─────────────────────────
# Pre-warmed at module load; ~5-15ms one-off cost per uvicorn worker.
# See ADR-0020 for the full rationale.
_cache_lock = threading.Lock()
_known_primes: list[int] = _build_prime_table(_INITIAL_PREWARM_BOUND)
_known_max: int = _INITIAL_PREWARM_BOUND


def _set_known_max(value: int) -> None:
    """Module-level setter — keeps the `global` keyword localised here."""
    global _known_max
    _known_max = value


def _estimate_compute_ms(start: int, end: int, known_max: int) -> int:
    """Estimate compute time in milliseconds, given current cache state.

    Conservative — over-estimate is OK (we cut early on 'too slow').
    Calibrated against M4 / Fargate t4g.medium. Constants reflect the
    cache-leveraging compute paths (ADR-0021):
      - Segmented sieve marking: ~1 ms per 10⁴ of compute_range
        (NOT bound — the bytearray is only `compute_range` bytes, much
        smaller than the prior full-sieve [0, end] allocation)
      - Trial division by known primes: ~7000 Python ops per ms
        (~2.4× faster than the legacy 6k±1 path because we divide only
        by actual primes ≤ sqrt(end), not by every 6k±1 candidate)
      - 6k±1 candidate generation factor of ~1/6 retained as a coarse
        upper-bound on candidates inspected
    """
    if end <= known_max:
        return 1   # bisect + slice path, sub-millisecond

    # Determine if we'll extend the cache or compute standalone.
    if start <= known_max + _GAP_THRESHOLD:
        compute_start = known_max + 1   # extend
    else:
        compute_start = start            # standalone (no cache pollution)

    compute_range = end - compute_start + 1

    if end <= _SIEVE_THRESHOLD:
        # Segmented sieve over [compute_start, end]; bytearray sized to
        # `compute_range`, marking work concentrated on the segment.
        return max(50, compute_range // 10_000)

    # Layer 3: trial division by known primes over `compute_range` candidates
    sqrt_max = int(end ** 0.5) + 1
    estimated_ops = compute_range * sqrt_max // 6
    return estimated_ops // 7_000


def primes_in_range(start: int, end: int) -> list[int]:
    """Return primes in the inclusive range [start, end].

    Pre-flight rejects queries that would exceed `_HARD_TIMEOUT_MS` at
    estimated cost (with cache state factored in). Cache state can only
    improve estimates for subsequent calls — more known → fewer estimated
    ops on the same query.

    Raises:
        ValueError: if start < 2, start > end, range > _RANGE_CEILING,
            or estimated compute time exceeds the hard timeout.
    """
    _validate(start, end)

    with _cache_lock:
        if end <= _known_max:
            return _slice_known(start, end)

        if start <= _known_max + _GAP_THRESHOLD:
            # Extend cache contiguously
            new_primes = list(_compute(_known_max + 1, end))
            _known_primes.extend(new_primes)
            _set_known_max(end)
            return _slice_known(start, end)

        # Far gap — compute standalone, do not pollute cache
        return list(_compute(start, end))


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
    # Snapshot `_known_max` once — Python int reads are atomic under the GIL,
    # and an off-by-one between snapshot and actual extension only matters in
    # the conservative direction (more known later = even cheaper).
    snapshot_max = _known_max
    estimated = _estimate_compute_ms(start, end, snapshot_max)
    if estimated > _HARD_TIMEOUT_MS:
        raise ValueError(
            f"estimated compute time {estimated} ms exceeds {_HARD_TIMEOUT_MS} ms "
            f"ceiling; split into smaller windows (start={start}, end={end})"
        )


def _slice_known(start: int, end: int) -> list[int]:
    """Bisect-slice the known_primes list for the inclusive range [start, end].

    O(log n) per range bound via bisect; O(k) for the slice copy. Caller
    must hold `_cache_lock` during this call (or operate on a snapshot)
    because `_known_primes` is mutable.
    """
    lo = bisect_left(_known_primes, start)
    hi = bisect_right(_known_primes, end)
    return _known_primes[lo:hi]


def _compute(start: int, end: int) -> list[int]:
    """Runtime computation when cache doesn't cover the range.

    Leverages `_known_primes` as the small-primes list for both sieve and
    trial-division paths (ADR-0021). Caller MUST hold `_cache_lock` so the
    `_known_primes` view is stable across the computation.

    Algorithm choice:
      - end <= _SIEVE_THRESHOLD: segmented sieve — memory O(end - start),
        avoids re-marking the [0, start) range that the legacy
        `_sieve_eratosthenes` would have wasted.
      - end > _SIEVE_THRESHOLD: trial division by known primes — faster than
        6k±1 because we skip composite candidates that 6k±1 would generate.

    The legacy `_sieve_eratosthenes` and `_trial_division_6k` are retained
    in this module as reference implementations for cross-validation tests
    (`tests/test_primes.py` asserts the new and legacy paths agree on every
    BVA point).
    """
    if end <= _SIEVE_THRESHOLD:
        return _segmented_sieve(start, end, _known_primes)
    return _trial_division_with_known(start, end, _known_primes)


def _segmented_sieve(low: int, high: int, small_primes: list[int]) -> list[int]:
    """Segmented Sieve of Eratosthenes over [low, high] using `small_primes`.

    Requires: `small_primes` contains all primes <= sqrt(high). For our
    bounds (`_RANGE_CEILING = 10⁷` → sqrt ≈ 3162; `_INITIAL_PREWARM_BOUND
    = 10⁵` ≥ 3162), `_known_primes` always satisfies this when the lock
    is held.

    Memory: O(high - low + 1) bytearray (the segment, not [0, high]).
    Time: O((high - low) × log log high) — the work is concentrated on the
    segment, NOT on re-sieving the [0, low) prefix that the legacy
    `_sieve_eratosthenes(high, low)` would have re-marked.

    Caller must hold `_cache_lock` if `small_primes is _known_primes`.
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
        # First multiple of p that lies in [low, high]. Smaller multiples
        # of p (i.e., p × k for k < p) were eliminated by smaller primes,
        # so we can start at max(p², ceil(low / p) × p).
        first_mult = max(p * p, ((low + p - 1) // p) * p)
        for m in range(first_mult, high + 1, p):
            seg[m - low] = 0

    return [low + i for i in range(seg_size) if seg[i]]


def _is_prime_with_known(n: int, small_primes: list[int]) -> bool:
    """Single primality check via trial division by `small_primes`.

    Requires: `small_primes` contains all primes <= sqrt(n). Faster than
    `_is_prime_6k` because we divide only by actual primes (~446 primes
    below sqrt(10⁷)) instead of every 6k±1 candidate (~1054 candidates),
    a ~2.4× speedup.
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
    """Trial division over [start, end] using `small_primes` as divisors.

    Requires: same as `_is_prime_with_known`. Caller must hold `_cache_lock`
    if `small_primes is _known_primes`.
    """
    return [n for n in range(start, end + 1) if _is_prime_with_known(n, small_primes)]


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
