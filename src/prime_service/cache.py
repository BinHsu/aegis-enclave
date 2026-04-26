"""Valkey/Redis distributed cache for prime ranges.

ZSET schema (per strategy.md § D pre-decided choices):
    Key:    primes:{ranges}      (sorted set; {ranges} hash tag for shard-locality)
    Member: {start}:{end}        (string, e.g. "2:100000")
    Score:  start                (enables ZRANGEBYSCORE for overlap queries)

Per-range value:
    Key:    primes:{ranges}:range:{start}:{end}   (string, JSON array of ints)

Example:
    ZADD "primes:{ranges}" 2 "2:100000"
    SET  "primes:{ranges}:range:2:100000" "[2,3,5,7,...]"

TTL policy:
    - Bootstrap entry (primes:{ranges}:range:1:100000): no TTL (permanent seed)
    - User-driven entries: 6 hours
    - Merged entries: inherit max(ttl_a, ttl_b) → simplified to 6h on merge

Lua merge script:
    Single Lua script for atomic range-coalescing. KEYS must be pre-declared
    (Serverless Valkey constraint). The script handles overlap detection and
    merges overlapping or adjacent ranges into a single coalesced entry.

Client factory:
    - `VALKEY_TLS=true`  → redis.cluster.RedisCluster(ssl=True) for cloud
    - `VALKEY_TLS=false` → redis.Redis (plaintext) for local dev
"""

from __future__ import annotations

import json
import os
from typing import Any

import redis
import redis.client
import redis.cluster

# ─── Constants ────────────────────────────────────────────────────────────────

_ZSET_KEY = "primes:{ranges}"  # sorted set; {ranges} hash tag for shard locality
_TTL_SECONDS = 6 * 3600  # 6 hours for user-driven entries

# Range start used for the bootstrap pre-warm entry. bootstrap.py writes
# range 1:100000 to seed the cache before the first real query arrives.
_BOOTSTRAP_START = 1
_BOOTSTRAP_END = 100_000


def _range_value_key(start: int, end: int) -> str:
    return f"primes:{{ranges}}:range:{start}:{end}"


# ─── Lua merge script ─────────────────────────────────────────────────────────
# KEYS[1]: the ZSET key (primes:{ranges})
# KEYS[2]: the new range's value key (primes:{ranges}:range:{start}:{end})
# ARGV[1]: start (integer as string)
# ARGV[2]: end   (integer as string)
# ARGV[3]: JSON-encoded prime list (the new range's value)
# ARGV[4]: TTL in seconds (0 = no TTL, e.g. bootstrap entry)
#
# Logic:
#   1. ZRANGEBYSCORE KEYS[1] from -inf to new_end (score=start) to find all
#      ranges whose start <= new_end.  Then filter: keep members where
#      m_end >= new_start (actual overlap; adjacent ranges where m_end = new_start-1
#      are NOT merged per strategy.md § D adjacency rule).
#   2. Union all overlapping prime lists with the new list (sorted-unique merge).
#   3. Delete old ZSET members + value keys.
#   4. Write coalesced ZSET member + value key.
#   5. Apply TTL if ARGV[4] > 0.
#
# Single-shard guarantee: the {ranges} hash tag pins all keys to one slot.
# KEYS pre-declaration satisfies Serverless Valkey's requirement for Lua.

_LUA_MERGE_OR_PUT = """
local zset_key = KEYS[1]
local new_val_key = KEYS[2]
local new_start = tonumber(ARGV[1])
local new_end   = tonumber(ARGV[2])
local new_json  = ARGV[3]
local ttl_s     = tonumber(ARGV[4])

-- Find candidates: all members whose score (start) <= new_end.
-- A range [m_start, m_end] overlaps [new_start, new_end] iff
-- m_start <= new_end AND m_end >= new_start.
-- We query by score (start) from -inf to new_end, then filter by m_end.
local candidates = redis.call('ZRANGEBYSCORE', zset_key, '-inf', new_end)

-- Filter to actual overlaps: member_end >= new_start
local overlapping = {}
local min_start = new_start
local max_end   = new_end

for _, member in ipairs(candidates) do
    -- member format: "{start}:{end}"
    local colon = string.find(member, ':')
    local m_start = tonumber(string.sub(member, 1, colon - 1))
    local m_end   = tonumber(string.sub(member, colon + 1))
    if m_end >= new_start and m_start <= new_end then
        table.insert(overlapping, {member=member, m_start=m_start, m_end=m_end})
        if m_start < min_start then min_start = m_start end
        if m_end   > max_end   then max_end   = m_end   end
    end
end

-- If no overlaps, just insert the new range directly.
if #overlapping == 0 then
    redis.call('ZADD', zset_key, new_start, new_start .. ':' .. new_end)
    if ttl_s > 0 then
        redis.call('SET', new_val_key, new_json, 'EX', ttl_s)
    else
        redis.call('SET', new_val_key, new_json)
    end
    return {new_start, new_end}
end

-- Union: collect all primes from overlapping ranges + new list.
local all_primes_set = {}
local new_primes = cjson.decode(new_json)
for _, p in ipairs(new_primes) do
    all_primes_set[p] = true
end

for _, ov in ipairs(overlapping) do
    local val_key = 'primes:{ranges}:range:' .. ov.m_start .. ':' .. ov.m_end
    local existing = redis.call('GET', val_key)
    if existing then
        local existing_primes = cjson.decode(existing)
        for _, p in ipairs(existing_primes) do
            all_primes_set[p] = true
        end
    end
    -- Delete old member and value key
    redis.call('ZREM', zset_key, ov.member)
    redis.call('DEL', val_key)
end

-- Build sorted merged list
local merged = {}
for p, _ in pairs(all_primes_set) do
    table.insert(merged, p)
end
table.sort(merged)

local merged_key = 'primes:{ranges}:range:' .. min_start .. ':' .. max_end
local merged_json = cjson.encode(merged)

redis.call('ZADD', zset_key, min_start, min_start .. ':' .. max_end)
if ttl_s > 0 then
    redis.call('SET', merged_key, merged_json, 'EX', ttl_s)
else
    redis.call('SET', merged_key, merged_json)
end

return {min_start, max_end}
"""


# ─── Client factory ───────────────────────────────────────────────────────────

# Use Any for the Redis client type to avoid mypy battles with redis-py's
# complex generic stubs. All public methods are typed at the PrimeCache level.
_RedisClient = Any


def _make_client() -> _RedisClient:
    """Build a Redis/Valkey client from environment variables.

    VALKEY_ENDPOINT: host:port or just host (default: localhost:6379)
    VALKEY_TLS: "true" enables SSL (cluster mode for cloud); anything else
                uses a plain Redis connection (local dev).
    """
    endpoint = os.environ.get("VALKEY_ENDPOINT", "localhost:6379")
    use_tls = os.environ.get("VALKEY_TLS", "false").lower() == "true"

    if ":" in endpoint:
        host, port_str = endpoint.rsplit(":", 1)
        port = int(port_str)
    else:
        host = endpoint
        port = 6379

    if use_tls:
        # Cluster mode + TLS for ElastiCache Serverless Valkey in cloud.
        return redis.cluster.RedisCluster(
            host=host,
            port=port,
            ssl=True,
            decode_responses=True,
        )

    return redis.Redis(host=host, port=port, decode_responses=True)


# ─── PrimeCache ───────────────────────────────────────────────────────────────


class PrimeCache:
    """Distributed cache for prime ranges backed by Valkey/Redis.

    Public interface:
        exists(start, end) → bool
        get(start, end) → list[int] | None
        put(start, end, primes, ttl) → None
        put_if_absent(start, end, primes) → bool   (True if written)
        merge_or_put(start, end, primes, ttl) → tuple[int, int]
        find_covering(start, end) → tuple[int, int] | None
        get_covering_slice(start, end) → list[int] | None
    """

    def __init__(self, client: _RedisClient = None) -> None:
        self._r: _RedisClient = client if client is not None else _make_client()
        self._merge_script: Any = self._r.register_script(_LUA_MERGE_OR_PUT)

    def _val_key(self, start: int, end: int) -> str:
        return _range_value_key(start, end)

    def exists(self, start: int, end: int) -> bool:
        """Return True if the exact range [start, end] has a cached value."""
        return bool(self._r.exists(self._val_key(start, end)))

    def get(self, start: int, end: int) -> list[int] | None:
        """Return cached primes for [start, end], or None if absent."""
        raw: str | None = self._r.get(self._val_key(start, end))
        if raw is None:
            return None
        result: list[int] = json.loads(raw)
        return result

    def put(self, start: int, end: int, primes: list[int], ttl: int = _TTL_SECONDS) -> None:
        """Write (or overwrite) a range entry with the given TTL (0 = no TTL)."""
        val = json.dumps(primes)
        zset_member = f"{start}:{end}"
        pipe = self._r.pipeline()
        pipe.zadd(_ZSET_KEY, {zset_member: float(start)})
        if ttl > 0:
            pipe.set(self._val_key(start, end), val, ex=ttl)
        else:
            pipe.set(self._val_key(start, end), val)
        pipe.execute()

    def put_if_absent(self, start: int, end: int, primes: list[int]) -> bool:
        """Write the range entry only if it does not already exist.

        Returns True if the value was written, False if it already existed.
        Used by the bootstrap task for idempotent pre-warming.
        """
        val = json.dumps(primes)
        zset_member = f"{start}:{end}"
        val_key = self._val_key(start, end)
        # SET NX: atomic "set if not exists"
        written: bool | None = self._r.set(val_key, val, nx=True)
        if written:
            # Only update the ZSET if the value was freshly written.
            self._r.zadd(_ZSET_KEY, {zset_member: float(start)})
            return True
        return False

    def merge_or_put(
        self,
        start: int,
        end: int,
        primes: list[int],
        ttl: int = _TTL_SECONDS,
    ) -> tuple[int, int]:
        """Atomically coalesce [start, end] with any overlapping ranges.

        Calls the Lua merge script. Returns the (start, end) of the final
        (possibly expanded) coalesced range.

        KEYS pre-declared for Serverless Valkey compatibility:
            KEYS[1]: _ZSET_KEY
            KEYS[2]: value key for [start, end]
        """
        val_key = self._val_key(start, end)
        result: list[Any] = self._merge_script(
            keys=[_ZSET_KEY, val_key],
            args=[str(start), str(end), json.dumps(primes), str(ttl)],
        )
        # Lua returns {min_start, max_end}
        return (int(result[0]), int(result[1]))

    def find_covering(self, start: int, end: int) -> tuple[int, int] | None:
        """Find a cached range that fully covers [start, end], if any.

        Uses ZRANGEBYSCORE on the ZSET to find candidates whose start <= start,
        then checks if any of them has an end >= end.

        Returns (cached_start, cached_end) of the covering range, or None.

        V2 opportunity (partial-hit read path, NOT implemented):
            A request that is *partially* covered (e.g. [50_000, 150_000] when
            cache has only bootstrap [1, 100_000]) currently returns None and
            the worker re-computes the entire requested range. After compute,
            the Lua merge_or_put coalesces the new write with the existing
            bootstrap entry into [1, 150_000], so subsequent fully-covered
            queries hit cache. The wasted work is the recomputation of the
            already-cached overlap on the first miss. A V2 partial-hit
            optimisation would: (a) detect partial coverage, (b) split the
            request into cached_part + uncached_part, (c) compute only
            uncached_part, (d) splice the two prime lists together, (e) merge.
            Trade-off: query splitter + multiple Valkey GETs + result splice +
            merge is non-trivial, while compute on a small uncached gap is
            often <10ms — the optimisation pays off only for large gaps over
            slow cache networks. Deferred until a real workload justifies it.

        Iteration order trade-off (also V2):
            Candidates are returned in ascending score (= ascending start). The
            loop returns the *first* covering range, which is therefore the
            range with the smallest start. When a query is covered by both the
            bootstrap entry [1, 100_000] and a tighter user-driven entry, the
            larger bootstrap entry is selected — pulling a 50KB JSON when a
            <1KB tighter entry would have sufficed. Wall time impact is
            sub-10ms over Valkey local network; storage transfer is the cost.
            V2 fix: rank candidates by (m_end - m_start) ascending and return
            the smallest covering range.
        """
        # Candidates: all ZSET members with score (start) <= start
        candidates: list[tuple[str, float]] = self._r.zrangebyscore(
            _ZSET_KEY, "-inf", start, withscores=True
        )
        for member, score in candidates:
            # member is "{m_start}:{m_end}"
            colon_idx = str(member).index(":")
            m_start = int(score)
            m_end = int(str(member)[colon_idx + 1 :])
            if m_start <= start and m_end >= end:
                return (m_start, m_end)
        return None

    def get_covering_slice(self, start: int, end: int) -> list[int] | None:
        """Return a slice of primes from a covering cached range, if available.

        Combines `find_covering` + `get` + `_slice_known` to satisfy a query
        from cache without computing. Returns None if no covering range exists.
        """
        covering = self.find_covering(start, end)
        if covering is None:
            return None
        cached = self.get(covering[0], covering[1])
        if cached is None:
            return None
        # Slice to the requested [start, end]
        from prime_service.primes import _slice_known

        return _slice_known(cached, start, end)
