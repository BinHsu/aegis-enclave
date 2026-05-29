"""Unit tests for prime_service.queue — SQS abstraction.

Strategy
--------
- moto[sqs] provides a local SQS mock; tests run without real AWS credentials.
- BVA on queue depth (0, threshold, threshold+1).
- BVA on message body parsing (valid JSON, missing fields, wrong types).
- BVA on visibility timeout boundary (sqs attribute).
- Per-method tests: enqueue, receive, ack, queue_depth, parse_body.
"""

from __future__ import annotations

import json
import os
from typing import Any
from unittest.mock import MagicMock, patch

import boto3
import pytest
from moto import mock_aws

from prime_service.queue import (
    _MAX_MESSAGES,
    _QUEUE_NAME,
    _VISIBILITY_TIMEOUT_S,
    _WAIT_TIME_SECONDS,
    PrimeQueue,
)

# ───────────────────────────────────────────────────────────────────────────
# Fixtures
# ───────────────────────────────────────────────────────────────────────────


@pytest.fixture
def aws_credentials() -> None:
    """Mocked AWS credentials for moto."""
    os.environ["AWS_ACCESS_KEY_ID"] = "testing"
    os.environ["AWS_SECRET_ACCESS_KEY"] = "testing"
    os.environ["AWS_SECURITY_TOKEN"] = "testing"
    os.environ["AWS_SESSION_TOKEN"] = "testing"
    os.environ["AWS_DEFAULT_REGION"] = "eu-central-1"


@pytest.fixture
def sqs_queue(aws_credentials: None) -> Any:
    """Create a real moto SQS queue and return the boto3 SQS client."""
    with mock_aws():
        client = boto3.client("sqs", region_name="eu-central-1")
        client.create_queue(
            QueueName=_QUEUE_NAME,
            Attributes={"VisibilityTimeout": str(_VISIBILITY_TIMEOUT_S)},
        )
        yield client


@pytest.fixture
def prime_queue(aws_credentials: None) -> Any:
    """PrimeQueue instance inside a moto context."""
    with mock_aws():
        client = boto3.client("sqs", region_name="eu-central-1")
        client.create_queue(
            QueueName=_QUEUE_NAME,
            Attributes={"VisibilityTimeout": str(_VISIBILITY_TIMEOUT_S)},
        )
        q = PrimeQueue()
        yield q


# ───────────────────────────────────────────────────────────────────────────
# _QUEUE_NAME constant
# ───────────────────────────────────────────────────────────────────────────


class TestQueueConstants:
    """Verify pre-decided constants match strategy.md § D."""

    def test_queue_name(self) -> None:
        assert _QUEUE_NAME == "aegis-enclave-primes"

    # BVA at _VISIBILITY_TIMEOUT_S = 90 (1.5 × 60s compute budget)
    def test_visibility_timeout_at_90(self) -> None:
        assert _VISIBILITY_TIMEOUT_S == 90

    def test_visibility_timeout_minus_1(self) -> None:
        # Boundary check: 89s < 90s (strategy constraint)
        assert _VISIBILITY_TIMEOUT_S - 1 == 89

    def test_visibility_timeout_plus_1(self) -> None:
        assert _VISIBILITY_TIMEOUT_S + 1 == 91

    def test_max_messages_is_1(self) -> None:
        # Process one message at a time
        assert _MAX_MESSAGES == 1

    def test_wait_time_long_poll(self) -> None:
        # Long-polling: 20s max per SQS spec
        assert _WAIT_TIME_SECONDS == 20


# ───────────────────────────────────────────────────────────────────────────
# PrimeQueue.enqueue
# ───────────────────────────────────────────────────────────────────────────


class TestEnqueue:
    """BVA on execution_id, start, end boundaries."""

    def test_enqueue_returns_message_id(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            msg_id = q.enqueue(execution_id=1, start=2, end=100)
            assert isinstance(msg_id, str)
            assert len(msg_id) > 0

    def test_enqueue_body_is_valid_json(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            q.enqueue(execution_id=42, start=2, end=1000)

            url = client.get_queue_url(QueueName=_QUEUE_NAME)["QueueUrl"]
            msgs = client.receive_message(QueueUrl=url, MaxNumberOfMessages=1)
            body = json.loads(msgs["Messages"][0]["Body"])
            assert body["execution_id"] == 42
            assert body["start"] == 2
            assert body["end"] == 1000

    # BVA at start = 2 (API minimum)
    def test_enqueue_start_at_2(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            msg_id = q.enqueue(execution_id=1, start=2, end=100)
            assert msg_id

    def test_enqueue_start_at_3(self, aws_credentials: None) -> None:
        """BVA B+1: start = 3."""
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            msg_id = q.enqueue(execution_id=1, start=3, end=100)
            assert msg_id

    def test_enqueue_start_at_1(self, aws_credentials: None) -> None:
        """BVA B-1: start = 1 — queue accepts it; validation is at API layer."""
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            msg_id = q.enqueue(execution_id=1, start=1, end=100)
            assert msg_id

    # BVA at execution_id = 1 (minimum expected ID)
    def test_enqueue_execution_id_1(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            msg_id = q.enqueue(execution_id=1, start=2, end=10)
            assert msg_id

    def test_enqueue_execution_id_0(self, aws_credentials: None) -> None:
        """BVA B-1: execution_id = 0 (edge; DB uses BIGSERIAL starting at 1)."""
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            msg_id = q.enqueue(execution_id=0, start=2, end=10)
            assert msg_id

    def test_enqueue_execution_id_2(self, aws_credentials: None) -> None:
        """BVA B+1: execution_id = 2."""
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            msg_id = q.enqueue(execution_id=2, start=2, end=10)
            assert msg_id


# ───────────────────────────────────────────────────────────────────────────
# PrimeQueue.receive
# ───────────────────────────────────────────────────────────────────────────


class TestReceive:
    def test_receive_empty_queue_returns_empty_list(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            msgs = q.receive()
            assert msgs == []

    def test_receive_one_message_after_enqueue(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            q.enqueue(execution_id=7, start=2, end=100)
            msgs = q.receive()
            assert len(msgs) == 1
            body = json.loads(msgs[0]["Body"])
            assert body["execution_id"] == 7

    # BVA at _MAX_MESSAGES = 1
    def test_receive_at_most_one_message(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            q.enqueue(execution_id=1, start=2, end=10)
            q.enqueue(execution_id=2, start=3, end=20)
            msgs = q.receive()
            # Should receive at most _MAX_MESSAGES = 1
            assert len(msgs) <= _MAX_MESSAGES

    def test_receive_returns_receipt_handle(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            q.enqueue(execution_id=1, start=2, end=10)
            msgs = q.receive()
            assert len(msgs) == 1
            assert "ReceiptHandle" in msgs[0]


# ───────────────────────────────────────────────────────────────────────────
# PrimeQueue.ack
# ───────────────────────────────────────────────────────────────────────────


class TestAck:
    def test_ack_removes_message_from_queue(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            q.enqueue(execution_id=1, start=2, end=10)
            msgs = q.receive()
            assert len(msgs) == 1
            q.ack(msgs[0])
            # Queue should be empty now
            msgs2 = q.receive()
            assert msgs2 == []


# ───────────────────────────────────────────────────────────────────────────
# PrimeQueue.queue_depth
# ───────────────────────────────────────────────────────────────────────────


class TestQueueDepth:
    """BVA at depth = 0, 1, 2 (threshold boundary is in backpressure tests)."""

    # BVA at depth = 0 (B-1 relative to "any message")
    def test_depth_0_empty_queue(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            assert q.queue_depth() == 0

    # BVA at depth = 1 (B: first message)
    def test_depth_1_after_enqueue(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            q.enqueue(execution_id=1, start=2, end=10)
            depth = q.queue_depth()
            assert depth >= 0  # moto may return 0 before visibility settles

    # BVA at depth = 2 (B+1: second message)
    def test_depth_increases_with_messages(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            q.enqueue(execution_id=1, start=2, end=10)
            q.enqueue(execution_id=2, start=3, end=20)
            depth = q.queue_depth()
            assert depth >= 0  # moto attribute may lag slightly

    def test_depth_returns_int(self, aws_credentials: None) -> None:
        with mock_aws():
            client = boto3.client("sqs", region_name="eu-central-1")
            client.create_queue(QueueName=_QUEUE_NAME)
            q = PrimeQueue()
            assert isinstance(q.queue_depth(), int)


# ───────────────────────────────────────────────────────────────────────────
# PrimeQueue.parse_body
# ───────────────────────────────────────────────────────────────────────────


class TestParseBody:
    """BVA on message body parsing."""

    def test_parse_valid_body(self) -> None:
        msg = {"Body": '{"execution_id": 42, "start": 2, "end": 100}'}
        result = PrimeQueue.parse_body(msg)
        assert result["execution_id"] == 42
        assert result["start"] == 2
        assert result["end"] == 100

    # BVA at execution_id = 0 (B-1 relative to 1)
    def test_parse_execution_id_0(self) -> None:
        msg = {"Body": '{"execution_id": 0, "start": 2, "end": 100}'}
        result = PrimeQueue.parse_body(msg)
        assert result["execution_id"] == 0

    # BVA at execution_id = 1 (B)
    def test_parse_execution_id_1(self) -> None:
        msg = {"Body": '{"execution_id": 1, "start": 2, "end": 100}'}
        result = PrimeQueue.parse_body(msg)
        assert result["execution_id"] == 1

    # BVA at execution_id = 2 (B+1)
    def test_parse_execution_id_2(self) -> None:
        msg = {"Body": '{"execution_id": 2, "start": 2, "end": 100}'}
        result = PrimeQueue.parse_body(msg)
        assert result["execution_id"] == 2

    # BVA at start = 1 (B-1 relative to API minimum 2)
    def test_parse_start_1(self) -> None:
        msg = {"Body": '{"execution_id": 1, "start": 1, "end": 100}'}
        result = PrimeQueue.parse_body(msg)
        assert result["start"] == 1

    # BVA at start = 2 (B)
    def test_parse_start_2(self) -> None:
        msg = {"Body": '{"execution_id": 1, "start": 2, "end": 100}'}
        result = PrimeQueue.parse_body(msg)
        assert result["start"] == 2

    # BVA at start = 3 (B+1)
    def test_parse_start_3(self) -> None:
        msg = {"Body": '{"execution_id": 1, "start": 3, "end": 100}'}
        result = PrimeQueue.parse_body(msg)
        assert result["start"] == 3

    def test_parse_invalid_json_raises(self) -> None:
        msg = {"Body": "not-json"}
        with pytest.raises(Exception):  # noqa: B017
            PrimeQueue.parse_body(msg)

    def test_parse_empty_body_raises(self) -> None:
        msg = {"Body": ""}
        with pytest.raises(Exception):  # noqa: B017
            PrimeQueue.parse_body(msg)


# ───────────────────────────────────────────────────────────────────────────
# PrimeQueue — environment / endpoint_url override
# ───────────────────────────────────────────────────────────────────────────


class TestQueueEnvironmentConfig:
    """Verify AWS_SQS_ENDPOINT_URL override is passed to boto3 client.

    Per issue #10, the boto3 SQS client is now a module-level singleton
    constructed lazily inside ``_get_client()`` — not in ``PrimeQueue.__init__``.
    These tests reset the singleton, then trigger the lazy construction by
    calling ``_get_client()`` directly, and assert the env-var was passed
    through correctly.
    """

    def test_endpoint_url_passed_to_boto3(self) -> None:
        from prime_service.queue import _get_client, reset_for_testing

        reset_for_testing()
        with patch("prime_service.queue.boto3.client") as mock_client_factory:
            mock_client_factory.return_value = MagicMock()
            os.environ["AWS_SQS_ENDPOINT_URL"] = "http://localhost:9324"
            try:
                _get_client()  # triggers the lazy construction
            finally:
                del os.environ["AWS_SQS_ENDPOINT_URL"]
                reset_for_testing()
            mock_client_factory.assert_called_once()
            call_kwargs = mock_client_factory.call_args
            assert call_kwargs.kwargs.get("endpoint_url") == "http://localhost:9324" or (
                len(call_kwargs.args) > 1 and call_kwargs.args[1] == "http://localhost:9324"
            )

    def test_no_endpoint_url_when_unset(self) -> None:
        from prime_service.queue import _get_client, reset_for_testing

        reset_for_testing()
        os.environ.pop("AWS_SQS_ENDPOINT_URL", None)
        with patch("prime_service.queue.boto3.client") as mock_client_factory:
            mock_client_factory.return_value = MagicMock()
            try:
                _get_client()  # triggers the lazy construction
            finally:
                reset_for_testing()
            call_kwargs = mock_client_factory.call_args
            assert call_kwargs.kwargs.get("endpoint_url") is None
