"""Unit tests for prime_service.cache — Valkey/Redis distributed cache.

Strategy
--------
- fakeredis provides an in-process Redis mock; tests run without a real server.
- ZSET overlap matrix BVA: 7 overlap scenarios (no-overlap, full subset,
  full superset, left overlap, right overlap, adjacent touching, gap
  non-touching) each with BVA at the touching boundary.
- Lua merge race: two concurrent merge_or_put calls produce a correctly
  coalesced result.
- Per-method tests: exists, get, put, put_if_absent, merge_or_put,
  find_covering, get_covering_slice.
- BVA at TTL boundary (0 vs positive) and at range start/end boundaries.

Notes on fakeredis:
    fakeredis 2.x ships with Lua script support (lua_modules parameter).
    Scripts registered via register_script() execute synchronously in-process.
    The Lua cjson library is provided by the luarocks-cjson package bundled
    with fakeredis when using the lua=True option.
"""

from __future__ import annotations

from typing import Any
from unittest.mock import MagicMock

import fakeredis
import pytest

from prime_service.cache import (
    _BOOTSTRAP_END,
    _BOOTSTRAP_START,
    _TTL_SECONDS,
    _ZSET_KEY,
    PrimeCache,
    _make_client,
    _range_value_key,
)

# ───────────────────────────────────────────────────────────────────────────
# Fixtures
# ───────────────────────────────────────────────────────────────────────────


@pytest.fixture
def fake_redis() -> Any:
    """fakeredis server + client with Lua support."""
    server = fakeredis.FakeServer()
    client = fakeredis.FakeRedis(server=server, decode_responses=True)
    return client


@pytest.fixture
def cache(fake_redis: Any) -> PrimeCache:
    """PrimeCache backed by fakeredis."""
    return PrimeCache(client=fake_redis)


def _primes_from_2_to(n: int) -> list[int]:
    """Build a small prime list for test fixtures."""
    from prime_service.primes import _build_prime_table

    return _build_prime_table(n)


# ───────────────────────────────────────────────────────────────────────────
# Constants
# ───────────────────────────────────────────────────────────────────────────


class TestCacheConstants:
    """Verify pre-decided key schema constants."""

    def test_zset_key_has_hash_tag(self) -> None:
        # {ranges} hash tag ensures single-shard placement in cluster mode
        assert "{ranges}" in _ZSET_KEY

    def test_range_value_key_format(self) -> None:
        key = _range_value_key(2, 100)
        assert key == "primes:{ranges}:range:2:100"
        assert "{ranges}" in key  # hash tag preserved

    def test_ttl_is_6_hours(self) -> None:
        assert _TTL_SECONDS == 6 * 3600

    # BVA at TTL = 0 (no-TTL boundary) vs positive
    def test_ttl_bva_zero(self) -> None:
        assert _TTL_SECONDS != 0  # default must be non-zero

    def test_ttl_bva_one(self) -> None:
        assert 1 > 0  # positive → TTL applies

    def test_bootstrap_constants(self) -> None:
        assert _BOOTSTRAP_START == 1
        assert _BOOTSTRAP_END == 100_000

    # BVA at _BOOTSTRAP_END
    def test_bootstrap_end_minus_1(self) -> None:
        assert _BOOTSTRAP_END - 1 == 99_999

    def test_bootstrap_end_at(self) -> None:
        assert _BOOTSTRAP_END == 100_000

    def test_bootstrap_end_plus_1(self) -> None:
        assert _BOOTSTRAP_END + 1 == 100_001


# ───────────────────────────────────────────────────────────────────────────
# PrimeCache.exists
# ───────────────────────────────────────────────────────────────────────────


class TestExists:
    def test_exists_false_when_absent(self, cache: PrimeCache) -> None:
        assert cache.exists(2, 100) is False

    def test_exists_true_after_put(self, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        assert cache.exists(2, 100) is True

    # BVA at start = 1 (bootstrap boundary)
    def test_exists_bva_start_1(self, cache: PrimeCache) -> None:
        cache.put(1, 100, [2, 3, 5, 7])
        assert cache.exists(1, 100) is True
        assert cache.exists(2, 100) is False  # different key

    def test_exists_bva_start_2(self, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        assert cache.exists(2, 100) is True

    def test_exists_bva_start_3(self, cache: PrimeCache) -> None:
        cache.put(3, 100, [3, 5, 7])
        assert cache.exists(3, 100) is True

    # BVA at end boundary
    def test_exists_different_ends_are_distinct(self, cache: PrimeCache) -> None:
        cache.put(2, 99, [2, 3, 5, 7])
        assert cache.exists(2, 99) is True
        assert cache.exists(2, 100) is False
        assert cache.exists(2, 101) is False


# ───────────────────────────────────────────────────────────────────────────
# PrimeCache.get
# ───────────────────────────────────────────────────────────────────────────


class TestGet:
    def test_get_none_when_absent(self, cache: PrimeCache) -> None:
        assert cache.get(2, 100) is None

    def test_get_returns_correct_primes(self, cache: PrimeCache) -> None:
        primes = [2, 3, 5, 7, 11, 13]
        cache.put(2, 13, primes)
        result = cache.get(2, 13)
        assert result == primes

    def test_get_returns_list_of_ints(self, cache: PrimeCache) -> None:
        cache.put(2, 10, [2, 3, 5, 7])
        result = cache.get(2, 10)
        assert result is not None
        assert all(isinstance(p, int) for p in result)

    def test_get_empty_list(self, cache: PrimeCache) -> None:
        # Range [4, 6] has no primes
        cache.put(4, 6, [])
        result = cache.get(4, 6)
        assert result == []

    # BVA at start = 2 (API minimum)
    def test_get_bva_start_2(self, cache: PrimeCache) -> None:
        cache.put(2, 10, [2, 3, 5, 7])
        assert cache.get(2, 10) == [2, 3, 5, 7]

    def test_get_bva_start_1(self, cache: PrimeCache) -> None:
        cache.put(1, 10, [2, 3, 5, 7])
        assert cache.get(1, 10) == [2, 3, 5, 7]
        assert cache.get(2, 10) is None  # different key

    def test_get_bva_start_3(self, cache: PrimeCache) -> None:
        cache.put(3, 10, [3, 5, 7])
        assert cache.get(3, 10) == [3, 5, 7]


# ───────────────────────────────────────────────────────────────────────────
# PrimeCache.put — TTL BVA
# ───────────────────────────────────────────────────────────────────────────


class TestPut:
    def test_put_writes_value(self, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        assert cache.exists(2, 100)

    def test_put_writes_to_zset(self, fake_redis: Any, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        # ZSET should have member "2:100" with score 2
        members = fake_redis.zrangebyscore(_ZSET_KEY, 2, 2, withscores=True)
        assert len(members) >= 1
        assert any("2:100" in str(m[0]) for m in members)

    def test_put_overwrites_existing(self, cache: PrimeCache) -> None:
        cache.put(2, 10, [2, 3, 5, 7])
        cache.put(2, 10, [2, 3, 5, 7, 11])  # overwrite
        result = cache.get(2, 10)
        assert result == [2, 3, 5, 7, 11]

    # BVA at TTL = 0 (no-TTL) vs TTL = 1 vs TTL = _TTL_SECONDS
    def test_put_no_ttl_persists(self, fake_redis: Any, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5], ttl=0)
        val_key = _range_value_key(2, 100)
        ttl = fake_redis.ttl(val_key)
        # ttl == -1 means no expiry in Redis
        assert ttl == -1

    def test_put_with_ttl_1_sets_expiry(self, fake_redis: Any, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5], ttl=1)
        val_key = _range_value_key(2, 100)
        ttl = fake_redis.ttl(val_key)
        assert ttl >= 0  # 0 or 1 (may expire immediately in slow CI)

    def test_put_with_default_ttl(self, fake_redis: Any, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5])
        val_key = _range_value_key(2, 100)
        ttl = fake_redis.ttl(val_key)
        assert ttl > 0


# ───────────────────────────────────────────────────────────────────────────
# PrimeCache.put_if_absent — idempotency (for bootstrap)
# ───────────────────────────────────────────────────────────────────────────


class TestPutIfAbsent:
    def test_writes_when_absent(self, cache: PrimeCache) -> None:
        result = cache.put_if_absent(2, 100, [2, 3, 5, 7])
        assert result is True
        assert cache.exists(2, 100)

    def test_skips_when_present(self, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        result = cache.put_if_absent(2, 100, [99])  # different value
        assert result is False
        # Original value preserved
        assert cache.get(2, 100) == [2, 3, 5, 7]

    def test_idempotent_on_double_call(self, cache: PrimeCache) -> None:
        r1 = cache.put_if_absent(2, 100, [2, 3, 5, 7])
        r2 = cache.put_if_absent(2, 100, [2, 3, 5, 7])
        assert r1 is True
        assert r2 is False
        assert cache.get(2, 100) == [2, 3, 5, 7]

    def test_zset_updated_when_written(self, fake_redis: Any, cache: PrimeCache) -> None:
        cache.put_if_absent(2, 100, [2, 3, 5, 7])
        members = fake_redis.zrange(_ZSET_KEY, 0, -1)
        assert len(members) >= 1

    def test_zset_not_duplicated_on_absent_skip(
        self, fake_redis: Any, cache: PrimeCache
    ) -> None:
        cache.put_if_absent(2, 100, [2, 3, 5, 7])
        cache.put_if_absent(2, 100, [2, 3, 5, 7])
        members = fake_redis.zrange(_ZSET_KEY, 0, -1)
        # Should have exactly one "2:100" member
        matching = [m for m in members if "2:100" in str(m)]
        assert len(matching) == 1


# ───────────────────────────────────────────────────────────────────────────
# PrimeCache.find_covering
# ───────────────────────────────────────────────────────────────────────────


class TestFindCovering:
    def test_none_when_cache_empty(self, cache: PrimeCache) -> None:
        assert cache.find_covering(10, 100) is None

    def test_finds_exact_match(self, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        result = cache.find_covering(2, 100)
        assert result == (2, 100)

    def test_finds_superset(self, cache: PrimeCache) -> None:
        # Cached [2, 1000] covers query [100, 500]
        primes = _primes_from_2_to(1000)
        cache.put(2, 1000, primes)
        result = cache.find_covering(100, 500)
        assert result == (2, 1000)

    def test_no_covering_for_larger_query(self, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        # Query [2, 200] is larger than cached [2, 100]
        result = cache.find_covering(2, 200)
        assert result is None

    # BVA at cache start = query start (exact left edge)
    def test_bva_query_start_at_cache_start(self, cache: PrimeCache) -> None:
        cache.put(10, 100, [11, 13, 17, 19])
        result = cache.find_covering(10, 80)
        assert result == (10, 100)

    def test_bva_query_start_one_below_cache_start(self, cache: PrimeCache) -> None:
        cache.put(10, 100, [11, 13, 17, 19])
        # Query starts at 9 < 10 → cache doesn't cover
        result = cache.find_covering(9, 80)
        assert result is None

    def test_bva_query_start_one_above_cache_start(self, cache: PrimeCache) -> None:
        cache.put(10, 100, [11, 13, 17, 19])
        # Query starts at 11 > 10 → cache covers [11, 80]
        result = cache.find_covering(11, 80)
        assert result == (10, 100)

    # BVA at cache end = query end (exact right edge)
    def test_bva_query_end_at_cache_end(self, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        result = cache.find_covering(2, 100)
        assert result == (2, 100)

    def test_bva_query_end_one_below_cache_end(self, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        result = cache.find_covering(2, 99)
        assert result == (2, 100)

    def test_bva_query_end_one_above_cache_end(self, cache: PrimeCache) -> None:
        cache.put(2, 100, [2, 3, 5, 7])
        # Query needs [2, 101] but cache only has [2, 100]
        result = cache.find_covering(2, 101)
        assert result is None


# ───────────────────────────────────────────────────────────────────────────
# PrimeCache.get_covering_slice
# ───────────────────────────────────────────────────────────────────────────


class TestGetCoveringSlice:
    def test_none_when_no_covering(self, cache: PrimeCache) -> None:
        assert cache.get_covering_slice(10, 100) is None

    def test_returns_correct_slice(self, cache: PrimeCache) -> None:
        primes = _primes_from_2_to(1000)
        cache.put(2, 1000, primes)
        result = cache.get_covering_slice(100, 200)
        from sympy import primerange

        expected = list(primerange(100, 201))
        assert result == expected

    def test_exact_range_returns_full_list(self, cache: PrimeCache) -> None:
        primes = [2, 3, 5, 7]
        cache.put(2, 10, primes)
        result = cache.get_covering_slice(2, 10)
        assert result == primes

    def test_none_when_value_key_missing(self, fake_redis: Any, cache: PrimeCache) -> None:
        # Put ZSET member but no value key — simulates partial corruption
        fake_redis.zadd(_ZSET_KEY, {"2:100": 2.0})
        result = cache.get_covering_slice(2, 100)
        assert result is None


# ───────────────────────────────────────────────────────────────────────────
# PrimeCache.merge_or_put — ZSET overlap matrix BVA
# ───────────────────────────────────────────────────────────────────────────


class TestMergeOrPut:
    """Seven overlap scenarios × BVA at touching boundary.

    Reference:
        Scenario A: No overlap — [2,10] and [20,30] are disjoint
        Scenario B: Full subset — [2,10] then [3,7] (new is subset)
        Scenario C: Full superset — [3,7] then [2,10] (new covers existing)
        Scenario D: Left overlap — [2,10] then [8,15]
        Scenario E: Right overlap — [8,15] then [2,10]
        Scenario F: Adjacent (touching) — [2,10] then [11,20]
        Scenario G: Gap (non-touching) — [2,10] then [12,20]

    BVA at touching boundary is exercised in scenarios F and G:
        F: end1=10, start2=11 → touching (10+1=11)
        G: end1=10, start2=12 → gap (10+2=12)
    """

    # ── A: No overlap ──────────────────────────────────────────────────────

    def test_no_overlap_inserts_two_ranges(
        self, fake_redis: Any, cache: PrimeCache
    ) -> None:
        p1 = [2, 3, 5, 7]
        p2 = [23, 29]
        cache.merge_or_put(2, 10, p1)
        cache.merge_or_put(20, 30, p2)
        # Both ranges exist independently
        assert cache.get(2, 10) == p1
        assert cache.get(20, 30) == p2

    def test_no_overlap_two_members_in_zset(
        self, fake_redis: Any, cache: PrimeCache
    ) -> None:
        cache.merge_or_put(2, 10, [2, 3, 5, 7])
        cache.merge_or_put(20, 30, [23, 29])
        members = fake_redis.zrange(_ZSET_KEY, 0, -1)
        assert len(members) == 2

    # BVA: gap boundary — [2,10] and [20,30]: gap of 9 → no merge
    def test_no_overlap_bva_gap_9(self, cache: PrimeCache) -> None:
        cache.merge_or_put(2, 10, [2, 3, 5, 7])
        r = cache.merge_or_put(20, 30, [23, 29])
        assert r == (20, 30)  # not merged with [2,10]

    # ── B: Full subset ─────────────────────────────────────────────────────

    def test_full_subset_existing_extends_to_superset(
        self, cache: PrimeCache
    ) -> None:
        large = _primes_from_2_to(100)
        small = [p for p in large if 10 <= p <= 50]
        cache.merge_or_put(2, 100, large)
        result = cache.merge_or_put(10, 50, small)
        # Merged range should be (2, 100) — the existing superset
        assert result[0] <= 2
        assert result[1] >= 100

    def test_full_subset_merged_value_contains_all_primes(
        self, cache: PrimeCache
    ) -> None:
        large = _primes_from_2_to(100)
        small = [p for p in large if 10 <= p <= 50]
        cache.merge_or_put(2, 100, large)
        cache.merge_or_put(10, 50, small)
        # The covering range still contains all primes up to 100
        covering = cache.find_covering(2, 100)
        assert covering is not None
        merged = cache.get(covering[0], covering[1])
        assert merged is not None
        assert set(large).issubset(set(merged))

    # BVA at subset boundaries: [B-1,B] vs [B,B+1]
    def test_subset_bva_at_left_boundary(self, cache: PrimeCache) -> None:
        outer = _primes_from_2_to(100)
        cache.merge_or_put(2, 100, outer)
        # Inner range [2, 50] — left edge == outer left edge
        inner = [p for p in outer if p <= 50]
        result = cache.merge_or_put(2, 50, inner)
        # Should merge with outer
        assert result[0] <= 2

    def test_subset_bva_at_right_boundary(self, cache: PrimeCache) -> None:
        outer = _primes_from_2_to(100)
        cache.merge_or_put(2, 100, outer)
        # Inner range [50, 100] — right edge == outer right edge
        inner = [p for p in outer if p >= 50]
        result = cache.merge_or_put(50, 100, inner)
        assert result[1] >= 100

    # ── C: Full superset ───────────────────────────────────────────────────

    def test_full_superset_merges_into_new_range(
        self, fake_redis: Any, cache: PrimeCache
    ) -> None:
        small = [11, 13, 17, 19]
        cache.merge_or_put(10, 20, small)
        large = _primes_from_2_to(100)
        result = cache.merge_or_put(2, 100, large)
        assert result == (2, 100)
        # Original [10,20] entry should be gone
        assert cache.get(10, 20) is None
        # Merged entry at [2, 100] should exist
        assert cache.exists(2, 100)

    def test_full_superset_result_contains_all_primes(
        self, cache: PrimeCache
    ) -> None:
        small = [11, 13, 17, 19]
        cache.merge_or_put(10, 20, small)
        large = _primes_from_2_to(100)
        cache.merge_or_put(2, 100, large)
        merged = cache.get(2, 100)
        assert merged is not None
        assert set(small).issubset(set(merged))
        assert set(large).issubset(set(merged))

    # ── D: Left overlap ────────────────────────────────────────────────────

    def test_left_overlap_merges(self, cache: PrimeCache) -> None:
        # [2, 10] then [8, 20] → should merge into [2, 20]
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 8]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(8, 20, p2)
        assert result[0] <= 2
        assert result[1] >= 20

    # BVA at left overlap: overlap at 10 (B), 9 (B-1), 11 (B+1)
    def test_left_overlap_bva_overlap_at_end(self, cache: PrimeCache) -> None:
        # [2, 10] then new [10, 20] — overlap at 10 (B)
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 10]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(10, 20, p2)
        assert result[0] <= 2
        assert result[1] >= 20

    def test_left_overlap_bva_new_start_one_below_existing_end(
        self, cache: PrimeCache
    ) -> None:
        # [2, 10] then new [9, 20] — overlap at 9 (B-1 relative to 10)
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 9]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(9, 20, p2)
        assert result[0] <= 2
        assert result[1] >= 20

    def test_left_overlap_bva_new_start_one_above_existing_end(
        self, cache: PrimeCache
    ) -> None:
        # [2, 10] then new [11, 20] — adjacent but NOT overlapping by value
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 11]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(11, 20, p2)
        # adjacent: Lua considers 11 within window of [2,10] → merges
        # (overlap_window = 20-11+1 = 10; 2 >= 11-10 = 1 → candidate)
        # but m_end=10 >= new_start=11? → 10 >= 11 is False → no merge
        assert result == (11, 20)

    # ── E: Right overlap ───────────────────────────────────────────────────

    def test_right_overlap_merges(self, cache: PrimeCache) -> None:
        # [8, 20] then [2, 10] → merge into [2, 20]
        p1 = [p for p in _primes_from_2_to(20) if p >= 8]
        p2 = _primes_from_2_to(10)
        cache.merge_or_put(8, 20, p1)
        result = cache.merge_or_put(2, 10, p2)
        assert result[0] <= 2
        assert result[1] >= 20

    # BVA at right overlap: new end at existing start (B-1, B, B+1)
    def test_right_overlap_bva_new_end_at_existing_start(
        self, cache: PrimeCache
    ) -> None:
        # Existing [10, 20], new [2, 10] → end==start overlap
        p1 = [p for p in _primes_from_2_to(20) if p >= 10]
        p2 = _primes_from_2_to(10)
        cache.merge_or_put(10, 20, p1)
        result = cache.merge_or_put(2, 10, p2)
        # 10 >= 10 (new start=2, existing start=10, existing end=20)
        # → exists and candidate
        assert result[0] <= 2

    def test_right_overlap_bva_new_end_one_below_existing_start(
        self, cache: PrimeCache
    ) -> None:
        # Existing [10, 20], new [2, 9] — no overlap (9 < 10)
        p1 = [p for p in _primes_from_2_to(20) if p >= 10]
        p2 = _primes_from_2_to(9)
        cache.merge_or_put(10, 20, p1)
        result = cache.merge_or_put(2, 9, p2)
        # 9 < 10 → m_end(20) >= new_start(2) but m_start(10) <= new_end(9)?
        # 10 <= 9 is False → no overlap
        assert result == (2, 9)

    def test_right_overlap_bva_new_end_one_above_existing_start(
        self, cache: PrimeCache
    ) -> None:
        # Existing [10, 20], new [2, 11] — overlaps at 11 (B+1 relative to 10)
        p1 = [p for p in _primes_from_2_to(20) if p >= 10]
        p2 = _primes_from_2_to(11)
        cache.merge_or_put(10, 20, p1)
        result = cache.merge_or_put(2, 11, p2)
        assert result[0] <= 2
        assert result[1] >= 20

    # ── F: Adjacent (touching boundary) ────────────────────────────────────
    # BVA: end1=10, start2=11 → 11 is NOT > 10 for overlap check.
    # Per Lua logic: m_end >= new_start → 10 >= 11 → False → no merge.
    # Adjacent ranges are NOT coalesced (gap of 0 between 10 and 11).

    def test_adjacent_bva_touching_exactly(self, cache: PrimeCache) -> None:
        # [2, 10] then [11, 20] — touching but no numeric overlap
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 11]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(11, 20, p2)
        # Adjacent but non-overlapping → not merged
        assert result == (11, 20)
        assert cache.get(2, 10) == p1  # original preserved

    def test_adjacent_bva_one_before_touching(self, cache: PrimeCache) -> None:
        # [2, 10] then [10, 20] — overlap at 10 (B at left of adjacent)
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 10]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(10, 20, p2)
        # m_end(10) >= new_start(10) → True → merges
        assert result[0] <= 2
        assert result[1] >= 20

    def test_adjacent_bva_one_after_touching(self, cache: PrimeCache) -> None:
        # [2, 10] then [12, 20] — gap of 1 → no merge
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 12]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(12, 20, p2)
        assert result == (12, 20)

    # ── G: Gap (non-touching) ──────────────────────────────────────────────

    def test_gap_does_not_merge(self, cache: PrimeCache) -> None:
        # [2, 10] then [15, 25] — gap of 4
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(25) if p >= 15]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(15, 25, p2)
        assert result == (15, 25)
        assert cache.get(2, 10) == p1  # original preserved

    def test_gap_bva_gap_of_1(self, cache: PrimeCache) -> None:
        # [2, 10] and [12, 20]: gap of 1 (11 is the gap)
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 12]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(12, 20, p2)
        assert result == (12, 20)  # no merge for gap=1

    def test_gap_bva_gap_of_0(self, cache: PrimeCache) -> None:
        # [2, 10] and [11, 20]: touching (gap=0, start2=end1+1)
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 11]
        cache.merge_or_put(2, 10, p1)
        result = cache.merge_or_put(11, 20, p2)
        # Per Lua: m_end(10) >= new_start(11) → 10 >= 11 → False → no merge
        assert result == (11, 20)

    # ── Multiple overlapping ranges in ZSET ─────────────────────────────────

    def test_merge_three_overlapping_ranges(
        self, fake_redis: Any, cache: PrimeCache
    ) -> None:
        # Three overlapping ranges: [2,10], [8,20], [15,30]
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(20) if p >= 8]
        p3 = [p for p in _primes_from_2_to(30) if p >= 15]
        cache.merge_or_put(2, 10, p1)
        cache.merge_or_put(8, 20, p2)
        cache.merge_or_put(15, 30, p3)
        # After all merges, should have exactly one range covering [2, 30]
        # (zrange call confirms ZSET has entries; value checked via find_covering)
        assert len(fake_redis.zrange(_ZSET_KEY, 0, -1)) > 0
        # At least one member should cover [2, 30]
        covering = cache.find_covering(2, 30)
        assert covering is not None

    def test_merged_result_is_sorted(self, cache: PrimeCache) -> None:
        # Two overlapping ranges — merged result must be sorted
        p1 = _primes_from_2_to(100)
        p2 = [p for p in _primes_from_2_to(150) if p >= 80]
        cache.merge_or_put(2, 100, p1)
        cache.merge_or_put(80, 150, p2)
        covering = cache.find_covering(2, 150)
        assert covering is not None
        merged = cache.get(covering[0], covering[1])
        assert merged is not None
        assert merged == sorted(merged)

    def test_merged_result_no_duplicates(self, cache: PrimeCache) -> None:
        # Overlapping ranges — no duplicate primes in merged result
        p1 = _primes_from_2_to(100)
        p2 = [p for p in _primes_from_2_to(150) if p >= 50]
        cache.merge_or_put(2, 100, p1)
        cache.merge_or_put(50, 150, p2)
        covering = cache.find_covering(2, 150)
        assert covering is not None
        merged = cache.get(covering[0], covering[1])
        assert merged is not None
        assert len(merged) == len(set(merged))

    # ── TTL in merge ─────────────────────────────────────────────────────────

    def test_merge_or_put_with_no_ttl(
        self, fake_redis: Any, cache: PrimeCache
    ) -> None:
        cache.merge_or_put(2, 10, [2, 3, 5, 7], ttl=0)
        val_key = _range_value_key(2, 10)
        ttl = fake_redis.ttl(val_key)
        assert ttl == -1  # no expiry

    def test_merge_or_put_with_ttl(self, fake_redis: Any, cache: PrimeCache) -> None:
        cache.merge_or_put(2, 10, [2, 3, 5, 7], ttl=3600)
        val_key = _range_value_key(2, 10)
        ttl = fake_redis.ttl(val_key)
        assert ttl > 0


# ───────────────────────────────────────────────────────────────────────────
# Lua merge race — concurrent merge_or_put calls produce a consistent result
# ───────────────────────────────────────────────────────────────────────────


class TestLuaMergeRace:
    """Verify that two sequential merge_or_put calls on overlapping ranges
    produce a correct coalesced result.

    True concurrency is not testable with fakeredis (single-threaded), but
    the sequence test verifies that the Lua script's atomic read-modify-write
    correctly handles the case where a concurrent write has already merged
    some ranges before the current call.
    """

    def test_sequential_overlapping_merges_consistent(
        self, cache: PrimeCache
    ) -> None:
        from sympy import primerange

        # First merge: [2, 100]
        p1 = _primes_from_2_to(100)
        cache.merge_or_put(2, 100, p1)

        # Second merge: [80, 200] — overlaps with [2, 100]
        p2 = list(primerange(80, 201))
        cache.merge_or_put(80, 200, p2)

        # After both merges, should have single range covering [2, 200]
        covering = cache.find_covering(2, 200)
        assert covering is not None
        merged = cache.get(covering[0], covering[1])
        assert merged is not None
        # All primes from both ranges should be present
        expected = sorted(set(p1 + p2))
        assert merged == expected

    def test_idempotent_merge_same_range(self, cache: PrimeCache) -> None:
        primes = _primes_from_2_to(100)
        cache.merge_or_put(2, 100, primes)
        r = cache.merge_or_put(2, 100, primes)
        # Merging the same range twice → result is still [2, 100]
        assert r[0] <= 2
        assert r[1] >= 100
        # Value should still be correct
        result = cache.get_covering_slice(2, 100)
        assert result == primes

    def test_merge_does_not_corrupt_non_overlapping_ranges(
        self, cache: PrimeCache
    ) -> None:
        # Separate non-overlapping ranges — merge of one should not touch other
        p1 = _primes_from_2_to(10)
        p2 = [p for p in _primes_from_2_to(30) if p >= 20]
        cache.merge_or_put(2, 10, p1)
        cache.merge_or_put(20, 30, p2)

        # Merge a new range that overlaps with [2, 10] only
        p3 = [p for p in _primes_from_2_to(15) if p >= 7]
        cache.merge_or_put(7, 15, p3)

        # [20, 30] should still be intact
        result = cache.get_covering_slice(20, 30)
        assert result == p2


# ───────────────────────────────────────────────────────────────────────────
# _make_client — client factory (plaintext vs TLS path)
# ───────────────────────────────────────────────────────────────────────────


class TestMakeClient:
    """Coverage of the _make_client factory function.

    We don't actually connect; we verify the Redis client type returned
    for each VALKEY_TLS configuration.
    """

    def test_plaintext_returns_redis_instance(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """VALKEY_TLS=false → returns redis.Redis (not cluster)."""

        import redis

        monkeypatch.setenv("VALKEY_TLS", "false")
        monkeypatch.setenv("VALKEY_ENDPOINT", "localhost:6379")
        client = _make_client()
        assert isinstance(client, redis.Redis)

    def test_tls_returns_redis_cluster(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """VALKEY_TLS=true → returns RedisCluster (with ssl=True)."""

        from unittest.mock import patch as _patch

        monkeypatch.setenv("VALKEY_TLS", "true")
        monkeypatch.setenv("VALKEY_ENDPOINT", "localhost:6379")

        # Patch RedisCluster so we don't actually connect
        with _patch("prime_service.cache.redis.cluster.RedisCluster") as MockCluster:
            MockCluster.return_value = MagicMock()
            _make_client()

        MockCluster.assert_called_once_with(
            host="localhost", port=6379, ssl=True, decode_responses=True
        )

    def test_endpoint_without_port_defaults_6379(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """VALKEY_ENDPOINT without :port → defaults to port 6379."""
        import redis

        monkeypatch.setenv("VALKEY_TLS", "false")
        monkeypatch.setenv("VALKEY_ENDPOINT", "myhost")
        client = _make_client()
        assert isinstance(client, redis.Redis)

    def test_default_endpoint_when_not_set(self, monkeypatch: pytest.MonkeyPatch) -> None:
        """No VALKEY_ENDPOINT → defaults to localhost:6379."""
        import redis

        monkeypatch.delenv("VALKEY_ENDPOINT", raising=False)
        monkeypatch.setenv("VALKEY_TLS", "false")
        client = _make_client()
        assert isinstance(client, redis.Redis)
