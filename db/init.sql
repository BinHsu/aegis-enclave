-- Initial schema for the executions audit table.
-- This file is mounted into the postgres container's
-- /docker-entrypoint-initdb.d/ and runs on first start (empty volume).
--
-- Schema choices:
--   - JSONB for the primes array: flexible storage, indexable on contained
--     values if a future query needs it. For very large ranges, a normalised
--     side table would be the next step (see ADR-0009 — read replicas etc.
--     are out of scope for current write-heavy workload).
--   - CHECK constraints enforce caller-side invariants at the DB tier — a
--     defence in depth against application-level validation drift.
--   - Index on created_at DESC supports the typical "show recent executions"
--     query pattern. Index on (range_start, range_end) supports dedupe-style
--     lookups if ever needed.
--   - status/started_at/completed_at/error_message added for async worker
--     state machine (queued → running → done | failed). Index on status
--     enables backpressure queue-depth proxy queries (Phase 2.3).

CREATE TABLE IF NOT EXISTS executions (
    id            BIGSERIAL PRIMARY KEY,
    range_start   INTEGER     NOT NULL,
    range_end     INTEGER     NOT NULL,
    primes_count  INTEGER     NOT NULL,
    primes        JSONB,
    duration_ms   INTEGER     NOT NULL,
    created_at    TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    status        TEXT        NOT NULL DEFAULT 'done',
    started_at    TIMESTAMPTZ,
    completed_at  TIMESTAMPTZ,
    error_message TEXT,

    CONSTRAINT executions_range_valid    CHECK (range_start <= range_end),
    CONSTRAINT executions_range_positive CHECK (range_start >= 2),
    CONSTRAINT executions_count_nonneg   CHECK (primes_count >= 0),
    CONSTRAINT executions_status_valid   CHECK (status IN ('queued', 'running', 'done', 'failed'))
);

CREATE INDEX IF NOT EXISTS idx_executions_created_at
    ON executions (created_at DESC);

CREATE INDEX IF NOT EXISTS idx_executions_range
    ON executions (range_start, range_end);

CREATE INDEX IF NOT EXISTS idx_executions_status
    ON executions (status);
