"""SQS queue abstraction for the prime-computation job queue.

Design:
    - boto3 sync client (not aiobotocore) — the worker is a simple consumer
      loop, not an async event loop.
    - Queue name: `aegis-enclave-primes` (configurable via env).
    - `AWS_SQS_ENDPOINT_URL` overrides the endpoint for local dev (ElasticMQ).
    - Visibility timeout = 90s (1.5× the 60s compute budget) so the message
      re-delivers if the worker crashes mid-compute without explicit ack.

Message schema (JSON body):
    {"execution_id": <str UUID4>, "start": <int>, "end": <int>}

Singleton boto3 client + cached queue URL (per issue #10):
    The previous design constructed a new ``boto3.client("sqs", ...)`` plus a
    fresh ``get_queue_url`` call inside ``PrimeQueue.__init__`` / first use.
    Because every POST /primes went through ``backpressure_middleware`` AND
    the handler, each request paid that cost TWICE — boto3 client construction
    is a metadata-loading round trip that takes tens to hundreds of ms, easily
    breaching the <100 ms p99 POST SLO from ADR-0008. It also masked the
    real depth signal: by the time the depth query returned, the worker had
    already drained the queue, so backpressure 503s never fired during a
    burst.

    Fix: keep the boto3 client and queue URL as **module-level singletons**
    constructed lazily on first use. boto3 clients are documented as
    thread-unsafe; this application serializes all calls on the asyncio event
    loop (sync boto3 in async handlers blocks the loop — that's the prod
    posture per ADR-0029), so single-client sharing is safe. Tests that want
    to construct a fresh boto3 client (e.g. moto rebuild) call
    ``reset_for_testing()``.

Thread-safety:
    The SQS client returned by boto3 is NOT thread-safe. This module's
    consumers are the FastAPI app (async, single-thread serialized) and the
    worker (single-thread sync loop). Do not introduce a ThreadPoolExecutor
    that calls into PrimeQueue without giving each thread its own client.
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

# ─── Module-level singletons (lazy; per issue #10) ───────────────────────────
# These hold the one boto3 SQS client + the one cached queue URL for the life
# of the process. Tests that need a fresh boto3 client (e.g. moto teardown +
# rebuild between cases) call ``reset_for_testing()`` to clear both.
_client: Any = None
_queue_url_cache: str | None = None


def _get_client() -> Any:
    """Return the process-wide boto3 SQS client, constructing it on first use."""
    global _client
    if _client is None:
        _client = boto3.client(
            "sqs",
            endpoint_url=os.environ.get("AWS_SQS_ENDPOINT_URL"),
            region_name=os.environ.get("AWS_DEFAULT_REGION", "eu-central-1"),
        )
    return _client


def _get_queue_url() -> str:
    """Return the cached queue URL, looking it up on first use."""
    global _queue_url_cache
    if _queue_url_cache is None:
        resp = _get_client().get_queue_url(QueueName=_QUEUE_NAME)
        _queue_url_cache = resp["QueueUrl"]
    return _queue_url_cache


def reset_for_testing() -> None:
    """Clear the module-level singletons.

    Required between tests that swap out the underlying boto3 client (e.g.
    moto rebuilds the mock SQS service in a new context, but the cached
    client still points at the previous context's resources). Production code
    must NOT call this — singletons are intentional.
    """
    global _client, _queue_url_cache
    _client = None
    _queue_url_cache = None


class PrimeQueue:
    """Thin façade around the SQS queue for prime-computation jobs.

    All state is module-level (see the singletons above) — constructing
    ``PrimeQueue()`` is a zero-cost no-op. The class form is preserved so
    callers and tests written against the previous design (which had
    per-instance state) keep working without churn.

    Usage (worker side):
        q = PrimeQueue()
        for msg in q.receive():
            process(msg)
            q.ack(msg)

    Usage (API side):
        q = PrimeQueue()
        q.enqueue(execution_id=42, start=2, end=10000)
    """

    def enqueue(self, *, execution_id: str, start: int, end: int) -> str:
        """Send a job message; returns the SQS MessageId."""
        body = json.dumps({"execution_id": execution_id, "start": start, "end": end})
        resp = _get_client().send_message(
            QueueUrl=_get_queue_url(),
            MessageBody=body,
        )
        return str(resp["MessageId"])

    def receive(self) -> list[dict[str, Any]]:
        """Long-poll for up to ``_MAX_MESSAGES`` messages.

        Returns a list of SQS message dicts (may be empty on timeout).
        Each dict has keys: MessageId, ReceiptHandle, Body, Attributes.
        """
        resp = _get_client().receive_message(
            QueueUrl=_get_queue_url(),
            MaxNumberOfMessages=_MAX_MESSAGES,
            WaitTimeSeconds=_WAIT_TIME_SECONDS,
            VisibilityTimeout=_VISIBILITY_TIMEOUT_S,
        )
        return resp.get("Messages", [])  # type: ignore[no-any-return]

    def ack(self, message: dict[str, Any]) -> None:
        """Delete a message from the queue (acknowledge successful processing)."""
        _get_client().delete_message(
            QueueUrl=_get_queue_url(),
            ReceiptHandle=message["ReceiptHandle"],
        )

    def queue_depth(self) -> int:
        """Approximate number of visible messages (for backpressure checks).

        Uses ``ApproximateNumberOfMessages`` attribute — may be slightly stale.
        Returns 0 if the attribute is unavailable (e.g. queue not yet created).
        """
        resp = _get_client().get_queue_attributes(
            QueueUrl=_get_queue_url(),
            AttributeNames=["ApproximateNumberOfMessages"],
        )
        attrs = resp.get("Attributes", {})
        return int(attrs.get("ApproximateNumberOfMessages", 0))

    @staticmethod
    def parse_body(message: dict[str, Any]) -> dict[str, Any]:
        """Parse JSON body from an SQS message dict."""
        return json.loads(message["Body"])  # type: ignore[no-any-return]
