"""Tests for EMF metric emission (src/prime_service/metrics.py).

Covers the structural contract of the emitted log line — that CloudWatch
Logs will recognise it as EMF and extract the metric. The actual extraction
is AWS's responsibility; we test that the envelope conforms to spec.
"""

from __future__ import annotations

import json
from unittest.mock import patch

import pytest

from prime_service.metrics import (
    UNIT_COUNT,
    UNIT_MS,
    UNIT_PERCENT,
    emit_count,
    emit_latency_ms,
    emit_metric,
)


@pytest.fixture
def captured_logs():
    """Capture structlog emissions made by the metrics module.

    structlog.get_logger() returns a real BoundLogger configured at module
    import. We patch the module-level _log and capture .info() calls.
    """
    with patch("prime_service.metrics._log") as mock_log:
        yield mock_log


class TestEmitMetricStructure:
    """The EMF envelope conforms to the CloudWatch spec."""

    def test_emits_metric_emit_event(self, captured_logs):
        emit_metric("request_total", 1)
        captured_logs.info.assert_called_once()
        args, kwargs = captured_logs.info.call_args
        assert args[0] == "metric_emit"

    def test_envelope_has_aws_block(self, captured_logs):
        emit_metric("request_total", 1)
        _, kwargs = captured_logs.info.call_args
        assert "_aws" in kwargs
        assert "Timestamp" in kwargs["_aws"]
        assert "CloudWatchMetrics" in kwargs["_aws"]

    def test_namespace_is_aegis_enclave(self, captured_logs):
        emit_metric("request_total", 1)
        _, kwargs = captured_logs.info.call_args
        cwm = kwargs["_aws"]["CloudWatchMetrics"][0]
        assert cwm["Namespace"] == "aegis-enclave"

    def test_metric_name_and_unit_in_envelope(self, captured_logs):
        emit_metric("request_latency_ms", 42.5, unit=UNIT_MS)
        _, kwargs = captured_logs.info.call_args
        cwm = kwargs["_aws"]["CloudWatchMetrics"][0]
        assert cwm["Metrics"] == [{"Name": "request_latency_ms", "Unit": "Milliseconds"}]

    def test_metric_value_at_top_level(self, captured_logs):
        emit_metric("request_latency_ms", 42.5, unit=UNIT_MS)
        _, kwargs = captured_logs.info.call_args
        assert kwargs["request_latency_ms"] == 42.5

    def test_timestamp_is_milliseconds(self, captured_logs):
        emit_metric("x", 1)
        _, kwargs = captured_logs.info.call_args
        ts = kwargs["_aws"]["Timestamp"]
        # CloudWatch EMF expects ms-precision Unix epoch
        # Sanity: ms timestamp should be > 10^12 (roughly year 2001+)
        assert ts > 10**12
        assert isinstance(ts, int)


class TestDimensions:
    """Dimensions are emitted both in the envelope and at top level."""

    def test_no_dimensions_emits_empty_dimension_set(self, captured_logs):
        emit_metric("x", 1)
        _, kwargs = captured_logs.info.call_args
        cwm = kwargs["_aws"]["CloudWatchMetrics"][0]
        # Empty dimension set is "no breakdown, just one aggregate metric"
        assert cwm["Dimensions"] == [[]]

    def test_one_dimension_listed_in_envelope(self, captured_logs):
        emit_metric("request_total", 1, path="/primes")
        _, kwargs = captured_logs.info.call_args
        cwm = kwargs["_aws"]["CloudWatchMetrics"][0]
        assert cwm["Dimensions"] == [["path"]]

    def test_one_dimension_value_at_top_level(self, captured_logs):
        emit_metric("request_total", 1, path="/primes")
        _, kwargs = captured_logs.info.call_args
        assert kwargs["path"] == "/primes"

    def test_two_dimensions_listed_in_envelope(self, captured_logs):
        emit_metric("request_errors", 1, path="/primes", error_class="5xx")
        _, kwargs = captured_logs.info.call_args
        cwm = kwargs["_aws"]["CloudWatchMetrics"][0]
        assert set(cwm["Dimensions"][0]) == {"path", "error_class"}

    def test_dimension_values_at_top_level(self, captured_logs):
        emit_metric("request_errors", 1, path="/primes", error_class="5xx")
        _, kwargs = captured_logs.info.call_args
        assert kwargs["path"] == "/primes"
        assert kwargs["error_class"] == "5xx"


class TestConvenienceHelpers:
    """emit_count / emit_latency_ms are thin wrappers over emit_metric."""

    def test_emit_count_value_is_one(self, captured_logs):
        emit_count("cache_hit_count")
        _, kwargs = captured_logs.info.call_args
        assert kwargs["cache_hit_count"] == 1

    def test_emit_count_unit_is_count(self, captured_logs):
        emit_count("cache_hit_count")
        _, kwargs = captured_logs.info.call_args
        cwm = kwargs["_aws"]["CloudWatchMetrics"][0]
        assert cwm["Metrics"][0]["Unit"] == "Count"

    def test_emit_count_with_dimensions(self, captured_logs):
        emit_count("request_total", path="/primes")
        _, kwargs = captured_logs.info.call_args
        assert kwargs["request_total"] == 1
        assert kwargs["path"] == "/primes"

    def test_emit_latency_ms_unit(self, captured_logs):
        emit_latency_ms("request_latency_ms", 42.5)
        _, kwargs = captured_logs.info.call_args
        cwm = kwargs["_aws"]["CloudWatchMetrics"][0]
        assert cwm["Metrics"][0]["Unit"] == "Milliseconds"

    def test_emit_latency_ms_value(self, captured_logs):
        emit_latency_ms("request_latency_ms", 42.5)
        _, kwargs = captured_logs.info.call_args
        assert kwargs["request_latency_ms"] == 42.5


class TestUnitConstants:
    """Unit constants resolve to CloudWatch-acceptable strings."""

    @pytest.mark.parametrize(
        "constant,expected",
        [
            (UNIT_COUNT, "Count"),
            (UNIT_MS, "Milliseconds"),
            (UNIT_PERCENT, "Percent"),
        ],
    )
    def test_unit_string_value(self, constant, expected):
        assert constant == expected


class TestSerialisability:
    """The envelope must be JSON-serialisable (structlog will JSON-render it)."""

    def test_envelope_round_trips_through_json(self, captured_logs):
        emit_metric("request_latency_ms", 42.5, unit=UNIT_MS, path="/primes")
        _, kwargs = captured_logs.info.call_args
        # If structlog can render it, json.dumps can too
        rendered = json.dumps(kwargs)
        parsed = json.loads(rendered)
        assert parsed["_aws"]["CloudWatchMetrics"][0]["Namespace"] == "aegis-enclave"
        assert parsed["request_latency_ms"] == 42.5
        assert parsed["path"] == "/primes"


class TestBoundaryValueAnalysis:
    """BVA per CLAUDE.md § 8 — boundaries on value, on dimension count."""

    @pytest.mark.parametrize("value", [0, 0.0, 1, 1.0, 1_000_000.0])
    def test_value_serialises_at_zero_one_and_large(self, captured_logs, value):
        # B-1 (negative — covered separately below), B (zero), B+1 (one), large
        emit_metric("x", value)
        _, kwargs = captured_logs.info.call_args
        assert kwargs["x"] == value

    def test_value_negative_is_emitted_verbatim(self, captured_logs):
        # CloudWatch accepts negative values for some metrics (e.g. delta)
        # — emit faithfully and let the operator decide if it's meaningful
        emit_metric("delta", -5)
        _, kwargs = captured_logs.info.call_args
        assert kwargs["delta"] == -5

    def test_zero_dimensions_is_valid(self, captured_logs):
        # B-1 (zero dimensions — explicit empty set)
        emit_metric("x", 1)
        _, kwargs = captured_logs.info.call_args
        assert kwargs["_aws"]["CloudWatchMetrics"][0]["Dimensions"] == [[]]

    def test_one_dimension_is_valid(self, captured_logs):
        # B (one dimension)
        emit_metric("x", 1, k="v")
        _, kwargs = captured_logs.info.call_args
        cwm = kwargs["_aws"]["CloudWatchMetrics"][0]
        assert cwm["Dimensions"] == [["k"]]

    def test_three_dimensions_listed(self, captured_logs):
        # B+1+1 (three dimensions — past the typical "service+region" pair)
        emit_metric("x", 1, a="1", b="2", c="3")
        _, kwargs = captured_logs.info.call_args
        cwm = kwargs["_aws"]["CloudWatchMetrics"][0]
        assert set(cwm["Dimensions"][0]) == {"a", "b", "c"}
