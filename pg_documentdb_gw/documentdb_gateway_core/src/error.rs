/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/error.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{backtrace::Backtrace, fmt::Display, io};

use bson::raw::ValueAccessError;
use deadpool_postgres::{BuildError, CreatePoolError, PoolError};
use documentdb_macros::documentdb_error_code_enum;
use openssl::error::ErrorStack;
use tokio_postgres::error::SqlState;

use crate::{
    context::ConnectionContext,
    responses::{constant::pg_returned_invalid_response_message, PgResponse},
};

documentdb_error_code_enum!();

pub enum DocumentDBError {
    IoError(io::Error, Backtrace),
    #[expect(clippy::enum_variant_names)]
    DocumentDBError(
        ErrorCode,
        String, // Error message shown to user. This should not be logged as it may contain PII.
        Option<String>, // Error message for logging, must be PII free.
        Backtrace,
    ),
    PostgresError(tokio_postgres::Error, Backtrace),
    #[expect(clippy::enum_variant_names)]
    PostgresDocumentDBError(i32, String, Backtrace),
    PoolError(PoolError, Backtrace),
    CreatePoolError(CreatePoolError, Backtrace),
    BuildPoolError(BuildError, Backtrace),
    RawBsonError(bson::raw::Error, Backtrace),
    SSLError(openssl::ssl::Error, Backtrace),
    SSLErrorStack(ErrorStack, Backtrace),
    ValueAccessError(ValueAccessError, Backtrace),
}

impl DocumentDBError {
    pub fn parse_failure<'a, E: std::fmt::Display>() -> impl Fn(E) -> Self + 'a {
        move |e| DocumentDBError::bad_value(format!("Failed to parse: {e}"))
    }

    pub fn pg_response_empty() -> Self {
        DocumentDBError::internal_error("PG returned no rows in response".to_string())
    }

    pub fn pg_response_invalid(e: ValueAccessError) -> Self {
        DocumentDBError::internal_error(pg_returned_invalid_response_message(e))
    }

    pub fn sasl_payload_invalid() -> Self {
        DocumentDBError::authentication_failed("Sasl payload invalid.".to_string())
    }

    pub fn unauthorized(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::Unauthorized,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    pub fn authentication_failed(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::AuthenticationFailed,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    pub fn bad_value(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::BadValue,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    pub fn internal_error(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::InternalError,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    pub fn type_mismatch(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::TypeMismatch,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    pub fn user_not_found(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::UserNotFound,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    pub fn role_not_found(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::RoleNotFound,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    pub fn duplicate_user(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::Location51003,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    pub fn duplicate_role(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::Location51002,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    pub fn reauthentication_required(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::ReauthenticationRequired,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[expect(clippy::self_named_constructors)]
    pub fn documentdb_error(error_code: ErrorCode, error_message: String) -> Self {
        DocumentDBError::DocumentDBError(
            error_code,
            error_message.clone(),
            error_message.into(),
            Backtrace::capture(),
        )
    }

    pub fn error_with_loggable_message(
        code: ErrorCode,
        message: &str,
        error_message_loggable: &str,
    ) -> Self {
        DocumentDBError::DocumentDBError(
            code,
            message.to_string(),
            Some(error_message_loggable.to_string()),
            Backtrace::capture(),
        )
    }

    pub fn error_code_enum(&self) -> Option<ErrorCode> {
        match self {
            DocumentDBError::DocumentDBError(code, _, _, _) => Some(*code),
            _ => None,
        }
    }

    pub fn command_not_supported(msg: String) -> Self {
        DocumentDBError::DocumentDBError(
            ErrorCode::CommandNotSupported,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    // Logs error with common format for all DocumentDBErrors on request failure.
    // The logged output here must be PII free and is used for telemetry and logging.
    pub fn log_request_failure(&self, connection_context: &ConnectionContext, activity_id: &str) {
        match self {
            DocumentDBError::IoError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "IoError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                })
            }
            DocumentDBError::DocumentDBError(code, _msg, error_message_loggable, backtrace) => {
                let error_code = *code as i32;
                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "DocumentDBError",
                    backtrace: Some(backtrace),
                    error_message_loggable: error_message_loggable.as_deref(),
                    error_code: Some(&error_code),
                    ..Default::default()
                })
            }
            DocumentDBError::PostgresError(error, backtrace) => {
                if let Some(dbe) = error.as_db_error() {
                    let error_message_loggable = PgResponse::known_pg_error(
                        connection_context,
                        dbe.code(),
                        dbe.message(),
                        activity_id,
                    )
                    .internal_note();

                    log_request_failure_inner(RequestFailureLogFields {
                        activity_id,
                        error_source: "PostgresError",
                        backtrace: Some(backtrace),
                        error_message_loggable,
                        sub_status: Some(dbe.code().code()),
                        sub_status_code: Some(&PgResponse::postgres_sqlstate_to_i32(dbe.code())),
                        error_hint: dbe.hint(),
                        error_file_name: dbe.file(),
                        error_file_line_num: dbe.line().as_ref(),
                        ..Default::default()
                    })
                } else {
                    let error_message_loggable = error.to_string();
                    log_request_failure_inner(RequestFailureLogFields {
                        activity_id,
                        error_source: "PostgresError",
                        backtrace: Some(backtrace),
                        error_message_loggable: Some(error_message_loggable.as_str()),
                        ..Default::default()
                    })
                }
            }
            DocumentDBError::PostgresDocumentDBError(pg_code, msg, backtrace) => {
                let (sql_state, error_message_loggable): (Option<SqlState>, Option<String>) =
                    match PgResponse::i32_to_postgres_sqlstate(pg_code) {
                        Ok(state) => {
                            let mapped_response = PgResponse::known_pg_error(
                                connection_context,
                                &state,
                                msg.as_str(),
                                activity_id,
                            );
                            (
                                Some(state.clone()),
                                mapped_response.internal_note().map(|s| s.to_string()),
                            )
                        }
                        Err(_) => (
                            None,
                            Some(format!(
                                "Unable to convert to Postgres SQLState code: {pg_code}"
                            )),
                        ),
                    };

                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "PostgresDocumentDBError",
                    backtrace: Some(backtrace),
                    error_message_loggable: error_message_loggable.as_deref(),
                    sub_status: sql_state.as_ref().map(|s| s.code()),
                    sub_status_code: Some(pg_code),
                    ..Default::default()
                })
            }
            DocumentDBError::PoolError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "PoolError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                })
            }
            DocumentDBError::CreatePoolError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "CreatePoolError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                })
            }
            DocumentDBError::BuildPoolError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "BuildPoolError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                })
            }
            DocumentDBError::RawBsonError(_error, backtrace) => {
                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "RawBsonError",
                    backtrace: Some(backtrace),
                    ..Default::default()
                })
            }
            DocumentDBError::SSLError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "SSLError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                })
            }
            DocumentDBError::SSLErrorStack(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "SSLErrorStack",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                })
            }
            DocumentDBError::ValueAccessError(_error, backtrace) => {
                log_request_failure_inner(RequestFailureLogFields {
                    activity_id,
                    error_source: "ValueAccessError",
                    backtrace: Some(backtrace),
                    ..Default::default()
                })
            }
        }
    }
}

#[derive(Default)]
struct RequestFailureLogFields<'a> {
    activity_id: &'a str,
    error_source: &'a str,
    backtrace: Option<&'a Backtrace>,
    error_message_loggable: Option<&'a str>,
    error_code: Option<&'a i32>,
    sub_status: Option<&'a str>,
    sub_status_code: Option<&'a i32>,
    error_hint: Option<&'a str>,
    error_file_name: Option<&'a str>,
    error_file_line_num: Option<&'a u32>,
}

// Function here helps in picking consistent field names for different error variants.
fn log_request_failure_inner(request_failure: RequestFailureLogFields<'_>) {
    tracing::error!(
        activity_id = request_failure.activity_id,
        error_source = request_failure.error_source,
        error_message_loggable = request_failure.error_message_loggable,
        error_code = request_failure.error_code,
        sub_status = request_failure.sub_status,
        sub_status_code = request_failure.sub_status_code,
        error_hint = request_failure.error_hint,
        error_file_name = request_failure.error_file_name,
        error_file_line_num = request_failure.error_file_line_num,
        backtrace = ?request_failure.backtrace,
        "Request failure: error_source={{error_source}}, error_message_loggable={{error_message_loggable}}, error_code={{error_code}}, \
        sub_status={{sub_status}}, sub_status_code={{sub_status_code}}, \
        error_hint={{error_hint}}, error_file_name={{error_file_name}}, error_file_line_num={{error_file_line_num}} \
        backtrace={{backtrace}}.",
    )
}

/// The result type for all methods that can return an error
pub type Result<T> = std::result::Result<T, DocumentDBError>;

impl From<io::Error> for DocumentDBError {
    fn from(error: io::Error) -> Self {
        DocumentDBError::IoError(error, Backtrace::capture())
    }
}

impl From<tokio_postgres::Error> for DocumentDBError {
    fn from(error: tokio_postgres::Error) -> Self {
        DocumentDBError::PostgresError(error, Backtrace::capture())
    }
}

impl From<bson::raw::Error> for DocumentDBError {
    fn from(error: bson::raw::Error) -> Self {
        DocumentDBError::RawBsonError(error, Backtrace::capture())
    }
}

impl From<PoolError> for DocumentDBError {
    fn from(error: PoolError) -> Self {
        DocumentDBError::PoolError(error, Backtrace::capture())
    }
}

impl From<CreatePoolError> for DocumentDBError {
    fn from(error: CreatePoolError) -> Self {
        DocumentDBError::CreatePoolError(error, Backtrace::capture())
    }
}

impl From<BuildError> for DocumentDBError {
    fn from(error: BuildError) -> Self {
        DocumentDBError::BuildPoolError(error, Backtrace::capture())
    }
}

impl From<ErrorStack> for DocumentDBError {
    fn from(error: ErrorStack) -> Self {
        DocumentDBError::SSLErrorStack(error, Backtrace::capture())
    }
}

impl From<openssl::ssl::Error> for DocumentDBError {
    fn from(error: openssl::ssl::Error) -> Self {
        DocumentDBError::SSLError(error, Backtrace::capture())
    }
}

impl From<ValueAccessError> for DocumentDBError {
    fn from(error: ValueAccessError) -> Self {
        DocumentDBError::ValueAccessError(error, Backtrace::capture())
    }
}

impl Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

// Please keep this output PII free.
impl Display for DocumentDBError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            DocumentDBError::IoError(e, _) => {
                let error_message = e.to_string();
                write!(f, "I/O error while processing request: {error_message}")
            }
            DocumentDBError::DocumentDBError(code, _, error_message_loggable, _) => {
                write!(
                    f,
                    "Request failed with error code {code}, error_message_loggable: {error_message_loggable:?}."
                )
            }
            DocumentDBError::PostgresError(e, _) => {
                let error_message = e.to_string();
                write!(f, "Postgres operation failed: {error_message}")
            }
            DocumentDBError::PostgresDocumentDBError(code, _, _) => {
                write!(f, "Postgres operation failed with error code {code}")
            }
            DocumentDBError::PoolError(e, _) => {
                let error_message = e.to_string();
                write!(f, "Connection pool error: {error_message}")
            }
            DocumentDBError::CreatePoolError(e, _) => {
                let error_message = e.to_string();
                write!(f, "Unable to create connection pool: {error_message}")
            }
            DocumentDBError::BuildPoolError(e, _) => {
                let error_message = e.to_string();
                write!(f, "Unable to build connection pool: {error_message}")
            }
            DocumentDBError::RawBsonError(_, _) => {
                write!(f, "Invalid BSON error.")
            }
            DocumentDBError::SSLError(e, _) => {
                let error_message = e.to_string();
                write!(f, "TLS/SSL error: {error_message}")
            }
            DocumentDBError::SSLErrorStack(e, _) => {
                let error_message = e.to_string();
                write!(f, "TLS/SSL error: {error_message}")
            }
            DocumentDBError::ValueAccessError(_, _) => {
                write!(f, "value access error.")
            }
        }
    }
}

// Debug delegates to Display intentionally: we must not derive Debug because some variants
// contain PII. Display is already PII-safe,
// so reusing it here satisfies Debug bounds.
impl std::fmt::Debug for DocumentDBError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        Display::fmt(self, f)
    }
}
