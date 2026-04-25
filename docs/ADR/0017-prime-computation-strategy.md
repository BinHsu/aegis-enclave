# ADR-0017: Layered prime-generation strategy with tuple-stored cache and sympy-as-oracle differential tests

## Status
Accepted (2026-04-25). **Partially superseded by ADR-0020** (the unified monotonic cache replaces the immutable-tuple `_PRIME_TABLE` posture; lock-protected mutability is required for monotonic cache extension. The other decisions in ADR-0017 — layered strategy, sympy as test oracle — remain in force).

## Context
The case-study brief's Task 1 specifies "your own implementation" of a prime-number generator with bounded inputs. Three orthogonal concerns shaped the implementation in `src/prime_service/primes.py`:

- **Performance**: per-call sieve allocation is wasteful when many queries fall in a small range. A pre-computed cache amortises that cost. The sieve-build cost (~5–15 ms for `bound = 10^5`) is paid once at module load; subsequent in-range queries are answered with bisect (O(log n)) plus a list slice (O(k)).
- **Correctness verification**: the brief disallows copying prime-detection code, but does not constrain the test oracle. Differential testing against a known-good reference is industry-standard practice — compilers test against a reference compiler, crypto libraries test against OpenSSL, arithmetic libraries test against sympy. The implementation imports nothing from sympy; tests compare its output to sympy's. Any divergence surfaces immediately.
- **Defensive storage**: a module-level mutable list is one accidental `.append()` away from corrupting every subsequent lookup process-wide. A tuple costs nothing in flight (bisect works on any sorted sequence) and turns the failure mode from "silent corruption" into "TypeError at the offending line".

The bounds (`_TABLE_BOUND = 10^5`, `_SIEVE_THRESHOLD = 10^6`, `_RANGE_CEILING = 10^7`) are calibrated for case-study scope per ADR-0003: small enough to keep module-load cost imperceptible, large enough to absorb the typical query distribution.

## Decision
Three implementation-discipline decisions, all in `src/prime_service/primes.py`:

1. **Layered prime-generation strategy.**
   - Layer 1 — lookup table for `end <= _TABLE_BOUND`.
   - Layer 1.5 — table prefix concatenated with computed suffix when the query straddles `_TABLE_BOUND`.
   - Layer 2 — per-call Sieve of Eratosthenes for `end <= _SIEVE_THRESHOLD`.
   - Layer 3 — 6k±1 trial division above `_SIEVE_THRESHOLD`.

   Each layer is independently testable.

2. **Lookup table stored as `tuple[int, ...]`** at module level, populated once at import via `tuple(_build_prime_table(_TABLE_BOUND))`. Bisect's API is unchanged. Mutation attempts (`.append`, item assignment) raise `AttributeError` / `TypeError` instead of silently corrupting later queries. The builder helper returns `list[int]` (idiomatic for a constructor); the conversion to tuple happens explicitly at the storage site, separating "build" from "store" concerns.

3. **Test oracle = sympy** as a dev-only dependency. `primes.py` imports nothing from sympy; `tests/test_primes.py` uses `sympy.primerange` and `sympy.isprime` to assert ground-truth equality across BVA points, layer-transition points, and deterministic-seed fuzz ranges. The brief's "implementation should be yours" rule is read as scoping the implementation, not the test oracle — the same way the test suite for any production-grade arithmetic library is allowed to assert against a reference implementation it would not ship.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| Single-algorithm implementation (sieve only, or trial division only) | Sieve is wasteful per call when the same small ranges are queried repeatedly; trial division is slow for large input ranges. Layering matches the actual cost shape. |
| Pre-generated `.py` data file (`_prime_table_data.py` with a literal `_PRIME_TABLE = [2, 3, 5, ...]`) | Saves ~5–15 ms at import but commits ~270 KB of Python source; reviewer-hostile and over-engineering at case-study scale. |
| Pre-generated binary cache (`struct.pack` of int32 values) | ~38 KB on disk and very fast load, but introduces a second file format to maintain. Not worth the complexity for case-study scope. |
| Pickle / msgpack cache | Pickle has deserialisation-attack surface; msgpack is an extra dependency. Neither earns its keep here. |
| Lazy `@lru_cache` on `_is_prime_6k` with no pre-build | First call still pays sieve / trial-division cost; cache only helps after warm-up. Build-once-at-import dominates for our query shape. |
| Storing `_PRIME_TABLE` as `list[int]` (mutable) | One accidental `.append()` or `.sort()` corrupts every subsequent lookup process-wide. The tuple alternative costs zero in flight and turns the failure into a loud `TypeError`. |
| Hand-rolled test oracle (e.g., naive trial division written separately) | Replaces one algorithm under test with another algorithm under test — double the verification surface, half the trust. sympy is hardened by years of production use. |
| Using sympy as the implementation (e.g., `from sympy import primerange`) | Violates Task 1's "implementation should be yours" — the carve-out for "API frameworks/libraries" is scoped to HTTP/API frameworks, not algorithmic libraries. Detected and rejected during scope review. |

## Consequences
- Module-load cost of ~5–15 ms (sieve up to `_TABLE_BOUND = 10^5`); imperceptible against a long-running container's lifetime, ECS Fargate cold-start budget absorbs it.
- Process memory ~270 KB for the table (9,592 primes × Python int overhead). Fits in the 256 MB Fargate task budget by orders of magnitude.
- Per-call query cost in Layer 1 is bisect (O(log n)) + list slice (O(k)) — typically sub-millisecond for ranges fitting in the table.
- Tuple storage costs nothing in flight (bisect works identically) but converts a class of "silent corruption" bugs into an immediate `TypeError`. The test `test_module_table_is_immutable` asserts the discipline.
- Sympy adds ~70 MB to the dev-only environment. Not present in the runtime container image (the Dockerfile installs the project, not the dev extras). No production cost.
- Differential test coverage against sympy plus BVA at `_TABLE_BOUND ± 1`, `_SIEVE_THRESHOLD ± 1`, and `_RANGE_CEILING ± 1` gives high confidence that off-by-one and miscategorisation bugs are caught at PR time.
- Future-proofing: if a workload appears that shifts queries into Layer 2 or 3, the layered structure makes "raise `_TABLE_BOUND` to 10^6" a one-constant change with predictable cost trade-offs.
- The runbook spec format from ADR-0012 generalises to "swap the implementation for a faster sieve" without changing the API contract — the layers are an internal optimisation, not a public surface.

## Related ADRs
- ADR-0003 (PoC scope, prod hygiene — drives the bound choices)
- ADR-0008 (reliability targets — latency budget for in-range queries)
