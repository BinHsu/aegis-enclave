"""SQS queue abstraction for the prime-computation job queue.

Design:
    - boto3 sync client (not aiobotocore) — the worker is a simple consumer
      loop, not an async event loop.
    - Queue name: `aegis-enclave-primes` (configurable via env).
    - `AWS_SQS_ENDPOINT_URL` overrides the endpoint for local dev (ElasticMQ).
    - Visibility timeout = 90s (1.5× the 60s compute budget) so the message
      re-delivers if the worker crashes mid-compute without explicit ack.

Message schema (JSON body):
    {"execution_id": <int>, "start": <int>, "end": <int>}

Thread-safety:
    The SQS client returned by boto3 is NOT thread-safe. The PrimeQueue class
    creates one client per instance; callers must not share an instance across
    threads. The worker creates one PrimeQueue per process.
"""

from __future__ import annotations

import json
import os
from typing import Any

import boto3

_QUEUE_NAME = "aegis-enclave-primes"
_VISIBILITY_TIMEOUT_S = 90
_WAIT_TIME_SECONDS = 20  # long-polling: up to 20 s per receive call
_MAX_MESSAGES = 1  # process one at a time for simplicity

# Message attribute name used to carry execution_id (also in body for clarity)
_EXEC_ID_ATTR = "execution_id"


class PrimeQueue:
    """Thin wrapper around the SQS queue for prime-computation jobs.

    Usage (worker side):
        q = PrimeQueue()
        for msg in q.receive():
            process(msg)
            q.ack(msg)

    Usage (API side):
        q = PrimeQueue()
        q.enqueue(execution_id=42, start=2, end=10000)
    """

    def __init__(self) -> None:
        endpoint_url = os.environ.get("AWS_SQS_ENDPOINT_URL")
        self._client: Any = boto3.client(
            "sqs",
            endpoint_url=endpoint_url,
            region_name=os.environ.get("AWS_DEFAULT_REGION", "eu-central-1"),
        )
        self._url: str | None = None

    def _queue_url(self) -> str:
        """Lazily resolve and cache the queue URL."""
        if self._url is None:
            resp = self._client.get_queue_url(QueueName=_QUEUE_NAME)
            self._url = resp["QueueUrl"]
        return self._url

    def enqueue(self, *, execution_id: int, start: int, end: int) -> str:
        """Send a job message; returns the SQS MessageId."""
        body = json.dumps({"execution_id": execution_id, "start": start, "end": end})
        resp = self._client.send_message(
            QueueUrl=self._queue_url(),
            MessageBody=body,
        )
        return str(resp["MessageId"])

    def receive(self) -> list[dict[str, Any]]:
        """Long-poll for up to `_MAX_MESSAGES` messages.

        Returns a list of SQS message dicts (may be empty on timeout).
        Each dict has keys: MessageId, ReceiptHandle, Body, Attributes.
        """
        resp = self._client.receive_message(
            QueueUrl=self._queue_url(),
            MaxNumberOfMessages=_MAX_MESSAGES,
            WaitTimeSeconds=_WAIT_TIME_SECONDS,
            VisibilityTimeout=_VISIBILITY_TIMEOUT_S,
        )
        return resp.get("Messages", [])  # type: ignore[no-any-return]

    def ack(self, message: dict[str, Any]) -> None:
        """Delete a message from the queue (acknowledge successful processing)."""
        self._client.delete_message(
            QueueUrl=self._queue_url(),
            ReceiptHandle=message["ReceiptHandle"],
        )

    def queue_depth(self) -> int:
        """Approximate number of visible messages (for backpressure checks).

        Uses `ApproximateNumberOfMessages` attribute — may be slightly stale.
        Returns 0 if the attribute is unavailable (e.g. queue not yet created).
        """
        resp = self._client.get_queue_attributes(
            QueueUrl=self._queue_url(),
            AttributeNames=["ApproximateNumberOfMessages"],
        )
        attrs = resp.get("Attributes", {})
        return int(attrs.get("ApproximateNumberOfMessages", 0))

    @staticmethod
    def parse_body(message: dict[str, Any]) -> dict[str, Any]:
        """Parse JSON body from an SQS message dict."""
        return json.loads(message["Body"])  # type: ignore[no-any-return]
