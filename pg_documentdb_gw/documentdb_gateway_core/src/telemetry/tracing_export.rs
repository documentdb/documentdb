/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/tracing_export.rs
 *
 *-------------------------------------------------------------------------
 */

use std::time::Duration;

use opentelemetry_otlp::WithExportConfig;
use opentelemetry_sdk::{
    trace::{RandomIdGenerator, Sampler, SdkTracerProvider},
    Resource,
};
use serde::Deserialize;

use crate::{
    error::{DocumentDBError, Result},
    telemetry::config::{env_var, DEFAULT_EXPORT_TIMEOUT_MS, DEFAULT_OTLP_ENDPOINT},
};

// ============================================================================
// Constants
// ============================================================================

const DEFAULT_TRACES_ENABLED: bool = false;
const DEFAULT_SAMPLER_RATIO: f64 = 1.0;
const DEFAULT_SQL_COMMENTER_ENABLED: bool = false;

// ============================================================================
// JSON Configuration
// ============================================================================

/// JSON configuration for tracing (matches `SetupConfiguration.json` `TelemetryOptions.Tracing`).
///
/// Each field is optional so a partial JSON block falls back to env / defaults.
#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
pub struct TracingOptions {
    /// Whether trace export is enabled.
    pub enabled: Option<bool>,
    /// OTLP endpoint for trace export.
    pub otlp_endpoint: Option<String>,
    /// Head sampler ratio for `ParentBased(TraceIdRatioBased(ratio))` (clamped to `[0.0, 1.0]`).
    pub sampler_ratio: Option<f64>,
    /// Export timeout in milliseconds.
    pub export_timeout_ms: Option<u64>,
    /// Whether to attach a W3C `traceparent` `SQLCommenter` comment to sampled
    /// data-path queries so they can be correlated with Postgres logs.
    pub sql_commenter_enabled: Option<bool>,
}

// ============================================================================
// Runtime Configuration
// ============================================================================

/// Runtime configuration for trace export with OTLP.
///
/// Stores JSON configuration values and provides accessor methods that implement
/// the fallback logic: JSON value > environment variable > default constant.
#[derive(Debug, Clone)]
pub struct TracingConfig {
    enabled: Option<bool>,
    otlp_endpoint: Option<String>,
    sampler_ratio: Option<f64>,
    export_timeout_ms: Option<u64>,
    sql_commenter_enabled: Option<bool>,
}

impl TracingConfig {
    /// Creates tracing config from optional JSON configuration.
    #[must_use]
    pub fn new(json_config: Option<&TracingOptions>) -> Self {
        let json = json_config.cloned().unwrap_or_default();

        Self {
            enabled: json.enabled,
            otlp_endpoint: json.otlp_endpoint,
            sampler_ratio: json.sampler_ratio,
            export_timeout_ms: json.export_timeout_ms,
            sql_commenter_enabled: json.sql_commenter_enabled,
        }
    }

    /// Whether trace export is enabled. Fallback: JSON > `OTEL_TRACES_ENABLED` > false.
    #[must_use]
    pub fn traces_enabled(&self) -> bool {
        self.enabled
            .or_else(|| env_var("OTEL_TRACES_ENABLED"))
            .unwrap_or(DEFAULT_TRACES_ENABLED)
    }

    /// OTLP endpoint for traces. Fallback: JSON > `OTEL_EXPORTER_OTLP_TRACES_ENDPOINT` > `OTEL_EXPORTER_OTLP_ENDPOINT` > default.
    ///
    /// Empty env values are treated as unset so operators can `export VAR=""` to fall through
    /// to the next precedence level.
    #[must_use]
    pub fn otlp_endpoint(&self) -> String {
        self.otlp_endpoint
            .clone()
            .filter(|s| !s.is_empty())
            .or_else(|| {
                env_var::<String>("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT").filter(|s| !s.is_empty())
            })
            .or_else(|| env_var::<String>("OTEL_EXPORTER_OTLP_ENDPOINT").filter(|s| !s.is_empty()))
            .unwrap_or_else(|| DEFAULT_OTLP_ENDPOINT.to_owned())
    }

    /// Head sampler ratio for `ParentBased(TraceIdRatioBased(ratio))`.
    ///
    /// Fallback: JSON > `OTEL_TRACES_SAMPLER_ARG` > 1.0. Clamped to `[0.0, 1.0]`; out-of-range
    /// values produce a warning log and fall back to the nearest valid value.
    ///
    /// Note: `OTEL_TRACES_SAMPLER` itself is intentionally ignored in v1 — the sampler is
    /// always `ParentBased(TraceIdRatioBased(_))` and only the ratio is configurable.
    #[must_use]
    pub fn sampler_ratio(&self) -> f64 {
        let raw = self
            .sampler_ratio
            .or_else(|| env_var("OTEL_TRACES_SAMPLER_ARG"))
            .unwrap_or(DEFAULT_SAMPLER_RATIO);

        let raw = if raw.is_finite() {
            raw
        } else {
            tracing::warn!(
                "OTel tracing sampler ratio {raw} is non-finite; falling back to {DEFAULT_SAMPLER_RATIO}."
            );
            DEFAULT_SAMPLER_RATIO
        };

        let clamped = raw.clamp(0.0, 1.0);
        if (raw - clamped).abs() > f64::EPSILON {
            tracing::warn!(
                "OTel tracing sampler ratio {raw} is outside [0.0, 1.0]; clamped to {clamped}."
            );
        }
        clamped
    }

    /// Export timeout in ms. Fallback: JSON > `OTEL_EXPORTER_OTLP_TRACES_TIMEOUT` > `OTEL_EXPORTER_OTLP_TIMEOUT` > 10000.
    #[must_use]
    pub fn export_timeout_ms(&self) -> u64 {
        self.export_timeout_ms
            .or_else(|| env_var("OTEL_EXPORTER_OTLP_TRACES_TIMEOUT"))
            .or_else(|| env_var("OTEL_EXPORTER_OTLP_TIMEOUT"))
            .unwrap_or(DEFAULT_EXPORT_TIMEOUT_MS)
    }

    /// Whether `SQLCommenter` trace correlation is enabled for data-path queries.
    ///
    /// When enabled, sampled queries get a trailing W3C `traceparent` comment so
    /// they can be matched to Postgres logs (e.g. `log_min_duration_statement`).
    /// Comment volume is governed by the trace sampler ratio, since a comment is
    /// only emitted for spans the sampler selected. Requires trace export to be
    /// enabled (an unsampled or absent span produces no comment).
    ///
    /// Cost: a commented query bypasses the prepared-statement cache and is
    /// re-parsed on every execution, so the bypass applies to the same fraction
    /// of queries as the sampler ratio. Because the ratio defaults to `1.0`
    /// (sample everything), keep `sampler_ratio` low in production when this is
    /// enabled so caching stays effective for the un-sampled majority; it is
    /// primarily a debugging aid for slow queries.
    ///
    /// Fallback: JSON > `DOCUMENTDB_SQL_COMMENTER_ENABLED` > false.
    #[must_use]
    pub fn sql_commenter_enabled(&self) -> bool {
        self.sql_commenter_enabled
            .or_else(|| env_var("DOCUMENTDB_SQL_COMMENTER_ENABLED"))
            .unwrap_or(DEFAULT_SQL_COMMENTER_ENABLED)
    }

    /// Creates an OTLP export configuration for traces.
    #[must_use]
    pub fn create_export_config(&self) -> opentelemetry_otlp::ExportConfig {
        opentelemetry_otlp::ExportConfig {
            endpoint: Some(self.otlp_endpoint()),
            protocol: opentelemetry_otlp::Protocol::Grpc,
            timeout: Some(Duration::from_millis(self.export_timeout_ms())),
        }
    }
}

// ============================================================================
// Provider Creation
// ============================================================================

/// Creates an OpenTelemetry tracer provider with batched OTLP export.
///
/// Returns `None` if traces are disabled in config. The returned provider uses
/// `ParentBased(TraceIdRatioBased(ratio))` for head sampling so child spans inherit
/// the root sampling decision and ratio sampling applies only at trace start.
///
/// # Errors
///
/// Returns an error if the OTLP span exporter fails to build (e.g., invalid endpoint
/// configuration).
pub fn create_tracer_provider(
    config: &TracingConfig,
    resource: Resource,
) -> Result<Option<SdkTracerProvider>> {
    if !config.traces_enabled() {
        return Ok(None);
    }

    let exporter = opentelemetry_otlp::SpanExporter::builder()
        .with_tonic()
        .with_export_config(config.create_export_config())
        .build()
        .map_err(|e| {
            DocumentDBError::internal_error(format!("Failed to build span exporter: {e}"))
        })?;

    let sampler =
        Sampler::ParentBased(Box::new(Sampler::TraceIdRatioBased(config.sampler_ratio())));

    let provider = SdkTracerProvider::builder()
        .with_sampler(sampler)
        .with_id_generator(RandomIdGenerator::default())
        .with_resource(resource)
        .with_batch_exporter(exporter)
        .build();

    Ok(Some(provider))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::testing::EnvGuard;

    #[test]
    fn tracing_config_disabled_by_default() {
        let _guard = EnvGuard::remove("OTEL_TRACES_ENABLED");
        let config = TracingConfig::new(None);
        assert!(!config.traces_enabled());
    }

    #[test]
    fn tracing_config_uses_env_var_for_enabled() {
        let _guard = EnvGuard::set("OTEL_TRACES_ENABLED", "true");
        let config = TracingConfig::new(None);
        assert!(config.traces_enabled());
    }

    #[test]
    fn tracing_config_json_overrides_env_for_enabled() {
        let _guard = EnvGuard::set("OTEL_TRACES_ENABLED", "true");
        let json = TracingOptions {
            enabled: Some(false),
            ..Default::default()
        };
        let config = TracingConfig::new(Some(&json));
        assert!(!config.traces_enabled());
    }

    #[test]
    fn tracing_config_uses_specific_env_var_for_endpoint() {
        let _guard = EnvGuard::set("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://traces:4317");
        let config = TracingConfig::new(None);
        assert_eq!(config.otlp_endpoint(), "http://traces:4317");
    }

    #[test]
    fn tracing_config_endpoint_falls_back_to_generic_when_specific_is_empty() {
        let _guard = EnvGuard::set_many([
            ("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", ""),
            ("OTEL_EXPORTER_OTLP_ENDPOINT", "http://generic:4317"),
        ]);
        // Empty env vars are treated as unset, so the fallback chain advances.
        let config = TracingConfig::new(None);
        assert_eq!(config.otlp_endpoint(), "http://generic:4317");
    }

    #[test]
    fn tracing_config_uses_default_endpoint_when_all_empty_or_unset() {
        let _guard = EnvGuard::set_many([
            ("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", ""),
            ("OTEL_EXPORTER_OTLP_ENDPOINT", ""),
        ]);
        let config = TracingConfig::new(None);
        assert_eq!(config.otlp_endpoint(), DEFAULT_OTLP_ENDPOINT);
    }

    #[test]
    fn tracing_config_json_overrides_env_for_endpoint() {
        let _guard = EnvGuard::set("OTEL_EXPORTER_OTLP_TRACES_ENDPOINT", "http://env:4317");
        let json = TracingOptions {
            otlp_endpoint: Some("http://json:4317".to_owned()),
            ..Default::default()
        };
        let config = TracingConfig::new(Some(&json));
        assert_eq!(config.otlp_endpoint(), "http://json:4317");
    }

    #[test]
    fn tracing_config_sampler_ratio_default_is_one() {
        let _guard = EnvGuard::remove("OTEL_TRACES_SAMPLER_ARG");
        let config = TracingConfig::new(None);
        assert!((config.sampler_ratio() - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn tracing_config_sampler_ratio_clamps_high_values() {
        let _guard = EnvGuard::remove("OTEL_TRACES_SAMPLER_ARG");
        let json = TracingOptions {
            sampler_ratio: Some(2.5),
            ..Default::default()
        };
        let config = TracingConfig::new(Some(&json));
        assert!((config.sampler_ratio() - 1.0).abs() < f64::EPSILON);
    }

    #[test]
    fn tracing_config_sampler_ratio_clamps_negative_values() {
        let _guard = EnvGuard::remove("OTEL_TRACES_SAMPLER_ARG");
        let json = TracingOptions {
            sampler_ratio: Some(-0.5),
            ..Default::default()
        };
        let config = TracingConfig::new(Some(&json));
        assert!(config.sampler_ratio().abs() < f64::EPSILON);
    }

    #[test]
    fn tracing_config_sampler_ratio_uses_env_when_json_missing() {
        let _guard = EnvGuard::set("OTEL_TRACES_SAMPLER_ARG", "0.25");
        let config = TracingConfig::new(None);
        assert!((config.sampler_ratio() - 0.25).abs() < f64::EPSILON);
    }

    #[test]
    fn tracing_config_sampler_ratio_falls_back_for_non_finite_env_value() {
        let _guard = EnvGuard::set("OTEL_TRACES_SAMPLER_ARG", "NaN");
        let config = TracingConfig::new(None);
        assert!((config.sampler_ratio() - DEFAULT_SAMPLER_RATIO).abs() < f64::EPSILON);
    }

    #[test]
    fn tracing_config_export_timeout_default() {
        let _guard = EnvGuard::remove("OTEL_EXPORTER_OTLP_TRACES_TIMEOUT");
        let config = TracingConfig::new(None);
        assert_eq!(config.export_timeout_ms(), DEFAULT_EXPORT_TIMEOUT_MS);
    }

    #[test]
    fn tracing_config_export_timeout_uses_signal_specific_env() {
        let _guard = EnvGuard::set("OTEL_EXPORTER_OTLP_TRACES_TIMEOUT", "5000");
        let config = TracingConfig::new(None);
        assert_eq!(config.export_timeout_ms(), 5000);
    }

    #[test]
    fn tracing_config_sql_commenter_disabled_by_default() {
        let _guard = EnvGuard::remove("DOCUMENTDB_SQL_COMMENTER_ENABLED");
        let config = TracingConfig::new(None);
        assert!(!config.sql_commenter_enabled());
    }

    #[test]
    fn tracing_config_sql_commenter_uses_env_var() {
        let _guard = EnvGuard::set("DOCUMENTDB_SQL_COMMENTER_ENABLED", "true");
        let config = TracingConfig::new(None);
        assert!(config.sql_commenter_enabled());
    }

    #[test]
    fn tracing_config_sql_commenter_json_overrides_env() {
        let _guard = EnvGuard::set("DOCUMENTDB_SQL_COMMENTER_ENABLED", "false");
        let json = TracingOptions {
            sql_commenter_enabled: Some(true),
            ..Default::default()
        };
        let config = TracingConfig::new(Some(&json));
        assert!(config.sql_commenter_enabled());
    }

    #[test]
    fn create_tracer_provider_returns_none_when_disabled() {
        let _guard = EnvGuard::remove("OTEL_TRACES_ENABLED");
        let config = TracingConfig::new(Some(&TracingOptions {
            enabled: Some(false),
            ..Default::default()
        }));
        let resource = Resource::builder().build();

        let result = create_tracer_provider(&config, resource);
        assert!(result.is_ok());
        assert!(result.unwrap().is_none());
    }

    #[tokio::test]
    async fn create_tracer_provider_returns_some_when_enabled() {
        let config = TracingConfig::new(Some(&TracingOptions {
            enabled: Some(true),
            ..Default::default()
        }));
        let resource = Resource::builder().build();

        let result = create_tracer_provider(&config, resource);
        assert!(result.is_ok());
        let provider = result.unwrap();
        assert!(provider.is_some());

        // Cleanly shut down to release the batch processor's background thread.
        if let Some(provider) = provider {
            let _ = provider.shutdown();
        }
    }
}
