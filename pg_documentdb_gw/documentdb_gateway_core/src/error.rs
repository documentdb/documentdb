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
use documentdb_macros::{documentdb_error_code_enum, documentdb_extensive_log_postgres_errors};
use openssl::error::ErrorStack;
use tokio_postgres::error::SqlState;

use crate::{
    context::ConnectionContext,
    responses::{self, constant::pg_returned_invalid_response_message},
};

documentdb_error_code_enum!();
documentdb_extensive_log_postgres_errors!();

pub enum DocumentDBError {
    IoError(io::Error, Backtrace),
    #[expect(clippy::enum_variant_names, reason = "variant name should be changed")]
    DocumentDBError(
        ErrorCode,
        String, // Error message shown to user. This should not be logged as it may contain PII.
        Option<String>, // Error message for logging, must be PII free.
        Backtrace,
    ),
    PostgresError(tokio_postgres::Error, Backtrace),
    #[expect(
        clippy::enum_variant_names,
        reason = "variant name matches type name for clarity"
    )]
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
        move |e| Self::bad_value(format!("Failed to parse: {e}"))
    }

    #[must_use]
    pub fn pg_response_empty() -> Self {
        Self::internal_error("PG returned no rows in response".to_owned())
    }

    #[must_use]
    pub fn pg_response_invalid(e: ValueAccessError) -> Self {
        Self::internal_error(pg_returned_invalid_response_message(e))
    }

    #[must_use]
    pub fn sasl_payload_invalid() -> Self {
        Self::authentication_failed("Sasl payload invalid.".to_owned())
    }

    #[must_use]
    pub fn unauthorized(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::Unauthorized,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn authentication_failed(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::AuthenticationFailed,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn bad_value(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::BadValue,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn internal_error(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::InternalError,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn type_mismatch(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::TypeMismatch,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn user_not_found(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::UserNotFound,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn role_not_found(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::RoleNotFound,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn duplicate_user(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::Location51003,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn duplicate_role(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::Location51002,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn reauthentication_required(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::ReauthenticationRequired,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    #[expect(
        clippy::self_named_constructors,
        reason = "need to refactor as a separate change"
    )]
    #[must_use]
    pub fn documentdb_error(error_code: ErrorCode, error_message: String) -> Self {
        Self::DocumentDBError(
            error_code,
            error_message.clone(),
            error_message.into(),
            Backtrace::capture(),
        )
    }

    #[must_use]
    pub fn error_with_loggable_message(
        code: ErrorCode,
        message: &str,
        error_message_loggable: &str,
    ) -> Self {
        Self::DocumentDBError(
            code,
            message.to_owned(),
            Some(error_message_loggable.to_owned()),
            Backtrace::capture(),
        )
    }

    pub const fn error_code_enum(&self) -> Option<ErrorCode> {
        match self {
            Self::DocumentDBError(code, _, _, _) => Some(*code),
            _ => None,
        }
    }

    #[must_use]
    pub fn command_not_supported(msg: String) -> Self {
        Self::DocumentDBError(
            ErrorCode::CommandNotSupported,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        )
    }

    // Logs error with common format for all DocumentDBErrors on request failure.
    // The logged output here must be PII free and is used for telemetry and logging.
    #[expect(
        clippy::too_many_lines,
        reason = "complex logic that would lose clarity if split"
    )]
    pub fn log_request_failure(&self, connection_context: &ConnectionContext, activity_id: &str) {
        match self {
            Self::IoError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "IoError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                });
            }
            Self::DocumentDBError(code, _msg, error_message_loggable, backtrace) => {
                let error_code = *code as i32;
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "DocumentDBError",
                    backtrace: Some(backtrace),
                    error_message_loggable: error_message_loggable.as_deref(),
                    error_code: Some(&error_code),
                    ..Default::default()
                });
            }
            Self::PostgresError(error, backtrace) => {
                if let Some(dbe) = error.as_db_error() {
                    if should_log_on_postgres_error(dbe.code()) {
                        tracing::error!(
                            activity_id = activity_id,
                            dbe = ?dbe,
                            "Postgres error with debug info: {{dbe}}."
                        );
                    }

                    let error_message_loggable = responses::known_pg_error(
                        connection_context,
                        dbe.code(),
                        dbe.message(),
                        activity_id,
                    )
                    .internal_note();

                    log_request_failure_inner(&RequestFailureLogFields {
                        activity_id,
                        error_source: "PostgresError",
                        backtrace: Some(backtrace),
                        error_message_loggable,
                        sub_status: Some(dbe.code().code()),
                        sub_status_code: Some(&responses::postgres_sqlstate_to_i32(dbe.code())),
                        error_hint: dbe.hint(),
                        error_file_name: dbe.file(),
                        error_file_line_num: dbe.line().as_ref(),
                        ..Default::default()
                    });
                } else {
                    let error_message_loggable = error.to_string();
                    log_request_failure_inner(&RequestFailureLogFields {
                        activity_id,
                        error_source: "PostgresError",
                        backtrace: Some(backtrace),
                        error_message_loggable: Some(error_message_loggable.as_str()),
                        ..Default::default()
                    });
                }
            }
            Self::PostgresDocumentDBError(pg_code, msg, backtrace) => {
                let (sql_state, error_message_loggable): (Option<SqlState>, Option<String>) =
                    match responses::i32_to_postgres_sqlstate(*pg_code) {
                        Ok(state) => {
                            let mapped_response = responses::known_pg_error(
                                connection_context,
                                &state,
                                msg.as_str(),
                                activity_id,
                            );
                            (
                                Some(state.clone()),
                                mapped_response
                                    .internal_note()
                                    .map(std::borrow::ToOwned::to_owned),
                            )
                        }
                        Err(_) => (
                            None,
                            Some(format!(
                                "Unable to convert to Postgres SQLState code: {pg_code}"
                            )),
                        ),
                    };

                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "PostgresDocumentDBError",
                    backtrace: Some(backtrace),
                    error_message_loggable: error_message_loggable.as_deref(),
                    sub_status: sql_state
                        .as_ref()
                        .map(tokio_postgres::error::SqlState::code),
                    sub_status_code: Some(pg_code),
                    ..Default::default()
                });
            }
            Self::PoolError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "PoolError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                });
            }
            Self::CreatePoolError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "CreatePoolError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                });
            }
            Self::BuildPoolError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "BuildPoolError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                });
            }
            Self::RawBsonError(_error, backtrace) => {
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "RawBsonError",
                    backtrace: Some(backtrace),
                    ..Default::default()
                });
            }
            Self::SSLError(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "SSLError",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                });
            }
            Self::SSLErrorStack(error, backtrace) => {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "SSLErrorStack",
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                });
            }
            Self::ValueAccessError(_error, backtrace) => {
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "ValueAccessError",
                    backtrace: Some(backtrace),
                    ..Default::default()
                });
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
fn log_request_failure_inner(request_failure: &RequestFailureLogFields<'_>) {
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
    );
}

/// The result type for all methods that can return an error
pub type Result<T> = std::result::Result<T, DocumentDBError>;

impl From<io::Error> for DocumentDBError {
    fn from(error: io::Error) -> Self {
        Self::IoError(error, Backtrace::capture())
    }
}

impl From<tokio_postgres::Error> for DocumentDBError {
    fn from(error: tokio_postgres::Error) -> Self {
        Self::PostgresError(error, Backtrace::capture())
    }
}

impl From<bson::raw::Error> for DocumentDBError {
    fn from(error: bson::raw::Error) -> Self {
        Self::RawBsonError(error, Backtrace::capture())
    }
}

impl From<PoolError> for DocumentDBError {
    fn from(error: PoolError) -> Self {
        Self::PoolError(error, Backtrace::capture())
    }
}

impl From<CreatePoolError> for DocumentDBError {
    fn from(error: CreatePoolError) -> Self {
        Self::CreatePoolError(error, Backtrace::capture())
    }
}

impl From<BuildError> for DocumentDBError {
    fn from(error: BuildError) -> Self {
        Self::BuildPoolError(error, Backtrace::capture())
    }
}

impl From<ErrorStack> for DocumentDBError {
    fn from(error: ErrorStack) -> Self {
        Self::SSLErrorStack(error, Backtrace::capture())
    }
}

impl From<openssl::ssl::Error> for DocumentDBError {
    fn from(error: openssl::ssl::Error) -> Self {
        Self::SSLError(error, Backtrace::capture())
    }
}

impl From<ValueAccessError> for DocumentDBError {
    fn from(error: ValueAccessError) -> Self {
        Self::ValueAccessError(error, Backtrace::capture())
    }
}

#[expect(
    clippy::use_debug,
    reason = "debug formatting for Display implementation"
)]
impl Display for ErrorCode {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{self:?}")
    }
}

// Please keep this output PII free.
impl Display for DocumentDBError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::IoError(e, _) => {
                let error_message = e.to_string();
                write!(f, "I/O error while processing request: {error_message}")
            }
            Self::DocumentDBError(code, _, error_message_loggable, _) => {
                let msg = error_message_loggable.as_deref().unwrap_or("None");
                write!(
                    f,
                    "Request failed with error code {code}, error_message_loggable: {msg}."
                )
            }
            Self::PostgresError(e, _) => {
                let error_message = e.to_string();
                write!(f, "Postgres operation failed: {error_message}")
            }
            Self::PostgresDocumentDBError(code, _, _) => {
                write!(f, "Postgres operation failed with error code {code}")
            }
            Self::PoolError(e, _) => {
                let error_message = e.to_string();
                write!(f, "Connection pool error: {error_message}")
            }
            Self::CreatePoolError(e, _) => {
                let error_message = e.to_string();
                write!(f, "Unable to create connection pool: {error_message}")
            }
            Self::BuildPoolError(e, _) => {
                let error_message = e.to_string();
                write!(f, "Unable to build connection pool: {error_message}")
            }
            Self::RawBsonError(_, _) => {
                write!(f, "Invalid BSON error.")
            }
            Self::SSLError(e, _) => {
                let error_message = e.to_string();
                write!(f, "TLS/SSL error: {error_message}")
            }
            Self::SSLErrorStack(e, _) => {
                let error_message = e.to_string();
                write!(f, "TLS/SSL error: {error_message}")
            }
            Self::ValueAccessError(_, _) => {
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

impl std::error::Error for DocumentDBError {}
