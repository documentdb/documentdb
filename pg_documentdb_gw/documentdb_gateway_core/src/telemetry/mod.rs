/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/mod.rs
 *
 *-------------------------------------------------------------------------
 */

pub mod client_info;
pub mod event_id;
mod telemetry_provider;
pub mod utils;
mod verbose_latency;

pub use telemetry_provider::TelemetryProvider;
pub use verbose_latency::try_log_verbose_latency;
