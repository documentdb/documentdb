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
use crate::responses::{postgres_sqlstate_to_i32, CustomPgDbError};

documentdb_error_code_enum!();
documentdb_extensive_log_postgres_errors!();

#[derive(Debug, PartialEq, Eq, strum_macros::AsRefStr, strum_macros::Display)]
pub enum ErrorKind {
    Io,
    Gateway,
    Postgres,
    Pool,
    RawBson,
    Ssl,
}

struct ErrorInner {
    kind: ErrorKind,
    error_code: ErrorCode,
    error_message_user: String,
    error_message_internal: Option<String>,
    source: Option<Box<dyn std::error::Error + Send + Sync>>,
    backtrace: Backtrace,
}

pub struct DocumentDBError(Box<ErrorInner>);

impl DocumentDBError {
    #[must_use]
    pub fn kind(&self) -> &ErrorKind {
        &self.0.kind
    }

    #[must_use]
    pub const fn error_code(&self) -> ErrorCode {
        self.0.error_code
    }

    /// Returns the HTTP status code corresponding to this error's error code.
    #[must_use]
    pub const fn http_status_code(&self) -> u16 {
        match self.0.error_code {
            ErrorCode::AuthenticationFailed => 401,
            ErrorCode::Unauthorized => 403,
            ErrorCode::InternalError => 500,
            ErrorCode::ExceededTimeLimit => 408,
            ErrorCode::DuplicateKey => 409,
            _ => 400,
        }
    }

    /// Returns the sub-status code derived from the underlying `PostgreSQL`
    /// `SqlState`, if one is available.
    #[must_use]
    pub fn sub_status_code(&self) -> Option<i32> {
        if let Some(db_error) = self.as_db_error() {
            return Some(postgres_sqlstate_to_i32(db_error.code()));
        }

        if let Some(custom) = self
            .0
            .source
            .as_ref()
            .and_then(|s| s.downcast_ref::<CustomPgDbError>())
        {
            return Some(postgres_sqlstate_to_i32(custom.status_code()));
        }

        None
    }

    #[must_use]
    pub fn error_message_user(&self) -> &str {
        &self.0.error_message_user
    }

    #[must_use]
    pub fn error_message_internal(&self) -> Option<&str> {
        self.0.error_message_internal.as_deref()
    }

    #[must_use]
    pub fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.0
            .source
            .as_deref()
            .map(|source| source as &(dyn std::error::Error + 'static))
    }

    #[must_use = "backtrace is captured for diagnostic purposes"]
    pub const fn backtrace(&self) -> &Backtrace {
        &self.0.backtrace
    }

    #[must_use]
    pub fn as_postgres_error(&self) -> Option<&tokio_postgres::Error> {
        self.0
            .source
            .as_ref()
            .and_then(|source| source.downcast_ref::<tokio_postgres::Error>())
    }

    #[must_use]
    pub fn as_db_error(&self) -> Option<&tokio_postgres::error::DbError> {
        self.as_postgres_error()
            .and_then(tokio_postgres::Error::as_db_error)
    }

    #[must_use]
    pub fn as_io_error(&self) -> Option<&std::io::Error> {
        self.0
            .source
            .as_ref()
            .and_then(|source| source.downcast_ref::<std::io::Error>())
    }

    #[must_use]
    pub fn as_pool_error(&self) -> Option<&PoolError> {
        self.0
            .source
            .as_ref()
            .and_then(|source| source.downcast_ref::<PoolError>())
    }

    fn new_documentdb_error(
        error_code: ErrorCode,
        error_message_user: String,
        error_message_internal: Option<String>,
        source: Option<Box<dyn std::error::Error + Send + Sync>>,
        kind: ErrorKind,
    ) -> Self {
        Self(Box::new(ErrorInner {
            error_code,
            error_message_user,
            error_message_internal,
            backtrace: Backtrace::capture(),
            source,
            kind,
        }))
    }

    #[must_use]
    pub fn from_mapped_postgres_error(
        code: ErrorCode,
        message: &str,
        error_message_internal: Option<&str>,
        pg_error: tokio_postgres::Error,
    ) -> Self {
        Self::new_documentdb_error(
            code,
            message.to_owned(),
            error_message_internal.map(std::borrow::ToOwned::to_owned),
            Some(Box::new(pg_error)),
            ErrorKind::Postgres,
        )
    }

    #[must_use]
    pub fn from_mapped_custom_postgres_error(
        code: ErrorCode,
        error_message_user: &str,
        error_message_internal: Option<&str>,
        custom_pg_db_error: CustomPgDbError,
    ) -> Self {
        Self::new_documentdb_error(
            code,
            error_message_user.to_owned(),
            error_message_internal.map(std::borrow::ToOwned::to_owned),
            Some(Box::new(custom_pg_db_error)),
            ErrorKind::Postgres,
        )
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

    /// Authentication and Authorization are two different mechansisms this method is provided
    /// to ensure a clear separation of these concerns and informs what kind of error message
    /// to return to the client.
    #[must_use]
    pub fn not_authenticated(error_message_user: String) -> Self {
        Self::unauthorized(error_message_user)
    }

    #[must_use]
    pub fn unauthorized(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::Unauthorized,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn authentication_failed(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::AuthenticationFailed,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn authentication_failed_internal_error(
        error_message_user: String,
        error_message_internal: &str,
    ) -> Self {
        Self::new_documentdb_error(
            ErrorCode::AuthenticationFailed,
            error_message_user,
            Some(format!(
                "[Authentication][InternalServerError] {error_message_internal}"
            )),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn bad_value(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::BadValue,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn internal_error(error_message_internal: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            Some(error_message_internal),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn type_mismatch(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::TypeMismatch,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn user_not_found(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::UserNotFound,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn role_not_found(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::RoleNotFound,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn duplicate_user(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::Location51003,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn duplicate_role(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::Location51002,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn reauthentication_required(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::ReauthenticationRequired,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[expect(
        clippy::self_named_constructors,
        reason = "need to refactor as a separate change"
    )]
    #[must_use]
    pub fn documentdb_error(error_code: ErrorCode, error_message_user: String) -> Self {
        Self::new_documentdb_error(
            error_code,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn error_with_loggable_message(
        code: ErrorCode,
        error_message_user: &str,
        error_message_internal: &str,
    ) -> Self {
        Self::new_documentdb_error(
            code,
            error_message_user.to_owned(),
            Some(error_message_internal.to_owned()),
            None,
            ErrorKind::Gateway,
        )
    }

    #[must_use]
    pub fn command_not_supported(error_message_user: String) -> Self {
        Self::new_documentdb_error(
            ErrorCode::CommandNotSupported,
            error_message_user.clone(),
            Some(error_message_user),
            None,
            ErrorKind::Gateway,
        )
    }
}

/// The result type for all methods that can return an error
pub type Result<T> = std::result::Result<T, DocumentDBError>;

impl From<io::Error> for DocumentDBError {
    fn from(error: io::Error) -> Self {
        Self::new_documentdb_error(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            Some(error.to_string()),
            Some(Box::new(error)),
            ErrorKind::Io,
        )
    }
}

impl From<tokio_postgres::Error> for DocumentDBError {
    fn from(error: tokio_postgres::Error) -> Self {
        Self::new_documentdb_error(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            Some(error.to_string()),
            Some(Box::new(error)),
            ErrorKind::Postgres,
        )
    }
}

impl From<bson::raw::Error> for DocumentDBError {
    fn from(error: bson::raw::Error) -> Self {
        Self::new_documentdb_error(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            Some(error.to_string()),
            None,
            ErrorKind::RawBson,
        )
    }
}

impl From<PoolError> for DocumentDBError {
    fn from(error: PoolError) -> Self {
        Self::new_documentdb_error(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            Some(error.to_string()),
            Some(Box::new(error)),
            ErrorKind::Pool,
        )
    }
}

impl From<CreatePoolError> for DocumentDBError {
    fn from(error: CreatePoolError) -> Self {
        Self::new_documentdb_error(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            Some(error.to_string()),
            None,
            ErrorKind::Pool,
        )
    }
}

impl From<BuildError> for DocumentDBError {
    fn from(error: BuildError) -> Self {
        Self::new_documentdb_error(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            Some(error.to_string()),
            None,
            ErrorKind::Pool,
        )
    }
}

impl From<ErrorStack> for DocumentDBError {
    fn from(error: ErrorStack) -> Self {
        Self::new_documentdb_error(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            Some(error.to_string()),
            None,
            ErrorKind::Ssl,
        )
    }
}

impl From<openssl::ssl::Error> for DocumentDBError {
    fn from(error: openssl::ssl::Error) -> Self {
        Self::new_documentdb_error(
            ErrorCode::InternalError,
            generic_internal_error_message().to_owned(),
            Some(error.to_string()),
            None,
            ErrorKind::Ssl,
        )
    }
}

// Please keep this output PII free.
impl Display for DocumentDBError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        fmt_error_kind_pii_safe(self, f)
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

fn fmt_error_kind_pii_safe(
    error: &DocumentDBError,
    f: &mut std::fmt::Formatter<'_>,
) -> std::fmt::Result {
    let kind = error.kind();
    let error_code = error.error_code();
    let error_message_internal = error
        .error_message_internal()
        .unwrap_or("no_internal_message");
    if let Some(db_error) = error.as_db_error() {
        write!(
            f,
            "Request failed with kind {kind}, code {error_code}, error_message_internal: {error_message_internal}, db_error_code: {}, db_error_hint: {}, db_error_file: {}, db_error_line: {}",
            db_error.code().code(),
            db_error.hint().unwrap_or_default(),
            db_error.file().unwrap_or("not_found"),
            db_error.line().unwrap_or_default()
        )
    } else {
        write!(
            f,
            "Request failed with kind {kind}, code {error_code}, error_message_internal: {error_message_internal}"
        )
    }
}

impl std::error::Error for DocumentDBError {}
