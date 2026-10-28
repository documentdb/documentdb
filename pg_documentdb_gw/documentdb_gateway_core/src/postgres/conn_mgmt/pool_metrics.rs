/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/pool_metrics.rs
 *
 * Connection pool reporting types: cumulative counters for connection
 * creation count and duration, plus deadpool acquisition timeouts. Exposes
 * a flat snapshot DTO and a status DTO consumed by reporting paths.
 *
 * Also records the backend pool instruments of the `metrics` facade, which
 * are partitioned by pool role so per-pool identifiers are never exported.
 *
 *-------------------------------------------------------------------------
 */

use std::{
    error::Error,
    io, iter,
    sync::{Mutex, MutexGuard, OnceLock},
    time::Duration,
};

use deadpool::managed::TimeoutType;
use deadpool_postgres::{PoolError, Status};
use metrics::{Counter, Gauge};
use tokio_postgres::error::SqlState;

use crate::telemetry::consts::{labels, metric_names};

/// The purpose a backend pool serves. A role names its pools in the backend
/// application name and in `docdb.backend.connection_pool.role`, so the label
/// stays the same however many pools serve the role.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(super) enum PoolRole {
    /// The system user's pool for queries the gateway runs on its own behalf.
    SystemRequests,
    /// The system user's pool for authenticating clients.
    PreAuthRequests,
    /// The pools that run client data requests.
    Data,
}

impl PoolRole {
    /// Every role, in declaration order.
    pub(super) const ALL: [Self; 3] = [Self::SystemRequests, Self::PreAuthRequests, Self::Data];

    /// Name the pools of this role append to the gateway application name
    /// when they connect to the backend.
    pub(super) const fn pool_name(self) -> &'static str {
        match self {
            Self::SystemRequests => "SystemRequests",
            Self::PreAuthRequests => "PreAuthRequests",
            Self::Data => "Data",
        }
    }

    /// The pool name in snake case, as recorded in
    /// `docdb.backend.connection_pool.role`.
    pub(super) const fn as_str(self) -> &'static str {
        match self {
            Self::SystemRequests => "system_requests",
            Self::PreAuthRequests => "pre_auth_requests",
            Self::Data => "data",
        }
    }

    /// Position of this role in [`Self::ALL`].
    pub(super) const fn index(self) -> usize {
        self as usize
    }
}

/// Bounded `error.type` of a failed backend connection creation attempt.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum ConnectionCreateFailure {
    /// The backend rejected the authorization (SQLSTATE class 28).
    Auth,
    /// The backend has no connection slots left (SQLSTATE 53300).
    ConnectionLimit,
    /// The transport failed, was closed, or timed out before the backend
    /// accepted the connection.
    Network,
    /// Any failure outside the other classes.
    Other,
}

impl ConnectionCreateFailure {
    fn classify(error: &tokio_postgres::Error) -> Self {
        if let Some(code) = error.code() {
            Self::from_sql_state(code)
        } else if error.is_closed() || has_io_source(error) {
            Self::Network
        } else {
            Self::Other
        }
    }

    fn from_sql_state(code: &SqlState) -> Self {
        if *code == SqlState::TOO_MANY_CONNECTIONS {
            Self::ConnectionLimit
        } else if code.code().starts_with("28") {
            Self::Auth
        } else {
            Self::Other
        }
    }

    const fn as_str(self) -> &'static str {
        match self {
            Self::Auth => "auth",
            Self::ConnectionLimit => "connection_limit",
            Self::Network => "network",
            Self::Other => "other",
        }
    }
}

/// Whether an I/O error appears anywhere in the source chain of `error`. TLS
/// libraries report a transport failure during the handshake as the source of
/// their own error type, so the direct source alone can miss it.
fn has_io_source(error: &tokio_postgres::Error) -> bool {
    iter::successors(error.source(), |&cause| cause.source()).any(<dyn Error>::is::<io::Error>)
}

/// Counter handles for one pool role, registered once per pool so that
/// recording an event never builds labels.
#[derive(Debug)]
struct PoolRoleCounters {
    role: PoolRole,
    timeouts: Counter,
    created: Counter,
    failed_auth: Counter,
    failed_connection_limit: Counter,
    failed_network: Counter,
    failed_other: Counter,
}

impl PoolRoleCounters {
    fn new(role: PoolRole) -> Self {
        let pool_name = role.as_str();
        let failed = |failure: ConnectionCreateFailure| {
            metrics::counter!(
                metric_names::BACKEND_CONNECTION_CREATE_COUNT,
                labels::BACKEND_CONNECTION_POOL_ROLE => pool_name,
                labels::ERROR_TYPE => failure.as_str(),
            )
        };

        Self {
            role,
            timeouts: metrics::counter!(
                metric_names::BACKEND_CONNECTION_POOL_TIMEOUT_COUNT,
                labels::BACKEND_CONNECTION_POOL_ROLE => pool_name,
            ),
            created: metrics::counter!(
                metric_names::BACKEND_CONNECTION_CREATE_COUNT,
                labels::BACKEND_CONNECTION_POOL_ROLE => pool_name,
            ),
            failed_auth: failed(ConnectionCreateFailure::Auth),
            failed_connection_limit: failed(ConnectionCreateFailure::ConnectionLimit),
            failed_network: failed(ConnectionCreateFailure::Network),
            failed_other: failed(ConnectionCreateFailure::Other),
        }
    }

    const fn failed(&self, failure: ConnectionCreateFailure) -> &Counter {
        match failure {
            ConnectionCreateFailure::Auth => &self.failed_auth,
            ConnectionCreateFailure::ConnectionLimit => &self.failed_connection_limit,
            ConnectionCreateFailure::Network => &self.failed_network,
            ConnectionCreateFailure::Other => &self.failed_other,
        }
    }
}

/// Connection counts summed over the pools of one role.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub(super) struct PoolUsage {
    used: usize,
    idle: usize,
    max: usize,
    pending_requests: usize,
}

impl PoolUsage {
    #[must_use]
    pub(super) const fn with(self, status: Status) -> Self {
        Self {
            used: self
                .used
                .saturating_add(status.size.saturating_sub(status.available)),
            idle: self.idle.saturating_add(status.available),
            max: self.max.saturating_add(status.max_size),
            pending_requests: self.pending_requests.saturating_add(status.waiting),
        }
    }
}

/// Gauge handles for one pool role, registered once by the sampler.
#[derive(Debug)]
pub(super) struct PoolRoleGauges {
    used: Gauge,
    idle: Gauge,
    max: Gauge,
    pending_requests: Gauge,
}

impl PoolRoleGauges {
    pub(super) fn new(role: PoolRole) -> Self {
        let pool_name = role.as_str();
        let connections = |state: &'static str| {
            metrics::gauge!(
                metric_names::BACKEND_CONNECTION_POOL_USAGE,
                labels::BACKEND_CONNECTION_POOL_ROLE => pool_name,
                labels::DB_CLIENT_CONNECTION_STATE => state,
            )
        };

        Self {
            used: connections("used"),
            idle: connections("idle"),
            max: metrics::gauge!(
                metric_names::BACKEND_CONNECTION_POOL_LIMIT,
                labels::BACKEND_CONNECTION_POOL_ROLE => pool_name,
            ),
            pending_requests: metrics::gauge!(
                metric_names::BACKEND_CONNECTION_POOL_WAIT_ACTIVE,
                labels::BACKEND_CONNECTION_POOL_ROLE => pool_name,
            ),
        }
    }

    pub(super) fn record(&self, usage: PoolUsage) {
        let value = |count: usize| u32::try_from(count).unwrap_or(u32::MAX);

        self.used.set(value(usage.used));
        self.idle.set(value(usage.idle));
        self.max.set(value(usage.max));
        self.pending_requests.set(value(usage.pending_requests));
    }
}

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
    role_counters: OnceLock<PoolRoleCounters>,
}

impl ConnectionPoolMetrics {
    /// Labels this pool's instruments with `role`. The first assignment wins;
    /// a pool without a role records no instruments.
    pub(super) fn assign_role(&self, role: PoolRole) {
        self.role_counters
            .get_or_init(|| PoolRoleCounters::new(role));
    }

    /// The role assigned to this pool, if any.
    pub(super) fn role(&self) -> Option<PoolRole> {
        self.role_counters.get().map(|counters| counters.role)
    }

    pub(super) fn record_connection_created(&self, create_time: Duration) {
        // Saturating conversion: any duration beyond `u64::MAX` microseconds
        // (≈584,000 years) is treated as the maximum representable value
        // rather than triggering a panic in debug builds.
        let create_time_us = u64::try_from(create_time.as_micros()).unwrap_or(u64::MAX);
        {
            let mut counters = self.lock_counters();
            counters.connections_created = counters.connections_created.saturating_add(1);
            counters.connection_create_time_us = counters
                .connection_create_time_us
                .saturating_add(create_time_us);
        }

        if let Some(role_counters) = self.role_counters.get() {
            role_counters.created.increment(1);
        }
    }

    pub(super) fn record_connection_failed(&self, error: &tokio_postgres::Error) {
        if let Some(role_counters) = self.role_counters.get() {
            role_counters
                .failed(ConnectionCreateFailure::classify(error))
                .increment(1);
        }
    }

    pub(super) fn record_connection_timeout(&self) {
        {
            let mut counters = self.lock_counters();
            counters.connection_timeouts = counters.connection_timeouts.saturating_add(1);
        }

        if let Some(role_counters) = self.role_counters.get() {
            role_counters.timeouts.increment(1);
        }
    }

    pub(super) fn record_timeout_if_pool_timeout(&self, error: &PoolError) {
        if let PoolError::Timeout(timeout_type) = error {
            self.record_connection_timeout();

            // The creation attempt was abandoned, so the connection manager
            // never observed its outcome.
            if matches!(timeout_type, TimeoutType::Create) {
                if let Some(role_counters) = self.role_counters.get() {
                    role_counters
                        .failed(ConnectionCreateFailure::Network)
                        .increment(1);
                }
            }
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
    use std::{
        fmt,
        future::{self, Ready},
        sync::{
            atomic::{AtomicBool, Ordering as AtomicOrdering},
            Arc,
        },
    };

    use tokio::{io::AsyncWriteExt, task::yield_now};
    use tokio_postgres::{
        config::SslMode,
        tls::{NoTlsStream, TlsConnect},
    };

    use super::*;
    use crate::testing::RecordingMetricsRecorder;

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

    // ── Pool role instruments ──────────────────────────────────────────

    #[test]
    fn sql_states_classify_connection_create_failures() {
        for (code, expected) in [
            ("28P01", ConnectionCreateFailure::Auth),
            ("28000", ConnectionCreateFailure::Auth),
            ("53300", ConnectionCreateFailure::ConnectionLimit),
            ("57P03", ConnectionCreateFailure::Other),
        ] {
            assert_eq!(
                ConnectionCreateFailure::from_sql_state(&SqlState::from_code(code)),
                expected,
                "SQLSTATE {code}"
            );
        }
    }

    /// Handshake error that reports its transport failure, if any, as its
    /// source, as TLS libraries do.
    #[derive(Debug)]
    struct HandshakeError(Option<io::Error>);

    impl fmt::Display for HandshakeError {
        fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
            f.write_str("TLS handshake failed")
        }
    }

    impl Error for HandshakeError {
        fn source(&self) -> Option<&(dyn Error + 'static)> {
            self.0.as_ref().map(|error| error as _)
        }
    }

    /// TLS connector whose handshake always fails, with a transport failure
    /// of the given kind when one is set.
    struct FailingTls(Option<io::ErrorKind>);

    impl<S> TlsConnect<S> for FailingTls {
        type Stream = NoTlsStream;
        type Error = HandshakeError;
        type Future = Ready<Result<NoTlsStream, HandshakeError>>;

        fn connect(self, _stream: S) -> Self::Future {
            future::ready(Err(HandshakeError(self.0.map(io::Error::from))))
        }
    }

    #[tokio::test]
    async fn tls_handshake_failures_classify_by_cause() {
        for (cause, expected) in [
            (
                Some(io::ErrorKind::ConnectionReset),
                ConnectionCreateFailure::Network,
            ),
            (None, ConnectionCreateFailure::Other),
        ] {
            let (client, mut backend) = tokio::io::duplex(64);
            // Accept the TLS request so the client starts the handshake.
            backend.write_all(b"S").await.unwrap();

            let Err(error) = tokio_postgres::Config::new()
                .ssl_mode(SslMode::Require)
                .connect_raw(client, FailingTls(cause))
                .await
            else {
                panic!("the TLS handshake should fail");
            };

            assert_eq!(
                ConnectionCreateFailure::classify(&error),
                expected,
                "cause {cause:?}"
            );
        }
    }

    #[test]
    fn role_labels_are_snake_case_application_name_suffixes() {
        for role in PoolRole::ALL {
            let mut snake_case = String::new();
            for (position, character) in role.pool_name().char_indices() {
                if position > 0 && character.is_ascii_uppercase() {
                    snake_case.push('_');
                }
                snake_case.push(character.to_ascii_lowercase());
            }

            assert_eq!(role.as_str(), snake_case, "{role:?}");
        }
    }

    #[test]
    fn role_counters_record_creations_and_timeouts() {
        let recorder = RecordingMetricsRecorder::default();
        let pool_metrics = ConnectionPoolMetrics::default();
        metrics::with_local_recorder(&recorder, || {
            pool_metrics.assign_role(PoolRole::Data);
        });

        pool_metrics.record_connection_created(Duration::from_micros(3));
        pool_metrics.record_timeout_if_pool_timeout(&PoolError::Timeout(TimeoutType::Wait));
        pool_metrics.record_timeout_if_pool_timeout(&PoolError::Timeout(TimeoutType::Create));
        pool_metrics.record_timeout_if_pool_timeout(&PoolError::Closed);

        let data = (labels::BACKEND_CONNECTION_POOL_ROLE, "data");
        assert_eq!(
            recorder.counter(metric_names::BACKEND_CONNECTION_POOL_TIMEOUT_COUNT, &[data]),
            Some(2)
        );
        assert_eq!(
            recorder.counter(metric_names::BACKEND_CONNECTION_CREATE_COUNT, &[data]),
            Some(1)
        );
        // An abandoned creation attempt is a network failure.
        for (error_type, expected) in [
            ("auth", 0),
            ("connection_limit", 0),
            ("network", 1),
            ("other", 0),
        ] {
            assert_eq!(
                recorder.counter(
                    metric_names::BACKEND_CONNECTION_CREATE_COUNT,
                    &[data, (labels::ERROR_TYPE, error_type)]
                ),
                Some(expected),
                "error.type {error_type}"
            );
        }
    }

    #[test]
    fn role_gauges_record_summed_usage() {
        let recorder = RecordingMetricsRecorder::default();
        let gauges =
            metrics::with_local_recorder(&recorder, || PoolRoleGauges::new(PoolRole::Data));

        gauges.record(PoolUsage::default().with(pool_status()).with(Status {
            max_size: 4,
            size: 4,
            available: 0,
            waiting: 3,
        }));

        let data = (labels::BACKEND_CONNECTION_POOL_ROLE, "data");
        for (state, expected) in [("used", 5.0), ("idle", 2.0)] {
            assert_eq!(
                recorder.gauge(
                    metric_names::BACKEND_CONNECTION_POOL_USAGE,
                    &[data, (labels::DB_CLIENT_CONNECTION_STATE, state)]
                ),
                Some(expected),
                "state {state}"
            );
        }
        assert_eq!(
            recorder.gauge(metric_names::BACKEND_CONNECTION_POOL_LIMIT, &[data]),
            Some(14.0)
        );
        assert_eq!(
            recorder.gauge(metric_names::BACKEND_CONNECTION_POOL_WAIT_ACTIVE, &[data]),
            Some(4.0)
        );
    }
}
