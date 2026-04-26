# ADR-0030: ElasticMQ for local SQS API parity

## Status
Accepted (2026-04-26)

## Context

ADR-0029 introduces SQS as the queue between the API and worker. The smoke test must remain self-contained — a reviewer runs `docker compose up && ./smoke.sh` without any AWS credentials. The test must exercise the full path: POST → queue enqueue → worker dequeue → compute → audit write → GET returns `done`. This means the Docker Compose stack needs a local SQS-compatible server.

The worker and API use the `boto3` SQS client with `AWS_SQS_ENDPOINT_URL` overriding the endpoint (standard boto3 pattern for local SQS testing). The local server must implement:

- `CreateQueue` (on startup / first use)
- `SendMessage` (from API enqueue path)
- `ReceiveMessage` with visibility timeout (worker poll)
- `DeleteMessage` (worker ack after successful processing)
- `GetQueueAttributes` with `ApproximateNumberOfMessagesVisible` (backpressure middleware reads this)

## Decision

Use **ElasticMQ** (`softwaremill/elasticmq-native:1.6.x`) as the local SQS emulator in Docker Compose.

Configuration (`elasticmq.conf`) declares the `aegis-enclave-primes` queue with matching visibility timeout (90 s), so the queue exists before the API or worker starts — no runtime `CreateQueue` call is required.

The `boto3` client receives `endpoint_url=os.environ["AWS_SQS_ENDPOINT_URL"]` (set to `http://elasticmq:9324` in Docker Compose, absent in cloud) and uses dummy credentials (`AWS_ACCESS_KEY_ID=test`, `AWS_SECRET_ACCESS_KEY=test`) — ElasticMQ accepts any non-empty credentials. The `queue.py` abstraction layer handles the endpoint-url injection so neither `main.py` nor `worker.py` needs to be aware of the local-vs-cloud distinction.

The `softwaremill/elasticmq-native` image is used (native binary, not JVM) to avoid a ~400 MB JVM overhead in the compose stack.

## Alternatives Considered

| Candidate | Why not |
|---|---|
| **LocalStack** | Full AWS emulation suite (100+ services). Significantly heavier than ElasticMQ for a single-queue use case: the free-tier image is ~600–900 MB and the startup time adds ~10–15 s to `docker compose up`. The pro-tier required for some SQS features (e.g., exact DLQ semantics) is paid. ElasticMQ is purpose-built for SQS; the fit is more direct and the image is ~30 MB. |
| **Postgres-as-queue** (SKIP LOCKED / `pg_notify`) | Eliminates the extra container. `SKIP LOCKED` provides adequate queue semantics for single-consumer use. But: (1) production uses SQS; a Postgres queue locally means two different code paths (SQS client vs. Postgres query) unless wrapped in an abstraction, adding test-coverage complexity; (2) the backpressure middleware reads `ApproximateNumberOfMessagesVisible` — a Postgres queue doesn't expose that attribute, requiring a separate `SELECT COUNT(*)` query and a custom attribute mapping; (3) a production-facing SQS abstraction that degrades to Postgres in tests has a larger semantic gap than boto3 with an endpoint override. |
| **In-memory mock (`unittest.mock`)** | Appropriate for unit tests of the queue abstraction itself (`tests/test_queue.py`). Not appropriate for the smoke test: the smoke test exercises the full compose stack end-to-end. An in-memory mock doesn't exercise the actual `boto3` SQS client code path, Docker networking between the worker and queue, or message visibility/redelivery semantics. |

## Consequences

- Smoke test exercises the full `boto3` → SQS → worker path without AWS credentials.
- `elasticmq.conf` is committed (no secrets — it's a queue configuration file with dummy queue names).
- Adding `softwaremill/elasticmq-native:1.6.x` to `docker compose up` adds ~30 MB to the compose stack. Pull-on-first-run is ~3–5 s on a typical connection.
- The `queue.py` abstraction's `endpoint_url` injection is testable in isolation via unit tests with `unittest.mock` — the ElasticMQ container is only needed for the smoke test.
- Version pinned to `1.6.x` (minor-version float, patch-version free). Breaking changes between minor versions are infrequent for a stable emulator; the pin avoids a silent upgrade to a breaking major version while still allowing security patches.

## Related ADRs
- ADR-0029 (async POST + SQS + worker pool — this ADR provides the local SQS emulator for it)
- ADR-0003 (PoC scope, prod hygiene — smoke-test self-contained requirement)
- ADR-0014 (Mermaid smoke-test acceptance — the smoke test this ADR enables to stay self-contained)
