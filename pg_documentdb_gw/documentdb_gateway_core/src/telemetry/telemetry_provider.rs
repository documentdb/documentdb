/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/telemetry_provider.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt::Debug;

use async_trait::async_trait;
use dyn_clone::{clone_trait_object, DynClone};
use either::Either;

use crate::{
    context::ConnectionContext,
    protocol::header::Header,
    requests::{request_tracker::RequestTracker, Request},
    responses::{CommandError, Response},
};

/// `TelemetryProvider` takes care of emitting events and metrics for tracking the gateway.
#[expect(
    clippy::too_many_arguments,
    reason = "telemetry requires many parameters"
)]
#[async_trait]
pub trait TelemetryProvider: Send + Sync + DynClone + Debug {
    /// Emits an event for every CRUD request dispatched to backend.
    async fn emit_request_event(
        &self,
        _: &ConnectionContext,
        _: &Header,
        _: Option<&Request<'_>>,
        _: Either<&Response, (&CommandError, usize)>,
        _: String,
        _: &RequestTracker,
        _: &str,
        _: &str,
    );
}

clone_trait_object!(TelemetryProvider);
