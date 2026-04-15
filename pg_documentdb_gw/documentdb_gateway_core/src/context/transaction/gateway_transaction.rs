/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/transaction/gateway_transaction.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;
use tokio_postgres::IsolationLevel;

use crate::context::transaction::TransactionNumber;
use crate::{
    configuration::DynamicConfiguration,
    context::{CursorStore, SessionId},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{self, conn_mgmt::Connection},
};

#[derive(Debug)]
pub struct RequestTransactionInfo {
    pub transaction_number: TransactionNumber,
    pub auto_commit: bool,
    pub start_transaction: bool,
    pub is_request_within_transaction: bool,
    pub isolation_level: Option<IsolationLevel>,
}

#[derive(Debug)]
pub struct GatewayTransaction {
    pub session_id: SessionId,
    pub transaction_number: TransactionNumber,
    pub cursors: CursorStore,
    pg_transaction: Option<postgres::Transaction>,
}

impl GatewayTransaction {
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub async fn start(
        config: Arc<dyn DynamicConfiguration>,
        request: &RequestTransactionInfo,
        conn: Arc<Connection>,
        isolation_level: IsolationLevel,
        session_id: SessionId,
    ) -> Result<Self> {
        Ok(Self {
            session_id,
            transaction_number: request.transaction_number,
            pg_transaction: Some(postgres::Transaction::start(conn, isolation_level).await?),
            cursors: CursorStore::new(config, false),
        })
    }

    #[must_use]
    pub fn get_connection(&self) -> Option<Arc<Connection>> {
        self.pg_transaction
            .as_ref()
            .map(postgres::Transaction::get_connection)
    }

    #[must_use]
    pub const fn get_session_id(&self) -> &SessionId {
        &self.session_id
    }

    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub async fn commit(&mut self) -> Result<()> {
        self.pg_transaction
            .as_mut()
            .ok_or_else(|| {
                DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    "No transaction found to commit".to_owned(),
                )
            })?
            .commit()
            .await
    }

    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub async fn abort(&mut self) -> Result<()> {
        self.pg_transaction
            .as_mut()
            .ok_or_else(|| {
                DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    "No transaction found to abort".to_owned(),
                )
            })?
            .abort()
            .await
    }

    #[must_use]
    pub const fn transaction_number(&self) -> TransactionNumber {
        self.transaction_number
    }
}

impl Drop for GatewayTransaction {
    fn drop(&mut self) {
        if let Some(inner) = &self.pg_transaction {
            if !inner.committed {
                let mut this = None;
                std::mem::swap(&mut this, &mut self.pg_transaction);
                tokio::spawn(async move {
                    if let Some(mut t) = this {
                        if let Err(e) = t.abort().await {
                            tracing::error!("Failed to drop a transaction: {e}");
                        }
                    }
                });
            }
        }
    }
}
