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
    error::{DocumentDBError, Result},
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
    pub async fn start(conn: Arc<Connection>, isolation_level: IsolationLevel) -> Result<Self> {
        let isolation = match isolation_level {
            IsolationLevel::RepeatableRead => "REPEATABLE READ",
            IsolationLevel::ReadCommitted => "READ COMMITTED",
            other => {
                return Err(DocumentDBError::bad_value(format!(
                    "Isolation level not supported: {other:?}"
                )))
            }
        };

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
    pub async fn commit(&mut self) -> Result<()> {
        self.conn.batch_execute("COMMIT").await?;
        self.committed = true;
        Ok(())
    }

    /// # Errors
    /// Returns error if the operation fails.
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub async fn abort(&mut self) -> Result<()> {
        self.conn.batch_execute("ROLLBACK").await?;
        self.committed = true;
        Ok(())
    }

    /// # Errors
    /// Returns error if the operation fails.
    pub async fn allow_writes_in_readonly(&self, query_catalog: &QueryCatalog) -> Result<()> {
        self.conn
            .batch_execute(query_catalog.set_allow_write())
            .await
            .map_err(DocumentDBError::from)
    }
}
