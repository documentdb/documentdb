/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/transaction/transaction_error.rs
 *
 * SPDX-License-Identifier: MIT
 *-------------------------------------------------------------------------
 */

use std::fmt;

use tokio_postgres::error::SqlState;

use crate::{
    error::{DocumentDBError, ErrorCode},
    postgres::conn_mgmt::StatementError,
    responses::map_pg_error,
};

/// Error type for transaction operations that defers PG error mapping
/// to the caller (typically `TransactionStore`).
#[derive(Debug)]
pub enum TransactionError {
    /// An application-level error with a known error code and user-facing message.
    SimpleError(ErrorCode, String),

    /// A raw `PostgreSQL` error from `tokio_postgres` that has not yet been
    /// mapped through [`map_pg_error`]. The caller is responsible for mapping
    /// this into a [`DocumentDBError`] with the appropriate context
    /// (`is_replica_cluster`, `activity_id`).
    PostgresError(tokio_postgres::Error),
}

impl fmt::Display for TransactionError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        match self {
            Self::SimpleError(code, msg) => {
                write!(f, "{code}: {msg}")
            }
            Self::PostgresError(e) => e.fmt(f),
        }
    }
}

impl std::error::Error for TransactionError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::SimpleError(..) => None,
            Self::PostgresError(e) => Some(e),
        }
    }
}

impl From<tokio_postgres::Error> for TransactionError {
    fn from(error: tokio_postgres::Error) -> Self {
        Self::PostgresError(error)
    }
}

impl From<StatementError> for TransactionError {
    fn from(error: StatementError) -> Self {
        match error {
            StatementError::Postgres(e) => Self::PostgresError(e),
            StatementError::Timeout(d) => Self::SimpleError(
                ErrorCode::ExceededTimeLimit,
                format!("Transaction statement timed out after {d:?}"),
            ),
        }
    }
}

/// Maps a [`TransactionError`] into a [`DocumentDBError`], applying PG error
/// mapping with the given replica/activity context. The `in_transaction` flag
/// is always `true` since these errors originate from transaction operations.
#[must_use]
pub fn map_transaction_error(
    err: TransactionError,
    is_replica_cluster: bool,
    activity_id: &str,
) -> DocumentDBError {
    match err {
        TransactionError::SimpleError(code, msg) => DocumentDBError::documentdb_error(code, msg),
        TransactionError::PostgresError(pg_err)
            if transaction_backend_is_gone(pg_err.is_closed(), pg_err.code()) =>
        {
            DocumentDBError::documentdb_error(
                ErrorCode::NoSuchTransaction,
                "The transaction has been aborted because its backend session ended.".to_owned(),
            )
        }
        TransactionError::PostgresError(pg_err) => {
            map_pg_error(pg_err, true, is_replica_cluster, activity_id)
        }
    }
}

fn transaction_backend_is_gone(is_closed: bool, sql_state: Option<&SqlState>) -> bool {
    is_closed || sql_state == Some(&SqlState::IDLE_IN_TRANSACTION_SESSION_TIMEOUT)
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    /// A statement deadline expiry carries no `PostgreSQL` error, so it must be
    /// surfaced as an application-level `ExceededTimeLimit` rather than a
    /// `PostgresError`, and the message must report how long was waited.
    #[test]
    fn timed_out_statement_maps_to_exceeded_time_limit_transaction_error() {
        let deadline = Duration::from_secs(7);

        match TransactionError::from(StatementError::Timeout(deadline)) {
            TransactionError::SimpleError(ErrorCode::ExceededTimeLimit, message) => {
                assert!(
                    message.contains(&format!("{deadline:?}")),
                    "message should report the deadline, got {message:?}"
                );
            }
            other => panic!("timeout must map to SimpleError(ExceededTimeLimit, _), got {other:?}"),
        }
    }

    #[test]
    fn ended_transaction_backend_is_no_longer_resumable() {
        assert!(transaction_backend_is_gone(true, None));
        assert!(transaction_backend_is_gone(
            false,
            Some(&SqlState::IDLE_IN_TRANSACTION_SESSION_TIMEOUT)
        ));
        assert!(!transaction_backend_is_gone(
            false,
            Some(&SqlState::QUERY_CANCELED)
        ));
    }
}
