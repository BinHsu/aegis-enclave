"""Shared pytest fixtures for the prime_service test suite.

The autouse fixtures here stub out the **S3 result store** introduced by
ADR-0048 + issue #14 so that the bulk of the suite (worker, main HTTP)
does not have to know S3 exists. Tests that want to *exercise* S3
behaviour (replication-lag 503, lifecycle-expiry 410, write-failure
mark_failed) opt in by patching `s3_store.put_primes` / `s3_store.get_primes`
themselves within the test body.

The fixture intentionally lives in `tests/conftest.py` rather than a
per-module fixture: every handler that mark_done's a job goes through
`s3_store.put_primes`, and the GET handler reads through `s3_store.get_primes`.
Without a global stub each test would need to patch both — repetitive +
easy to forget, with a confusing real-boto3 failure on first miss.
"""

from __future__ import annotations

from collections.abc import Iterator
from unittest.mock import patch

import pytest


@pytest.fixture(autouse=True)
def _stub_s3_store() -> Iterator[None]:
    """Mock `s3_store.put_primes` + `s3_store.get_primes` for every test.

    Default behaviour:
        put_primes(execution_id, primes) -> returns a deterministic key
            ``"done/{execution_id}.json.gz"`` so the DDB row's `s3_key`
            attribute gets a non-empty string.
        get_primes(s3_key) -> returns an empty list. Tests that need the
            real list back should patch `s3_store.get_primes` themselves
            (the patch from this fixture is shadowable per-test).

    This stub does NOT cover `s3_store._get_client()` etc. — those are
    only reached when put/get themselves are NOT patched. By patching the
    public functions we avoid touching boto3 / botocore at all in tests.
    """
    with (
        patch(
            "prime_service.s3_store.put_primes",
            side_effect=lambda execution_id, primes: f"done/{execution_id}.json.gz",
        ),
        patch(
            "prime_service.s3_store.get_primes",
            return_value=[],
        ),
    ):
        yield
