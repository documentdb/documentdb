/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/mod.rs
 *
 * Telemetry infrastructure for the DocumentDB gateway.
 * Provides provider-neutral tracing and metrics instrumentation.
 *
 *-------------------------------------------------------------------------
 */

mod log_request_fail;
mod telemetry_provider;

pub mod client_info;
pub mod config;
pub mod consts;
pub mod context_propagation;
pub mod event_id;
pub mod metrics;
#[cfg(feature = "postgres-sql-commenter")]
pub mod sql_commenter;
pub mod utils;

// Re-export commonly used types
pub use config::TelemetrySettings;
pub use log_request_fail::log_request_failure;
pub use metrics::{record_gateway_metrics, record_startup_metrics};
pub use telemetry_provider::TelemetryProvider;
pub use utils::{ns_to_ms, NANOS_PER_MILLISECOND};
