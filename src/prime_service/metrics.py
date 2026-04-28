"""CloudWatch Embedded Metric Format (EMF) emission helper.

Emits structured JSON log entries that CloudWatch Logs auto-extracts into
metrics in the named namespace. No synchronous PutMetricData call;
overhead is bounded by JSON serialisation cost (~5-10ms per emit) and lands
in CloudWatch Metrics within ~30 seconds of the log line shipping.

Why EMF over PutMetricData:
    - PutMetricData is a synchronous network call (5-50ms latency); on the
      request hot path that dominates the API's own response latency.
    - EMF rides on the awslogs driver that already ships stdout/stderr;
      zero additional network round-trips.
    - EMF preserves contextvars (request_id, execution_id) on the same log
      line as the metric values — log query and metric query correlate
      naturally on those fields.

Format reference: AWS EMF spec
    https://docs.aws.amazon.com/AmazonCloudWatch/latest/monitoring/CloudWatch_Embedded_Metric_Format_Specification.html
"""

from __future__ import annotations

import time
from typing import Any

import structlog

# Single namespace per the design_doc § 3 service-name convention. All metric
# queries (CloudWatch Dashboards / CloudWatch Metrics Insights) filter by this.
_NAMESPACE = "aegis-enclave"

# EMF unit vocabulary (subset). CloudWatch accepts more, but these cover the
# SLI metrics specified in ADR-0041.
UNIT_COUNT = "Count"
UNIT_MS = "Milliseconds"
UNIT_BYTES = "Bytes"
UNIT_PERCENT = "Percent"

_log = structlog.get_logger()


def emit_metric(
    name: str,
    value: float,
    unit: str = UNIT_COUNT,
    **dimensions: Any,
) -> None:
    """Emit one metric via CloudWatch EMF.

    Args:
        name: Metric name. Convention: snake_case (`request_latency_ms`,
            `cache_hit_count`).
        value: Metric value. CloudWatch interprets as `StatisticSet` when
            the same name is emitted multiple times in the aggregation
            period (CloudWatch automatically computes count/sum/min/max
            and percentiles p50/p90/p95/p99 from the population).
        unit: One of UNIT_* constants. Defaults to Count.
        **dimensions: Optional dimension key-value pairs (e.g.,
            `path="/primes"`, `error_class="5xx"`). CloudWatch indexes
            metrics by dimensions; cardinality matters — keep dimension
            values bounded (no execution_id or request_id as dimensions).

    The structlog event 'metric_emit' wraps the EMF envelope; merge_contextvars
    (configured in main.py / worker.py) attaches request_id / execution_id
    so the log line is searchable both as a metric and as a structlog event.
    """
    dimension_set = list(dimensions.keys())
    payload: dict[str, Any] = {
        "_aws": {
            "Timestamp": int(time.time() * 1000),
            "CloudWatchMetrics": [
                {
                    "Namespace": _NAMESPACE,
                    "Dimensions": [dimension_set] if dimension_set else [[]],
                    "Metrics": [{"Name": name, "Unit": unit}],
                }
            ],
        },
        name: value,
    }
    payload.update(dimensions)
    _log.info("metric_emit", **payload)


def emit_count(name: str, **dimensions: Any) -> None:
    """Convenience: emit a Count metric with value 1 (event counter)."""
    emit_metric(name, 1, unit=UNIT_COUNT, **dimensions)


def emit_latency_ms(name: str, value_ms: float, **dimensions: Any) -> None:
    """Convenience: emit a Milliseconds latency metric."""
    emit_metric(name, value_ms, unit=UNIT_MS, **dimensions)
