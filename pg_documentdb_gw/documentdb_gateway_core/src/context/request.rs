/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/request.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::requests::{request_tracker::RequestTracker, Request, RequestInfo};

#[derive(Debug)]
pub struct RequestContext<'a> {
    pub activity_id: &'a str,
    pub payload: &'a Request<'a>,
    pub info: &'a RequestInfo<'a>,
    pub tracker: &'a RequestTracker,
}

impl<'a> RequestContext<'a> {
    #[must_use]
    pub const fn get_components(&self) -> (&Request<'a>, &RequestInfo<'a>, &RequestTracker) {
        (self.payload, self.info, self.tracker)
    }

    #[must_use]
    pub const fn payload(&self) -> &'a Request<'a> {
        self.payload
    }

    #[must_use]
    pub const fn info(&self) -> &'a RequestInfo<'a> {
        self.info
    }
}
