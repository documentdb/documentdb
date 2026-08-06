/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_otel/src/config.rs
 *
 *-------------------------------------------------------------------------
 */

use std::env;

use documentdb_gateway_core::{
    error::{DocumentDBError, Result},
    telemetry::TelemetrySettings,
};
use serde::Deserialize;
use serde_json::Value;

use crate::consts::env_vars;

const DEFAULT_OTLP_ENDPOINT: &str = "http://localhost:4317";
const DEFAULT_EXPORT_TIMEOUT_MS: u64 = 10000;
const DEFAULT_COLLECTION_INTERVAL_MS: u64 = 15000;
const DEFAULT_SAMPLER_RATIO: f64 = 1.0;
const DEFAULT_SERVICE_NAME: &str = "documentdb_gateway";
const DEFAULT_SERVICE_VERSION: &str = env!("CARGO_PKG_VERSION");

fn env_var<T: std::str::FromStr>(var: &str) -> Option<T> {
    env::var(var).ok().and_then(|value| value.parse().ok())
}

#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
struct TelemetryOptions {
    service_name: Option<String>,
    service_version: Option<String>,
    metrics: Option<MetricsOptions>,
    tracing: Option<TracingOptions>,
}

#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
struct MetricsOptions {
    enabled: Option<bool>,
    otlp_endpoint: Option<String>,
    export_interval_ms: Option<u64>,
    export_timeout_ms: Option<u64>,
}

#[derive(Debug, Deserialize, Default, Clone)]
#[serde(rename_all = "PascalCase")]
struct TracingOptions {
    enabled: Option<bool>,
    otlp_endpoint: Option<String>,
    sampler_ratio: Option<f64>,
    export_timeout_ms: Option<u64>,
    #[cfg(feature = "postgres-sql-commenter")]
    sql_commenter_enabled: Option<bool>,
}

#[derive(Debug, Clone)]
pub struct TelemetryConfig {
    service_name: Option<String>,
    service_version: Option<String>,
    metrics: MetricsConfig,
    tracing: TracingConfig,
}

impl TelemetryConfig {
    pub(crate) fn new(options: Option<&Value>) -> Result<Self> {
        let options: TelemetryOptions = options
            .cloned()
            .map(serde_json::from_value)
            .transpose()
            .map_err(|error| {
                DocumentDBError::bad_value(format!("Invalid OpenTelemetry configuration: {error}"))
            })?
            .unwrap_or_default();

        Ok(Self {
            service_name: options.service_name,
            service_version: options.service_version,
            metrics: MetricsConfig::new(options.metrics.as_ref()),
            tracing: TracingConfig::new(options.tracing.as_ref()),
        })
    }

    pub(crate) fn service_name(&self) -> String {
        self.service_name
            .clone()
            .or_else(|| env_var(env_vars::OTEL_SERVICE_NAME))
            .unwrap_or_else(|| DEFAULT_SERVICE_NAME.to_owned())
    }

    pub(crate) fn service_version(&self) -> String {
        self.service_version
            .clone()
            .or_else(|| env_var(env_vars::OTEL_SERVICE_VERSION))
            .unwrap_or_else(|| DEFAULT_SERVICE_VERSION.to_owned())
    }

    pub(crate) const fn metrics(&self) -> &MetricsConfig {
        &self.metrics
    }

    pub(crate) const fn tracing(&self) -> &TracingConfig {
        &self.tracing
    }

    pub(crate) fn any_signal_enabled(&self) -> bool {
        self.metrics.enabled() || self.tracing.enabled()
    }

    pub(crate) fn settings(&self) -> TelemetrySettings {
        TelemetrySettings::new(self.metrics.enabled())
    }
}

#[derive(Debug, Clone)]
pub struct MetricsConfig {
    enabled: Option<bool>,
    otlp_endpoint: Option<String>,
    export_interval_ms: Option<u64>,
    export_timeout_ms: Option<u64>,
}

impl MetricsConfig {
    fn new(options: Option<&MetricsOptions>) -> Self {
        let options = options.cloned().unwrap_or_default();
        Self {
            enabled: options.enabled,
            otlp_endpoint: options.otlp_endpoint,
            export_interval_ms: options.export_interval_ms,
            export_timeout_ms: options.export_timeout_ms,
        }
    }

    pub(crate) fn enabled(&self) -> bool {
        self.enabled
            .or_else(|| env_var(env_vars::OTEL_METRICS_ENABLED))
            .unwrap_or(false)
    }

    pub(crate) fn otlp_endpoint(&self) -> String {
        self.otlp_endpoint
            .clone()
            .or_else(|| env_var(env_vars::OTEL_EXPORTER_OTLP_METRICS_ENDPOINT))
            .or_else(|| env_var(env_vars::OTEL_EXPORTER_OTLP_ENDPOINT))
            .unwrap_or_else(|| DEFAULT_OTLP_ENDPOINT.to_owned())
    }

    pub(crate) fn export_interval_ms(&self) -> u64 {
        self.export_interval_ms
            .or_else(|| env_var(env_vars::OTEL_METRIC_EXPORT_INTERVAL))
            .unwrap_or(DEFAULT_COLLECTION_INTERVAL_MS)
    }

    pub(crate) fn export_timeout_ms(&self) -> u64 {
        self.export_timeout_ms
            .or_else(|| env_var(env_vars::OTEL_EXPORTER_OTLP_METRICS_TIMEOUT))
            .or_else(|| env_var(env_vars::OTEL_EXPORTER_OTLP_TIMEOUT))
            .unwrap_or(DEFAULT_EXPORT_TIMEOUT_MS)
    }
}

#[derive(Debug, Clone)]
pub struct TracingConfig {
    enabled: Option<bool>,
    otlp_endpoint: Option<String>,
    sampler_ratio: Option<f64>,
    export_timeout_ms: Option<u64>,
    #[cfg(feature = "postgres-sql-commenter")]
    sql_commenter_enabled: Option<bool>,
}

impl TracingConfig {
    fn new(options: Option<&TracingOptions>) -> Self {
        let options = options.cloned().unwrap_or_default();
        Self {
            enabled: options.enabled,
            otlp_endpoint: options.otlp_endpoint,
            sampler_ratio: options.sampler_ratio,
            export_timeout_ms: options.export_timeout_ms,
            #[cfg(feature = "postgres-sql-commenter")]
            sql_commenter_enabled: options.sql_commenter_enabled,
        }
    }

    pub(crate) fn enabled(&self) -> bool {
        self.enabled
            .or_else(|| env_var(env_vars::OTEL_TRACES_ENABLED))
            .unwrap_or(false)
    }

    pub(crate) fn otlp_endpoint(&self) -> String {
        self.otlp_endpoint
            .clone()
            .filter(|value| !value.is_empty())
            .or_else(|| {
                env_var::<String>(env_vars::OTEL_EXPORTER_OTLP_TRACES_ENDPOINT)
                    .filter(|value| !value.is_empty())
            })
            .or_else(|| {
                env_var::<String>(env_vars::OTEL_EXPORTER_OTLP_ENDPOINT)
                    .filter(|value| !value.is_empty())
            })
            .unwrap_or_else(|| DEFAULT_OTLP_ENDPOINT.to_owned())
    }

    pub(crate) fn sampler_ratio(&self) -> f64 {
        let ratio = self
            .sampler_ratio
            .or_else(|| env_var(env_vars::OTEL_TRACES_SAMPLER_ARG))
            .unwrap_or(DEFAULT_SAMPLER_RATIO);
        let ratio = if ratio.is_finite() {
            ratio
        } else {
            tracing::warn!(
                "OpenTelemetry sampler ratio {ratio} is non-finite; falling back to {DEFAULT_SAMPLER_RATIO}."
            );
            DEFAULT_SAMPLER_RATIO
        };

        let clamped = ratio.clamp(0.0, 1.0);
        if (ratio - clamped).abs() > f64::EPSILON {
            tracing::warn!(
                "OpenTelemetry sampler ratio {ratio} is outside [0.0, 1.0]; clamped to {clamped}."
            );
        }
        clamped
    }

    pub(crate) fn export_timeout_ms(&self) -> u64 {
        self.export_timeout_ms
            .or_else(|| env_var(env_vars::OTEL_EXPORTER_OTLP_TRACES_TIMEOUT))
            .or_else(|| env_var(env_vars::OTEL_EXPORTER_OTLP_TIMEOUT))
            .unwrap_or(DEFAULT_EXPORT_TIMEOUT_MS)
    }

    #[cfg(feature = "postgres-sql-commenter")]
    pub(crate) fn sql_commenter_enabled(&self) -> bool {
        self.sql_commenter_enabled
            .or_else(|| env_var(env_vars::DOCUMENTDB_SQL_COMMENTER_ENABLED))
            .unwrap_or(false)
    }
}

pub fn resource_attributes() -> Vec<(String, String)> {
    env::var(env_vars::OTEL_RESOURCE_ATTRIBUTES)
        .unwrap_or_default()
        .split(',')
        .filter_map(|pair| {
            let (key, value) = pair.split_once('=')?;
            Some((key.trim().to_owned(), value.trim().to_owned()))
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use std::sync::{Mutex, MutexGuard};

    use serde_json::json;

    use super::*;

    static ENV_LOCK: Mutex<()> = Mutex::new(());

    struct EnvGuard {
        key: &'static str,
        original: Option<String>,
        _lock: MutexGuard<'static, ()>,
    }

    impl EnvGuard {
        fn set(key: &'static str, value: &str) -> Self {
            let lock = ENV_LOCK
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner);
            let original = env::var(key).ok();
            env::set_var(key, value);
            Self {
                key,
                original,
                _lock: lock,
            }
        }
    }

    impl Drop for EnvGuard {
        fn drop(&mut self) {
            if let Some(value) = &self.original {
                env::set_var(self.key, value);
            } else {
                env::remove_var(self.key);
            }
        }
    }

    #[test]
    fn json_overrides_environment() {
        let _guard = EnvGuard::set(env_vars::OTEL_SERVICE_NAME, "env-service");
        let options = json!({
            "ServiceName": "json-service",
            "Metrics": { "Enabled": true }
        });
        let config = TelemetryConfig::new(Some(&options)).expect("configuration should parse");
        assert_eq!(config.service_name(), "json-service");
        assert!(config.metrics().enabled());
    }

    #[test]
    fn environment_configures_metrics() {
        let _guard = EnvGuard::set(
            env_vars::OTEL_EXPORTER_OTLP_METRICS_ENDPOINT,
            "http://metrics:4317",
        );
        let config = TelemetryConfig::new(None).expect("default configuration should parse");
        assert_eq!(config.metrics().otlp_endpoint(), "http://metrics:4317");
    }

    #[test]
    fn settings_are_provider_neutral() {
        let options = json!({
            "Metrics": { "Enabled": true },
            "Tracing": { "Enabled": true, "SqlCommenterEnabled": true }
        });
        let config = TelemetryConfig::new(Some(&options)).expect("configuration should parse");
        let settings = config.settings();
        assert!(settings.request_metrics_enabled());
        #[cfg(feature = "postgres-sql-commenter")]
        assert!(config.tracing().sql_commenter_enabled());
    }

    #[test]
    fn invalid_configuration_is_rejected() {
        let options = json!({ "Metrics": "invalid" });
        TelemetryConfig::new(Some(&options)).expect_err("configuration should be rejected");
    }

    #[test]
    fn resource_attributes_are_parsed() {
        let _guard = EnvGuard::set(env_vars::OTEL_RESOURCE_ATTRIBUTES, "key1=val1,key2=val2");
        assert_eq!(
            resource_attributes(),
            vec![
                ("key1".to_owned(), "val1".to_owned()),
                ("key2".to_owned(), "val2".to_owned())
            ]
        );
    }
}
