/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/error.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::RawDocumentBuf;
use deadpool_postgres::PoolError;

use crate::{
    context::ConnectionContext,
    error::{DocumentDBError, ErrorCode, ErrorKind},
    protocol::OK_FAILED,
    responses::{self, constant::generic_internal_error_message},
};

#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct CommandError {
    ok: f64,

    /// The `ErrorCode` associated with this error response.
    code: ErrorCode,

    /// A human-readable description of the error, sent to the client.
    message: String,
}

impl CommandError {
    #[must_use = "Constructor for CommandError."]
    pub const fn new(code: ErrorCode, msg: String) -> Self {
        Self {
            ok: OK_FAILED,
            code,
            message: msg,
        }
    }

    #[must_use]
    pub const fn ok(&self) -> f64 {
        self.ok
    }

    #[must_use]
    pub const fn code(&self) -> &ErrorCode {
        &self.code
    }

    #[must_use]
    pub fn message(&self) -> &str {
        &self.message
    }

    /// Converts the `CommandError` into a `RawDocumentBuf` that can be sent to the client.
    #[must_use = "This constructs the actual error response to be sent to the client."]
    pub fn to_raw_document_buf(&self) -> RawDocumentBuf {
        // The key names used here must match with the field names expected by the driver sdk on errors.
        let mut doc = RawDocumentBuf::new();
        doc.append("ok", self.ok);
        doc.append("code", self.code as i32);
        doc.append("codeName", self.code.as_ref().to_owned());
        doc.append("errmsg", self.message.clone());
        doc
    }

    fn internal_error() -> Self {
        Self::new(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
        )
    }

    pub fn from_error(
        connection_context: &ConnectionContext,
        err: &DocumentDBError,
        activity_id: &str,
    ) -> Self {
        match err.kind() {
            ErrorKind::PostgresError(e, _) | ErrorKind::PoolError(PoolError::Backend(e), _) => {
                Self::from_pg_error(connection_context, e, activity_id)
            }
            ErrorKind::PostgresDocumentDBError(error_code, msg, _) => {
                if let Ok(state) = responses::i32_to_postgres_sqlstate(*error_code) {
                    let mapped_response = responses::map_pg_error(
                        connection_context,
                        &state,
                        msg.as_str(),
                        activity_id,
                    );
                    return Self::new(
                        mapped_response.error_code(),
                        mapped_response.error_message().to_owned(),
                    );
                }

                tracing::error!(
                    activity_id = activity_id,
                    "Unable to parse PostgresDocumentDBError code: {error_code}, message: {msg}"
                );
                Self::internal_error()
            }
            ErrorKind::DocumentDBError(error_code, msg, _, _) => {
                Self::new(*error_code, msg.clone())
            }
            ErrorKind::IoError(_, _)
            | ErrorKind::RawBsonError(_, _)
            | ErrorKind::PoolError(_, _)
            | ErrorKind::CreatePoolError(_, _)
            | ErrorKind::BuildPoolError(_, _)
            | ErrorKind::SSLErrorStack(_, _)
            | ErrorKind::SSLError(_, _) => Self::internal_error(),
        }
    }

    #[must_use]
    pub fn from_pg_error(
        context: &ConnectionContext,
        e: &tokio_postgres::Error,
        activity_id: &str,
    ) -> Self {
        if let Some(state) = e.code() {
            let mapped_result = responses::map_pg_error(
                context,
                state,
                e.as_db_error().map_or("", |e| e.message()),
                activity_id,
            );

            Self::new(
                mapped_result.error_code(),
                mapped_result.error_message().to_owned(),
            )
        } else {
            Self::internal_error()
        }
    }
}
