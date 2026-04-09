/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/mod.rs
 *
 * Telemetry infrastructure for the DocumentDB gateway.
 * Provides OpenTelemetry-based metrics.
 *
 *-------------------------------------------------------------------------
 */

mod log_request_fail;
mod telemetry_provider;
mod verbose_latency;

pub mod client_info;
pub mod config;
pub mod event_id;
pub mod metrics;
pub mod telemetry_manager;
pub mod utils;

// Re-export commonly used types
pub use config::{TelemetryConfig, TelemetryOptions};
pub use log_request_fail::log_request_failure;
pub use metrics::{record_gateway_metrics, MetricsConfig, MetricsOptions};
pub use telemetry_manager::TelemetryManager;
pub use telemetry_provider::TelemetryProvider;
pub use verbose_latency::try_log_verbose_latency;
