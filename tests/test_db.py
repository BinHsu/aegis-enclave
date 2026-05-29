"""Tests for prime_service.db — DynamoDB layer (ADR-0042).

Strategy
--------
- ``moto[dynamodb]`` mocks DynamoDB in-process; no real AWS calls.
- Every test that exercises the table uses the ``ddb_table`` fixture which
  creates a fresh moto-backed table.
- BVA on UUID format, status transitions, TTL math, and conditional write
  idempotency.

What these tests cover:
- ``insert_queued_execution``: happy path, idempotency (duplicate UUID no-op),
  round-trip attribute presence.
- ``get_execution``: found, not found, ConsistentRead semantics (mocked).
- ``mark_running``: queued → running transition + ConditionExpression guard.
- ``mark_done``: running → done + TTL set at completed_at + 30d.
- ``mark_failed``: running → failed + TTL set at completed_at + 90d.
- ``health_check``: returns True on ACTIVE table, False on error.
- TTL BVA: TTL values are within expected epoch windows.
- UUID format BVA: execution_id must be a valid UUID4 string.
- Status transition BVA: each status value (queued/running/done/failed).
"""

from __future__ import annotations

import os
import re
import time
import uuid
from typing import Any
from unittest.mock import patch

import boto3
import pytest
from moto import mock_aws  # moto >= 5 uses mock_aws unified decorator

# ---------------------------------------------------------------------------
# Test helpers / fixtures
# ---------------------------------------------------------------------------

_TABLE_NAME = "aegis-enclave-executions"
_REGION = "eu-central-1"


@pytest.fixture(autouse=True)
def _aws_env(monkeypatch: pytest.MonkeyPatch) -> None:
    """Set dummy AWS credentials so boto3 doesn't reject moto calls."""
    monkeypatch.setenv("AWS_ACCESS_KEY_ID", "test")
    monkeypatch.setenv("AWS_SECRET_ACCESS_KEY", "test")
    monkeypatch.setenv("AWS_DEFAULT_REGION", _REGION)
    monkeypatch.setenv("DYNAMODB_TABLE_NAME", _TABLE_NAME)
    monkeypatch.delenv("AWS_ENDPOINT_URL_DYNAMODB", raising=False)


@pytest.fixture()
def ddb_table() -> Any:
    """Create a moto-backed DynamoDB table and yield it for the duration of one test."""
    with mock_aws():
        ddb = boto3.resource("dynamodb", region_name=_REGION)
        table = ddb.create_table(
            TableName=_TABLE_NAME,
            KeySchema=[{"AttributeName": "execution_id", "KeyType": "HASH"}],
            AttributeDefinitions=[{"AttributeName": "execution_id", "AttributeType": "S"}],
            BillingMode="PAY_PER_REQUEST",
        )
        table.meta.client.get_waiter("table_exists").wait(TableName=_TABLE_NAME)
        yield table


def _make_uuid() -> str:
    return str(uuid.uuid4())


# ---------------------------------------------------------------------------
# Import the module under test AFTER env vars are set
# ---------------------------------------------------------------------------


def _import_db() -> Any:
    """Return the db module (re-imported so env vars apply)."""
    import prime_service.db as db_mod

    return db_mod


# ---------------------------------------------------------------------------
# insert_queued_execution
# ---------------------------------------------------------------------------


class TestInsertQueuedExecution:
    """Verify insert_queued_execution writes a 'queued' row and returns execution_id."""

    def test_returns_execution_id(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            result = db.insert_queued_execution(
                execution_id=eid,
                range_start=2,
                range_end=100,
            )
        assert result == eid

    def test_row_written_to_table(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=100)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True).get("Item")
        assert item is not None
        assert item["execution_id"] == eid

    def test_status_is_queued(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=100)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "queued"

    def test_range_attributes_stored(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=7, range_end=999)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert int(item["range_start"]) == 7
        assert int(item["range_end"]) == 999

    def test_created_at_is_recent_epoch(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        before = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        after = int(time.time())
        assert before <= int(item["created_at"]) <= after

    # BVA on range_start boundary (API minimum = 2)
    def test_range_start_bva_at_2(self, ddb_table: Any) -> None:
        """BVA B: range_start=2 (API minimum) is stored correctly."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert int(item["range_start"]) == 2

    def test_range_start_bva_at_3(self, ddb_table: Any) -> None:
        """BVA B+1: range_start=3 stored correctly."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=3, range_end=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert int(item["range_start"]) == 3

    def test_range_start_bva_at_1(self, ddb_table: Any) -> None:
        """BVA B-1: range_start=1 (bootstrap range) stored correctly."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=1, range_end=100000)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert int(item["range_start"]) == 1

    # Idempotency — duplicate UUID must not raise; returns same id
    def test_duplicate_uuid_is_idempotent(self, ddb_table: Any) -> None:
        """Second insert with same UUID → no error; returns same id."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            result1 = db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            result2 = db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
        assert result1 == eid
        assert result2 == eid

    def test_duplicate_uuid_does_not_overwrite(self, ddb_table: Any) -> None:
        """Conditional put: second insert with same UUID leaves original row intact."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            # First mark it running to change status
            db.mark_running(eid)
            # Re-insert with same UUID — should not reset status back to queued
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        # Status should still be 'running' (not reset to 'queued')
        assert item["status"] == "running"

    # UUID format BVA: must be valid UUID4 format
    def test_uuid4_format_is_string(self, ddb_table: Any) -> None:
        """execution_id is a string UUID4."""
        eid = _make_uuid()
        # Verify format: must parse as UUID without error
        parsed = uuid.UUID(eid, version=4)
        assert str(parsed) == eid

    def test_uuid_all_lowercase_hex_format(self, ddb_table: Any) -> None:
        """UUID4 strings contain only hex chars and hyphens."""
        eid = _make_uuid()
        _UUID4_PATTERN = r"^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
        assert re.match(_UUID4_PATTERN, eid)

    def test_two_uuids_are_distinct(self, ddb_table: Any) -> None:
        """UUID4 generation produces unique values."""
        eid1 = _make_uuid()
        eid2 = _make_uuid()
        assert eid1 != eid2

    def test_no_ttl_at_on_queued_insert(self, ddb_table: Any) -> None:
        """queued row must NOT have a ttl_at set (per TTL policy)."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=100)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert "ttl_at" not in item


# ---------------------------------------------------------------------------
# get_execution
# ---------------------------------------------------------------------------


class TestGetExecution:
    """Verify get_execution returns item dict or None."""

    def test_returns_dict_when_found(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            result = db.get_execution(eid)
        assert result is not None
        assert isinstance(result, dict)
        assert result["execution_id"] == eid

    def test_returns_none_when_not_found(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            result = db.get_execution(eid)
        assert result is None

    def test_status_field_present_in_result(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=100)
            result = db.get_execution(eid)
        assert result is not None
        assert "status" in result
        assert result["status"] == "queued"

    # BVA: UUID with all zeros edge case
    def test_zero_uuid_not_found(self, ddb_table: Any) -> None:
        """get_execution with a zero UUID (not inserted) returns None."""
        db = _import_db()
        with mock_aws():
            result = db.get_execution("00000000-0000-0000-0000-000000000000")
        assert result is None


# ---------------------------------------------------------------------------
# mark_running
# ---------------------------------------------------------------------------


class TestMarkRunning:
    """Verify queued → running transition."""

    def test_queued_transitions_to_running(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "running"

    def test_started_at_set_on_running(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        before = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        after = int(time.time())
        assert "started_at" in item
        assert before <= int(item["started_at"]) <= after

    def test_mark_running_on_already_running_is_no_op(self, ddb_table: Any) -> None:
        """ConditionExpression: status must be 'queued'. Double mark_running is silently ignored."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            # Second mark_running should not raise
            db.mark_running(eid)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "running"

    def test_mark_running_on_done_is_no_op(self, ddb_table: Any) -> None:
        """ConditionExpression: status must be 'queued'. mark_running on done row is ignored."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            # Should not raise
            db.mark_running(eid)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "done"


# ---------------------------------------------------------------------------
# mark_done
# ---------------------------------------------------------------------------


class TestMarkDone:
    """Verify running → done transition + TTL math."""

    def test_running_transitions_to_done(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5, 7], duration_ms=50)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "done"

    def test_primes_stored_as_list(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5, 7], duration_ms=50)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        stored = [int(p) for p in item["primes"]]
        assert stored == [2, 3, 5, 7]

    def test_primes_count_matches(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5, 7], duration_ms=50)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert int(item["primes_count"]) == 4

    def test_duration_ms_stored(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5, 7], duration_ms=123)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert int(item["duration_ms"]) == 123

    def test_completed_at_set(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        before = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        after = int(time.time())
        assert before <= int(item["completed_at"]) <= after

    # TTL BVA: done TTL = completed_at + 30d
    def test_done_ttl_is_30_days_from_completed_at(self, ddb_table: Any) -> None:
        """BVA B: ttl_at = completed_at + 30d (exactly)."""
        db = _import_db()
        eid = _make_uuid()
        before = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        after = int(time.time())
        ttl_at = int(item["ttl_at"])
        # ttl_at should be approximately now + 30 days
        expected_min = before + 30 * 86_400
        expected_max = after + 30 * 86_400
        assert expected_min <= ttl_at <= expected_max

    def test_done_ttl_bva_29_days_below(self, ddb_table: Any) -> None:
        """BVA B-1: 29d in seconds < TTL value (TTL must be >= 30d from now)."""
        db = _import_db()
        eid = _make_uuid()
        now = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        ttl_at = int(item["ttl_at"])
        # ttl_at must be strictly more than 29 days from now
        assert ttl_at > now + 29 * 86_400

    def test_done_ttl_bva_31_days_above(self, ddb_table: Any) -> None:
        """BVA B+1: TTL value < 31d from now (TTL must be <= 31d from now)."""
        db = _import_db()
        eid = _make_uuid()
        now = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        ttl_at = int(item["ttl_at"])
        # ttl_at must be strictly less than 31 days from now
        assert ttl_at < now + 31 * 86_400

    def test_mark_done_on_done_is_no_op(self, ddb_table: Any) -> None:
        """Double mark_done should not raise."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            # Should not raise
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "done"

    def test_empty_primes_list(self, ddb_table: Any) -> None:
        """Empty primes list (range with no primes) stores correctly."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=14, range_end=16)
            db.mark_running(eid)
            db.mark_done(eid, primes=[], duration_ms=5)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert int(item["primes_count"]) == 0


# ---------------------------------------------------------------------------
# mark_failed
# ---------------------------------------------------------------------------


class TestMarkFailed:
    """Verify running → failed transition + TTL math."""

    def test_running_transitions_to_failed(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="compute timeout")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "failed"

    def test_error_message_stored(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="compute exceeded 60s SIGALRM budget")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert "60s" in item["error_message"]

    def test_completed_at_set_on_failed(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        before = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="err")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        after = int(time.time())
        assert before <= int(item["completed_at"]) <= after

    # TTL BVA: failed TTL = completed_at + 90d
    def test_failed_ttl_is_90_days_from_completed_at(self, ddb_table: Any) -> None:
        """BVA B: ttl_at = completed_at + 90d (exactly)."""
        db = _import_db()
        eid = _make_uuid()
        before = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="err")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        after = int(time.time())
        ttl_at = int(item["ttl_at"])
        expected_min = before + 90 * 86_400
        expected_max = after + 90 * 86_400
        assert expected_min <= ttl_at <= expected_max

    def test_failed_ttl_bva_89_days_below(self, ddb_table: Any) -> None:
        """BVA B-1: 89d in seconds < TTL value (TTL must be >= 90d from now)."""
        db = _import_db()
        eid = _make_uuid()
        now = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="err")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        ttl_at = int(item["ttl_at"])
        assert ttl_at > now + 89 * 86_400

    def test_failed_ttl_bva_91_days_above(self, ddb_table: Any) -> None:
        """BVA B+1: TTL value < 91d from now (TTL must be <= 91d from now)."""
        db = _import_db()
        eid = _make_uuid()
        now = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="err")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        ttl_at = int(item["ttl_at"])
        assert ttl_at < now + 91 * 86_400

    def test_mark_failed_from_queued_is_allowed(self, ddb_table: Any) -> None:
        """queued → failed is allowed (stale-detection path skips mark_running)."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_failed(eid, error_message="stale running — prior worker crash")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "failed"

    def test_mark_failed_on_done_is_no_op(self, ddb_table: Any) -> None:
        """Cannot transition done → failed (ConditionExpression guards it)."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            # Should not raise; just silently ignored
            db.mark_failed(eid, error_message="should be ignored")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "done"


# ---------------------------------------------------------------------------
# Status transition state machine BVA
# ---------------------------------------------------------------------------


class TestStatusTransitions:
    """BVA on the status state machine: queued → running → done | failed."""

    # BVA at each status value (4 states)
    @pytest.mark.parametrize("status_value", ["queued", "running", "done", "failed"])
    def test_all_status_values_are_strings(self, status_value: str) -> None:
        """Each status is a string (DynamoDB String type)."""
        assert isinstance(status_value, str)

    def test_full_happy_path_queued_running_done(self, ddb_table: Any) -> None:
        """Full state machine traversal: queued → running → done."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
            assert item["status"] == "queued"

            db.mark_running(eid)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
            assert item["status"] == "running"

            db.mark_done(eid, primes=[2, 3, 5, 7], duration_ms=50)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
            assert item["status"] == "done"

    def test_full_failure_path_queued_running_failed(self, ddb_table: Any) -> None:
        """Full state machine traversal: queued → running → failed."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="timeout")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "failed"

    def test_queued_no_ttl_at(self, ddb_table: Any) -> None:
        """BVA: queued status → no ttl_at (TTL policy: in-flight rows not expired)."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert "ttl_at" not in item

    def test_running_no_ttl_at(self, ddb_table: Any) -> None:
        """BVA: running status → no ttl_at (TTL policy: in-flight rows not expired)."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert "ttl_at" not in item

    def test_done_has_ttl_at(self, ddb_table: Any) -> None:
        """BVA: done status → ttl_at set."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert "ttl_at" in item

    def test_failed_has_ttl_at(self, ddb_table: Any) -> None:
        """BVA: failed status → ttl_at set."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="err")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert "ttl_at" in item


# ---------------------------------------------------------------------------
# health_check
# ---------------------------------------------------------------------------


class TestHealthCheck:
    """Verify health_check returns True on ACTIVE table, False on error."""

    def test_returns_true_when_table_active(self, ddb_table: Any) -> None:
        db = _import_db()
        with mock_aws():
            result = db.health_check()
        assert result is True

    def test_returns_false_when_endpoint_unreachable(self) -> None:
        """No mock_aws context → boto3 hits an unreachable endpoint → returns False."""
        db = _import_db()
        with patch.dict(
            os.environ,
            {"AWS_ENDPOINT_URL_DYNAMODB": "http://127.0.0.1:9999"},
        ):
            result = db.health_check()
        assert result is False

    def test_returns_bool_type(self, ddb_table: Any) -> None:
        db = _import_db()
        with mock_aws():
            result = db.health_check()
        assert isinstance(result, bool)

    def test_returns_false_on_missing_table(self) -> None:
        """Table does not exist → health_check returns False."""
        db = _import_db()
        with mock_aws():
            # No table created in this context
            result = db.health_check()
        assert result is False


# ---------------------------------------------------------------------------
# Conditional write idempotency — concurrent write races
# ---------------------------------------------------------------------------


class TestConditionalWriteIdempotency:
    """Verify ConditionExpression guards prevent duplicate state transitions."""

    def test_concurrent_insert_same_uuid_both_return_id(self, ddb_table: Any) -> None:
        """Two inserts with the same UUID: both return the id without error."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            r1 = db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            r2 = db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
        assert r1 == eid
        assert r2 == eid

    def test_mark_running_on_queued_succeeds(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)  # should not raise
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "running"

    def test_mark_done_on_running_succeeds(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=50)  # should not raise
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "done"

    def test_mark_failed_on_running_succeeds(self, ddb_table: Any) -> None:
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="err")  # should not raise
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "failed"

    def test_mark_done_guards_done_to_failed(self, ddb_table: Any) -> None:
        """done → failed must be blocked by ConditionExpression."""
        db = _import_db()
        eid = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[2, 3, 5], duration_ms=10)
            db.mark_failed(eid, error_message="should not apply")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        assert item["status"] == "done"


# ---------------------------------------------------------------------------
# TTL differences between done (30d) and failed (90d)
# ---------------------------------------------------------------------------


class TestTTLDifference:
    """BVA: done TTL < failed TTL (30d vs 90d)."""

    def test_done_ttl_less_than_failed_ttl(self, ddb_table: Any) -> None:
        """done row's ttl_at is < failed row's ttl_at (30d < 90d)."""
        db = _import_db()
        eid_done = _make_uuid()
        eid_failed = _make_uuid()
        with mock_aws():
            db.insert_queued_execution(execution_id=eid_done, range_start=2, range_end=10)
            db.mark_running(eid_done)
            db.mark_done(eid_done, primes=[2, 3], duration_ms=5)

            db.insert_queued_execution(execution_id=eid_failed, range_start=2, range_end=10)
            db.mark_running(eid_failed)
            db.mark_failed(eid_failed, error_message="err")

            item_done = ddb_table.get_item(Key={"execution_id": eid_done}, ConsistentRead=True)[
                "Item"
            ]
            item_failed = ddb_table.get_item(Key={"execution_id": eid_failed}, ConsistentRead=True)[
                "Item"
            ]

        assert int(item_done["ttl_at"]) < int(item_failed["ttl_at"])

    def test_done_ttl_delta_30d(self, ddb_table: Any) -> None:
        """done TTL delta = 30 days × 86400 s/day."""
        db = _import_db()
        eid = _make_uuid()
        now = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_done(eid, primes=[], duration_ms=1)
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        ttl_at = int(item["ttl_at"])
        # Delta from now should be approximately 30*86400 (within 2 seconds clock drift)
        delta = ttl_at - now
        assert 30 * 86_400 - 2 <= delta <= 30 * 86_400 + 2

    def test_failed_ttl_delta_90d(self, ddb_table: Any) -> None:
        """failed TTL delta = 90 days × 86400 s/day."""
        db = _import_db()
        eid = _make_uuid()
        now = int(time.time())
        with mock_aws():
            db.insert_queued_execution(execution_id=eid, range_start=2, range_end=10)
            db.mark_running(eid)
            db.mark_failed(eid, error_message="err")
            item = ddb_table.get_item(Key={"execution_id": eid}, ConsistentRead=True)["Item"]
        ttl_at = int(item["ttl_at"])
        delta = ttl_at - now
        assert 90 * 86_400 - 2 <= delta <= 90 * 86_400 + 2
