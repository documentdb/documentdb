/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/request.rs
 *
 *-------------------------------------------------------------------------
 */

use tokio::time::Instant;

use crate::requests::{request_tracker::RequestTracker, RequestType, WireRequest};

#[derive(Debug, Clone, Copy)]
pub struct RequestContext<'a> {
    pub activity_id: &'a str,
    request: &'a WireRequest<'a>,
    pub tracker: &'a RequestTracker,
    /// When this attempt must finish. `None` on a first attempt.
    deadline: Option<Instant>,
}

impl<'a> RequestContext<'a> {
    #[must_use]
    pub const fn new(
        activity_id: &'a str,
        request: &'a WireRequest<'a>,
        tracker: &'a RequestTracker,
    ) -> Self {
        Self {
            activity_id,
            request,
            tracker,
            deadline: None,
        }
    }

    /// Returns a copy bounded by `deadline`, so a reissued attempt does not
    /// start a fresh budget.
    #[must_use]
    pub const fn with_deadline(&self, deadline: Instant) -> Self {
        Self {
            deadline: Some(deadline),
            ..*self
        }
    }

    #[must_use]
    pub const fn deadline(&self) -> Option<Instant> {
        self.deadline
    }

    #[must_use]
    pub const fn request(&self) -> &'a WireRequest<'a> {
        self.request
    }

    /// Returns the request type parsed from the command name.
    #[must_use]
    pub const fn request_type(&self) -> RequestType {
        self.request.request_type()
    }

    /// Returns the request type to execute after applying request metadata.
    #[must_use]
    pub const fn execution_request_type(&self) -> RequestType {
        self.request.execution_request_type()
    }
}
