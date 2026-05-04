/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/transaction/transaction_store.rs
 *
 *-------------------------------------------------------------------------
 */

use dashmap::DashMap;
use std::sync::Arc;
use tokio::time::Duration;
use tokio_postgres::IsolationLevel;

use crate::{
    collections::cache::{AsyncCache, CacheConfiguration, TtlCache},
    context::{
        session::SessionKey,
        transaction::{GatewayTransaction, RequestTransactionInfo},
        TransactionNumber,
    },
    security::principal::Principal,
    time::EpochClock,
};
use crate::{
    context::{ConnectionContext, SessionId},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{conn_mgmt::Connection, PgDataClient},
};

#[derive(Debug, PartialEq, Eq, Copy, Clone)]
enum TransactionState {
    Started,
    Committed,
    Aborted,
}

#[derive(Debug, PartialEq, Eq, Copy, Clone)]
pub struct LastSeenTransaction {
    transaction_number: TransactionNumber,
    state: TransactionState,
}

impl LastSeenTransaction {
    const fn with_state(transaction_number: TransactionNumber, state: TransactionState) -> Self {
        Self {
            transaction_number,
            state,
        }
    }

    pub const fn started(transaction_number: TransactionNumber) -> Self {
        Self::with_state(transaction_number, TransactionState::Started)
    }

    pub const fn committed(transaction_number: TransactionNumber) -> Self {
        Self::with_state(transaction_number, TransactionState::Committed)
    }

    pub const fn aborted(transaction_number: TransactionNumber) -> Self {
        Self::with_state(transaction_number, TransactionState::Aborted)
    }
}

type TransactionEntry = (u64, GatewayTransaction);

#[derive(Debug)]
pub struct TransactionStore {
    pub transactions: Arc<DashMap<SessionKey, TransactionEntry>>,
    last_seen_transactions: Arc<TtlCache<SessionKey, LastSeenTransaction>>,
    default_ttl: Duration,
}

impl TransactionStore {
    #[must_use]
    pub fn new(default_ttl: Duration) -> Self {
        let transactions = Arc::new(DashMap::new());
        let last_seen_transactions =
            Arc::new(TtlCache::new(CacheConfiguration::with_ttl(default_ttl)));

        Self {
            default_ttl,
            transactions: Arc::clone(&transactions),
            last_seen_transactions: Arc::clone(&last_seen_transactions),
        }
    }

    pub async fn evict_expired(&self) -> Vec<Arc<GatewayTransaction>> {
        let mut evicted = Vec::new();

        let expired_keys: Vec<SessionKey> = self
            .transactions
            .iter()
            .filter_map(|entry| {
                (EpochClock::almost_now_timestamp() >= entry.value().0).then(|| entry.key().clone())
            })
            .collect();

        for key in expired_keys {
            if let Some((_, (_, transaction))) = self.transactions.remove(&key) {
                evicted.push(Arc::new(transaction));
            }
        }

        let _ = self.last_seen_transactions.evict_expired_async().await;

        evicted
    }

    #[must_use]
    pub fn get_connection(
        &self,
        session_id: &SessionId,
        caller: &Principal,
    ) -> Option<Arc<Connection>> {
        let key = SessionKey::new(session_id.clone(), caller.clone());

        self.transactions
            .get(&key)
            .and_then(|entry| entry.value().1.get_connection())
    }

    /// # Errors
    ///
    /// Returns an error if the operation fails.
    #[expect(
        clippy::too_many_lines,
        reason = "This function is long due to the number of checks and operations required to create a transaction."
    )]
    pub async fn create(
        &self,
        connection_context: &ConnectionContext,
        transaction_info: &RequestTransactionInfo,
        session_id: SessionId,
        pg_data_client: &impl PgDataClient,
        caller: &Principal,
    ) -> Result<()> {
        let key = SessionKey::new(session_id.clone(), caller.clone());

        if let Some((_, transaction_number)) = connection_context.transaction.as_ref() {
            if transaction_number > &transaction_info.transaction_number {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::TransactionTooOld,
                    "Transaction number is lower than last seen transaction".to_owned(),
                    0,
                ));
            }
        }

        if transaction_info.start_transaction && !transaction_info.auto_commit {
            if let Some(last_transaction) = self.last_seen_transactions.get_async(&key).await {
                if let Some(error_message) = (last_transaction.transaction_number
                    == transaction_info.transaction_number)
                    .then(|| match last_transaction.state {
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
                    })
                {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::ConflictingOperationInProgress,
                        error_message,
                        0,
                    ));
                }
            }

            if let Some((_, mut old_transaction)) = self.transactions.remove(&key) {
                if old_transaction.1.transaction_number == transaction_info.transaction_number {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::ConflictingOperationInProgress,
                        "This transaction is already started.".to_owned(),
                        0,
                    ));
                }

                old_transaction.1.abort().await?;
            }

            let transaction = GatewayTransaction::start(
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
                caller.clone(),
            )
            .await?;

            let _ = self
                .last_seen_transactions
                .upsert_async(
                    key.clone(),
                    LastSeenTransaction::started(transaction.transaction_number()),
                )
                .await;

            let expires_at = EpochClock::almost_now_timestamp() + self.default_ttl.as_secs();

            self.transactions.insert(key, (expires_at, transaction));

            return Ok(());
        }

        if let Some(transaction_entry) = self.transactions.get(&key) {
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
                    0,
                ))
            };
        }

        if let Some(last_seen) = self.last_seen_transactions.get_async(&key).await {
            if last_seen.transaction_number == transaction_info.transaction_number
                && last_seen.state == TransactionState::Committed
            {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::TransactionCommitted,
                    format!(
                        "Transaction {} already committed",
                        transaction_info.transaction_number
                    ),
                    0,
                ));
            }
        }

        // Return an error since the request is trying to continue a transaction that doesn't exist.
        Err(DocumentDBError::documentdb_error(
            ErrorCode::NoSuchTransaction,
            format!(
                "Cannot continue transaction {}",
                transaction_info.transaction_number
            ),
            0,
        ))
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
        caller: &Principal,
    ) -> Result<Option<(SessionId, TransactionEntry)>> {
        let key = SessionKey::new(session_id.clone(), caller.clone());

        let Some((deleted_session_id, mut transaction_entry)) = self.transactions.remove(&key)
        else {
            return Ok(None);
        };

        transaction_entry.1.abort().await?;

        let last_seen_transaction =
            LastSeenTransaction::aborted(transaction_entry.1.transaction_number());

        let _ = self
            .last_seen_transactions
            .upsert_async(deleted_session_id.clone(), last_seen_transaction)
            .await;

        Ok(Some((
            transaction_entry.1.session_id.clone(),
            transaction_entry,
        )))
    }

    /// Aborts and removes the active transaction for `session_id`.
    ///
    /// # Errors
    ///
    /// Returns `ErrorCode::NoSuchTransaction` when there is no active
    /// transaction for the session or when the removal fails.
    pub async fn abort(&self, session_id: &SessionId, caller: &Principal) -> Result<()> {
        self.remove_transaction_by_session(session_id, caller)
            .await?
            .map(|_| ())
            .ok_or_else(|| {
                DocumentDBError::documentdb_error(
                    ErrorCode::NoSuchTransaction,
                    "No such transaction to abort".to_owned(),
                    0,
                )
            })
    }

    /// Commits a transaction
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub async fn commit(&self, session_id: &SessionId, caller: &Principal) -> Result<()> {
        let key = SessionKey::new(session_id.clone(), caller.clone());

        if let Some((_, (_, mut transaction))) = self.transactions.remove(&key) {
            transaction.commit().await?;

            let _ = self
                .last_seen_transactions
                .upsert_async(
                    key,
                    LastSeenTransaction::committed(transaction.transaction_number()),
                )
                .await;

            Ok(())
        } else {
            Err(DocumentDBError::documentdb_error(
                ErrorCode::NoSuchTransaction,
                "No such transaction to commit".to_owned(),
                0,
            ))
        }
    }
}
