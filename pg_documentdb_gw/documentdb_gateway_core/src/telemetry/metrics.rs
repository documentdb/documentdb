/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/telemetry/metrics.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{sync::LazyLock, time::Duration};

use either::Either;
use opentelemetry::{global, metrics::Counter, KeyValue};
use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::{
    metrics::{PeriodicReader, SdkMeterProvider, Temporality},
    Resource,
};
use serde::Deserialize;

use crate::{
    error::{DocumentDBError, Result},
    protocol::header::Header,
    requests::{request_tracker::RequestTracker, Request, RequestIntervalKind, RequestType},
    responses::{CommandError, Response},
    telemetry::config::{env_var, DEFAULT_EXPORT_TIMEOUT_MS, DEFAULT_OTLP_ENDPOINT},
};

// ============================================================================
// Constants
// ============================================================================

const DEFAULT_METRICS_ENABLED: bool = false;
const DEFAULT_COLLECTION_INTERVAL_MS: u64 = 15000;

// ============================================================================
// JSON Configuration
// ============================================================================

/// JSON configuration for metrics (matches SetupConfiguration.json TelemetryOptions.Metrics)
#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct MetricsOptions {
    /// Whether metrics are enabled
    pub enabled: Option<bool>,
    /// OTLP endpoint for metrics export
    pub otlp_endpoint: Option<String>,
    /// Export interval in milliseconds
    pub export_interval_ms: Option<u64>,
    /// Export timeout in milliseconds
    pub export_timeout_ms: Option<u64>,
}

// ============================================================================
// Runtime Configuration
// ============================================================================

/// Runtime configuration for metrics collection with OTLP export.
///
/// Stores JSON configuration values and provides accessor methods that implement
/// the fallback logic: JSON value > environment variable > default constant.
#[derive(Debug, Clone)]
pub struct MetricsConfig {
    enabled: Option<bool>,
    otlp_endpoint: Option<String>,
    export_interval_ms: Option<u64>,
    export_timeout_ms: Option<u64>,
}

impl MetricsConfig {
    /// Creates metrics config from optional JSON configuration.
    #[must_use]
    pub fn new(json_config: Option<&MetricsOptions>) -> Self {
        let json = json_config.cloned().unwrap_or_default();

        Self {
            enabled: json.enabled,
            otlp_endpoint: json.otlp_endpoint,
            export_interval_ms: json.export_interval_ms,
            export_timeout_ms: json.export_timeout_ms,
        }
    }

    /// Whether metrics are enabled. Fallback: JSON > `OTEL_METRICS_ENABLED` > false.
    #[must_use]
    pub fn metrics_enabled(&self) -> bool {
        self.enabled
            .or_else(|| env_var("OTEL_METRICS_ENABLED"))
            .unwrap_or(DEFAULT_METRICS_ENABLED)
    }

    /// OTLP endpoint for metrics. Fallback: JSON > `OTEL_EXPORTER_OTLP_METRICS_ENDPOINT` > `OTEL_EXPORTER_OTLP_ENDPOINT` > default.
    #[must_use]
    pub fn otlp_endpoint(&self) -> String {
        self.otlp_endpoint
            .clone()
            .or_else(|| env_var("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"))
            .or_else(|| env_var("OTEL_EXPORTER_OTLP_ENDPOINT"))
            .unwrap_or_else(|| DEFAULT_OTLP_ENDPOINT.to_owned())
    }

    /// Export interval in ms. Fallback: JSON > `OTEL_METRIC_EXPORT_INTERVAL` > 15000.
    #[must_use]
    pub fn export_interval_ms(&self) -> u64 {
        self.export_interval_ms
            .or_else(|| env_var("OTEL_METRIC_EXPORT_INTERVAL"))
            .unwrap_or(DEFAULT_COLLECTION_INTERVAL_MS)
    }

    /// Export timeout in ms. Fallback: JSON > `OTEL_EXPORTER_OTLP_METRICS_TIMEOUT` > `OTEL_EXPORTER_OTLP_TIMEOUT` > 10000.
    #[must_use]
    pub fn export_timeout_ms(&self) -> u64 {
        self.export_timeout_ms
            .or_else(|| env_var("OTEL_EXPORTER_OTLP_METRICS_TIMEOUT"))
            .or_else(|| env_var("OTEL_EXPORTER_OTLP_TIMEOUT"))
            .unwrap_or(DEFAULT_EXPORT_TIMEOUT_MS)
    }

    /// Creates an OTLP export configuration for metrics.
    #[must_use]
    pub fn create_export_config(&self) -> opentelemetry_otlp::ExportConfig {
        opentelemetry_otlp::ExportConfig {
            endpoint: Some(self.otlp_endpoint()),
            protocol: opentelemetry_otlp::Protocol::Grpc,
            timeout: Some(std::time::Duration::from_millis(self.export_timeout_ms())),
        }
    }
}

// ============================================================================
// Provider Creation
// ============================================================================

/// Creates an OpenTelemetry meter provider with periodic OTLP export.
///
/// Returns `None` if metrics are disabled in config.
///
/// # Errors
///
/// Returns an error if the OTLP metrics exporter fails to build.
pub fn create_metrics_provider(
    config: &MetricsConfig,
    resource: Resource,
) -> Result<Option<SdkMeterProvider>> {
    if !config.metrics_enabled() {
        return Ok(None);
    }

    // Delta temporality: counters emit deltas (change since last export).
    // The OTel Collector aggregates deltas into cumulative for Prometheus.
    let exporter = opentelemetry_otlp::MetricExporter::builder()
        .with_temporality(Temporality::Delta)
        .with_tonic()
        .with_export_config(config.create_export_config())
        .build()
        .map_err(|e| {
            DocumentDBError::internal_error(format!("Failed to build metrics exporter: {e}"))
        })?;

    let reader = PeriodicReader::builder(exporter)
        .with_interval(Duration::from_millis(config.export_interval_ms()))
        .build();

    let meter_provider = SdkMeterProvider::builder()
        .with_resource(resource)
        .with_reader(reader)
        .build();

    Ok(Some(meter_provider))
}

// ============================================================================
// Gateway Metrics (recorded directly in the request path)
// ============================================================================

/// Lazily-initialized `OTel` counters for gateway request metrics.
///
/// Uses `global::meter()` which returns a no-op meter if no `MeterProvider` is
/// registered, making these calls zero-cost when telemetry is disabled.
struct GatewayMetrics {
    operation_duration_total: Counter<f64>,
    operations_count: Counter<u64>,
    request_size_total: Counter<u64>,
    response_size_total: Counter<u64>,
    documents_returned: Counter<u64>,
    documents_inserted: Counter<u64>,
    documents_updated: Counter<u64>,
    documents_deleted: Counter<u64>,
}

static GATEWAY_METRICS: LazyLock<GatewayMetrics> = LazyLock::new(|| {
    let meter = global::meter("documentdb_gateway");

    GatewayMetrics {
        operation_duration_total: meter
            .f64_counter("db.client.operation.duration.total")
            .with_description("Total duration of database client operations (sum)")
            .with_unit("s")
            .build(),
        operations_count: meter
            .u64_counter("db.client.operations")
            .with_description("Count of database client operations")
            .with_unit("{operation}")
            .build(),
        request_size_total: meter
            .u64_counter("db.client.request.size.total")
            .with_description("Total size of database client request payloads")
            .with_unit("By")
            .build(),
        response_size_total: meter
            .u64_counter("db.client.response.size.total")
            .with_description("Total size of database client response payloads")
            .with_unit("By")
            .build(),
        documents_returned: meter
            .u64_counter("db.client.documents.returned")
            .with_description("Documents returned by read operations")
            .with_unit("{document}")
            .build(),
        documents_inserted: meter
            .u64_counter("db.client.documents.inserted")
            .with_description("Documents inserted")
            .with_unit("{document}")
            .build(),
        documents_updated: meter
            .u64_counter("db.client.documents.updated")
            .with_description("Documents updated")
            .with_unit("{document}")
            .build(),
        documents_deleted: meter
            .u64_counter("db.client.documents.deleted")
            .with_description("Documents deleted")
            .with_unit("{document}")
            .build(),
    }
});

/// Records request-level metrics directly in the request handling path.
///
/// See: <https://opentelemetry.io/docs/specs/semconv/database/database-metrics/>
///
/// Called unconditionally for every request. When no global `MeterProvider`
/// is registered, all counters are no-ops with negligible overhead.
///
/// Aggregation (averages, percentiles) is delegated to the collector.
pub fn record_gateway_metrics(
    header: &Header,
    request: Option<&Request<'_>>,
    response: Either<&Response, (&CommandError, usize)>,
    collection: &str,
    request_tracker: &RequestTracker,
) {
    let metrics = &*GATEWAY_METRICS;

    let operation = request.map_or_else(|| "unknown".to_owned(), |r| r.request_type().to_string());

    let db_name = request.and_then(|r| r.db().ok()).unwrap_or("unknown");

    let duration_to_secs = |ns: u64| -> f64 { Duration::from_nanos(ns).as_secs_f64() };

    let duration_ns = request_tracker.get_interval_elapsed_time(RequestIntervalKind::HandleRequest);

    let mut base_attrs: Vec<KeyValue> = vec![
        KeyValue::new("db.system.name", "documentdb"),
        KeyValue::new("db.operation.name", operation),
        KeyValue::new("db.collection.name", collection.to_owned()),
        KeyValue::new("db.namespace", db_name.to_owned()),
    ];
    if let Either::Right((err, _)) = &response {
        base_attrs.push(KeyValue::new("error.type", err.code().to_string()));
    }

    metrics.operations_count.add(1, &base_attrs);
    metrics
        .operation_duration_total
        .add(duration_to_secs(duration_ns), &base_attrs);

    metrics
        .request_size_total
        .add(u64::from(header.length.max(0).cast_unsigned()), &base_attrs);

    let response_size_bytes = match &response {
        Either::Left(resp) => resp
            .as_raw_document()
            .map(|doc| doc.as_bytes().len() as u64)
            .unwrap_or(0),
        Either::Right((_, size)) => *size as u64,
    };
    metrics
        .response_size_total
        .add(response_size_bytes, &base_attrs);

    // Record document throughput counters based on operation type
    if let Some(req) = request {
        if let Either::Left(resp) = &response {
            record_document_counts(metrics, req, resp, &base_attrs);
        }
    }

    // Record PostgreSQL phase breakdown (duration totals).
    let mut phase_attrs = Vec::with_capacity(base_attrs.len() + 1);

    let mut record_phase = |phase: &'static str, ns: u64| {
        if ns > 0 {
            phase_attrs.clear();
            phase_attrs.extend_from_slice(&base_attrs);
            phase_attrs.push(KeyValue::new("db.operation.phase", phase));
            metrics
                .operation_duration_total
                .add(duration_to_secs(ns), &phase_attrs);
        }
    };

    record_phase(
        "postgres_begin_transaction",
        request_tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresBeginTransaction),
    );
    record_phase(
        "postgres_execution",
        request_tracker.get_interval_elapsed_time(RequestIntervalKind::ProcessRequest),
    );
    record_phase(
        "postgres_commit",
        request_tracker.get_interval_elapsed_time(RequestIntervalKind::PostgresCommitTransaction),
    );
}

/// Extract document counts from the response based on operation type.
fn record_document_counts(
    metrics: &GatewayMetrics,
    request: &Request<'_>,
    response: &Response,
    attrs: &[KeyValue],
) {
    let Ok(doc) = response.as_raw_document() else {
        return;
    };

    match request.request_type() {
        RequestType::Find | RequestType::Aggregate | RequestType::GetMore => {
            // Cursor responses: { cursor: { firstBatch/nextBatch: [...] } }
            if let Ok(cursor) = doc.get_document("cursor") {
                let batch_len = cursor
                    .get_array("firstBatch")
                    .or_else(|_| cursor.get_array("nextBatch"))
                    .map(|arr| arr.into_iter().count() as u64)
                    .unwrap_or(0);
                if batch_len > 0 {
                    metrics.documents_returned.add(batch_len, attrs);
                }
            }
        }
        RequestType::Insert => {
            // Insert response: { n: <count> }
            if let Ok(n) = doc.get_i32("n") {
                metrics
                    .documents_inserted
                    .add(u64::from(n.max(0).cast_unsigned()), attrs);
            }
        }
        RequestType::Update | RequestType::FindAndModify => {
            // Update response: { nModified: <count> }
            if let Ok(n) = doc.get_i32("nModified") {
                metrics
                    .documents_updated
                    .add(u64::from(n.max(0).cast_unsigned()), attrs);
            }
        }
        RequestType::Delete => {
            // Delete response: { n: <count> }
            if let Ok(n) = doc.get_i32("n") {
                metrics
                    .documents_deleted
                    .add(u64::from(n.max(0).cast_unsigned()), attrs);
            }
        }
        _ => {}
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::EnvGuard;

    #[test]
    fn test_metrics_config_uses_env_var() {
        let _guard = EnvGuard::set("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "http://custom:4317");
        let config = MetricsConfig::new(None);
        assert!(!config.metrics_enabled());
        assert_eq!(config.otlp_endpoint(), "http://custom:4317");
    }

    #[test]
    fn test_metrics_config_json_overrides_env() {
        let _guard = EnvGuard::set("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT", "http://env:4317");

        // Test with JSON config - should override env var
        let json_config = MetricsOptions {
            enabled: Some(false),
            otlp_endpoint: Some("http://json:4317".to_owned()),
            export_interval_ms: Some(30000),
            ..Default::default()
        };
        let config = MetricsConfig::new(Some(&json_config));
        assert!(!config.metrics_enabled());
        assert_eq!(config.otlp_endpoint(), "http://json:4317");
        assert_eq!(config.export_interval_ms(), 30000);

        // Test with no JSON config - should use env var
        let config = MetricsConfig::new(None);
        assert_eq!(config.otlp_endpoint(), "http://env:4317");
    }

    #[test]
    fn test_create_metrics_provider_when_disabled() {
        let json_config = MetricsOptions {
            enabled: Some(false),
            ..Default::default()
        };
        let config = MetricsConfig::new(Some(&json_config));

        let attributes = vec![
            KeyValue::new("service.name", "test-service"),
            KeyValue::new("service.version", "1.0.0"),
        ];
        let resource = Resource::builder().with_attributes(attributes).build();

        let result = create_metrics_provider(&config, resource);
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
    }

    #[tokio::test]
    async fn test_create_metrics_provider_when_enabled() {
        let json_config = MetricsOptions {
            enabled: Some(true),
            ..Default::default()
        };
        let config = MetricsConfig::new(Some(&json_config));

        let attributes = vec![
            KeyValue::new("service.name", "metrics-service"),
            KeyValue::new("environment", "test"),
        ];
        let resource = Resource::builder().with_attributes(attributes).build();

        let result = create_metrics_provider(&config, resource);
        assert!(result.is_ok());
        assert!(result.unwrap().is_some());
    }

    #[test]
    fn test_gateway_metrics_callable_without_provider() {
        // Verify record_gateway_metrics is callable.
        // Without a registered MeterProvider, global::meter() returns a no-op meter,
        // so all counter .add() calls are harmless no-ops.
        // (We can't easily construct Header/Request/Response here, but we verify
        // the LazyLock initializes without panic.)
        let _metrics = &*super::GATEWAY_METRICS;
    }
}
