/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/session/session_manager.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{sync::Arc, time::Duration};

use tokio::task::JoinHandle;

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

            loop {
                interval.tick().await;
                let expired_transactions = session_manager.transactions.evict_expired().await;

                for expired_transaction in expired_transactions {
                    let _ = session_manager
                        .cursors
                        .invalidate_cursors_by_transaction(expired_transaction.transaction_number);
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
