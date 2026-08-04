/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/transaction.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use tokio_postgres::IsolationLevel;

use crate::{
    context::TransactionError,
    error::ErrorCode,
    postgres::{conn_mgmt::Connection, QueryCatalog},
};

#[derive(Debug)]
pub struct Transaction {
    conn: Arc<Connection>,
    pub committed: bool,
}

impl Transaction {
    /// # Errors
    /// Returns error if the operation fails.
    pub async fn start(
        conn: Arc<Connection>,
        isolation_level: IsolationLevel,
    ) -> Result<Self, TransactionError> {
        let isolation = match isolation_level {
            IsolationLevel::RepeatableRead => "REPEATABLE READ",
            IsolationLevel::ReadCommitted => "READ COMMITTED",
            other => {
                return Err(TransactionError::SimpleError(
                    ErrorCode::BadValue,
                    format!("Isolation level not supported: {other:?}"),
                ))
            }
        };

        // Marked before the statement is issued: if the batch fails partway or
        // the caller is cancelled, only a set flag triggers the rollback.
        conn.set_in_transaction(true);

        conn.batch_execute(&format!(
                "START TRANSACTION ISOLATION LEVEL {isolation}; SET LOCAL lock_timeout='20ms'; SET LOCAL citus.max_adaptive_executor_pool_size=1;"
            ))
            .await?;

        Ok(Self {
            conn,
            committed: false,
        })
    }

    #[must_use]
    pub fn get_connection(&self) -> Arc<Connection> {
        Arc::clone(&self.conn)
    }

    /// # Errors
    /// Returns error if the operation fails.
    ///
    /// A failed COMMIT leaves the in-transaction flag set: the caller may still
    /// abort, so the drop-time backstop stays armed.
    pub async fn commit(&mut self) -> Result<(), TransactionError> {
        self.conn.batch_execute("COMMIT").await?;
        self.conn.set_in_transaction(false);
        self.committed = true;
        Ok(())
    }

    /// # Errors
    /// Returns error if the operation fails.
    pub async fn abort(&mut self) -> Result<(), TransactionError> {
        self.conn.batch_execute("ROLLBACK").await?;
        self.conn.set_in_transaction(false);
        self.committed = true;
        Ok(())
    }

    /// # Errors
    /// Returns error if the operation fails.
    pub async fn allow_writes_in_readonly(
        &self,
        query_catalog: &QueryCatalog,
    ) -> Result<(), TransactionError> {
        self.conn
            .batch_execute(query_catalog.set_allow_write())
            .await?;
        Ok(())
    }
}
