"""S3-backed primes-list store — large-result decoupling per ADR-0048.

The DynamoDB executions row holds metadata + an `s3_key` pointer (NOT a
full `s3://bucket/key` URI). The actual primes list lives in a regional
S3 bucket. Each region's bucket is independent — there is no cross-region
replication (ADR-0049 replaced bidirectional CRR with recompute-on-miss).
At read time the GET handler resolves `bucket = f"{prefix}-{AWS_REGION}"`
at runtime; if the object is absent in this region (the job was computed
elsewhere), the worker regenerates it locally from the DDB-replicated range.

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

See ADR-0048 § 2-§ 4 for the result-store design and ADR-0049 for the
GET handler recompute-on-miss path that *uses* this module's NoSuchKey
exception (a missing object triggers a local recompute, not a CRR wait).
"""

from __future__ import annotations

import gzip
import json
import os
from typing import Any

import boto3
from botocore.exceptions import ClientError

# S3 object lifecycle (30-day expiration on the done/ prefix) is enforced by
# the Terraform lifecycle policy, not by application code. Under ADR-0049 a
# missing object is regenerated on read (recompute-on-miss), so the GET
# handler no longer needs a Python-side TTL to distinguish lag from expiry.
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
    stored in DynamoDB — only the key is — so each region reads from its
    own bucket and regenerates a missing object via recompute-on-miss
    (ADR-0049) regardless of which region originally wrote it.
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


def exists(s3_key: str) -> bool:
    """Return True if the object is present in THIS region's bucket.

    Used by the worker (ADR-0049): a `done` row whose object is absent from
    this region's bucket is the cross-region recompute-on-miss case — the
    job was computed elsewhere, the DDB row replicated, but the S3 object did
    not (buckets are independent, no CRR). HEAD avoids pulling the payload.
    """
    try:
        _get_client().head_object(Bucket=_bucket_for(), Key=s3_key)
        return True
    except ClientError as exc:
        code = exc.response.get("Error", {}).get("Code", "")
        if code in ("404", "NoSuchKey", "NotFound"):
            return False
        raise


def get_primes(s3_key: str) -> list[int]:
    """Read + decompress + parse the primes list from the local-region bucket.

    Raises `botocore.exceptions.ClientError` with `Error.Code == "NoSuchKey"`
    when the object is absent in this region (computed elsewhere, no CRR) or
    lifecycle-expired. The GET handler treats both the same: re-enqueue a
    local recompute from the row's range and return 503 (ADR-0049).
    """
    resp = _get_client().get_object(Bucket=_bucket_for(), Key=s3_key)
    raw = resp["Body"].read()
    decoded = gzip.decompress(raw).decode("utf-8")
    return json.loads(decoded)  # type: ignore[no-any-return]
