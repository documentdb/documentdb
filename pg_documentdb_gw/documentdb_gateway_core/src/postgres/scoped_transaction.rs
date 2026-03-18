/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/scoped_transaction.rs
 *
 * Lightweight transaction guard for per-closure transaction management.
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use crate::postgres::conn_mgmt::Connection;

/// Lightweight transaction guard for use within query closures.
///
/// If a transaction is already active on the connection (e.g., started by
/// the gateway timeout layer), this is a no-op wrapper.
/// Otherwise it starts a new `READ COMMITTED` transaction and will roll
/// it back on [`Drop`] if [`commit`](Self::commit) was not called.
#[derive(Debug)]
pub struct ScopedTransaction {
    /// Holds the connection only when *this* guard started the transaction.
    /// `None` means either no transaction was needed or it has already been
    /// committed.
    connection: Option<Arc<Connection>>,
}

impl ScopedTransaction {
    /// Start a `READ COMMITTED` transaction if one is not already active on
    /// `connection`.
    ///
    /// Returns a guard whose [`Drop`] implementation will issue a best-effort
    /// `ROLLBACK` if [`commit`](Self::commit) was never called.
    ///
    /// # Errors
    /// Returns a [`tokio_postgres::Error`] if issuing `START TRANSACTION` fails.
    pub async fn start_if_necessary(
        connection: &Arc<Connection>,
    ) -> std::result::Result<Self, tokio_postgres::Error> {
        if !connection.try_start_transaction() {
            return Ok(Self { connection: None });
        }

        connection
            .batch_execute("START TRANSACTION ISOLATION LEVEL READ COMMITTED")
            .await?;

        Ok(Self {
            connection: Some(Arc::clone(connection)),
        })
    }

    /// Commit the transaction.  No-op if this guard did not start one.
    ///
    /// On success the guard is disarmed (no `ROLLBACK` on drop).
    /// On failure the connection is left for [`Drop`] to roll back.
    ///
    /// # Errors
    /// Returns a [`tokio_postgres::Error`] if the `COMMIT` statement fails.
    pub async fn commit(&mut self) -> std::result::Result<(), tokio_postgres::Error> {
        if let Some(ref conn) = self.connection {
            conn.batch_execute("COMMIT").await?;
            conn.set_in_transaction(false);
        }
        self.connection = None;
        Ok(())
    }
}

impl Drop for ScopedTransaction {
    fn drop(&mut self) {
        if let Some(conn) = self.connection.take() {
            conn.set_in_transaction(false);
            // Best-effort async rollback — same pattern used by
            // context::Transaction::Drop for user-level transactions.
            if let Ok(handle) = tokio::runtime::Handle::try_current() {
                handle.spawn(async move {
                    if let Err(e) = conn.batch_execute("ROLLBACK").await {
                        tracing::error!("ScopedTransaction: failed to rollback on drop: {e}");
                    }
                });
            } else {
                tracing::error!("ScopedTransaction: no tokio runtime for rollback");
            }
        }
    }
}
