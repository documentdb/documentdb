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

pub fn enhance_internal_error_message(
    user_error_message: &str,
    error_code: ErrorCode,
    activity_id: &str,
) -> String {
    if error_code != ErrorCode::InternalError {
        return user_error_message.to_owned();
    }

    format!("[ActivityId={activity_id}] {user_error_message}")
}

/// Error response fields emitted for a failed command.
#[derive(Debug, Clone)]
#[non_exhaustive]
struct CommandError {
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

    /// Creates a command error from a gateway error and request `ActivityId`.
    #[must_use]
    pub fn from_error(error: &DocumentDBError, activity_id: &str) -> Self {
        Self::new(
            error.error_code(),
            enhance_internal_error_message(
                error.error_message_user(),
                error.error_code(),
                activity_id,
            ),
        )
    }

    /// Converts the `CommandError` into a `RawDocumentBuf` that can be sent to the client.
    /// The key names match the field names expected by the driver SDK on errors.
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

/// Converts a `DocumentDBError` into a raw error response.
#[must_use]
pub fn error_to_raw_document_buf(error: &DocumentDBError, activity_id: &str) -> RawDocumentBuf {
    CommandError::from_error(error, activity_id).to_raw_document_buf()
}

#[cfg(test)]
mod tests {
    use bson::Document;

    use super::*;

    #[test]
    fn internal_error_message_includes_activity_id() {
        let message = enhance_internal_error_message(
            "An unexpected internal error has occurred",
            ErrorCode::InternalError,
            "test-activity-id",
        );

        assert_eq!(
            message,
            "[ActivityId=test-activity-id] An unexpected internal error has occurred"
        );
    }

    #[test]
    fn non_internal_error_message_ignores_activity_id() {
        let message =
            enhance_internal_error_message("bad value", ErrorCode::BadValue, "test-activity-id");

        assert_eq!(message, "bad value");
    }

    #[test]
    fn command_error_from_error_enhances_internal_error_message() {
        let error = DocumentDBError::internal_error("loggable internal error".to_owned());

        let response = Document::try_from(
            CommandError::from_error(&error, "test-activity-id").to_raw_document_buf(),
        )
        .expect("error response should convert to document");

        assert_eq!(response.get_f64("ok"), Ok(OK_FAILED));
        assert_eq!(response.get_i32("code"), Ok(1));
        assert_eq!(response.get_str("codeName"), Ok("InternalError"));
        assert_eq!(
            response.get_str("errmsg"),
            Ok("[ActivityId=test-activity-id] An unexpected internal error has occurred.")
        );
    }

    #[test]
    fn raw_document_buf_with_activity_id_enhances_internal_error_message() {
        let error = DocumentDBError::internal_error("loggable internal error".to_owned());

        let response = Document::try_from(error_to_raw_document_buf(&error, "test-activity-id"))
            .expect("error response should convert to document");

        assert_eq!(
            response.get_str("errmsg"),
            Ok("[ActivityId=test-activity-id] An unexpected internal error has occurred.")
        );
    }
}
