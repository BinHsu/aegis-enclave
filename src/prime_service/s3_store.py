"""S3-backed primes-list store — large-result decoupling per ADR-0048.

The DynamoDB executions row holds metadata + an `s3_key` pointer (NOT a
full `s3://bucket/key` URI). The actual primes list lives in a regional
S3 bucket; cross-region replication (CRR) keeps an identical copy in
each region's local bucket. At read time the GET handler resolves
`bucket = f"{prefix}-{AWS_REGION}"` at runtime — so a client polling
from any region reads its own local replica.

This module owns the S3 client (lazy singleton, mirroring `queue.py`'s
fix from issue #10) and the key-naming convention.

Env contract:
    AWS_REGION                 — current task region (set by ECS / docker-compose).
                                 Falls back to AWS_DEFAULT_REGION; final
                                 fallback "eu-central-1".
    AWS_ENDPOINT_URL_S3        — boto3 per-service endpoint override (used by
                                 docker-compose's `minio` service for local
                                 parity; unset in cloud).
    S3_RESULTS_BUCKET_PREFIX   — bucket-name prefix; defaults to
                                 "aegis-enclave-results". Final bucket name is
                                 "${prefix}-${region}".

See ADR-0048 § 2-§ 4 for the full design and § 5 for the GET handler
replication-lag handling that *uses* this module's NoSuchKey exception.
"""

from __future__ import annotations

import gzip
import json
import os
from typing import Any

import boto3

# Lifecycle TTL — matches the DDB TTL for `done` rows (30 days, per db.py).
# The GET handler uses this to distinguish replication lag (transient → 503)
# from lifecycle-expired (genuine loss → 410): if the row's completed_at is
# older than this and the S3 object is missing, it has been removed by the
# S3 lifecycle policy, not by an in-flight replication race.
_LIFECYCLE_TTL_S = 30 * 86_400

_RESULT_BUCKET_PREFIX = "aegis-enclave-results"

# ─── Module-level singletons (per #10's pattern) ─────────────────────────────
_client: Any = None


def _get_region() -> str:
    return os.environ.get("AWS_REGION") or os.environ.get("AWS_DEFAULT_REGION", "eu-central-1")


def _get_bucket_prefix() -> str:
    return os.environ.get("S3_RESULTS_BUCKET_PREFIX", _RESULT_BUCKET_PREFIX)


def _bucket_for(region: str | None = None) -> str:
    """Return the bucket name for the given (or current) region.

    Key correctness point (ADR-0048 § 3): each region resolves its own
    bucket name from `AWS_REGION` at runtime. The bucket name is NOT
    stored in DynamoDB — only the key is — so CRR replicas serve local
    reads regardless of which region originally wrote the object.
    """
    return f"{_get_bucket_prefix()}-{region or _get_region()}"


def _get_client() -> Any:
    """Return the process-wide boto3 S3 client, constructing it on first use.

    Per issue #10's pattern: boto3 client construction is a metadata-load
    round trip that takes tens to hundreds of ms — a module-level singleton
    avoids paying that on every request.
    """
    global _client
    if _client is None:
        _client = boto3.client(
            "s3",
            endpoint_url=os.environ.get("AWS_ENDPOINT_URL_S3"),
            region_name=_get_region(),
        )
    return _client


def reset_for_testing() -> None:
    """Clear the module-level S3 client (call between tests that swap moto)."""
    global _client
    _client = None


# ─── Key-naming convention ───────────────────────────────────────────────────


def key_for(execution_id: str) -> str:
    """Return the bucket-relative S3 key for a given execution.

    Layout: `done/{execution_id}.json.gz`. The `done/` prefix is what the
    Terraform lifecycle policy targets (30-day expiration), matching the
    DDB `done`-status TTL.
    """
    return f"done/{execution_id}.json.gz"


# ─── Read / write ────────────────────────────────────────────────────────────


def put_primes(execution_id: str, primes: list[int]) -> str:
    """Gzip the primes list and write it to the local-region bucket.

    Returns the bucket-relative `s3_key` to store in the DDB row.
    Raises `botocore.exceptions.ClientError` on failure — the caller
    decides whether to mark_failed or propagate.
    """
    key = key_for(execution_id)
    body = gzip.compress(json.dumps(primes).encode("utf-8"))
    _get_client().put_object(
        Bucket=_bucket_for(),
        Key=key,
        Body=body,
        ContentEncoding="gzip",
        ContentType="application/json",
    )
    return key


def get_primes(s3_key: str) -> list[int]:
    """Read + decompress + parse the primes list from the local-region bucket.

    Raises `botocore.exceptions.ClientError` with `Error.Code == "NoSuchKey"`
    when the object is not (yet) replicated to this region OR has been
    lifecycle-expired. The GET handler uses `completed_at` age to
    distinguish the two cases (ADR-0048 § 5).
    """
    resp = _get_client().get_object(Bucket=_bucket_for(), Key=s3_key)
    raw = resp["Body"].read()
    decoded = gzip.decompress(raw).decode("utf-8")
    return json.loads(decoded)  # type: ignore[no-any-return]
