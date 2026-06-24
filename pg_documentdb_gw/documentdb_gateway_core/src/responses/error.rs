/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/error.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::RawDocumentBuf;

use crate::{
    error::{DocumentDBError, ErrorCode},
    protocol::OK_FAILED,
};

/// Error response fields emitted for a failed command.
#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct CommandError {
    ok: f64,
    code: ErrorCode,
    message: String,
}

impl CommandError {
    /// Creates a command error from a response code and user-facing message.
    #[must_use]
    pub const fn new(code: ErrorCode, message: String) -> Self {
        Self {
            ok: OK_FAILED,
            code,
            message,
        }
    }

    /// Returns the command success flag.
    #[must_use]
    pub const fn ok(&self) -> f64 {
        self.ok
    }

    /// Returns the command error code.
    #[must_use]
    pub const fn code(&self) -> &ErrorCode {
        &self.code
    }

    /// Returns the user-facing command error message.
    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }

    /// Converts the `CommandError` into a `RawDocumentBuf` that can be sent to the client.
    #[must_use]
    pub fn to_raw_document_buf(&self) -> RawDocumentBuf {
        let mut doc = RawDocumentBuf::new();
        doc.append("ok", self.ok);
        doc.append("code", self.code as i32);
        doc.append("codeName", self.code.as_ref().to_owned());
        doc.append("errmsg", self.message.clone());
        doc
    }
}

impl From<&DocumentDBError> for CommandError {
    fn from(error: &DocumentDBError) -> Self {
        Self::new(error.error_code(), error.error_message_user().to_owned())
    }
}

/// Converts a `DocumentDBError` into a `RawDocumentBuf` error response
/// that can be sent to the client.
///
/// The key names match the field names expected by the driver SDK on errors.
#[must_use]
pub fn error_to_raw_document_buf(error: &DocumentDBError) -> RawDocumentBuf {
    CommandError::from(error).to_raw_document_buf()
}
