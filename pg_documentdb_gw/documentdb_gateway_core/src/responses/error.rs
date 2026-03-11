/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/error.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{raw::ValueAccessErrorKind, RawDocumentBuf};
use deadpool_postgres::PoolError;

use crate::{
    context::ConnectionContext,
    error::{DocumentDBError, ErrorCode},
    protocol::OK_FAILED,
    responses::{
        constant::{generic_internal_error_message, value_access_error_message},
        pg::PgResponse,
    },
};

/// Display and Debug trait are not implemented explicitly to avoid logging PII mistakenly.
#[derive(Clone)]
#[non_exhaustive]
pub struct CommandError {
    pub ok: f64,

    /// The error code in i32, e.g. InternalError has error code 1.
    pub code: i32,

    /// The error string, e.g. Internal Error.
    pub code_name: String,

    /// A human-readable description of the error, sent to the client.
    pub message: String,
}

impl CommandError {
    pub fn new(code: i32, code_name: String, msg: String) -> Self {
        CommandError {
            ok: OK_FAILED,
            code,
            code_name,
            message: msg,
        }
    }

    pub fn to_raw_document_buf(&self) -> RawDocumentBuf {
        // The key names used here must match with the field names expected by the driver sdk on errors.
        let mut doc = RawDocumentBuf::new();
        doc.append("ok", self.ok);
        doc.append("code", self.code);
        doc.append("codeName", self.code_name.clone());
        doc.append("errmsg", self.message.clone());
        doc
    }

    fn internal(msg: String) -> Self {
        CommandError::new(
            ErrorCode::InternalError as i32,
            "Internal Error".to_string(),
            msg,
        )
    }

    pub fn from_error(
        connection_context: &ConnectionContext,
        err: &DocumentDBError,
        activity_id: &str,
    ) -> Self {
        match err {
            DocumentDBError::IoError(e, _) => CommandError::internal(e.to_string()),
            DocumentDBError::PostgresError(e, _) => {
                Self::from_pg_error(connection_context, e, activity_id)
            }
            DocumentDBError::PoolError(PoolError::Backend(e), _) => {
                Self::from_pg_error(connection_context, e, activity_id)
            }
            DocumentDBError::PostgresDocumentDBError(e, msg, _) => {
                if let Ok(state) = PgResponse::i32_to_postgres_sqlstate(e) {
                    let mapped_response = PgResponse::known_pg_error(
                        connection_context,
                        &state,
                        msg.as_str(),
                        activity_id,
                    );
                    return CommandError::new(
                        mapped_response.error_code(),
                        mapped_response.code_name().unwrap_or_default().to_string(),
                        mapped_response.error_message().to_string(),
                    );
                }

                tracing::error!(
                    activity_id = activity_id,
                    "Unable to parse PostgresDocumentDBError code: {e}, message: {msg}"
                );
                CommandError::internal(generic_internal_error_message().to_string())
            }
            DocumentDBError::RawBsonError(e, _) => {
                CommandError::internal(format!("Raw BSON error: {e}"))
            }
            DocumentDBError::PoolError(e, _) => CommandError::internal(format!("Pool error: {e}")),
            DocumentDBError::CreatePoolError(e, _) => {
                CommandError::internal(format!("Create pool error: {e}"))
            }
            DocumentDBError::BuildPoolError(e, _) => {
                CommandError::internal(format!("Build pool error: {e}"))
            }
            DocumentDBError::DocumentDBError(error_code, msg, _, _) => {
                CommandError::new(*error_code as i32, error_code.to_string(), msg.to_string())
            }
            DocumentDBError::SSLErrorStack(error_stack, _) => {
                CommandError::internal(format!("SSL error stack: {error_stack}"))
            }
            DocumentDBError::SSLError(error, _) => {
                CommandError::internal(format!("SSL error: {error}"))
            }
            DocumentDBError::ValueAccessError(error, _) => match &error.kind {
                ValueAccessErrorKind::UnexpectedType {
                    actual, expected, ..
                } => {
                    tracing::error!(
                        activity_id = activity_id,
                        "Type mismatch error: expected {expected:?} but got {actual:?}"
                    );
                    CommandError::new(
                        ErrorCode::TypeMismatch as i32,
                        value_access_error_message(),
                        format!(
                            "Expected {:?} but got {:?}, at key {}",
                            expected,
                            actual,
                            error.key()
                        ),
                    )
                }
                ValueAccessErrorKind::InvalidBson(_) => {
                    let error_message = "Value is not a valid BSON";
                    tracing::error!(activity_id = activity_id, "{error_message}");
                    CommandError::new(
                        ErrorCode::BadValue as i32,
                        value_access_error_message(),
                        error_message.to_string(),
                    )
                }
                ValueAccessErrorKind::NotPresent => {
                    let error_message = "Value is not present";
                    tracing::error!(activity_id = activity_id, "{error_message}");
                    CommandError::new(
                        ErrorCode::BadValue as i32,
                        value_access_error_message(),
                        error_message.to_string(),
                    )
                }
                _ => {
                    tracing::error!(activity_id = activity_id, "Hit generic ValueAccessError.");
                    CommandError::new(
                        ErrorCode::BadValue as i32,
                        value_access_error_message(),
                        "Unexpected value".to_string(),
                    )
                }
            },
        }
    }

    pub fn from_pg_error(
        context: &ConnectionContext,
        e: &tokio_postgres::Error,
        activity_id: &str,
    ) -> Self {
        if let Some(state) = e.code() {
            let mapped_result = PgResponse::known_pg_error(
                context,
                state,
                e.as_db_error().map_or("", |e| e.message()),
                activity_id,
            );

            CommandError::new(
                mapped_result.error_code(),
                mapped_result.code_name().unwrap_or_default().to_string(),
                mapped_result.error_message().to_string(),
            )
        } else {
            CommandError::internal(e.to_string())
        }
    }
}
