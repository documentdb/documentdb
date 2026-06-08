/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/error.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::RawDocumentBuf;

use crate::{error::DocumentDBError, protocol::OK_FAILED};

/// Converts a `DocumentDBError` into a `RawDocumentBuf` error response
/// that can be sent to the client.
///
/// The key names match the field names expected by the driver SDK on errors.
#[must_use]
pub fn error_to_raw_document_buf(error: &DocumentDBError) -> RawDocumentBuf {
    let mut doc = RawDocumentBuf::new();
    doc.append("ok", OK_FAILED);
    doc.append("code", error.error_code() as i32);
    doc.append("codeName", error.error_code().as_ref().to_owned());
    doc.append("errmsg", error.error_message_user().to_owned());
    doc
}
