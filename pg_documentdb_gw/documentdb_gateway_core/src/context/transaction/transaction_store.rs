/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/transaction/transaction_store.rs
 *
 *-------------------------------------------------------------------------
 */

use dashmap::DashMap;
use std::sync::Arc;
use tokio::{
    task::JoinHandle,
    time::{Duration, Instant},
};
use tokio_postgres::IsolationLevel;

use crate::context::transaction::{GatewayTransaction, RequestTransactionInfo, TransactionNumber};
use crate::{
    context::{ConnectionContext, SessionId},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{conn_mgmt::Connection, PgDataClient},
};

#[derive(Debug, PartialEq)]
enum TransactionState {
    Started,
    Committed,
    Aborted,
}

#[derive(Debug)]
struct LastSeenTransaction {
    transaction_number: TransactionNumber,
    state: TransactionState,
}

impl LastSeenTransaction {
    pub const fn new(transaction_number: TransactionNumber) -> Self {
        Self {
            transaction_number,
            state: TransactionState::Started,
        }
    }
}

type TransactionEntry = (Instant, GatewayTransaction);

#[derive(Debug)]
pub struct TransactionStore {
    pub transactions: Arc<DashMap<SessionId, TransactionEntry>>,
    last_seen_transactions: DashMap<SessionId, LastSeenTransaction>,
    _reaper: JoinHandle<()>,
}

impl TransactionStore {
    #[must_use]
    pub fn new(expiration: Duration) -> Self {
        let transactions = Arc::new(DashMap::new());
        Self {
            transactions: Arc::clone(&transactions),
            last_seen_transactions: DashMap::new(),
            _reaper: tokio::spawn(async move {
                let mut interval = tokio::time::interval(expiration / 2);
                loop {
                    interval.tick().await;
                    transactions.retain(|_, (time, _)| time.elapsed() < expiration);
                }
            }),
        }
    }

    #[must_use]
    pub fn get_connection(&self, session_id: &SessionId) -> Option<Arc<Connection>> {
        self.transactions
            .get(session_id)
            .and_then(|entry| entry.value().1.get_connection())
    }

    /// # Errors
    ///
    /// Returns an error if the operation fails.
    #[expect(clippy::too_many_lines, reason = "complex transaction logic")]
    pub async fn create(
        &self,
        connection_context: &ConnectionContext,
        transaction_info: &RequestTransactionInfo,
        session_id: SessionId,
        pg_data_client: &impl PgDataClient,
    ) -> Result<()> {
        if let Some((_, transaction_number)) = connection_context.transaction.as_ref() {
            if transaction_number > &transaction_info.transaction_number {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::TransactionTooOld,
                    "Transaction number is lower than last seen transaction".to_owned(),
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
                        "This transaction is already started.".to_owned(),
                    ));
                }

                old_transaction.1.abort().await?;
            }

            let transaction = GatewayTransaction::start(
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
            return if transaction.transaction_number() == transaction_info.transaction_number {
                Ok(())
            } else {
                Err(DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    format!(
                        "Cannot continue transaction {}",
                        transaction_info.transaction_number
                    ),
                ))
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
                    "Cannot continue transaction {}",
                    transaction_info.transaction_number
                ),
            ))
        }
    }

    /// Removes the active transaction for `session_id`, aborts it, and marks the
    /// last-seen transaction as aborted.
    ///
    /// Returns `Ok(None)` when there is no active transaction for the session.
    ///
    /// # Errors
    ///
    /// Returns `ErrorCode::NoSuchTransaction` if the transaction is found but the
    /// last-seen record is missing, or if aborting the transaction fails.
    pub async fn remove_transaction_by_session(
        &self,
        session_id: &SessionId,
    ) -> Result<Option<(SessionId, TransactionEntry)>> {
        let Some((deleted_sessions_id, mut transaction_entry)) =
            self.transactions.remove(session_id)
        else {
            return Ok(None);
        };

        transaction_entry.1.abort().await?;
        self.last_seen_transactions
            .get_mut(session_id)
            .map(|mut last_seen| last_seen.state = TransactionState::Aborted)
            .ok_or_else(|| {
                DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    "Last seen transaction should always exist for an existing transaction"
                        .to_owned(),
                )
            })?;

        Ok(Some((deleted_sessions_id, transaction_entry)))
    }

    /// Aborts and removes the active transaction for `session_id`.
    ///
    /// # Errors
    ///
    /// Returns `ErrorCode::NoSuchTransaction` when there is no active
    /// transaction for the session or when the removal fails.
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub async fn abort(&self, session_id: &SessionId) -> Result<()> {
        self.remove_transaction_by_session(session_id)
            .await?
            .map(|_| ())
            .ok_or_else(|| {
                DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    "No such transaction to abort".to_owned(),
                )
            })
    }

    /// Commits a transaction
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub async fn commit(&self, session_id: &SessionId) -> Result<()> {
        if let Some((_, (_, mut transaction))) = self.transactions.remove(session_id) {
            transaction.commit().await?;
            if let Some(mut last_seen) = self.last_seen_transactions.get_mut(session_id) {
                last_seen.state = TransactionState::Committed;
            } else {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    "Last seen transaction should always exist for an existing transaction"
                        .to_owned(),
                ));
            }
            Ok(())
        } else {
            Err(DocumentDBError::documentdb_error(
                ErrorCode::NoSuchTransaction,
                "No such transaction to commit".to_owned(),
            ))
        }
    }
}
