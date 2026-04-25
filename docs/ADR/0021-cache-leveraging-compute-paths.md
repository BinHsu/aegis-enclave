# ADR-0021: Leverage cached primes as small-primes for segmented sieve and trial division

## Status
Accepted (2026-04-25)

## Context
ADR-0017 chose Sieve of Eratosthenes for `end <= _SIEVE_THRESHOLD` and 6k±1 trial division above. ADR-0020 introduced the unified monotonic cache (`_known_primes` + `_known_max`) that supersedes the static table.

Two by-product observations from those decisions surfaced during review:

1. **The legacy `_sieve_eratosthenes(end, start)` always re-sieves from 0.** Even when `_known_primes` already contains every prime up to `_known_max`, the function allocates a bytearray of size `end + 1` and re-marks composites in `[0, _known_max]`. That work is redundant — the answer for that range is already in the cache.

2. **The legacy `_trial_division_6k` divides by every 6k±1 candidate up to sqrt(n).** The 6k±1 form generates a superset of primes — 25, 35, 49, 55, etc. are tested as divisors even though they are themselves composite. For `n` near 10⁷, sqrt(n) ≈ 3162; π(3162) ≈ 446 actual primes, vs ~1054 6k±1 candidates. About 60 % of trial-division work is wasted on composite divisors.

Both are textbook "use what you already know" optimisations. They become available BECAUSE of ADR-0020's unified cache: a stable, sorted `_known_primes` list that's always populated up to at least `_INITIAL_PREWARM_BOUND = 10⁵`.

For our bounds (`_RANGE_CEILING = 10⁷`, sqrt ≈ 3162), `_known_primes` always covers sqrt(end) once cache is initialised. The optimisations apply unconditionally without fallback logic.

## Decision
Add three new compute helpers in `primes.py` that take `small_primes` as a parameter:

| Function | Purpose | Speedup vs legacy |
|---|---|---|
| `_segmented_sieve(low, high, small_primes)` | Sieve only the segment [low, high]; mark composites using small_primes as multipliers | Memory `O(high - low)` vs `O(high)`; time gain proportional to gap fraction (e.g., extending from 10⁶ to 1.1×10⁶ is ~11× faster than full sieve) |
| `_is_prime_with_known(n, small_primes)` | Single primality via division by primes only | ~2.4× faster than `_is_prime_6k` (446 divisions vs 1054 candidates at sqrt(10⁷)) |
| `_trial_division_with_known(start, end, small_primes)` | Iterate `_is_prime_with_known` over the range | Same factor on Layer 3 |

`_compute` switches to the new helpers, passing `_known_primes` as the small-primes argument. Caller MUST hold `_cache_lock` so the snapshot is consistent through the computation.

Legacy `_sieve_eratosthenes`, `_trial_division_6k`, `_is_prime_6k` are retained as reference implementations — `tests/test_primes.py` cross-validates the new and legacy paths produce identical output on every BVA point.

`_estimate_compute_ms` constants are recalibrated:
- Layer 2 estimate uses `compute_range // 10_000` (not `end // 10_000`) — segmented sieve scales with segment size
- Layer 3 divisor changed from `// 3_000` to `// 7_000` — known-primes path is ~2.4× faster

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Keep legacy paths in `_compute`; add cache leverage as Phase 2 | The optimisations are unconditional given our bounds — no fallback logic needed. Postponing the change leaves measurable waste in the deliverable for no architectural reason. |
| Replace legacy entirely; remove `_sieve_eratosthenes` / `_trial_division_6k` | Useful as reference implementations for cross-validation tests. Removing them loses the "two independent implementations agree" assertion that catches subtle bugs. Cost of keeping: ~60 lines of dead-from-runtime code that lives only in test imports. Worth it. |
| Use a third-party prime library (sympy, gmpy2, pyprimesieve) | Brief Task 1 explicitly excludes this — "implementation logic should be yours, not code". The case-study constraint is a hard guardrail. |
| Pre-compute `_known_primes` to sqrt(`_RANGE_CEILING`) always | The `_INITIAL_PREWARM_BOUND = 10⁵` already exceeds sqrt(10⁷) ≈ 3162 by ~30×. Going further inflates module-load cost without gaining anything. |
| Implement Miller-Rabin probabilistic primality for Layer 3 | Faster asymptotically but adds correctness reasoning (false-positive probabilities, witness selection). For our bounds (n ≤ 10⁷), deterministic trial division is fast enough and easier to defend in interview. |

## Consequences
- **Layer 2 cache extension is dramatically faster as the cache grows.** Extending from `_known_max = 10⁶` to `end = 1.1 × 10⁶` is ~11× faster than the legacy full sieve (segment of 10⁵ vs allocation of 1.1 × 10⁶).
- **Layer 3 trial division is ~2.4× faster across the board.** Constants in `_estimate_compute_ms` recalibrated; the estimator's pre-flight reject threshold (30 s wall budget) now allows ~2.4× larger query ranges before rejection.
- **Cache-leverage is unconditional given our bounds.** `_INITIAL_PREWARM_BOUND = 10⁵` always covers sqrt(`_RANGE_CEILING` = 10⁷) ≈ 3162, so neither helper needs a fallback. If `_RANGE_CEILING` is ever raised above `_INITIAL_PREWARM_BOUND²`, the helpers' precondition (`small_primes` covers sqrt(high)) fails and a recursive bootstrap is required — flagged in primes.py docstring for future contributors.
- **Lock invariants from ADR-0020 are preserved.** New helpers don't acquire `_cache_lock` and don't call back into `primes_in_range`. Caller-holds-lock is the contract; the docstrings state it explicitly.
- **Cross-validation tests assert correctness against the legacy paths.** `tests/test_primes.py` includes parametrised triplets that compare `_segmented_sieve(low, high, _known_primes)` against `_sieve_eratosthenes(high, low)` for every BVA point, and `_trial_division_with_known` against `_trial_division_6k`. Catches regressions where one path drifts from the other.
- **Sympy remains the third oracle.** All three implementations (segmented sieve, full sieve, sympy `primerange`) must agree on every test input — three-way differential testing.
- **Legacy code retained at the module level, not deleted.** `_sieve_eratosthenes`, `_trial_division_6k`, and `_is_prime_6k` are kept for cross-validation. Deleting them on a future cleanup pass is a deliberate decision requiring a new ADR.

## Related ADRs
- ADR-0017 (prime computation strategy — partially superseded by ADR-0020; this ADR refines the compute paths)
- ADR-0020 (unified monotonic cache — supplies the `_known_primes` foundation this ADR exploits)
- ADR-0008 (reliability targets — recalibrated estimator constants tighten the SLO budget)
- ADR-0018 (managed-default tool selection — same shape: pick simpler primitive, upgrade with surrounding context)
