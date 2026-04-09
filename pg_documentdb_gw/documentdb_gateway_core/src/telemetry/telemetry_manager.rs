/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/telemetry/telemetry_manager.rs
 *
 *-------------------------------------------------------------------------
 */

use std::collections::HashMap;

use opentelemetry::{global, KeyValue};
use opentelemetry_sdk::{metrics::SdkMeterProvider, Resource};

use crate::{
    error::{DocumentDBError, Result},
    telemetry::{config::TelemetryConfig, metrics::create_metrics_provider},
};

/// Manages OpenTelemetry providers for telemetry signals.
///
/// Currently supports metrics. Tracing and logging will be added in follow-up PRs.
#[derive(Debug)]
pub struct TelemetryManager {
    meter_provider: Option<SdkMeterProvider>,
}

impl TelemetryManager {
    /// # Errors
    ///
    /// Returns an error if telemetry attributes contain reserved keys (`service.name` or `service.version`),
    /// or if the OTLP metrics provider fails to initialize.
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

        let mut resource_attributes = attributes
            .unwrap_or_default()
            .into_iter()
            .map(|(k, v)| KeyValue::new(k, v))
            .collect::<Vec<_>>();

        resource_attributes.push(KeyValue::new("service.name", config.service_name()));
        resource_attributes.push(KeyValue::new("service.version", config.service_version()));

        if !config.any_signal_enabled() {
            return Ok(Self {
                meter_provider: None,
            });
        }

        let resource = Resource::builder()
            .with_attributes(resource_attributes)
            .build();

        let meter_provider = create_metrics_provider(config.metrics(), resource)?;

        if let Some(ref provider) = meter_provider {
            global::set_meter_provider(provider.clone());
        }

        Ok(Self { meter_provider })
    }

    /// # Errors
    ///
    /// Returns an error if the meter provider fails to shut down.
    pub fn shutdown(self) -> Result<()> {
        if let Some(meter_provider) = self.meter_provider {
            if let Err(e) = meter_provider.shutdown() {
                return Err(DocumentDBError::internal_error(format!(
                    "Failed to shutdown meter provider: {e}"
                )));
            }
        }

        Ok(())
    }
}
