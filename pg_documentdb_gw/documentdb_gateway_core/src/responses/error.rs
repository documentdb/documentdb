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
    error::{DocumentDBError, ErrorCode, Result},
    protocol::OK_FAILED,
    responses::{self, constant::generic_internal_error_message},
};

#[derive(Debug, Clone)]
#[non_exhaustive]
pub struct CommandError {
    pub ok: f64,

    /// The error code in i32, e.g. `InternalError` has error code 1.
    pub code: i32,

    /// A human-readable description of the error, sent to the client.
    pub message: String,
}

impl CommandError {
    #[must_use = "Constructor for CommandError."]
    pub const fn new(code: i32, msg: String) -> Self {
        Self {
            ok: OK_FAILED,
            code,
            message: msg,
        }
    }

    /// Converts the `CommandError` into a `RawDocumentBuf` that can be sent to the client.
    ///
    /// # Errors
    /// - Returns an error if the conversion of code into to `ErrorCode` fails, which should be extremely rare.
    #[must_use = "This constructs the actual error response to be sent to the client."]
    pub fn to_raw_document_buf(&self) -> Result<RawDocumentBuf> {
        // The key names used here must match with the field names expected by the driver sdk on errors.
        let mut doc = RawDocumentBuf::new();
        doc.append("ok", self.ok);
        doc.append("code", self.code);

        let code_name = ErrorCode::from_i32(self.code).ok_or_else(|| {
            DocumentDBError::internal_error(format!(
                "Failed to map error code {} to ErrorCode for code_name.",
                self.code
            ))
        })?;
        doc.append("codeName", code_name.as_ref().to_owned());

        doc.append("errmsg", self.message.clone());
        Ok(doc)
    }

    const fn internal(msg: String) -> Self {
        Self::new(ErrorCode::InternalError as i32, msg)
    }

    pub fn from_error(
        connection_context: &ConnectionContext,
        err: &DocumentDBError,
        activity_id: &str,
    ) -> Self {
        match err {
            DocumentDBError::IoError(e, _) => Self::internal(e.to_string()),
            DocumentDBError::PostgresError(e, _)
            | DocumentDBError::PoolError(PoolError::Backend(e), _) => {
                Self::from_pg_error(connection_context, e, activity_id)
            }
            DocumentDBError::PostgresDocumentDBError(error_code, msg, _) => {
                if let Ok(state) = responses::i32_to_postgres_sqlstate(*error_code) {
                    let mapped_response = responses::known_pg_error(
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
                Self::internal(generic_internal_error_message().to_owned())
            }
            DocumentDBError::RawBsonError(e, _) => Self::internal(format!("Raw BSON error: {e}")),
            DocumentDBError::PoolError(e, _) => Self::internal(format!("Pool error: {e}")),
            DocumentDBError::CreatePoolError(e, _) => {
                Self::internal(format!("Create pool error: {e}"))
            }
            DocumentDBError::BuildPoolError(e, _) => {
                Self::internal(format!("Build pool error: {e}"))
            }
            DocumentDBError::DocumentDBError(error_code, msg, _, _) => {
                Self::new(*error_code as i32, msg.clone())
            }
            DocumentDBError::SSLErrorStack(error_stack, _) => {
                Self::internal(format!("SSL error stack: {error_stack}"))
            }
            DocumentDBError::SSLError(error, _) => Self::internal(format!("SSL error: {error}")),
            DocumentDBError::ValueAccessError(error, _) => match &error.kind {
                ValueAccessErrorKind::UnexpectedType {
                    actual, expected, ..
                } => {
                    tracing::error!(
                        activity_id = activity_id,
                        "Type mismatch error: expected {expected:?} but got {actual:?}"
                    );
                    Self::new(
                        ErrorCode::TypeMismatch as i32,
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
                    Self::new(ErrorCode::BadValue as i32, error_message.to_owned())
                }
                ValueAccessErrorKind::NotPresent => {
                    let error_message = "Value is not present";
                    tracing::error!(activity_id = activity_id, "{error_message}");
                    Self::new(ErrorCode::BadValue as i32, error_message.to_owned())
                }
                _ => {
                    tracing::error!(activity_id = activity_id, "Hit generic ValueAccessError.");
                    Self::new(ErrorCode::BadValue as i32, "Unexpected value".to_owned())
                }
            },
        }
    }

    #[must_use]
    pub fn from_pg_error(
        context: &ConnectionContext,
        e: &tokio_postgres::Error,
        activity_id: &str,
    ) -> Self {
        if let Some(state) = e.code() {
            let mapped_result = responses::known_pg_error(
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
            Self::internal(e.to_string())
        }
    }
}
