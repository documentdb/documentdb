/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/telemetry_provider.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{fmt::Debug, time::Duration};

use dyn_clone::{clone_trait_object, DynClone};
use either::Either;

use crate::{
    context::ConnectionContext,
    error::DocumentDBError,
    protocol::header::Header,
    requests::{request_tracker::RequestTracker, RequestObservation},
    responses::Response,
    telemetry::record_startup_metrics,
};

/// `TelemetryProvider` takes care of emitting events and metrics for tracking the gateway.
#[expect(
    clippy::too_many_arguments,
    reason = "Telemetry requires many parameters"
)]
pub trait TelemetryProvider: Send + Sync + DynClone + Debug {
    /// Emits an event for every CRUD request dispatched to backend.
    ///
    /// Error responses carry the originating `DocumentDBError` so providers
    /// derive status and code from a single source.
    fn emit_request_event(
        &self,
        _: &ConnectionContext,
        _: &Header,
        _: Option<RequestObservation<'_, '_>>,
        _: Either<&Response, (&DocumentDBError, usize)>,
        _: &str,
        _: &RequestTracker,
        _: &str,
        _: &str,
    );

    /// Records the gateway startup duration once the gateway is ready to accept
    /// connections.
    ///
    /// The default implementation records the duration to the `OpenTelemetry`
    /// startup instruments (a no-op when no global `MeterProvider` is
    /// registered). Providers may override this to add their own sinks; an
    /// override that still wants the `OpenTelemetry` emission should call
    /// [`record_startup_metrics`] as well.
    fn record_startup_duration(&self, duration: Duration) {
        record_startup_metrics(duration);
    }
}

clone_trait_object!(TelemetryProvider);
