/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/context/session/session_manager.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{sync::Arc, time::Duration};

use metrics::{Counter, Gauge};
use tokio::task::{JoinHandle, JoinSet};

use crate::{
    context::{CursorStore, TransactionStore},
    telemetry::consts::{labels, metric_names},
};

#[derive(Clone, Debug)]
pub struct SessionResourceMetrics {
    enabled: bool,

    // Session lifecycle metrics - currently not used since this is an implicit assignment
    _active_sessions: Gauge,
    _session_opened: Counter,
    _session_closed: Counter,
    _session_expired: Counter,

    // Transaction lifecycle metrics
    active_transactions: Gauge,
    transaction_started: Counter,
    transaction_committed: Counter,
    transaction_aborted: Counter,
    transaction_expired: Counter,

    // Cursor lifecycle metrics
    active_cursors: Gauge,
    cursor_opened: Counter,
    cursor_exhausted: Counter,
    cursor_killed: Counter,
    cursor_invalidated: Counter,
    cursor_expired: Counter,
}

impl Default for SessionResourceMetrics {
    fn default() -> Self {
        Self::new(false)
    }
}

impl SessionResourceMetrics {
    #[must_use]
    pub fn new(enabled: bool) -> Self {
        Self {
            // Enable / Disable
            enabled,

            // Session Lifecycle
            _active_sessions: metrics::gauge!(metric_names::SESSION_ACTIVE),
            _session_opened: metrics::counter!(metric_names::SESSION_OPENED),
            _session_closed: metrics::counter!(metric_names::SESSION_CLOSED),
            _session_expired: metrics::counter!(metric_names::SESSION_EXPIRED),

            active_transactions: metrics::gauge!(metric_names::TRANSACTION_ACTIVE),
            transaction_started: metrics::counter!(metric_names::TRANSACTION_STARTED),
            transaction_committed: metrics::counter!(
                metric_names::TRANSACTION_ENDED,
                labels::TRANSACTION_END_OUTCOME => "committed"
            ),
            transaction_aborted: metrics::counter!(
                metric_names::TRANSACTION_ENDED,
                labels::TRANSACTION_END_OUTCOME => "aborted"
            ),
            transaction_expired: metrics::counter!(
                metric_names::TRANSACTION_ENDED,
                labels::TRANSACTION_END_OUTCOME => "expired"
            ),

            active_cursors: metrics::gauge!(metric_names::CURSOR_ACTIVE),
            cursor_opened: metrics::counter!(metric_names::CURSOR_OPENED),
            cursor_exhausted: metrics::counter!(
                metric_names::CURSOR_ENDED,
                labels::CURSOR_END_REASON => "exhausted"
            ),
            cursor_killed: metrics::counter!(
                metric_names::CURSOR_ENDED,
                labels::CURSOR_END_REASON => "killed"
            ),
            cursor_invalidated: metrics::counter!(
                metric_names::CURSOR_ENDED,
                labels::CURSOR_END_REASON => "invalidated"
            ),
            cursor_expired: metrics::counter!(
                metric_names::CURSOR_ENDED,
                labels::CURSOR_END_REASON => "expired"
            ),
        }
    }

    pub(crate) fn observe_active_counts(&self, transactions: usize, cursors: usize) {
        if self.enabled {
            self.active_transactions
                .set(u32::try_from(transactions).unwrap_or(u32::MAX));
            self.active_cursors
                .set(u32::try_from(cursors).unwrap_or(u32::MAX));
        }
    }

    pub(crate) fn transaction_started(&self) {
        if self.enabled {
            self.transaction_started.increment(1);
        }
    }

    pub(crate) fn transaction_committed(&self) {
        if self.enabled {
            self.transaction_committed.increment(1);
        }
    }

    pub(crate) fn transaction_aborted(&self) {
        if self.enabled {
            self.transaction_aborted.increment(1);
        }
    }

    pub(crate) fn transactions_expired(&self, value: usize) {
        if self.enabled {
            self.transaction_expired
                .increment(u64::try_from(value).unwrap_or(u64::MAX));
        }
    }

    pub(crate) fn cursor_opened(&self) {
        if self.enabled {
            self.cursor_opened.increment(1);
        }
    }

    pub(crate) fn cursor_exhausted(&self) {
        if self.enabled {
            self.cursor_exhausted.increment(1);
        }
    }

    pub(crate) fn cursors_killed(&self, value: usize) {
        if self.enabled {
            self.cursor_killed
                .increment(u64::try_from(value).unwrap_or(u64::MAX));
        }
    }

    pub(crate) fn cursors_expired(&self, value: usize) {
        if self.enabled {
            self.cursor_expired
                .increment(u64::try_from(value).unwrap_or(u64::MAX));
        }
    }

    pub(crate) fn cursors_invalidated(&self, value: usize) {
        if self.enabled {
            self.cursor_invalidated
                .increment(u64::try_from(value).unwrap_or(u64::MAX));
        }
    }
}

#[derive(Debug)]
struct SessionManagerInner {
    metrics: SessionResourceMetrics,
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
        metrics: SessionResourceMetrics,
        cleanup_interval: Duration,
    ) -> Self {
        let inner = Arc::new(SessionManagerInner {
            metrics,
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

    #[must_use]
    pub fn metrics(&self) -> &SessionResourceMetrics {
        &self.inner.metrics
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
                    session_manager.metrics.observe_active_counts(
                        session_manager.transactions.len(),
                        session_manager.cursors.len(),
                    );
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

                session_manager.metrics.observe_active_counts(
                    session_manager.transactions.len(),
                    session_manager.cursors.len(),
                );
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
