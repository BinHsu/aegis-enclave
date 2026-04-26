"""Unit tests for prime_service.bootstrap — one-shot cache pre-warm task.

Strategy
--------
- All I/O (cache) is mocked — bootstrap tests are pure unit tests.
- `run_bootstrap` is the focal function.
- BVA on the bootstrap range constants (_BOOTSTRAP_START, _BOOTSTRAP_END):
    _BOOTSTRAP_START = 1  → BVA at 0, 1, 2
    _BOOTSTRAP_END = 100_000 → BVA at 99_999, 100_000, 100_001
- BVA on return codes: 0 = success/skip, 1 = error.
- Idempotency: already-present → skip without compute (put_if_absent not called).
- Concurrent write guard: put_if_absent returns False → still exits 0.
- Error propagation: cache.exists raises → exits 1.
"""

from __future__ import annotations

from unittest.mock import AsyncMock, MagicMock, patch

import pytest

from prime_service.bootstrap import run_bootstrap
from prime_service.cache import _BOOTSTRAP_END, _BOOTSTRAP_START


@pytest.fixture(autouse=True)
def _mock_ensure_schema() -> object:
    """Patch out the async DB schema migration for all bootstrap tests.

    `run_bootstrap` calls `asyncio.run(_ensure_schema())` before cache seeding.
    Without this fixture, every test would try to connect to a real Postgres
    (settings.database_url) and fail. Tests covering the schema migration
    itself live in test_db.py / integration suite, not here.
    """
    with patch(
        "prime_service.bootstrap._ensure_schema",
        new=AsyncMock(return_value=None),
    ):
        yield


# ───────────────────────────────────────────────────────────────────────────
# Constants BVA
# ───────────────────────────────────────────────────────────────────────────


class TestBootstrapConstants:
    """Verify pre-decided bootstrap range constants."""

    # _BOOTSTRAP_START = 1 — BVA at B-1=0, B=1, B+1=2
    def test_bootstrap_start_is_1(self) -> None:
        assert _BOOTSTRAP_START == 1

    def test_bootstrap_start_minus_1(self) -> None:
        """B-1: value below start is not the bootstrap start."""
        assert _BOOTSTRAP_START - 1 == 0

    def test_bootstrap_start_plus_1(self) -> None:
        """B+1: value above start is not the bootstrap start."""
        assert _BOOTSTRAP_START + 1 == 2

    # _BOOTSTRAP_END = 100_000 — BVA at B-1=99_999, B=100_000, B+1=100_001
    def test_bootstrap_end_is_100000(self) -> None:
        assert _BOOTSTRAP_END == 100_000

    def test_bootstrap_end_minus_1(self) -> None:
        """B-1: value just below end is not the bootstrap end."""
        assert _BOOTSTRAP_END - 1 == 99_999

    def test_bootstrap_end_plus_1(self) -> None:
        """B+1: value just above end is not the bootstrap end."""
        assert _BOOTSTRAP_END + 1 == 100_001


# ───────────────────────────────────────────────────────────────────────────
# Fixtures
# ───────────────────────────────────────────────────────────────────────────


def _mock_cache(
    *,
    exists_return: bool = False,
    put_if_absent_return: bool = True,
) -> MagicMock:
    cache = MagicMock()
    cache.exists = MagicMock(return_value=exists_return)
    cache.put_if_absent = MagicMock(return_value=put_if_absent_return)
    return cache


# ───────────────────────────────────────────────────────────────────────────
# run_bootstrap — skip path (already cached)
# ───────────────────────────────────────────────────────────────────────────


class TestRunBootstrapSkip:
    """Already cached → exits 0 without compute or write."""

    def test_already_cached_returns_0(self) -> None:
        cache = _mock_cache(exists_return=True)
        result = run_bootstrap(cache=cache)
        assert result == 0

    def test_already_cached_does_not_call_put_if_absent(self) -> None:
        cache = _mock_cache(exists_return=True)
        run_bootstrap(cache=cache)
        cache.put_if_absent.assert_not_called()

    def test_already_cached_checks_correct_range(self) -> None:
        """exists() must be called with (_BOOTSTRAP_START, _BOOTSTRAP_END)."""
        cache = _mock_cache(exists_return=True)
        run_bootstrap(cache=cache)
        cache.exists.assert_called_once_with(_BOOTSTRAP_START, _BOOTSTRAP_END)


# ───────────────────────────────────────────────────────────────────────────
# run_bootstrap — write path (not cached)
# ───────────────────────────────────────────────────────────────────────────


class TestRunBootstrapWrite:
    """Not cached → computes primes, writes via put_if_absent, exits 0."""

    def test_not_cached_returns_0(self) -> None:
        cache = _mock_cache(exists_return=False)
        result = run_bootstrap(cache=cache)
        assert result == 0

    def test_not_cached_calls_put_if_absent(self) -> None:
        cache = _mock_cache(exists_return=False)
        run_bootstrap(cache=cache)
        cache.put_if_absent.assert_called_once()

    def test_put_if_absent_called_with_correct_range(self) -> None:
        """put_if_absent must be called with start=1, end=100000."""
        cache = _mock_cache(exists_return=False)
        run_bootstrap(cache=cache)
        call_args = cache.put_if_absent.call_args
        assert call_args[0][0] == _BOOTSTRAP_START
        assert call_args[0][1] == _BOOTSTRAP_END

    def test_put_if_absent_called_with_prime_list(self) -> None:
        """Third arg to put_if_absent must be a non-empty list of ints."""
        cache = _mock_cache(exists_return=False)
        run_bootstrap(cache=cache)
        call_args = cache.put_if_absent.call_args
        primes_arg = call_args[0][2]
        assert isinstance(primes_arg, list)
        assert len(primes_arg) > 0
        # The first prime in any range starting at 1 is 2
        assert primes_arg[0] == 2

    def test_bootstrap_100000_count_matches_oracle(self) -> None:
        """There are 9592 primes <= 100000 (well-known constant)."""
        cache = _mock_cache(exists_return=False)
        run_bootstrap(cache=cache)
        call_args = cache.put_if_absent.call_args
        primes_arg = call_args[0][2]
        assert len(primes_arg) == 9592

    def test_bootstrap_primes_sorted_ascending(self) -> None:
        """Written prime list must be sorted ascending."""
        cache = _mock_cache(exists_return=False)
        run_bootstrap(cache=cache)
        call_args = cache.put_if_absent.call_args
        primes_arg = call_args[0][2]
        assert primes_arg == sorted(primes_arg)

    def test_bootstrap_primes_all_within_range(self) -> None:
        """All written primes must be within [_BOOTSTRAP_START, _BOOTSTRAP_END]."""
        cache = _mock_cache(exists_return=False)
        run_bootstrap(cache=cache)
        call_args = cache.put_if_absent.call_args
        primes_arg = call_args[0][2]
        assert all(_BOOTSTRAP_START <= p <= _BOOTSTRAP_END for p in primes_arg)


# ───────────────────────────────────────────────────────────────────────────
# run_bootstrap — concurrent write guard
# ───────────────────────────────────────────────────────────────────────────


class TestRunBootstrapConcurrentWrite:
    """put_if_absent returns False (concurrent write won) → still exits 0."""

    def test_concurrent_write_returns_0(self) -> None:
        """Another bootstrap task wrote first → still OK, exit 0."""
        cache = _mock_cache(exists_return=False, put_if_absent_return=False)
        result = run_bootstrap(cache=cache)
        assert result == 0

    def test_concurrent_write_still_calls_put_if_absent(self) -> None:
        """We still attempt the write; the NX flag handles the race."""
        cache = _mock_cache(exists_return=False, put_if_absent_return=False)
        run_bootstrap(cache=cache)
        cache.put_if_absent.assert_called_once()


# ───────────────────────────────────────────────────────────────────────────
# run_bootstrap — error paths
# ───────────────────────────────────────────────────────────────────────────


class TestRunBootstrapErrors:
    """Unexpected exceptions → exits 1 (non-zero)."""

    def test_cache_exists_error_returns_1(self) -> None:
        cache = MagicMock()
        cache.exists = MagicMock(side_effect=Exception("cache unreachable"))
        result = run_bootstrap(cache=cache)
        assert result == 1

    def test_put_if_absent_error_returns_1(self) -> None:
        cache = MagicMock()
        cache.exists = MagicMock(return_value=False)
        cache.put_if_absent = MagicMock(side_effect=Exception("write failed"))
        result = run_bootstrap(cache=cache)
        assert result == 1

    def test_build_prime_table_error_returns_1(self) -> None:
        """If compute itself fails, exit 1 (not crash)."""
        cache = _mock_cache(exists_return=False)
        with patch(
            "prime_service.bootstrap._build_prime_table",
            side_effect=RuntimeError("sieve blown"),
        ):
            result = run_bootstrap(cache=cache)
        assert result == 1

    def test_connection_error_returns_1(self) -> None:
        """Network-level errors during cache.exists → exit 1."""
        cache = MagicMock()
        cache.exists = MagicMock(side_effect=ConnectionError("Valkey unreachable"))
        result = run_bootstrap(cache=cache)
        assert result == 1


# ───────────────────────────────────────────────────────────────────────────
# run_bootstrap — default PrimeCache instantiation (smoke)
# ───────────────────────────────────────────────────────────────────────────


class TestRunBootstrapDefaultCache:
    """When no cache is passed, PrimeCache() is constructed internally."""

    def test_no_cache_arg_instantiates_prime_cache(self) -> None:
        """Passing no cache arg triggers PrimeCache() instantiation."""
        with patch("prime_service.bootstrap.PrimeCache") as mock_cache_cls:
            instance = MagicMock()
            instance.exists = MagicMock(return_value=True)  # skip compute
            mock_cache_cls.return_value = instance

            result = run_bootstrap()

        mock_cache_cls.assert_called_once()
        assert result == 0

    def test_no_cache_arg_error_from_prime_cache_init_returns_1(self) -> None:
        """PrimeCache() init failure → exits 1."""
        with patch(
            "prime_service.bootstrap.PrimeCache",
            side_effect=Exception("Valkey connection refused"),
        ):
            result = run_bootstrap()

        assert result == 1


# ───────────────────────────────────────────────────────────────────────────
# __main__ block — coverage of sys.exit call
# ───────────────────────────────────────────────────────────────────────────


class TestBootstrapMain:
    """Coverage of the if __name__ == '__main__': sys.exit(run_bootstrap()) block."""

    def test_main_exits_0_on_success(self) -> None:
        """Calling run_bootstrap() as __main__ exits with code 0 on success."""
        import sys

        cache = _mock_cache(exists_return=True)  # skip compute
        with patch("prime_service.bootstrap.PrimeCache", return_value=cache):
            with patch.object(sys, "exit") as mock_exit:
                # Simulate what __main__ does
                code = run_bootstrap()
                sys.exit(code)

        mock_exit.assert_called_once_with(0)

    def test_main_exits_1_on_error(self) -> None:
        """__main__ sys.exit(1) on error."""
        import sys

        with patch(
            "prime_service.bootstrap.PrimeCache",
            side_effect=Exception("db down"),
        ):
            with patch.object(sys, "exit") as mock_exit:
                code = run_bootstrap()
                sys.exit(code)

        mock_exit.assert_called_once_with(1)


# ───────────────────────────────────────────────────────────────────────────
# Return code BVA — exit codes 0 and 1 are the only valid values
# ───────────────────────────────────────────────────────────────────────────


class TestRunBootstrapReturnCodeBVA:
    """BVA on return codes: 0 = success, 1 = error. No other values valid."""

    # B-1 of error code: 0 (success)
    def test_success_path_returns_exactly_0(self) -> None:
        cache = _mock_cache(exists_return=True)
        assert run_bootstrap(cache=cache) == 0

    # B of error code: 1 (error)
    def test_error_path_returns_exactly_1(self) -> None:
        cache = MagicMock()
        cache.exists = MagicMock(side_effect=Exception("boom"))
        assert run_bootstrap(cache=cache) == 1

    # B+1 of error code: 2 (should never occur)
    def test_return_code_never_exceeds_1(self) -> None:
        """run_bootstrap never returns a code > 1."""
        cache = _mock_cache(exists_return=True)
        code = run_bootstrap(cache=cache)
        assert code <= 1

    def test_return_code_never_negative(self) -> None:
        """run_bootstrap never returns a negative code."""
        cache = _mock_cache(exists_return=True)
        code = run_bootstrap(cache=cache)
        assert code >= 0
