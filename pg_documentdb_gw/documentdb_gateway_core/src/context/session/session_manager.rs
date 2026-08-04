/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/session/session_manager.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{sync::Arc, time::Duration};

use tokio::task::{JoinHandle, JoinSet};

use crate::context::{CursorStore, TransactionStore};

#[derive(Debug)]
struct SessionManagerInner {
    transactions: TransactionStore,
    cursors: CursorStore,
    cleanup_interval: Duration,
}

#[derive(Debug)]
pub struct SessionManager {
    inner: Arc<SessionManagerInner>,
    cleanup_task: JoinHandle<()>,
}

impl Drop for SessionManager {
    fn drop(&mut self) {
        self.cleanup_task.abort();
    }
}

impl SessionManager {
    #[must_use]
    pub fn new(
        transactions: TransactionStore,
        cursors: CursorStore,
        cleanup_interval: Duration,
    ) -> Self {
        let inner = Arc::new(SessionManagerInner {
            transactions,
            cursors,
            cleanup_interval,
        });

        let cleanup_task = Self::start_cleanup_task(Arc::clone(&inner));

        Self {
            inner,
            cleanup_task,
        }
    }

    fn start_cleanup_task(session_manager: Arc<SessionManagerInner>) -> JoinHandle<()> {
        tokio::spawn(async move {
            let mut interval = tokio::time::interval(session_manager.cleanup_interval);
            // A pass can outrun the interval; catching up with back-to-back
            // ticks would serve no purpose.
            interval.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);

            loop {
                interval.tick().await;
                let expired_transactions = session_manager.transactions.evict_expired().await;

                if expired_transactions.is_empty() {
                    continue;
                }

                // Rolled back here rather than by the drop-time backstop so the
                // failure is reported against its transaction. One task each so
                // a slow connection does not hold up the rest.
                let mut aborts = JoinSet::new();
                for mut expired_transaction in expired_transactions {
                    let transaction_number = expired_transaction.transaction_number;
                    let _ = session_manager
                        .cursors
                        .invalidate_cursors_by_transaction(transaction_number);

                    aborts.spawn(async move {
                        if let Err(e) = expired_transaction.abort().await {
                            tracing::warn!(
                                "Failed to abort expired transaction {transaction_number}: {e}"
                            );
                        }
                    });
                }

                // Drained so in-flight aborts cannot accumulate across ticks:
                // a rollback may block for the full command deadline, which is
                // longer than the cleanup interval.
                while let Some(result) = aborts.join_next().await {
                    if let Err(e) = result {
                        tracing::error!("Expired transaction rollback task failed: {e}");
                    }
                }
            }
        })
    }

    #[must_use]
    pub fn transactions(&self) -> &TransactionStore {
        &self.inner.transactions
    }

    #[must_use]
    pub fn cursors(&self) -> &CursorStore {
        &self.inner.cursors
    }
}
