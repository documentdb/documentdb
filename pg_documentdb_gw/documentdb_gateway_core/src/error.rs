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

use crate::responses::constant::{
    generic_internal_error_message, pg_returned_invalid_response_message,
};

documentdb_error_code_enum!();
documentdb_extensive_log_postgres_errors!();

pub enum ErrorKind {
    IoError(io::Error, Backtrace),
    DocumentDBError(
        ErrorCode,
        String, // Error message shown to user. This should not be logged as it may contain PII.
        Option<String>, // Error message for logging, must be PII free.
        Backtrace,
    ),
    PostgresError(tokio_postgres::Error, Backtrace),
    PostgresDocumentDBError(i32, String, Backtrace),
    PoolError(PoolError, Backtrace),
    CreatePoolError(CreatePoolError, Backtrace),
    BuildPoolError(BuildError, Backtrace),
    RawBsonError(bson::raw::Error, Backtrace),
    SSLError(openssl::ssl::Error, Backtrace),
    SSLErrorStack(ErrorStack, Backtrace),
}

pub struct DocumentDBError(Box<ErrorKind>);

impl DocumentDBError {
    #[must_use]
    pub fn new(document_db_error: ErrorKind) -> Self {
        Self(Box::new(document_db_error))
    }

    #[must_use]
    pub const fn kind(&self) -> &ErrorKind {
        &self.0
    }

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
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::Unauthorized,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn authentication_failed(msg: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::AuthenticationFailed,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn authentication_failed_with_custom_log(msg: String, message_log: &str) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::AuthenticationFailed,
            msg,
            Some(message_log.to_owned()),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn bad_value(msg: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::BadValue,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn internal_error(message_log: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            message_log.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn type_mismatch(msg: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::TypeMismatch,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn user_not_found(msg: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::UserNotFound,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn role_not_found(msg: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::RoleNotFound,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn duplicate_user(msg: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::Location51003,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn duplicate_role(msg: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::Location51002,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn reauthentication_required(msg: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::ReauthenticationRequired,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }

    #[expect(
        clippy::self_named_constructors,
        reason = "need to refactor as a separate change"
    )]
    #[must_use]
    pub fn documentdb_error(error_code: ErrorCode, error_message: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            error_code,
            error_message.clone(),
            error_message.into(),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub fn error_with_loggable_message(
        code: ErrorCode,
        message: &str,
        error_message_loggable: &str,
    ) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            code,
            message.to_owned(),
            Some(error_message_loggable.to_owned()),
            Backtrace::capture(),
        ))
    }

    #[must_use]
    pub const fn error_code_enum(&self) -> Option<ErrorCode> {
        match self.kind() {
            ErrorKind::DocumentDBError(code, _, _, _) => Some(*code),
            _ => None,
        }
    }

    #[must_use]
    pub fn command_not_supported(msg: String) -> Self {
        Self::new(ErrorKind::DocumentDBError(
            ErrorCode::CommandNotSupported,
            msg.clone(),
            msg.into(),
            Backtrace::capture(),
        ))
    }
}

/// The result type for all methods that can return an error
pub type Result<T> = std::result::Result<T, DocumentDBError>;

impl From<io::Error> for DocumentDBError {
    fn from(error: io::Error) -> Self {
        Self::new(ErrorKind::IoError(error, Backtrace::capture()))
    }
}

impl From<tokio_postgres::Error> for DocumentDBError {
    fn from(error: tokio_postgres::Error) -> Self {
        Self::new(ErrorKind::PostgresError(error, Backtrace::capture()))
    }
}

impl From<bson::raw::Error> for DocumentDBError {
    fn from(error: bson::raw::Error) -> Self {
        Self::new(ErrorKind::RawBsonError(error, Backtrace::capture()))
    }
}

impl From<PoolError> for DocumentDBError {
    fn from(error: PoolError) -> Self {
        Self::new(ErrorKind::PoolError(error, Backtrace::capture()))
    }
}

impl From<CreatePoolError> for DocumentDBError {
    fn from(error: CreatePoolError) -> Self {
        Self::new(ErrorKind::CreatePoolError(error, Backtrace::capture()))
    }
}

impl From<BuildError> for DocumentDBError {
    fn from(error: BuildError) -> Self {
        Self::new(ErrorKind::BuildPoolError(error, Backtrace::capture()))
    }
}

impl From<ErrorStack> for DocumentDBError {
    fn from(error: ErrorStack) -> Self {
        Self::new(ErrorKind::SSLErrorStack(error, Backtrace::capture()))
    }
}

impl From<openssl::ssl::Error> for DocumentDBError {
    fn from(error: openssl::ssl::Error) -> Self {
        Self::new(ErrorKind::SSLError(error, Backtrace::capture()))
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
        fmt_error_kind_pii_safe(self.kind(), f)
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

impl std::fmt::Debug for ErrorKind {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        fmt_error_kind_pii_safe(self, f)
    }
}

fn fmt_error_kind_pii_safe(
    error_kind: &ErrorKind,
    f: &mut std::fmt::Formatter<'_>,
) -> std::fmt::Result {
    match error_kind {
        ErrorKind::IoError(e, _) => {
            write!(f, "I/O error while processing request: {e}")
        }
        ErrorKind::DocumentDBError(code, _, error_message_loggable, _) => {
            let msg = error_message_loggable.as_deref().unwrap_or("None");
            write!(
                f,
                "Request failed with error code {code}, error_message_loggable: {msg}"
            )
        }
        ErrorKind::PostgresError(e, _) => {
            let error_message = match e.as_db_error() {
                Some(db_error) => format!(
                    "Postgres db error, code={}, hint={}, file={}, line={}",
                    db_error.code().code(),
                    db_error.hint().unwrap_or("None"),
                    db_error.file().unwrap_or("None"),
                    db_error.line().unwrap_or(0),
                ),
                None => e.to_string(),
            };
            write!(f, "Postgres operation failed: {error_message}")
        }
        ErrorKind::PostgresDocumentDBError(code, _, _) => {
            write!(f, "Postgres operation failed with error code {code}")
        }
        ErrorKind::PoolError(e, _) => {
            write!(f, "Connection pool error: {e}")
        }
        ErrorKind::CreatePoolError(e, _) => {
            write!(f, "Unable to create connection pool: {e}")
        }
        ErrorKind::BuildPoolError(e, _) => {
            write!(f, "Unable to build connection pool: {e}")
        }
        ErrorKind::RawBsonError(e, _) => {
            write!(f, "Invalid BSON error: {e}")
        }
        ErrorKind::SSLError(e, _) => {
            write!(f, "TLS/SSL error: {e}")
        }
        ErrorKind::SSLErrorStack(e, _) => {
            write!(f, "TLS/SSL error: {e}")
        }
    }
}

impl std::error::Error for DocumentDBError {}
