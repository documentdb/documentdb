/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/testing/telemetry.rs
 *
 * Shared telemetry test doubles for unit tests.
 *
 *-------------------------------------------------------------------------
 */

use std::sync::{Arc, Mutex};

use either::Either;

use crate::{
    context::ConnectionContext,
    protocol::header::Header,
    requests::{request_tracker::RequestTracker, Request, RequestType},
    responses::{CommandError, Response},
    telemetry::TelemetryProvider,
};

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct RecordedTelemetryEvent {
    activity_id: String,
    collection: String,
    user_agent: String,
    request_type: Option<RequestType>,
    is_error: bool,
    error_code_name: Option<String>,
}

impl RecordedTelemetryEvent {
    pub fn activity_id(&self) -> &str {
        &self.activity_id
    }

    pub fn collection(&self) -> &str {
        &self.collection
    }

    pub fn user_agent(&self) -> &str {
        &self.user_agent
    }

    pub fn request_type(&self) -> Option<RequestType> {
        self.request_type
    }

    pub fn is_error(&self) -> bool {
        self.is_error
    }

    pub fn error_code_name(&self) -> Option<&str> {
        self.error_code_name.as_deref()
    }
}

#[derive(Clone, Debug, Default)]
pub struct RecordingTelemetryProvider {
    events: Arc<Mutex<Vec<RecordedTelemetryEvent>>>,
}

impl RecordingTelemetryProvider {
    pub fn events(&self) -> Vec<RecordedTelemetryEvent> {
        self.events
            .lock()
            .expect("telemetry events lock should not be poisoned")
            .clone()
    }
}

impl TelemetryProvider for RecordingTelemetryProvider {
    fn emit_request_event(
        &self,
        _: &ConnectionContext,
        _: &Header,
        request: Option<&Request<'_>>,
        response: Either<&Response, (&CommandError, usize)>,
        collection: String,
        _: &RequestTracker,
        activity_id: &str,
        user_agent: &str,
    ) {
        let (is_error, error_code_name) = match response {
            Either::Left(_) => (false, None),
            Either::Right((error, _)) => (true, Some(error.code().to_string())),
        };

        self.events
            .lock()
            .expect("telemetry events lock should not be poisoned")
            .push(RecordedTelemetryEvent {
                activity_id: activity_id.to_owned(),
                collection,
                user_agent: user_agent.to_owned(),
                request_type: request.map(Request::request_type),
                is_error,
                error_code_name,
            });
    }
}
