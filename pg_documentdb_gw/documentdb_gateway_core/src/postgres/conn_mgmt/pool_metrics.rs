/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/pool_metrics.rs
 *
 * Connection pool reporting types: cumulative counters for connection
 * creation count and duration, plus deadpool acquisition timeouts. Exposes
 * a flat snapshot DTO and a status DTO consumed by reporting paths.
 *
 *-------------------------------------------------------------------------
 */

use std::{
    sync::{Mutex, MutexGuard},
    time::Duration,
};

use deadpool_postgres::Status;

/// Immutable snapshot of connection pool interval metrics.
///
/// Carries the cumulative counters for one reporting interval:
/// - `connections_created`: backend connections successfully created during
///   the interval.
/// - `connection_create_time_us`: total backend creation time in microseconds.
/// - `connection_timeouts`: number of `deadpool_postgres::PoolError::Timeout`
///   results returned by acquire calls during the interval.
///
/// All counters saturate at [`u64::MAX`] rather than overflow.
#[derive(Clone, Copy, Debug, Default)]
pub struct ConnectionPoolMetricSnapshot {
    connections_created: u64,
    connection_create_time_us: u64,
    connection_timeouts: u64,
}

impl ConnectionPoolMetricSnapshot {
    #[must_use]
    pub const fn new(
        connections_created: u64,
        connection_create_time_us: u64,
        connection_timeouts: u64,
    ) -> Self {
        Self {
            connections_created,
            connection_create_time_us,
            connection_timeouts,
        }
    }

    #[must_use]
    pub const fn connections_created(&self) -> u64 {
        self.connections_created
    }

    #[must_use]
    pub const fn connection_create_time_us(&self) -> u64 {
        self.connection_create_time_us
    }

    #[must_use]
    pub const fn connection_timeouts(&self) -> u64 {
        self.connection_timeouts
    }
}

/// Reporting view of one logical connection pool: identifier, deadpool runtime
/// gauges, and the most recent interval metric snapshot.
#[derive(Debug)]
pub struct ConnectionPoolStatus {
    identifier: String,
    status: Status,
    metrics: ConnectionPoolMetricSnapshot,
}

impl ConnectionPoolStatus {
    #[must_use]
    pub const fn new(identifier: String, status: Status) -> Self {
        Self::new_with_metrics(identifier, status, 0, 0, 0)
    }

    #[must_use]
    pub const fn new_with_metrics(
        identifier: String,
        status: Status,
        connections_created: u64,
        connection_create_time_us: u64,
        connection_timeouts: u64,
    ) -> Self {
        Self::new_with_metric_snapshot(
            identifier,
            status,
            ConnectionPoolMetricSnapshot::new(
                connections_created,
                connection_create_time_us,
                connection_timeouts,
            ),
        )
    }

    #[must_use]
    pub fn identifier(&self) -> &str {
        &self.identifier
    }

    #[must_use]
    pub const fn status(&self) -> Status {
        self.status
    }

    #[must_use]
    pub const fn metrics(&self) -> ConnectionPoolMetricSnapshot {
        self.metrics
    }

    #[must_use]
    pub const fn connections_created(&self) -> u64 {
        self.metrics.connections_created()
    }

    #[must_use]
    pub const fn connection_create_time_us(&self) -> u64 {
        self.metrics.connection_create_time_us()
    }

    #[must_use]
    pub const fn connection_timeouts(&self) -> u64 {
        self.metrics.connection_timeouts()
    }

    pub(super) const fn new_with_metric_snapshot(
        identifier: String,
        status: Status,
        metrics: ConnectionPoolMetricSnapshot,
    ) -> Self {
        Self {
            identifier,
            status,
            metrics,
        }
    }
}

#[derive(Clone, Copy, Debug, Default)]
struct MetricCounters {
    connections_created: u64,
    connection_create_time_us: u64,
    connection_timeouts: u64,
}

impl MetricCounters {
    fn reset(&mut self) {
        *self = Self::default();
    }
}

#[derive(Debug, Default)]
pub(super) struct ConnectionPoolMetrics {
    counters: Mutex<MetricCounters>,
}

impl ConnectionPoolMetrics {
    pub(super) fn record_connection_created(&self, create_time: Duration) {
        // Saturating conversion: any duration beyond `u64::MAX` microseconds
        // (≈584,000 years) is treated as the maximum representable value
        // rather than triggering a panic in debug builds.
        let create_time_us = u64::try_from(create_time.as_micros()).unwrap_or(u64::MAX);
        let mut counters = self.lock_counters();
        counters.connections_created = counters.connections_created.saturating_add(1);
        counters.connection_create_time_us = counters
            .connection_create_time_us
            .saturating_add(create_time_us);
    }

    pub(super) fn record_connection_timeout(&self) {
        let mut counters = self.lock_counters();
        counters.connection_timeouts = counters.connection_timeouts.saturating_add(1);
    }

    pub(super) fn record_timeout_if_pool_timeout(&self, error: &deadpool_postgres::PoolError) {
        if matches!(error, deadpool_postgres::PoolError::Timeout(_)) {
            self.record_connection_timeout();
        }
    }

    pub(super) fn snapshot(&self) -> ConnectionPoolMetricSnapshot {
        let counters = self.lock_counters();
        ConnectionPoolMetricSnapshot::new(
            counters.connections_created,
            counters.connection_create_time_us,
            counters.connection_timeouts,
        )
    }

    pub(super) fn flush(&self) -> ConnectionPoolMetricSnapshot {
        let mut counters = self.lock_counters();
        let snap = ConnectionPoolMetricSnapshot::new(
            counters.connections_created,
            counters.connection_create_time_us,
            counters.connection_timeouts,
        );
        counters.reset();
        snap
    }

    fn lock_counters(&self) -> MutexGuard<'_, MetricCounters> {
        match self.counters.lock() {
            Ok(guard) => guard,
            Err(poisoned) => poisoned.into_inner(),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::{
        atomic::{AtomicBool, Ordering as AtomicOrdering},
        Arc,
    };

    use deadpool::managed::TimeoutType;
    use deadpool_postgres::PoolError;
    use tokio::task::yield_now;

    fn pool_status() -> Status {
        Status {
            max_size: 10,
            size: 3,
            available: 2,
            waiting: 1,
        }
    }

    // ── ConnectionPoolMetricSnapshot ───────────────────────────────────

    #[test]
    fn metric_snapshot_new_stores_values() {
        let snap = ConnectionPoolMetricSnapshot::new(2, 17, 1);
        assert_eq!(snap.connections_created(), 2);
        assert_eq!(snap.connection_create_time_us(), 17);
        assert_eq!(snap.connection_timeouts(), 1);
    }

    #[test]
    fn metric_snapshot_default_is_zero() {
        let snap = ConnectionPoolMetricSnapshot::default();
        assert_eq!(snap.connections_created(), 0);
        assert_eq!(snap.connection_create_time_us(), 0);
        assert_eq!(snap.connection_timeouts(), 0);
    }

    // ── ConnectionPoolStatus ───────────────────────────────────────────

    #[test]
    fn status_new_zeros_metrics() {
        let status = ConnectionPoolStatus::new("test-pool".to_owned(), pool_status());

        assert_eq!(status.identifier(), "test-pool");
        assert_eq!(status.status().max_size, 10);
        assert_eq!(status.status().size, 3);
        assert_eq!(status.status().available, 2);
        assert_eq!(status.status().waiting, 1);
        assert_eq!(status.connections_created(), 0);
        assert_eq!(status.connection_create_time_us(), 0);
        assert_eq!(status.connection_timeouts(), 0);
    }

    #[test]
    fn status_new_with_metrics_stores_metric_values() {
        let status =
            ConnectionPoolStatus::new_with_metrics("test-pool".to_owned(), pool_status(), 2, 17, 1);

        assert_eq!(status.connections_created(), 2);
        assert_eq!(status.connection_create_time_us(), 17);
        assert_eq!(status.connection_timeouts(), 1);
    }

    #[test]
    fn status_metrics_returns_embedded_snapshot() {
        let status =
            ConnectionPoolStatus::new_with_metrics("test-pool".to_owned(), pool_status(), 5, 11, 2);
        let snap = status.metrics();

        assert_eq!(snap.connections_created(), 5);
        assert_eq!(snap.connection_create_time_us(), 11);
        assert_eq!(snap.connection_timeouts(), 2);
    }

    // ── ConnectionPoolMetrics ──────────────────────────────────────────

    #[test]
    fn metrics_default_snapshot_is_zero() {
        let metrics = ConnectionPoolMetrics::default();
        let snap = metrics.snapshot();

        assert_eq!(snap.connections_created(), 0);
        assert_eq!(snap.connection_create_time_us(), 0);
        assert_eq!(snap.connection_timeouts(), 0);
    }

    #[test]
    fn record_connection_created_increments_count_and_time() {
        let metrics = ConnectionPoolMetrics::default();
        metrics.record_connection_created(Duration::from_micros(7));
        metrics.record_connection_created(Duration::from_micros(11));

        let snap = metrics.snapshot();
        assert_eq!(snap.connections_created(), 2);
        assert_eq!(snap.connection_create_time_us(), 18);
        assert_eq!(snap.connection_timeouts(), 0);
    }

    #[test]
    fn record_connection_timeout_increments_only_timeouts() {
        let metrics = ConnectionPoolMetrics::default();
        metrics.record_connection_timeout();
        metrics.record_connection_timeout();

        let snap = metrics.snapshot();
        assert_eq!(snap.connections_created(), 0);
        assert_eq!(snap.connection_create_time_us(), 0);
        assert_eq!(snap.connection_timeouts(), 2);
    }

    #[test]
    fn record_timeout_if_pool_timeout_filters_non_timeout_errors() {
        let metrics = ConnectionPoolMetrics::default();

        metrics.record_timeout_if_pool_timeout(&PoolError::Closed);
        metrics.record_timeout_if_pool_timeout(&PoolError::NoRuntimeSpecified);
        metrics.record_timeout_if_pool_timeout(&PoolError::Timeout(TimeoutType::Wait));
        metrics.record_timeout_if_pool_timeout(&PoolError::Timeout(TimeoutType::Create));

        let snap = metrics.snapshot();
        assert_eq!(snap.connection_timeouts(), 2);
    }

    #[test]
    fn snapshot_does_not_reset_counters() {
        let metrics = ConnectionPoolMetrics::default();
        metrics.record_connection_created(Duration::from_micros(5));
        metrics.record_connection_timeout();

        let first = metrics.snapshot();
        let second = metrics.snapshot();

        assert_eq!(first.connections_created(), 1);
        assert_eq!(second.connections_created(), 1);
        assert_eq!(first.connection_create_time_us(), 5);
        assert_eq!(second.connection_create_time_us(), 5);
        assert_eq!(first.connection_timeouts(), 1);
        assert_eq!(second.connection_timeouts(), 1);
    }

    #[test]
    fn flush_returns_current_values_and_resets() {
        let metrics = ConnectionPoolMetrics::default();
        metrics.record_connection_created(Duration::from_micros(7));
        metrics.record_connection_created(Duration::from_micros(11));
        metrics.record_connection_timeout();

        let flushed = metrics.flush();
        assert_eq!(flushed.connections_created(), 2);
        assert_eq!(flushed.connection_create_time_us(), 18);
        assert_eq!(flushed.connection_timeouts(), 1);

        let post_flush = metrics.snapshot();
        assert_eq!(post_flush.connections_created(), 0);
        assert_eq!(post_flush.connection_create_time_us(), 0);
        assert_eq!(post_flush.connection_timeouts(), 0);
    }

    #[test]
    fn flush_with_zero_activity_returns_zero() {
        let metrics = ConnectionPoolMetrics::default();
        let flushed = metrics.flush();

        assert_eq!(flushed.connections_created(), 0);
        assert_eq!(flushed.connection_create_time_us(), 0);
        assert_eq!(flushed.connection_timeouts(), 0);
    }

    #[test]
    fn record_connection_created_saturates_at_u64_max() {
        let metrics = ConnectionPoolMetrics::default();
        // First record pushes connection_create_time_us to u64::MAX; the second
        // would overflow without saturating_add.
        metrics.record_connection_created(Duration::from_micros(u64::MAX));
        metrics.record_connection_created(Duration::from_micros(u64::MAX));

        let snap = metrics.snapshot();
        assert_eq!(snap.connections_created(), 2);
        assert_eq!(snap.connection_create_time_us(), u64::MAX);
    }

    #[tokio::test]
    async fn concurrent_records_and_flushes_preserve_all_metrics() {
        let metrics = Arc::new(ConnectionPoolMetrics::default());
        let producers_done = Arc::new(AtomicBool::new(false));
        let create_time = Duration::from_micros(5);
        let create_time_us = u64::try_from(create_time.as_micros()).unwrap_or(u64::MAX);
        let producers = 8usize;
        let updates_per_producer = 100usize;
        let expected_connections_created = producers * updates_per_producer;
        let expected_connection_create_time_us = expected_connections_created * 5;
        let expected_connection_timeouts = producers * (updates_per_producer / 2);

        let mut producer_handles = Vec::new();
        for _ in 0..producers {
            let metrics = Arc::clone(&metrics);
            producer_handles.push(tokio::spawn(async move {
                for index in 0..updates_per_producer {
                    metrics.record_connection_created(create_time);
                    if index % 2 == 0 {
                        metrics.record_connection_timeout();
                    }
                    yield_now().await;
                }
            }));
        }

        let flush_metrics = Arc::clone(&metrics);
        let producers_done_clone = Arc::clone(&producers_done);
        let flusher = tokio::spawn(async move {
            let mut connections_created = 0u64;
            let mut connection_create_time_us = 0u64;
            let mut connection_timeouts = 0u64;

            loop {
                let snap = flush_metrics.flush();
                assert_eq!(
                    snap.connection_create_time_us(),
                    snap.connections_created() * create_time_us
                );
                connections_created += snap.connections_created();
                connection_create_time_us += snap.connection_create_time_us();
                connection_timeouts += snap.connection_timeouts();

                if producers_done_clone.load(AtomicOrdering::Relaxed) {
                    break;
                }
                yield_now().await;
            }

            (
                connections_created,
                connection_create_time_us,
                connection_timeouts,
            )
        });

        for handle in producer_handles {
            handle.await.unwrap();
        }
        producers_done.store(true, AtomicOrdering::Relaxed);

        let (connections_created, connection_create_time_us, connection_timeouts) =
            flusher.await.unwrap();

        assert_eq!(connections_created, expected_connections_created as u64);
        assert_eq!(
            connection_create_time_us,
            expected_connection_create_time_us as u64
        );
        assert_eq!(connection_timeouts, expected_connection_timeouts as u64);

        let post_flush = metrics.flush();
        assert_eq!(post_flush.connections_created(), 0);
        assert_eq!(post_flush.connection_create_time_us(), 0);
        assert_eq!(post_flush.connection_timeouts(), 0);
    }
}
