/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/lib.rs
 *
 *-------------------------------------------------------------------------
 */

pub mod auth;
pub mod bson;
pub mod configuration;
pub mod context;
pub mod error;
pub mod explain;
pub mod postgres;
pub mod processor;
pub mod protocol;
pub mod requests;
pub mod responses;
pub mod security;
pub mod service;
pub mod shutdown_controller;
pub mod startup;
pub mod telemetry;
pub mod time;

pub(crate) mod collections;
mod runtime;

#[cfg(test)]
pub(crate) mod testing;

use tokio_util::sync::CancellationToken;

use crate::{
    context::ServiceContext, error::Result, postgres::PgDataClient, telemetry::TelemetryProvider,
};

/// Runs the `DocumentDB` gateway server.
///
/// The runtime flag is evaluated once here so a gateway process runs either the
/// legacy gateway implementation or the nacelle runtime implementation.
///
/// The startup duration is recorded via [`crate::time::STARTUP_INSTANT`] once
/// the gateway is ready to accept connections.
///
/// # Errors
///
/// Returns an error if the selected gateway runtime fails while binding,
/// serving, or shutting down listener tasks.
pub async fn run_gateway<T>(
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    token: CancellationToken,
) -> Result<()>
where
    T: PgDataClient + 'static,
{
    tracing::info!(">> Starting Gateway v1 Runtime");
    runtime::v1::run_gateway::<T>(service_context, telemetry, token).await
}
