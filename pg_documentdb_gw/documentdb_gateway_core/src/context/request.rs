/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/request.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::requests::{request_tracker::RequestTracker, RequestType, WireRequest};

#[derive(Debug)]
pub struct RequestContext<'a> {
    pub activity_id: &'a str,
    request: &'a WireRequest<'a>,
    pub tracker: &'a RequestTracker,
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
        }
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
