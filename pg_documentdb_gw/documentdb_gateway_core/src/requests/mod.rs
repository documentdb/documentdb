/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/mod.rs
 *
 *-------------------------------------------------------------------------
 */

mod common_fields;
mod info;
mod message;
#[cfg(test)]
mod request;
mod wire_request;

pub mod read_concern;
pub mod read_preference;
pub mod request_tracker;
pub mod request_type;
pub mod validation;

pub(crate) use common_fields::extract_request_type_and_info_from_document;
pub(crate) use info::StrictRequestInfo;
pub use message::RequestMessage;
#[cfg(test)]
pub(crate) use request::Request;
pub use request_tracker::RequestIntervalKind;
pub use request_type::RequestType;
pub use wire_request::{
    ExplainTarget, RequestExecutionMode, RequestObservation, RequestPreview, WireRequest,
    WireRequestFrame,
};
