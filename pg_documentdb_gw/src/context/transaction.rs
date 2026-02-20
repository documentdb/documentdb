/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/context/transaction.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use dashmap::DashMap;
use tokio::{
    task::JoinHandle,
    time::{Duration, Instant},
};
use tokio_postgres::IsolationLevel;

use crate::{
    configuration::DynamicConfiguration,
    context::{ConnectionContext, CursorStore},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{self, Connection, PgDataClient},
};

#[derive(Debug)]
pub struct RequestTransactionInfo {
    pub transaction_number: i64,
    pub auto_commit: bool,
    pub start_transaction: bool,
    pub is_request_within_transaction: bool,
    pub isolation_level: Option<IsolationLevel>,
}

pub struct Transaction {
    pub session_id: Vec<u8>,
    pub transaction_number: i64,
    pub cursors: CursorStore,
    transaction: Option<postgres::Transaction>,
}

impl Transaction {
    pub async fn start(
        config: Arc<dyn DynamicConfiguration>,
        request: &RequestTransactionInfo,
        conn: Arc<Connection>,
        isolation_level: IsolationLevel,
        session_id: Vec<u8>,
    ) -> Result<Self> {
        Ok(Transaction {
            session_id,
            transaction_number: request.transaction_number,
            transaction: Some(postgres::Transaction::start(conn, isolation_level).await?),
            cursors: CursorStore::new(config, false),
        })
    }

    pub fn get_connection(&self) -> Option<Arc<Connection>> {
        self.transaction.as_ref().map(|t| t.get_connection())
    }

    pub fn get_session_id(&self) -> &[u8] {
        &self.session_id
    }

    pub async fn commit(&mut self) -> Result<()> {
        let t = self
            .transaction
            .as_mut()
            .ok_or(DocumentDBError::documentdb_error(
                ErrorCode::NoSuchTransaction,
                "No transaction found to commit".to_string(),
            ))?;
        t.commit().await
    }

    pub async fn abort(&mut self) -> Result<()> {
        let t = self
            .transaction
            .as_mut()
            .ok_or(DocumentDBError::documentdb_error(
                ErrorCode::NoSuchTransaction,
                "No transaction found to commit".to_string(),
            ))?;
        t.abort().await
    }

    pub fn transaction_number(&self) -> i64 {
        self.transaction_number
    }
}

impl Drop for Transaction {
    fn drop(&mut self) {
        if let Some(inner) = &self.transaction {
            if !inner.committed {
                let mut this = None;
                std::mem::swap(&mut this, &mut self.transaction);
                tokio::spawn(async move {
                    if let Some(mut t) = this {
                        if let Err(e) = t.abort().await {
                            tracing::error!("Failed to drop a transaction: {e}")
                        }
                    }
                });
            }
        }
    }
}

#[derive(Debug, PartialEq)]
enum TransactionState {
    Started,
    Committed,
    Aborted,
}

#[derive(Debug)]
struct LastSeenTransaction {
    transaction_number: i64,
    state: TransactionState,
}

impl LastSeenTransaction {
    pub fn new(transaction_number: i64) -> Self {
        LastSeenTransaction {
            transaction_number,
            state: TransactionState::Started,
        }
    }
}

type TransactionEntry = (Instant, Transaction);

pub struct TransactionStore {
    pub transactions: Arc<DashMap<Vec<u8>, TransactionEntry>>,
    last_seen_transactions: DashMap<Vec<u8>, LastSeenTransaction>,
    _reaper: JoinHandle<()>,
}

impl TransactionStore {
    pub fn new(expiration: Duration) -> Self {
        let transactions = Arc::new(DashMap::new());
        TransactionStore {
            transactions: transactions.clone(),
            last_seen_transactions: DashMap::new(),
            _reaper: tokio::spawn(async move {
                let mut interval = tokio::time::interval(expiration / 2);
                loop {
                    interval.tick().await;
                    transactions.retain(|_, (time, _)| time.elapsed() < expiration)
                }
            }),
        }
    }

    pub async fn get_connection(&self, session_id: &[u8]) -> Option<Arc<Connection>> {
        self.transactions
            .get(session_id)
            .and_then(|entry| entry.value().1.get_connection())
    }

    pub async fn create(
        &self,
        connection_context: &ConnectionContext,
        transaction_info: &RequestTransactionInfo,
        session_id: Vec<u8>,
        pg_data_client: &impl PgDataClient,
    ) -> Result<()> {
        if let Some((_, transaction_number)) = connection_context.transaction.as_ref() {
            if transaction_number > &transaction_info.transaction_number {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::TransactionTooOld,
                    "Transaction number is lower than last seen transaction".to_string(),
                ));
            }
        }

        if transaction_info.start_transaction && !transaction_info.auto_commit {
            if let Some(last_transaction) = self.last_seen_transactions.get(&session_id) {
                if last_transaction.transaction_number == transaction_info.transaction_number {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::ConflictingOperationInProgress,
                        match last_transaction.state {
                            TransactionState::Committed => format!(
                                "Transaction {} is already committed.",
                                transaction_info.transaction_number
                            ),
                            TransactionState::Aborted => format!(
                                "Transaction {} is already aborted.",
                                transaction_info.transaction_number
                            ),
                            TransactionState::Started => format!(
                                "Transaction {} is already started.",
                                transaction_info.transaction_number
                            ),
                        },
                    ));
                }
            }

            // Remove any existing transaction from this session
            if let Some((_, mut old_transaction)) = self.transactions.remove(&session_id) {
                if old_transaction.1.transaction_number == transaction_info.transaction_number {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::ConflictingOperationInProgress,
                        "This transaction is already started.".to_string(),
                    ));
                }

                old_transaction.1.abort().await?;
            }

            let transaction = Transaction::start(
                connection_context.service_context.dynamic_configuration(),
                transaction_info,
                Arc::new(
                    pg_data_client
                        .pull_connection_with_transaction(true)
                        .await?,
                ),
                transaction_info
                    .isolation_level
                    .unwrap_or(IsolationLevel::ReadCommitted),
                session_id.clone(),
            )
            .await?;

            self.last_seen_transactions.insert(
                session_id.clone(),
                LastSeenTransaction::new(transaction.transaction_number()),
            );
            self.transactions
                .insert(session_id, (Instant::now(), transaction));

            return Ok(());
        }

        if let Some(transaction_entry) = self.transactions.get(&session_id) {
            let transaction = &transaction_entry.value().1;
            return if transaction.transaction_number() != transaction_info.transaction_number {
                Err(DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    format!(
                        "Given transaction number {} does not match any in-progress transactions.",
                        transaction_info.transaction_number
                    ),
                ))
            } else {
                Ok(())
            };
        }

        if self
            .last_seen_transactions
            .get(&session_id)
            .is_some_and(|s| {
                s.transaction_number == transaction_info.transaction_number
                    && s.state == TransactionState::Committed
            })
        {
            Err(DocumentDBError::documentdb_error(
                ErrorCode::TransactionCommitted,
                format!(
                    "Transaction {} already committed",
                    transaction_info.transaction_number
                ),
            ))
        } else {
            Err(DocumentDBError::documentdb_error(
                ErrorCode::NoSuchTransaction,
                format!(
                    "Given transaction number {} does not match any in-progress transactions.",
                    transaction_info.transaction_number
                ),
            ))
        }
    }

    pub async fn abort(&self, session_id: &[u8]) -> Result<()> {
        if let Some((_, (_, mut transaction))) = self.transactions.remove(session_id) {
            transaction.abort().await?;
            if let Some(mut last_seen) = self.last_seen_transactions.get_mut(session_id) {
                last_seen.state = TransactionState::Aborted;
            } else {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    "Last seen transaction should always exist for an existing transaction"
                        .to_string(),
                ));
            }
            Ok(())
        } else {
            Err(DocumentDBError::documentdb_error(
                ErrorCode::NoSuchTransaction,
                "No such transaction to abort".to_string(),
            ))
        }
    }

    pub async fn commit(&self, session_id: &[u8]) -> Result<()> {
        if let Some((_, (_, mut transaction))) = self.transactions.remove(session_id) {
            transaction.commit().await?;
            if let Some(mut last_seen) = self.last_seen_transactions.get_mut(session_id) {
                last_seen.state = TransactionState::Committed;
            } else {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    "Last seen transaction should always exist for an existing transaction"
                        .to_string(),
                ));
            }
            Ok(())
        } else {
            Err(DocumentDBError::documentdb_error(
                ErrorCode::NoSuchTransaction,
                "No such transaction to commit".to_string(),
            ))
        }
    }
}
