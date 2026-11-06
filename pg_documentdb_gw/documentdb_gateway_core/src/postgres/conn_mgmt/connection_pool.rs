/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/connection_pool.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    collections::hash_map::DefaultHasher,
    hash::{Hash, Hasher},
    ops::Deref,
    sync::{
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
        Arc,
    },
};

use arc_swap::ArcSwap;
use deadpool::{
    managed::{
        Manager as DeadpoolManager, Metrics as DeadpoolMetrics, Object as DeadpoolObject,
        Pool as DeadpoolPool, RecycleError as DeadpoolRecycleError,
        RecycleResult as DeadpoolRecycleResult, TimeoutType,
    },
    Runtime, Status,
};
use deadpool_postgres::{
    ClientWrapper, Manager as PostgresManager, ManagerConfig, RecyclingMethod,
};
use openssl::sha::Sha256;
use tokio::{
    task::JoinHandle,
    time::{Duration, Instant},
};
use tokio_postgres::{
    config::SslMode,
    tls::{MakeTlsConnect, TlsConnect},
    NoTls, Socket,
};

use crate::{
    configuration::{DynamicConfiguration, SetupConfiguration},
    error::Result,
    postgres::{
        conn_mgmt::{
            pool_metrics::{ConnectionPoolMetrics, ConnectionPoolStatus, PoolRole},
            PgPoolSettings,
        },
        QueryCatalog,
    },
    telemetry::event_id::EventId,
    time::{self, EpochClock},
};

/// Per-connection settings not derived from the setup configuration.
#[derive(Clone, Copy)]
struct BackendConnectionConfig {
    command_timeout: Duration,
    transaction_timeout: Duration,
    connect_timeout: Option<Duration>,
    ssl_mode: SslMode,
}

fn pg_configuration(
    setup_configuration: &dyn SetupConfiguration,
    query_catalog: &QueryCatalog,
    user: &str,
    password: Option<&str>,
    application_name: &str,
    connection_buffer_size: usize,
    connection: BackendConnectionConfig,
) -> tokio_postgres::Config {
    let mut config = tokio_postgres::Config::new();

    let command_timeout_ms = connection.command_timeout.as_millis().to_string();

    let transaction_timeout_ms = connection.transaction_timeout.as_millis().to_string();

    config
        .host(setup_configuration.postgres_host_name())
        .port(setup_configuration.postgres_port())
        .dbname(setup_configuration.postgres_database())
        .user(user)
        .application_name(application_name)
        .options(
            query_catalog.set_search_path_and_timeout(&command_timeout_ms, &transaction_timeout_ms),
        );

    if let Some(pass) = password {
        config.password(pass);
    }

    // Bounds each socket attempt, which is per resolved address. The pool's
    // create timeout bounds the attempt as a whole.
    if let Some(connect_timeout) = connection.connect_timeout {
        config.connect_timeout(connect_timeout);
    }

    config.ssl_mode(connection.ssl_mode);

    set_connection_buffer_size(&mut config, connection_buffer_size);

    config
}

/// Applies the per-connection buffer size to the `PostgreSQL` configuration.
///
/// Only compiled when the `pg_buffer_size` cfg is set, which requires a
/// `tokio-postgres` build that exposes `Config::buffer_size`.
#[cfg(pg_buffer_size)]
fn set_connection_buffer_size(config: &mut tokio_postgres::Config, buffer_size: usize) {
    config.buffer_size(buffer_size);
}

/// No-op fallback when the `pg_buffer_size` cfg is not set: the default
/// `tokio-postgres` does not expose a buffer size setting.
#[cfg(not(pg_buffer_size))]
const fn set_connection_buffer_size(_config: &mut tokio_postgres::Config, _buffer_size: usize) {}

/// Nanoseconds since [`EpochClock::epoch`], the domain
/// [`ConnectionPool::last_used`] decodes from. `almost_now_timestamp` is unix
/// seconds and does not round-trip through [`time::u64_to_instant`];
/// `almost_now` freezes once the runtime that initialised it goes away.
fn now_epoch_nanos() -> u64 {
    time::instant_to_u64(EpochClock::now())
}

/// Slack between the pool-wide `statement_timeout` and the client-side deadline
/// backing it up, so the server's own graceful timeout error wins the race.
const COMMAND_DEADLINE_SLACK: Duration = Duration::from_secs(1);
const PRE_ALLOCATION_TIMEOUT: Duration = Duration::from_secs(30);

/// Client-side deadline for a request that carries no timeout of its own;
/// `Connection::set_command_deadline` replaces it per request.
///
/// Catches a connection that has stopped responding, which no server-side GUC
/// covers.
#[must_use]
pub fn command_deadline_for(dynamic_configuration: &dyn DynamicConfiguration) -> Duration {
    Duration::from_secs(dynamic_configuration.max_request_timeout_sec())
        .saturating_add(COMMAND_DEADLINE_SLACK)
}

const fn command_timeout_for(pool_settings: PgPoolSettings) -> Duration {
    pool_settings.max_request_timeout()
}

/// Only ever compared, never logged. Collision-resistant so a rotated
/// credential is never mistaken for the current one; the tag byte keeps an
/// absent credential distinct from an empty one.
fn credential_fingerprint(password: Option<&str>) -> [u8; 32] {
    let mut hasher = Sha256::new();

    match password {
        Some(password) => {
            hasher.update(b"p");
            hasher.update(password.as_bytes());
        }
        None => hasher.update(b"n"),
    }

    hasher.finish()
}

/// Restores a connection whose session state a borrower modified.
///
/// The statements are those `RecyclingMethod::Clean` runs, preceded by
/// `RESET statement_timeout`. `PostgreSQL` arms the statement timeout for each
/// statement of a multi-statement string, so resetting it first keeps a tight
/// timeout left by the previous borrower from cancelling the reset itself.
/// `DISCARD ALL` is avoided because it deallocates prepared statements that the
/// client-side statement cache still references.
const SESSION_RESET_SQL: &str = "RESET statement_timeout; \
    CLOSE ALL; \
    SET SESSION AUTHORIZATION DEFAULT; \
    RESET ALL; \
    UNLISTEN *; \
    SELECT pg_advisory_unlock_all(); \
    DISCARD TEMP; \
    DISCARD SEQUENCES;";

/// Pooled backend client that tracks whether a borrower changed session state
/// that must not reach the next borrower.
#[doc(hidden)]
#[derive(Debug)]
pub struct PooledClient {
    client: ClientWrapper,
    /// Set by a borrower before it issues session-level state, and cleared
    /// once [`SESSION_RESET_SQL`] succeeds when the connection is next
    /// checked out.
    session_state_modified: AtomicBool,
}

impl PooledClient {
    const fn new(client: ClientWrapper) -> Self {
        Self {
            client,
            session_state_modified: AtomicBool::new(false),
        }
    }

    /// Requests a session reset before the connection serves another borrower.
    ///
    /// Call before issuing the statement that changes session state, so the
    /// reset still runs if that statement is cancelled or fails part-way.
    pub fn mark_session_state_modified(&self) {
        self.session_state_modified.store(true, Ordering::Relaxed);
    }

    /// Whether a session reset is pending for this connection.
    pub fn session_state_modified(&self) -> bool {
        self.session_state_modified.load(Ordering::Relaxed)
    }
}

impl Deref for PooledClient {
    type Target = ClientWrapper;

    fn deref(&self) -> &Self::Target {
        &self.client
    }
}

/// Internal deadpool manager wrapper that records connection creation metrics
/// and resets connections whose session state a borrower modified.
#[doc(hidden)]
#[derive(Debug)]
pub struct InstrumentedManager {
    inner: PostgresManager,
    metrics: Arc<ConnectionPoolMetrics>,
    /// Bound on [`SESSION_RESET_SQL`]. Recycling runs before a `Connection`
    /// exists, so no command deadline covers it otherwise.
    session_reset_timeout: Duration,
}

impl InstrumentedManager {
    const fn new(
        inner: PostgresManager,
        metrics: Arc<ConnectionPoolMetrics>,
        session_reset_timeout: Duration,
    ) -> Self {
        Self {
            inner,
            metrics,
            session_reset_timeout,
        }
    }
}

impl DeadpoolManager for InstrumentedManager {
    type Type = PooledClient;
    type Error = tokio_postgres::Error;

    async fn create(&self) -> std::result::Result<Self::Type, Self::Error> {
        let create_start = Instant::now();
        let client = DeadpoolManager::create(&self.inner)
            .await
            .inspect_err(|error| self.metrics.record_connection_failed(error))?;
        self.metrics
            .record_connection_created(create_start.elapsed());
        Ok(PooledClient::new(client))
    }

    /// Checks liveness on every checkout, and resets session state only for a
    /// connection whose previous borrower modified it, so unmodified
    /// connections pay no round trip.
    ///
    /// A failed or timed-out reset discards the connection; deadpool then
    /// serves another one or creates a replacement.
    async fn recycle(
        &self,
        obj: &mut Self::Type,
        metrics: &DeadpoolMetrics,
    ) -> DeadpoolRecycleResult<Self::Error> {
        DeadpoolManager::recycle(&self.inner, &mut obj.client, metrics).await?;

        if !*obj.session_state_modified.get_mut() {
            return Ok(());
        }

        match tokio::time::timeout(
            self.session_reset_timeout,
            obj.client.batch_execute(SESSION_RESET_SQL),
        )
        .await
        {
            Ok(Ok(())) => {
                *obj.session_state_modified.get_mut() = false;
                Ok(())
            }
            Ok(Err(error)) => {
                tracing::warn!("Discarding connection whose session reset failed: {error}");
                Err(DeadpoolRecycleError::Backend(error))
            }
            Err(_) => {
                tracing::warn!(
                    "Discarding connection whose session reset exceeded {:?}",
                    self.session_reset_timeout
                );
                Err(DeadpoolRecycleError::message("session reset timed out"))
            }
        }
    }

    fn detach(&self, obj: &mut Self::Type) {
        DeadpoolManager::detach(&self.inner, &mut obj.client);
    }
}

pub type PoolConnection = DeadpoolObject<InstrumentedManager>;

#[derive(Debug)]
pub struct ConnectionPool {
    /// Recycles with `RecyclingMethod::Fast`, plus a session reset for
    /// connections whose borrower modified session state; see
    /// [`InstrumentedManager::recycle`]. The reset does not roll back an open
    /// transaction, which is why `Connection` rolls back on drop.
    pool: DeadpoolPool<InstrumentedManager>,
    max_pool_size: AtomicUsize,
    min_pool_size: Arc<AtomicUsize>,
    /// Nanosecond offset from `EPOCH` of the last `acquire_connection` call.
    /// Always written through [`now_epoch_nanos`].
    /// Uses `AtomicU64` instead of `RwLock<Instant>` to avoid async lock
    /// overhead on the hot acquire path.
    last_used_nanos: AtomicU64,
    metrics: Arc<ConnectionPoolMetrics>,
    identifier: String,
    credential_fingerprint: [u8; 32],
    max_connection_age: Arc<ArcSwap<Duration>>,
    max_connection_idle: Arc<ArcSwap<Duration>>,
    pruning_interval: Arc<ArcSwap<Duration>>,
    prune_task: Option<JoinHandle<()>>,
    /// Client-side deadline for statements executed on connections from this
    /// pool; see [`command_deadline_for`].
    command_deadline: Duration,
}

impl ConnectionPool {
    /// Creates a pool with on-demand connections and background pruning.
    ///
    /// # Errors
    ///
    /// Returns error if the operation fails.
    pub fn new_with_user(
        setup_configuration: &dyn SetupConfiguration,
        query_catalog: &QueryCatalog,
        user: &str,
        password: Option<&str>,
        application_name: &str,
        pool_settings: PgPoolSettings,
    ) -> Result<Self> {
        Self::new_with_user_and_tls(
            setup_configuration,
            query_catalog,
            user,
            password,
            application_name,
            pool_settings,
            &NoTls,
            SslMode::Prefer,
        )
    }

    /// Builds a pool whose transport security is supplied by the caller.
    ///
    /// `tls` is the mechanism, `ssl_mode` the policy: supplying a connector does
    /// not by itself require the backend to negotiate.
    /// Connections open on demand; call [`Self::pre_allocate_connections`] for
    /// startup warmup.
    ///
    /// # Errors
    ///
    /// Returns error if the underlying pool fails to build.
    #[expect(
        clippy::too_many_arguments,
        reason = "mirrors `new_with_user` plus the transport the caller supplies"
    )]
    pub fn new_with_user_and_tls<T>(
        setup_configuration: &dyn SetupConfiguration,
        query_catalog: &QueryCatalog,
        user: &str,
        password: Option<&str>,
        application_name: &str,
        pool_settings: PgPoolSettings,
        tls: &T,
        ssl_mode: SslMode,
    ) -> Result<Self>
    where
        T: MakeTlsConnect<Socket> + Clone + Send + Sync + 'static,
        T::Stream: Send + Sync,
        T::TlsConnect: Send + Sync,
        <T::TlsConnect as TlsConnect<Socket>>::Future: Send,
    {
        let command_timeout = command_timeout_for(pool_settings);
        let max_connections = pool_settings.data_pool_max_connections();
        let connection = BackendConnectionConfig {
            command_timeout,
            transaction_timeout: pool_settings.transaction_timeout(),
            connect_timeout: pool_settings.connect_timeout(),
            ssl_mode,
        };

        let config = pg_configuration(
            setup_configuration,
            query_catalog,
            user,
            password,
            application_name,
            pool_settings.connection_buffer_size(),
            connection,
        );

        let metrics = Arc::new(ConnectionPoolMetrics::default());
        let command_deadline = command_timeout.saturating_add(COMMAND_DEADLINE_SLACK);
        let manager = InstrumentedManager::new(
            PostgresManager::from_config(
                config,
                T::clone(tls),
                ManagerConfig {
                    recycling_method: RecyclingMethod::Fast,
                },
            ),
            Arc::clone(&metrics),
            // The same bound `Connection` applies to its own housekeeping.
            command_deadline,
        );

        let pool = DeadpoolPool::builder(manager)
            .runtime(Runtime::Tokio1)
            .max_size(max_connections)
            .wait_timeout(Some(command_timeout))
            // A second, outer bound: the client-side connect timeout covers
            // the socket only, leaving negotiation and startup unbounded.
            .create_timeout(pool_settings.connect_timeout())
            .build()?;

        let mut hasher = DefaultHasher::new();
        user.hash(&mut hasher);
        let pool_identifier = format!(
            "{:x}-{application_name}-{}",
            hasher.finish(),
            max_connections
        );

        let mut connection_pool = Self {
            pool,
            max_pool_size: AtomicUsize::new(pool_settings.data_pool_max_connections()),
            min_pool_size: Arc::new(AtomicUsize::new(pool_settings.data_pool_min_connections())),
            last_used_nanos: AtomicU64::new(now_epoch_nanos()),
            metrics,
            identifier: pool_identifier,
            credential_fingerprint: credential_fingerprint(password),
            max_connection_age: Arc::new(ArcSwap::from_pointee(
                pool_settings.connection_lifetime(),
            )),
            max_connection_idle: Arc::new(ArcSwap::from_pointee(
                pool_settings.connection_idle_lifetime(),
            )),
            pruning_interval: Arc::new(ArcSwap::from_pointee(
                pool_settings.connection_pruning_interval(),
            )),
            prune_task: None,
            command_deadline,
        };
        connection_pool.prune_task = Some(connection_pool.spawn_prune_task());

        Ok(connection_pool)
    }

    /// Warms the pool within a 30-second total budget. Failures are logged and
    /// leave the pool usable on demand.
    pub async fn pre_allocate_connections(&self) {
        if let Err(error) =
            Self::pre_allocate_pool_connections(&self.pool, &self.metrics, self.get_min_pool_size())
                .await
        {
            tracing::warn!(
                event_id = EventId::ConnectionPool.code(),
                error = %error,
                "Backend connection preallocation failed"
            );
        }
    }

    fn spawn_prune_task(&self) -> JoinHandle<()> {
        // `Pool` is internally `Arc`-wrapped, so cloning shares state with the pruner.
        let pool = self.pool.clone();
        let min_pool_size = Arc::clone(&self.min_pool_size);
        let max_connection_age = Arc::clone(&self.max_connection_age);
        let max_connection_idle = Arc::clone(&self.max_connection_idle);
        let pruning_interval = Arc::clone(&self.pruning_interval);

        tokio::spawn(async move {
            let mut prune_interval = tokio::time::interval(**pruning_interval.load());

            loop {
                prune_interval.tick().await;

                let pool_status = pool.status();
                let prunable_connection_count = pool_status
                    .size
                    .saturating_sub(min_pool_size.load(Ordering::Relaxed));

                // Do not prune connections if the pool is already at or below the minimum.
                if prunable_connection_count > 0 {
                    let max_connection_age = **max_connection_age.load();
                    let max_connection_idle = **max_connection_idle.load();
                    let mut pruned_connection_count = 0;

                    // Prune expired idle connections without reducing the pool below its minimum.
                    pool.retain(|_, conn_metrics| {
                        if pruned_connection_count >= prunable_connection_count {
                            return true;
                        }

                        if conn_metrics.last_used() < max_connection_idle
                            && conn_metrics.age() < max_connection_age
                        {
                            return true;
                        }

                        pruned_connection_count += 1;
                        false
                    });
                }

                let interval = **pruning_interval.load();
                if interval != prune_interval.period() {
                    prune_interval = tokio::time::interval_at(Instant::now() + interval, interval);
                }
            }
        })
    }

    fn abort_prune_task(&self) {
        if let Some(prune_task) = &self.prune_task {
            prune_task.abort();
        }
    }

    #[must_use]
    pub fn get_max_pool_size(&self) -> usize {
        self.max_pool_size.load(Ordering::Relaxed)
    }

    pub fn set_max_pool_size(&self, max_pool_size: usize) {
        self.max_pool_size.store(max_pool_size, Ordering::Relaxed);
        self.pool.resize(max_pool_size);
    }

    #[must_use]
    pub fn get_min_pool_size(&self) -> usize {
        self.min_pool_size.load(Ordering::Relaxed)
    }

    pub fn set_min_pool_size(&self, min_pool_size: usize) {
        self.min_pool_size.store(min_pool_size, Ordering::Relaxed);
    }

    /// Returns the maximum lifetime allowed for a pooled connection.
    #[must_use]
    pub fn get_max_connection_age(&self) -> Duration {
        **self.max_connection_age.load()
    }

    /// Updates the maximum lifetime allowed for a pooled connection.
    pub fn set_max_connection_age(&self, max_connection_age: Duration) {
        self.max_connection_age.store(Arc::new(max_connection_age));
    }

    /// Returns the maximum idle lifetime allowed for a pooled connection.
    #[must_use]
    pub fn get_max_connection_idle(&self) -> Duration {
        **self.max_connection_idle.load()
    }

    /// Updates the maximum idle lifetime allowed for a pooled connection.
    pub fn set_max_connection_idle(&self, max_connection_idle: Duration) {
        self.max_connection_idle
            .store(Arc::new(max_connection_idle));
    }

    /// Returns the interval between connection-pruning passes.
    #[must_use]
    pub fn get_pruning_interval(&self) -> Duration {
        **self.pruning_interval.load()
    }

    /// Updates the interval between connection-pruning passes.
    pub fn set_pruning_interval(&self, pruning_interval: Duration) {
        self.pruning_interval.store(Arc::new(pruning_interval));
    }

    /// Acquires a connection from the pool.
    ///
    /// A connection whose previous borrower modified session state is reset
    /// before it is returned; see [`InstrumentedManager::recycle`].
    ///
    /// On a deadpool acquisition timeout, the pool's `connection_timeouts`
    /// metric is incremented before the error is returned.
    ///
    /// # Errors
    /// Returns a [`deadpool_postgres::PoolError`] if the pool is exhausted or
    /// the connection cannot be established.
    #[cfg_attr(
        feature = "request-tracing",
        tracing::instrument(
            name = "postgres.acquire_connection",
            skip_all,
            fields(span.kind = "client", db.system.name = "postgresql")
        )
    )]
    pub async fn acquire_connection(
        &self,
    ) -> std::result::Result<PoolConnection, deadpool_postgres::PoolError> {
        self.touch();

        self.pool.get().await.inspect_err(|error| {
            self.metrics.record_timeout_if_pool_timeout(error);
        })
    }

    /// Records one successfully created backend connection for this logical
    /// pool and accumulates its creation duration in microseconds.
    ///
    /// Visible to in-crate tests; production paths record automatically via
    /// the deadpool `Manager` adapter.
    #[cfg(test)]
    pub(crate) fn record_connection_created(&self, create_time: Duration) {
        self.metrics.record_connection_created(create_time);
    }

    /// Records one pool-acquisition timeout for this logical pool.
    ///
    /// Visible to in-crate tests; production paths record automatically from
    /// [`Self::acquire_connection`].
    #[cfg(test)]
    pub(crate) fn record_connection_timeout(&self) {
        self.metrics.record_connection_timeout();
    }

    pub fn last_used(&self) -> Instant {
        time::u64_to_instant(self.last_used_nanos.load(Ordering::Relaxed))
    }

    /// Records use of this pool, refreshing the window `clean_unused_pools`
    /// measures. Handing the pool to a caller counts as use, not just acquiring
    /// a connection from it, so a pool handed out is never disposed on a stale
    /// timestamp before its first acquire.
    pub(crate) fn touch(&self) {
        self.last_used_nanos
            .store(now_epoch_nanos(), Ordering::Relaxed);
    }

    /// Whether the pool still has connections checked out. deadpool reports
    /// these counters with eventual consistency, so this only ever keeps a pool
    /// alive — a stale reading costs one extra sweep, never a live eviction.
    pub(crate) fn has_checked_out_connections(&self) -> bool {
        let status = self.pool.status();
        status.size.saturating_sub(status.available) > 0
    }

    /// Whether this pool was built with `password`, and can therefore still
    /// serve a connection authenticating with that credential.
    pub(crate) fn matches_credential(&self, password: Option<&str>) -> bool {
        openssl::memcmp::eq(
            &self.credential_fingerprint,
            &credential_fingerprint(password),
        )
    }

    /// Client-side deadline applied to statements executed without a result set
    /// on connections handed out by this pool.
    #[must_use]
    pub const fn command_deadline(&self) -> Duration {
        self.command_deadline
    }

    /// Returns a non-mutating status snapshot for this logical pool.
    pub fn status(&self) -> ConnectionPoolStatus {
        ConnectionPoolStatus::new_with_metric_snapshot(
            self.identifier.clone(),
            self.pool.status(),
            self.metrics.snapshot(),
        )
    }

    /// Returns the reporting snapshot for this logical pool and clears the
    /// interval counters used for pool metric reporting.
    pub fn report_status(&self) -> ConnectionPoolStatus {
        ConnectionPoolStatus::new_with_metric_snapshot(
            self.identifier.clone(),
            self.pool.status(),
            self.metrics.flush(),
        )
    }

    /// Labels this pool's backend connection instruments with `role`. The
    /// first assignment wins; until then the pool records no instruments.
    pub(super) fn assign_role(&self, role: PoolRole) {
        self.metrics.assign_role(role);
    }

    /// The role this pool serves, once assigned.
    pub(super) fn role(&self) -> Option<PoolRole> {
        self.metrics.role()
    }

    /// Returns the deadpool status for this logical pool.
    pub(super) fn combined_status(&self) -> Status {
        self.pool.status()
    }

    /// Preallocates connections without recording request activity.
    /// Waiting requests take priority, so contention can stop warmup early.
    /// The entire operation is limited to 30 seconds; cancellation releases
    /// held connections and any in-flight acquisition.
    async fn pre_allocate_pool_connections(
        pool: &DeadpoolPool<InstrumentedManager>,
        metrics: &ConnectionPoolMetrics,
        min_pool_size: usize,
    ) -> std::result::Result<(), deadpool_postgres::PoolError> {
        let status = pool.status();
        let target_size = min_pool_size.min(status.max_size);
        if status.size >= target_size {
            return Ok(());
        }

        let mut timeouts = pool.timeouts();
        timeouts.wait = Some(Duration::ZERO);
        timeouts.create = Some(timeouts.create.unwrap_or(PRE_ALLOCATION_TIMEOUT));

        if let Ok(result) = tokio::time::timeout(PRE_ALLOCATION_TIMEOUT, async {
            // Hold idle connections so subsequent checkouts create new ones
            // rather than repeatedly recycling the same connection.
            let mut connections = Vec::with_capacity(target_size);
            while connections.len() < target_size {
                let status = pool.status();
                if status.size >= target_size.min(status.max_size) || status.waiting > 0 {
                    break;
                }

                connections.push(pool.timeout_get(&timeouts).await.inspect_err(|error| {
                    metrics.record_timeout_if_pool_timeout(error);
                })?);
            }
            Ok(())
        })
        .await
        {
            result
        } else {
            let error = deadpool_postgres::PoolError::Timeout(TimeoutType::Create);
            metrics.record_timeout_if_pool_timeout(&error);
            Err(error)
        }
    }
}

impl Drop for ConnectionPool {
    fn drop(&mut self) {
        // Stop the background pruner when the pool is dropped.
        self.abort_prune_task();
    }
}

#[cfg(test)]
mod tests {
    use std::{iter, time::Instant as WallClockInstant};

    use tokio::{
        io::{AsyncReadExt, AsyncWriteExt},
        net::TcpListener,
        sync::oneshot,
        task::{yield_now, JoinSet},
    };

    use super::*;
    use crate::{
        configuration::DocumentDBSetupConfiguration,
        postgres::{conn_mgmt::PoolManager, create_query_catalog},
        telemetry::consts::{labels, metric_names},
        testing::{
            test_connection_pool, test_setup_configuration, RecordingMetricsRecorder,
            TestDynamicConfiguration,
        },
    };

    #[tokio::test]
    async fn test_new_with_user_with_valid_config_creates_pool() {
        let setup_config = test_setup_configuration();
        let pool = test_connection_pool(
            &setup_config,
            &setup_config.postgres_system_user.clone(),
            10,
        )
        .await;

        let status = pool.status();
        assert_eq!(status.status().max_size, 10);
        assert_eq!(status.status().size, 0);
        assert_eq!(status.status().available, 0);
        assert_eq!(status.connections_created(), 0);
        assert_eq!(status.connection_create_time_us(), 0);
        assert_eq!(status.connection_timeouts(), 0);
    }

    /// A single pool serves every request, so the reported capacity is the
    /// configured maximum rather than a multiple of it.
    #[tokio::test]
    async fn test_status_reports_configured_max_size() {
        yield_now().await;

        let setup_config = test_setup_configuration();
        let pool =
            test_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 5)
                .await;

        let status = pool.status();
        assert_eq!(status.status().max_size, 5);
    }

    #[tokio::test]
    async fn test_new_with_user_with_different_users_produces_different_identifiers() {
        yield_now().await;

        let setup_config = test_setup_configuration();
        let query_catalog = create_query_catalog();
        let settings = PgPoolSettings::system_pool_settings(5);

        let pool_a = ConnectionPool::new_with_user(
            &setup_config,
            &query_catalog,
            "alice",
            None,
            "test-app",
            settings,
        )
        .unwrap();

        let pool_b = ConnectionPool::new_with_user(
            &setup_config,
            &query_catalog,
            "bob",
            None,
            "test-app",
            settings,
        )
        .unwrap();

        assert_ne!(pool_a.status().identifier(), pool_b.status().identifier());
    }

    #[tokio::test]
    async fn test_new_with_user_with_same_user_produces_same_identifier() {
        yield_now().await;

        let setup_config = test_setup_configuration();
        let query_catalog = create_query_catalog();
        let settings = PgPoolSettings::system_pool_settings(5);

        let pool_a = ConnectionPool::new_with_user(
            &setup_config,
            &query_catalog,
            "alice",
            None,
            "test-app",
            settings,
        )
        .unwrap();

        let pool_b = ConnectionPool::new_with_user(
            &setup_config,
            &query_catalog,
            "alice",
            None,
            "test-app",
            settings,
        )
        .unwrap();

        assert_eq!(pool_a.status().identifier(), pool_b.status().identifier());
    }

    #[tokio::test]
    async fn test_identifier_with_application_name_includes_name_and_size() {
        yield_now().await;

        let setup_config = test_setup_configuration();
        let query_catalog = create_query_catalog();

        let pool = ConnectionPool::new_with_user(
            &setup_config,
            &query_catalog,
            "testuser",
            None,
            "my-gw",
            PgPoolSettings::system_pool_settings(7),
        )
        .unwrap();

        let id = pool.status().identifier().to_owned();
        assert!(id.contains("my-gw"), "identifier should contain app name");
        assert!(
            id.contains('7'),
            "identifier should contain max connections"
        );
    }

    #[tokio::test]
    async fn test_last_used_with_fresh_pool_returns_recent_instant() {
        let before = Instant::now();
        let setup_config = test_setup_configuration();
        let pool =
            test_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 2)
                .await;

        assert!(pool.last_used() >= before);
        assert!(
            pool.last_used() - before < Duration::from_millis(250),
            "a fresh pool must record `last_used` as nanoseconds since the clock epoch"
        );
    }

    /// `last_used` feeds `PoolManager::clean_unused_pools`, so every acquire
    /// must record activity in the domain `last_used` decodes from.
    #[tokio::test]
    async fn test_acquire_connection_advances_last_used_with_elapsed_time() {
        let setup_config = test_setup_configuration();
        let pool =
            test_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 2)
                .await;

        // `last_used` is recorded before the acquisition attempt, so this holds
        // whether or not a live PostgreSQL backend answers.
        let before_acquire = Instant::now();
        let _ = pool.acquire_connection().await;
        let first_use = pool.last_used();

        let skew = first_use.max(before_acquire) - first_use.min(before_acquire);
        assert!(
            skew < Duration::from_millis(250),
            "last_used must be recorded as nanoseconds since the clock epoch, off by {skew:?}"
        );

        tokio::time::sleep(Duration::from_millis(200)).await;
        let _ = pool.acquire_connection().await;

        let advance = pool.last_used().saturating_duration_since(first_use);
        assert!(
            advance >= Duration::from_millis(150),
            "last_used must advance with elapsed time, advanced by {advance:?}"
        );
    }

    #[test]
    fn test_credential_fingerprint_separates_absent_from_empty_credential() {
        assert_ne!(
            credential_fingerprint(None),
            credential_fingerprint(Some("")),
            "an absent credential must not fingerprint as an empty one"
        );
    }

    #[test]
    fn test_pg_configuration_with_password_sets_password() {
        let setup_config = test_setup_configuration();
        let query_catalog = create_query_catalog();

        let config = pg_configuration(
            &setup_config,
            &query_catalog,
            "user",
            Some("secret"),
            "app",
            262_144,
            test_connection(None),
        );
        let password = config.get_password().expect("password should be set");
        assert_eq!(password, b"secret");
    }

    #[test]
    fn test_pg_configuration_with_no_password_omits_password() {
        let setup_config = test_setup_configuration();
        let query_catalog = create_query_catalog();

        let config = pg_configuration(
            &setup_config,
            &query_catalog,
            "user",
            None,
            "app",
            262_144,
            test_connection(None),
        );
        assert!(config.get_password().is_none());
    }

    #[test]
    fn test_pg_configuration_uses_the_configured_endpoint() {
        let setup_config = test_setup_configuration();
        let query_catalog = create_query_catalog();

        let config = pg_configuration(
            &setup_config,
            &query_catalog,
            "user",
            None,
            "app",
            262_144,
            test_connection(None),
        );

        assert_eq!(config.get_ports(), &[setup_config.postgres_port()]);
        assert!(
            config.get_connect_timeout().is_none(),
            "an unset connect timeout must not impose one"
        );
    }

    #[test]
    fn test_pg_configuration_applies_the_connect_timeout() {
        let setup_config = test_setup_configuration();
        let query_catalog = create_query_catalog();

        let config = pg_configuration(
            &setup_config,
            &query_catalog,
            "user",
            None,
            "app",
            262_144,
            test_connection(Some(Duration::from_secs(5))),
        );

        // On the PostgreSQL config, so the failure carries the endpoint that timed out.
        assert_eq!(config.get_connect_timeout(), Some(&Duration::from_secs(5)));
    }

    #[test]
    fn test_pg_configuration_requires_tls_only_when_asked() {
        let setup_config = test_setup_configuration();
        let query_catalog = create_query_catalog();

        let default_config = pg_configuration(
            &setup_config,
            &query_catalog,
            "user",
            None,
            "app",
            262_144,
            test_connection(None),
        );
        assert_eq!(
            default_config.get_ssl_mode(),
            SslMode::Prefer,
            "a backend reached over a trusted local socket keeps the driver default"
        );

        let mut secured = test_connection(None);
        secured.ssl_mode = SslMode::Require;
        let secured_config = pg_configuration(
            &setup_config,
            &query_catalog,
            "user",
            None,
            "app",
            262_144,
            secured,
        );

        assert_eq!(secured_config.get_ssl_mode(), SslMode::Require);
    }

    /// A backend that accepts the connection and then goes quiet. The client-side
    /// connect timeout does not cover the negotiation that follows, so without a
    /// creation timeout the acquire never returns.
    #[tokio::test]
    async fn a_silent_backend_does_not_hang_the_acquire() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let accept_task = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            // Hold the connection open and answer nothing.
            tokio::time::sleep(Duration::from_secs(30)).await;
            drop(socket);
        });

        let recorder = RecordingMetricsRecorder::default();
        let pool = data_pool(&recorder, port);

        let started = Instant::now();
        pool.acquire_connection()
            .await
            .expect_err("a backend that never answers cannot produce a connection");

        assert!(
            started.elapsed() < Duration::from_secs(10),
            "the acquire must be bounded by the creation timeout, not left to hang"
        );
        assert_eq!(
            recorder.counter(metric_names::BACKEND_CONNECTION_POOL_TIMEOUT_COUNT, &[DATA]),
            Some(1)
        );
        assert_eq!(failed_creations(&recorder, "network"), Some(1));

        accept_task.abort();
    }

    #[tokio::test]
    async fn rejected_connections_are_counted_by_error_type() {
        for (code, error_type) in [
            ("28P01", "auth"),
            ("53300", "connection_limit"),
            ("57P03", "other"),
        ] {
            let (port, backend) = scripted_backend(error_response(code)).await;
            let recorder = RecordingMetricsRecorder::default();
            let pool = data_pool(&recorder, port);

            pool.acquire_connection()
                .await
                .expect_err("the backend rejects the connection");

            for failure in ["auth", "connection_limit", "network", "other"] {
                let expected = u64::from(failure == error_type);
                assert_eq!(
                    failed_creations(&recorder, failure),
                    Some(expected),
                    "SQLSTATE {code}, error.type {failure}"
                );
            }
            assert_eq!(
                recorder.counter(metric_names::BACKEND_CONNECTION_CREATE_COUNT, &[DATA]),
                Some(0),
                "SQLSTATE {code}"
            );
            backend.abort();
        }
    }

    #[tokio::test]
    async fn an_unreachable_backend_is_a_network_failure() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);

        let recorder = RecordingMetricsRecorder::default();
        let pool = data_pool(&recorder, port);

        pool.acquire_connection()
            .await
            .expect_err("nothing listens on the port");

        assert_eq!(failed_creations(&recorder, "network"), Some(1));
        assert_eq!(
            recorder.counter(metric_names::BACKEND_CONNECTION_POOL_TIMEOUT_COUNT, &[DATA]),
            Some(0)
        );
    }

    #[tokio::test]
    async fn a_created_connection_is_counted_without_an_error_type() {
        // AuthenticationOk, then ReadyForQuery with an idle transaction status.
        let ready = vec![b'R', 0, 0, 0, 8, 0, 0, 0, 0, b'Z', 0, 0, 0, 5, b'I'];
        let (port, backend) = scripted_backend(ready).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = data_pool(&recorder, port);

        let connection = pool
            .acquire_connection()
            .await
            .expect("the backend accepts the connection");

        assert_eq!(
            recorder.counter(metric_names::BACKEND_CONNECTION_CREATE_COUNT, &[DATA]),
            Some(1)
        );
        for failure in ["auth", "connection_limit", "network", "other"] {
            assert_eq!(failed_creations(&recorder, failure), Some(0), "{failure}");
        }

        drop(connection);
        backend.abort();
    }

    #[tokio::test]
    async fn explicit_preallocation_warms_the_configured_minimum() {
        let (port, backend) = scripted_backend(READY.to_vec()).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = backend_pool(
            &recorder,
            port,
            PgPoolSettings::system_pool_settings(4).with_min_pool_size_percent(25),
        );
        let last_used = pool.last_used();

        tokio::time::timeout(Duration::from_secs(5), pool.pre_allocate_connections())
            .await
            .expect("initial preallocation completes");

        assert_eq!(pool.combined_status().size, pool.get_min_pool_size());
        assert_eq!(pool.combined_status().size, 1);
        assert_eq!(pool.combined_status().available, 1);
        assert_eq!(pool.last_used(), last_used);
        assert_eq!(pool.status().connections_created(), 1);
        backend.abort();
    }

    #[tokio::test]
    async fn construction_does_not_preallocate_connections() {
        let (port, backend) = scripted_backend(READY.to_vec()).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = backend_pool(
            &recorder,
            port,
            PgPoolSettings::system_pool_settings(1).with_min_pool_size_percent(100),
        );

        yield_now().await;

        assert_eq!(pool.combined_status().size, 0);
        assert_eq!(pool.combined_status().waiting, 0);
        assert_eq!(pool.status().connections_created(), 0);
        backend.abort();
    }

    #[tokio::test]
    async fn startup_warms_the_shared_pool_used_by_requests() {
        let (port, backend) = scripted_backend(READY.to_vec()).await;
        let setup_config = DocumentDBSetupConfiguration {
            postgres_host_name: Some("127.0.0.1".to_owned()),
            postgres_port: Some(port),
            ..test_setup_configuration()
        };
        let query_catalog = create_query_catalog();
        let system_pool = |name| {
            ConnectionPool::new_with_user(
                &setup_config,
                &query_catalog,
                "user",
                None,
                name,
                PgPoolSettings::system_pool_settings(1),
            )
            .unwrap()
        };
        let requests = system_pool("requests");
        let auth = system_pool("auth");
        let manager = PoolManager::new(query_catalog, Box::new(setup_config), requests, auth);
        let dynamic_configuration = TestDynamicConfiguration::default();
        dynamic_configuration.set_min_data_pool_size_percent(25);
        let minimum =
            PgPoolSettings::from_configuration(&dynamic_configuration).data_pool_min_connections();
        assert!(minimum > 0);

        let pool = manager
            .get_system_shared_pool(&dynamic_configuration)
            .unwrap();
        tokio::time::timeout(Duration::from_secs(5), pool.pre_allocate_connections())
            .await
            .expect("startup warmup completes");

        let reused = manager
            .get_system_shared_pool(&dynamic_configuration)
            .unwrap();
        assert!(Arc::ptr_eq(&pool, &reused));
        assert_eq!(pool.combined_status().size, minimum);
        assert_eq!(pool.combined_status().available, minimum);
        let connection = reused.acquire_connection().await.unwrap();
        assert_eq!(pool.status().connections_created(), minimum as u64);
        drop(connection);
        backend.abort();
    }

    #[tokio::test]
    async fn prune_task_uses_updated_settings_and_respects_minimum() {
        let (port, backend) = scripted_backend(READY.to_vec()).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = backend_pool(
            &recorder,
            port,
            PgPoolSettings::system_pool_settings(4).with_min_pool_size_percent(25),
        );

        tokio::time::timeout(Duration::from_secs(5), pool.pre_allocate_connections())
            .await
            .expect("initial preallocation completes");

        let first = pool.acquire_connection().await.unwrap();
        let second = pool.acquire_connection().await.unwrap();
        drop(first);
        drop(second);

        pool.set_min_pool_size(2);
        pool.set_max_connection_age(Duration::ZERO);
        pool.set_max_connection_idle(Duration::ZERO);
        pool.set_pruning_interval(Duration::from_secs(1));

        assert_eq!(pool.get_max_connection_age(), Duration::ZERO);
        assert_eq!(pool.get_max_connection_idle(), Duration::ZERO);
        assert_eq!(pool.get_pruning_interval(), Duration::from_secs(1));

        yield_now().await;
        tokio::time::pause();
        tokio::time::advance(Duration::from_secs(11)).await;
        yield_now().await;

        assert_eq!(pool.combined_status().size, 2);

        pool.set_min_pool_size(1);
        tokio::time::advance(Duration::from_secs(2)).await;
        yield_now().await;

        assert_eq!(pool.combined_status().size, 1);

        pool.set_min_pool_size(0);
        tokio::time::advance(Duration::from_secs(2)).await;
        yield_now().await;

        assert_eq!(pool.combined_status().size, 0);
        backend.abort();
    }

    #[tokio::test]
    async fn preallocation_stops_at_the_minimum_not_the_maximum() {
        let (port, backend) = scripted_backend(READY.to_vec()).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = preallocation_pool(&recorder, port, 3, 8);
        let last_used = pool.last_used();

        preallocate(&pool).await.unwrap();

        assert_eq!(pool.combined_status().max_size, 8);
        assert_eq!(pool.combined_status().size, 3);
        assert_eq!(pool.combined_status().available, 3);
        assert_eq!(pool.last_used(), last_used);
        assert_eq!(
            recorder.counter(metric_names::BACKEND_CONNECTION_CREATE_COUNT, &[DATA]),
            Some(3)
        );
        backend.abort();
    }

    #[tokio::test]
    async fn preallocation_counts_existing_connections_and_caps_the_target() {
        let (port, backend) = scripted_backend(READY.to_vec()).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = data_pool(&recorder, port);
        pool.set_max_pool_size(4);
        let first = pool.acquire_connection().await.unwrap();
        let second = pool.acquire_connection().await.unwrap();
        drop(second);

        pool.set_min_pool_size(3);
        preallocate(&pool).await.unwrap();
        assert_eq!(pool.combined_status().size, 3);
        assert_eq!(pool.combined_status().available, 2);
        assert_eq!(pool.status().connections_created(), 3);
        drop(first);

        pool.set_min_pool_size(10);
        preallocate(&pool).await.unwrap();
        assert_eq!(pool.combined_status().size, 4);
        assert_eq!(pool.combined_status().available, 4);
        assert_eq!(pool.status().connections_created(), 4);
        backend.abort();
    }

    #[tokio::test]
    async fn preallocation_skips_a_zero_minimum_or_a_full_pool() {
        let (port, backend) = scripted_backend(READY.to_vec()).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = data_pool(&recorder, port);
        pool.set_min_pool_size(0);
        preallocate(&pool).await.unwrap();
        assert_eq!(pool.status().connections_created(), 0);

        let connection = pool.acquire_connection().await.unwrap();
        pool.set_min_pool_size(1);
        preallocate(&pool).await.unwrap();
        assert_eq!(pool.status().connections_created(), 1);
        drop(connection);
        backend.abort();
    }

    #[tokio::test]
    async fn preallocation_records_backend_creation_failures() {
        let (port, backend) = scripted_backend(error_response("28P01")).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = preallocation_pool(&recorder, port, 2, 4);

        let error = preallocate(&pool).await.unwrap_err();
        assert!(matches!(error, deadpool::managed::PoolError::Backend(_)));

        assert_eq!(failed_creations(&recorder, "auth"), Some(1));
        assert_eq!(pool.combined_status().size, 0);
        assert_eq!(pool.combined_status().waiting, 0);
        backend.abort();
    }

    #[tokio::test]
    async fn startup_preallocation_failure_is_nonfatal() {
        let (port, backend) =
            scripted_backend_replies(vec![error_response("53300"), READY.to_vec()].into_iter())
                .await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = backend_pool(
            &recorder,
            port,
            PgPoolSettings::system_pool_settings(2).with_min_pool_size_percent(100),
        );

        pool.pre_allocate_connections().await;

        assert_eq!(failed_creations(&recorder, "connection_limit"), Some(1));
        assert_eq!(pool.combined_status().size, 0);
        assert_eq!(pool.combined_status().waiting, 0);

        let connection = pool.acquire_connection().await.unwrap();
        assert_eq!(pool.status().connections_created(), 1);
        drop(connection);
        backend.abort();
    }

    #[tokio::test]
    async fn preallocation_yields_to_pending_requests() {
        let (port, backend) = scripted_backend(Vec::new()).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = data_pool(&recorder, port);
        pool.set_max_pool_size(2);
        pool.set_min_pool_size(2);
        let request_pool = pool.pool.clone();
        let request = tokio::spawn(async move { request_pool.get().await });
        tokio::time::timeout(Duration::from_secs(5), async {
            while pool.combined_status().waiting == 0 {
                yield_now().await;
            }
        })
        .await
        .expect("the request starts acquiring a connection");

        preallocate(&pool).await.unwrap();

        assert_eq!(pool.combined_status().waiting, 1);
        assert_eq!(pool.status().connections_created(), 0);
        assert_eq!(failed_creations(&recorder, "network"), Some(0));
        request.abort();
        request.await.expect_err("the pending request is cancelled");
        backend.abort();
    }

    #[tokio::test]
    async fn preallocation_respects_connect_timeout_and_releases_connections() {
        let (port, backend) =
            scripted_backend_replies(vec![READY.to_vec(), Vec::new()].into_iter()).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = backend_pool(
            &recorder,
            port,
            PgPoolSettings::system_pool_settings_with_command_timeout(2, 0)
                .with_connect_timeout(Duration::from_secs(1))
                .with_min_pool_size_percent(50),
        );
        pool.abort_prune_task();
        assert_eq!(pool.pool.timeouts().create, Some(Duration::from_secs(1)));
        preallocate(&pool).await.unwrap();

        pool.set_min_pool_size(2);
        let error = preallocate(&pool).await.unwrap_err();
        assert!(matches!(
            error,
            deadpool::managed::PoolError::Timeout(deadpool::managed::TimeoutType::Create)
        ));

        assert_eq!(pool.combined_status().size, 1);
        assert_eq!(pool.combined_status().available, 1);
        assert_eq!(pool.combined_status().waiting, 0);
        assert_eq!(
            recorder.counter(metric_names::BACKEND_CONNECTION_POOL_TIMEOUT_COUNT, &[DATA]),
            Some(1)
        );
        assert_eq!(failed_creations(&recorder, "network"), Some(1));
        backend.abort();
    }

    #[tokio::test(start_paused = true)]
    async fn startup_preallocation_has_thirty_seconds_total_and_exits_safely() {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let (release_reply, reply_ready) = oneshot::channel();
        let backend = tokio::spawn(async move {
            let (mut first, _) = listener.accept().await.unwrap();
            let length = usize::try_from(first.read_u32().await.unwrap()).unwrap();
            let mut startup = vec![0; length - 4];
            first.read_exact(&mut startup).await.unwrap();
            reply_ready.await.unwrap();
            first.write_all(&READY).await.unwrap();
            let (mut second, _) = listener.accept().await.unwrap();
            let mut remaining = Vec::new();
            let _ = second.read_to_end(&mut remaining).await;
            let _ = first.read_to_end(&mut remaining).await;
        });
        let recorder = RecordingMetricsRecorder::default();
        let pool = backend_pool(
            &recorder,
            port,
            PgPoolSettings::system_pool_settings_with_command_timeout(2, 0)
                .with_min_pool_size_percent(100),
        );
        pool.abort_prune_task();
        assert!(pool.pool.timeouts().create.is_none());
        let started = Instant::now();
        let mut preallocation = Box::pin(pool.pre_allocate_connections());
        let mut release_reply = Some(release_reply);

        for expected_size in [0, 1] {
            if expected_size == 1 {
                tokio::time::advance(Duration::from_secs(20)).await;
                release_reply.take().unwrap().send(()).unwrap();
            }
            let wait_started = WallClockInstant::now();
            tokio::select! {
                () = async {
                    loop {
                        let status = pool.combined_status();
                        if status.size == expected_size && status.waiting == 1 {
                            break;
                        }
                        assert!(wait_started.elapsed() < Duration::from_secs(5));
                        yield_now().await;
                    }
                } => {}
                result = &mut preallocation => {
                    panic!("preallocation exited before the total deadline: {result:?}");
                }
            }
        }

        tokio::time::advance(Duration::from_secs(9)).await;
        tokio::select! {
            biased;
            result = &mut preallocation => {
                panic!("preallocation exited before thirty seconds: {result:?}");
            }
            () = yield_now() => {}
        }
        tokio::time::advance(Duration::from_secs(1)).await;
        preallocation.await;

        assert_eq!(started.elapsed(), Duration::from_secs(30));
        assert_eq!(pool.combined_status().size, 1);
        assert_eq!(pool.combined_status().available, 1);
        assert_eq!(pool.combined_status().waiting, 0);
        assert_eq!(
            recorder.counter(metric_names::BACKEND_CONNECTION_POOL_TIMEOUT_COUNT, &[DATA]),
            Some(1)
        );
        let connection = pool.acquire_connection().await.unwrap();
        assert_eq!(pool.status().connections_created(), 1);
        drop(connection);
        backend.abort();
    }

    #[tokio::test]
    async fn cancelling_preallocation_returns_held_connections() {
        let (port, backend) =
            scripted_backend_replies(vec![READY.to_vec(), Vec::new()].into_iter()).await;
        let recorder = RecordingMetricsRecorder::default();
        let pool = preallocation_pool(&recorder, port, 2, 2);
        let mut preallocation = Box::pin(preallocate(&pool));

        tokio::time::timeout(Duration::from_secs(5), async {
            tokio::select! {
                () = async {
                    loop {
                        let status = pool.combined_status();
                        if status.size == 1 && status.waiting == 1 {
                            break;
                        }
                        yield_now().await;
                    }
                } => {}
                result = &mut preallocation => {
                    panic!("preallocation completed before cancellation: {result:?}");
                }
            }
        })
        .await
        .expect("preallocation holds one connection while creating the next");
        drop(preallocation);

        assert_eq!(pool.combined_status().size, 1);
        assert_eq!(pool.combined_status().available, 1);
        assert_eq!(pool.combined_status().waiting, 0);
        backend.abort();
    }

    const READY: [u8; 15] = [b'R', 0, 0, 0, 8, 0, 0, 0, 0, b'Z', 0, 0, 0, 5, b'I'];
    const DATA: (&str, &str) = (labels::BACKEND_CONNECTION_POOL_ROLE, "data");

    async fn preallocate(
        pool: &ConnectionPool,
    ) -> std::result::Result<(), deadpool_postgres::PoolError> {
        tokio::time::timeout(
            Duration::from_secs(5),
            ConnectionPool::pre_allocate_pool_connections(
                &pool.pool,
                &pool.metrics,
                pool.get_min_pool_size(),
            ),
        )
        .await
        .expect("preallocation is bounded")
    }

    fn preallocation_pool(
        recorder: &RecordingMetricsRecorder,
        port: u16,
        minimum: usize,
        maximum: usize,
    ) -> ConnectionPool {
        let pool = data_pool(recorder, port);
        pool.set_max_pool_size(maximum);
        pool.set_min_pool_size(minimum);
        pool
    }

    fn failed_creations(recorder: &RecordingMetricsRecorder, error_type: &str) -> Option<u64> {
        recorder.counter(
            metric_names::BACKEND_CONNECTION_CREATE_COUNT,
            &[DATA, (labels::ERROR_TYPE, error_type)],
        )
    }

    /// Builds a single-connection pool for a local test backend whose
    /// instruments report to `recorder` under the `data` role.
    fn data_pool(recorder: &RecordingMetricsRecorder, port: u16) -> ConnectionPool {
        let pool = backend_pool(
            recorder,
            port,
            PgPoolSettings::system_pool_settings(1).with_connect_timeout(Duration::from_secs(1)),
        );
        pool.abort_prune_task();
        pool
    }

    fn backend_pool(
        recorder: &RecordingMetricsRecorder,
        port: u16,
        settings: PgPoolSettings,
    ) -> ConnectionPool {
        let setup_config = DocumentDBSetupConfiguration {
            postgres_host_name: Some("127.0.0.1".to_owned()),
            postgres_port: Some(port),
            ..test_setup_configuration()
        };

        let pool = ConnectionPool::new_with_user(
            &setup_config,
            &create_query_catalog(),
            "user",
            None,
            "app",
            settings,
        )
        .expect("the pool should build");
        metrics::with_local_recorder(recorder, || pool.assign_role(PoolRole::Data));
        pool
    }

    /// A backend that answers startup messages with `reply`, then holds each
    /// connection until the client closes it.
    async fn scripted_backend(reply: Vec<u8>) -> (u16, JoinHandle<()>) {
        scripted_backend_replies(iter::repeat(reply)).await
    }

    async fn scripted_backend_replies(
        replies: impl Iterator<Item = Vec<u8>> + Send + 'static,
    ) -> (u16, JoinHandle<()>) {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let backend = tokio::spawn(async move {
            let mut connections = JoinSet::new();
            for reply in replies {
                let (mut socket, _) = listener.accept().await.unwrap();
                connections.spawn(async move {
                    let length = usize::try_from(socket.read_u32().await.unwrap()).unwrap();
                    let mut startup = vec![0; length - 4];
                    socket.read_exact(&mut startup).await.unwrap();
                    socket.write_all(&reply).await.unwrap();
                    let mut remaining = Vec::new();
                    let _ = socket.read_to_end(&mut remaining).await;
                });
            }
            while let Some(result) = connections.join_next().await {
                result.unwrap();
            }
        });
        (port, backend)
    }

    /// Encodes a fatal `ErrorResponse` message carrying the SQLSTATE `code`.
    fn error_response(code: &str) -> Vec<u8> {
        let mut fields = Vec::new();
        for (field, value) in [
            (b'S', "FATAL"),
            (b'C', code),
            (b'M', "rejected by the test backend"),
        ] {
            fields.push(field);
            fields.extend_from_slice(value.as_bytes());
            fields.push(0);
        }
        fields.push(0);

        let length = u32::try_from(fields.len() + 4).unwrap();
        let mut message = vec![b'E'];
        message.extend_from_slice(&length.to_be_bytes());
        message.extend_from_slice(&fields);
        message
    }

    const fn test_connection(connect_timeout: Option<Duration>) -> BackendConnectionConfig {
        BackendConnectionConfig {
            command_timeout: Duration::from_mins(1),
            transaction_timeout: Duration::from_secs(30),
            connect_timeout,
            ssl_mode: SslMode::Prefer,
        }
    }
}
