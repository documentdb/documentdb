/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/transaction/transaction_error.rs
 *
 * SPDX-License-Identifier: MIT
 *-------------------------------------------------------------------------
 */

use std::fmt;

use crate::error::{DocumentDBError, ErrorCode};
use crate::responses::map_pg_error;

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
        TransactionError::PostgresError(pg_err) => {
            map_pg_error(pg_err, true, is_replica_cluster, activity_id)
        }
    }
}
