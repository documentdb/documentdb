/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/telemetry/telemetry_manager.rs
 *
 *-------------------------------------------------------------------------
 */

use std::collections::HashMap;

use opentelemetry::{global, KeyValue};
use opentelemetry_sdk::{
    metrics::SdkMeterProvider, propagation::TraceContextPropagator, trace::SdkTracerProvider,
    Resource,
};

use crate::{
    error::{DocumentDBError, Result},
    telemetry::{
        config::{parse_resource_attributes, TelemetryConfig},
        metrics::create_metrics_provider,
        tracing_export::create_tracer_provider,
    },
};

/// Manages OpenTelemetry providers for telemetry signals.
///
/// Owns the SDK providers for metrics and traces; logs export over OTLP is a planned
/// follow-up. Returned from [`TelemetryManager::init_telemetry`] for the lifetime of
/// the gateway and shut down on graceful exit so batched data is flushed.
#[derive(Debug)]
pub struct TelemetryManager {
    meter_provider: Option<SdkMeterProvider>,
    tracer_provider: Option<SdkTracerProvider>,
}

impl TelemetryManager {
    /// # Errors
    ///
    /// Returns an error if telemetry attributes contain reserved keys (`service.name` or `service.version`),
    /// or if any OTLP exporter (metrics or traces) fails to initialize.
    pub fn init_telemetry(
        config: &TelemetryConfig,
        attributes: Option<HashMap<String, String>>,
    ) -> Result<Self> {
        if let Some(ref attrs) = attributes {
            if attrs.contains_key("service.name") {
                return Err(DocumentDBError::bad_value(
                    "Telemetry attributes should not include 'service.name' as it is set automatically from the TelemetryConfig".to_owned(),
                ));
            }

            if attrs.contains_key("service.version") {
                return Err(DocumentDBError::bad_value(
                    "Telemetry attributes should not include 'service.version' as it is set automatically from the TelemetryConfig".to_owned(),
                ));
            }
        }

        // Resource attribute precedence (later entries win on duplicate keys via
        // Resource::builder semantics): OTEL_RESOURCE_ATTRIBUTES env -> caller-provided
        // attributes -> service.name / service.version (always last so they cannot be
        // overridden through either mechanism).
        let env_attributes = parse_resource_attributes();
        let caller_attributes = attributes
            .unwrap_or_default()
            .into_iter()
            .map(|(k, v)| KeyValue::new(k, v));

        let mut resource_attributes: Vec<KeyValue> =
            Vec::with_capacity(env_attributes.len() + caller_attributes.size_hint().0 + 2);
        resource_attributes.extend(env_attributes);
        resource_attributes.extend(caller_attributes);
        resource_attributes.push(KeyValue::new("service.name", config.service_name()));
        resource_attributes.push(KeyValue::new("service.version", config.service_version()));

        if !config.any_signal_enabled() {
            return Ok(Self {
                meter_provider: None,
                tracer_provider: None,
            });
        }

        let resource = Resource::builder()
            .with_attributes(resource_attributes)
            .build();

        let meter_provider = create_metrics_provider(config.metrics(), resource.clone())?;
        let tracer_provider = create_tracer_provider(config.tracing(), resource)?;

        if let Some(ref provider) = meter_provider {
            global::set_meter_provider(provider.clone());
        }

        if let Some(ref provider) = tracer_provider {
            global::set_tracer_provider(provider.clone());
            // Install the W3C TraceContext propagator so any future client/server hops
            // honor the standard `traceparent`/`tracestate` headers. Mongo wire itself
            // doesn't carry trace context today, but other transports might.
            global::set_text_map_propagator(TraceContextPropagator::new());
        }

        Ok(Self {
            meter_provider,
            tracer_provider,
        })
    }

    /// Returns the configured tracer provider, if traces were enabled at init time.
    ///
    /// Used by binary crates to install a `tracing-opentelemetry` layer that bridges
    /// `tracing` spans into OTLP-exported OpenTelemetry spans.
    #[must_use]
    pub const fn tracer_provider(&self) -> Option<&SdkTracerProvider> {
        self.tracer_provider.as_ref()
    }

    /// # Errors
    ///
    /// Returns an error if either the meter or tracer provider fails to shut down.
    pub fn shutdown(self) -> Result<()> {
        let mut errors: Vec<String> = Vec::new();

        if let Some(meter_provider) = self.meter_provider {
            if let Err(e) = meter_provider.shutdown() {
                errors.push(format!("Failed to shutdown meter provider: {e}"));
            }
        }

        if let Some(tracer_provider) = self.tracer_provider {
            if let Err(e) = tracer_provider.shutdown() {
                errors.push(format!("Failed to shutdown tracer provider: {e}"));
            }
        }

        if errors.is_empty() {
            Ok(())
        } else {
            Err(DocumentDBError::internal_error(errors.join("; ")))
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        telemetry::{
            config::TelemetryOptions, metrics::MetricsOptions, tracing_export::TracingOptions,
        },
        testing::EnvGuard,
    };

    fn disabled_config() -> TelemetryConfig {
        TelemetryConfig::new(Some(&TelemetryOptions {
            metrics: Some(MetricsOptions {
                enabled: Some(false),
                ..Default::default()
            }),
            ..Default::default()
        }))
    }

    fn traces_enabled_config() -> TelemetryConfig {
        TelemetryConfig::new(Some(&TelemetryOptions {
            metrics: Some(MetricsOptions {
                enabled: Some(false),
                ..Default::default()
            }),
            tracing: Some(TracingOptions {
                enabled: Some(true),
                ..Default::default()
            }),
            ..Default::default()
        }))
    }

    #[test]
    fn init_telemetry_rejects_reserved_service_name_attribute() {
        let mut attrs = HashMap::new();
        attrs.insert("service.name".to_owned(), "override".to_owned());

        let config = disabled_config();
        let result = TelemetryManager::init_telemetry(&config, Some(attrs));
        assert!(
            result.is_err(),
            "service.name in caller attributes should be rejected"
        );
    }

    #[test]
    fn init_telemetry_rejects_reserved_service_version_attribute() {
        let mut attrs = HashMap::new();
        attrs.insert("service.version".to_owned(), "override".to_owned());

        let config = disabled_config();
        let result = TelemetryManager::init_telemetry(&config, Some(attrs));
        assert!(
            result.is_err(),
            "service.version in caller attributes should be rejected"
        );
    }

    #[test]
    fn init_telemetry_succeeds_when_signals_disabled() {
        let _guard = EnvGuard::set(
            "OTEL_RESOURCE_ATTRIBUTES",
            "deployment.environment=test,team=db",
        );

        let config = disabled_config();
        // With every signal disabled the manager initializes without provider creation.
        let manager = TelemetryManager::init_telemetry(&config, None)
            .expect("disabled signals should still produce a manager");
        manager.shutdown().expect("shutdown should be infallible");
    }

    #[tokio::test]
    async fn init_telemetry_exposes_tracer_provider_when_traces_enabled() {
        let config = traces_enabled_config();

        let manager = TelemetryManager::init_telemetry(&config, None)
            .expect("traces-enabled config should initialize");
        assert!(
            manager.tracer_provider().is_some(),
            "tracer provider should be available when tracing is enabled"
        );
        manager
            .shutdown()
            .expect("shutdown should flush tracer provider cleanly");
    }

    #[test]
    fn init_telemetry_omits_tracer_provider_when_only_metrics_disabled_path() {
        // When every signal is disabled, neither provider is constructed, and the
        // manager exposes `None` for the tracer provider so consumers know to skip
        // installing the OpenTelemetry tracing layer.
        let config = disabled_config();
        let manager = TelemetryManager::init_telemetry(&config, None)
            .expect("disabled signals should still produce a manager");
        assert!(
            manager.tracer_provider().is_none(),
            "tracer provider should be absent when traces are disabled"
        );
    }
}
