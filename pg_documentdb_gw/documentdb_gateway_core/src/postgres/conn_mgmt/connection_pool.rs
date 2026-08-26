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
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    },
};

use deadpool::{
    managed::{
        Manager as DeadpoolManager, Metrics as DeadpoolMetrics, Object as DeadpoolObject,
        Pool as DeadpoolPool, RecycleResult as DeadpoolRecycleResult,
    },
    Runtime,
};
use deadpool_postgres::{
    ClientWrapper, Manager as PostgresManager, ManagerConfig, RecyclingMethod, Status,
};
use openssl::sha::Sha256;
use tokio::{
    task::JoinHandle,
    time::{Duration, Instant},
};
use tokio_postgres::NoTls;

use crate::{
    configuration::SetupConfiguration,
    error::Result,
    postgres::{
        conn_mgmt::{
            pool_metrics::{ConnectionPoolMetrics, ConnectionPoolStatus},
            PgPoolSettings,
        },
        QueryCatalog,
    },
    time::{self, EpochClock},
};

fn pg_configuration(
    setup_configuration: &dyn SetupConfiguration,
    query_catalog: &QueryCatalog,
    user: &str,
    password: Option<&str>,
    application_name: &str,
    connection_buffer_size: usize,
) -> tokio_postgres::Config {
    let mut config = tokio_postgres::Config::new();

    let command_timeout_ms =
        Duration::from_secs(setup_configuration.postgres_command_timeout_secs())
            .as_millis()
            .to_string();

    let transaction_timeout_ms =
        Duration::from_secs(setup_configuration.transaction_timeout_secs())
            .as_millis()
            .to_string();

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

/// Client-side deadline for a request that carries no timeout of its own;
/// `Connection::set_command_deadline` replaces it per request.
///
/// Catches a connection that has stopped responding, which no server-side GUC
/// covers.
#[must_use]
pub fn command_deadline_for(setup_configuration: &dyn SetupConfiguration) -> Duration {
    Duration::from_secs(setup_configuration.postgres_command_timeout_secs())
        .saturating_add(COMMAND_DEADLINE_SLACK)
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

/// Internal deadpool manager wrapper that records connection creation metrics.
#[doc(hidden)]
#[derive(Debug)]
pub struct InstrumentedManager {
    inner: PostgresManager,
    metrics: Arc<ConnectionPoolMetrics>,
}

impl InstrumentedManager {
    const fn new(inner: PostgresManager, metrics: Arc<ConnectionPoolMetrics>) -> Self {
        Self { inner, metrics }
    }
}

impl DeadpoolManager for InstrumentedManager {
    type Type = ClientWrapper;
    type Error = tokio_postgres::Error;

    async fn create(&self) -> std::result::Result<Self::Type, Self::Error> {
        let create_start = Instant::now();
        let client = DeadpoolManager::create(&self.inner).await?;
        self.metrics
            .record_connection_created(create_start.elapsed());
        Ok(client)
    }

    async fn recycle(
        &self,
        obj: &mut Self::Type,
        metrics: &DeadpoolMetrics,
    ) -> DeadpoolRecycleResult<Self::Error> {
        DeadpoolManager::recycle(&self.inner, obj, metrics).await
    }

    fn detach(&self, client: &mut Self::Type) {
        DeadpoolManager::detach(&self.inner, client);
    }
}

pub type PoolConnection = DeadpoolObject<InstrumentedManager>;

#[derive(Debug)]
pub struct ConnectionPool {
    pool: DeadpoolPool<InstrumentedManager>,
    /// Secondary pool for connections that may have session-level state
    /// (e.g. `SET statement_timeout`) modified per-request. Uses
    /// `RecyclingMethod::Clean`, which runs its reset when a connection is
    /// handed back *out* of the pool, not when it is returned. That reset
    /// covers GUCs, temp objects, cursors and advisory locks; it does not roll
    /// back an open transaction, which is why `Connection` rolls back on drop.
    timeout_pool: DeadpoolPool<InstrumentedManager>,
    /// Nanosecond offset from `EPOCH` of the last `acquire_connection` call.
    /// Always written through [`now_epoch_nanos`].
    /// Uses `AtomicU64` instead of `RwLock<Instant>` to avoid async lock
    /// overhead on the hot acquire path.
    last_used_nanos: AtomicU64,
    metrics: Arc<ConnectionPoolMetrics>,
    identifier: String,
    credential_fingerprint: [u8; 32],
    prune_task: JoinHandle<()>,
    /// Client-side deadline for statements executed on connections from this
    /// pool; see [`command_deadline_for`].
    command_deadline: Duration,
}

impl ConnectionPool {
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
        let config = pg_configuration(
            setup_configuration,
            query_catalog,
            user,
            password,
            application_name,
            pool_settings.connection_buffer_size(),
        );

        let metrics = Arc::new(ConnectionPoolMetrics::default());
        let build_pool = |pg_config: tokio_postgres::Config,
                          recycling_method: RecyclingMethod,
                          metrics: Arc<ConnectionPoolMetrics>| {
            let manager = InstrumentedManager::new(
                PostgresManager::from_config(pg_config, NoTls, ManagerConfig { recycling_method }),
                metrics,
            );

            DeadpoolPool::builder(manager)
                .runtime(Runtime::Tokio1)
                .max_size(pool_settings.adjusted_max_connections())
                .wait_timeout(Some(Duration::from_secs(
                    setup_configuration.postgres_command_timeout_secs(),
                )))
                .build()
        };

        // Primary pool — RecyclingMethod::Fast (liveness check only, no reset)
        let pool = build_pool(config.clone(), RecyclingMethod::Fast, Arc::clone(&metrics))?;

        // Timeout pool — RecyclingMethod::Clean (resets session state on
        // checkout). Used for requests that SET statement_timeout at session
        // level.
        let timeout_pool = build_pool(config, RecyclingMethod::Clean, Arc::clone(&metrics))?;

        // `Pool` is internally `Arc`-wrapped, so cloning shares state with the pruner.
        let pool_copy = pool.clone();
        let timeout_pool_copy = timeout_pool.clone();
        // Timeout pool connections are pruned more aggressively on idleness
        // to free slots back to the primary pool for general use.
        let timeout_idle_lifetime =
            Duration::from_secs(setup_configuration.postgres_command_timeout_secs());

        let prune_task = tokio::spawn(async move {
            let mut prune_interval =
                tokio::time::interval(pool_settings.connection_pruning_interval());

            loop {
                prune_interval.tick().await;

                // Prune idle connections that have exceeded idle lifetime or total lifetime
                pool_copy.retain(|_, conn_metrics| {
                    conn_metrics.last_used() < pool_settings.connection_idle_lifetime()
                        && conn_metrics.age() < pool_settings.connection_lifetime()
                });

                timeout_pool_copy.retain(|_, conn_metrics| {
                    conn_metrics.last_used() < timeout_idle_lifetime
                        && conn_metrics.age() < pool_settings.connection_lifetime()
                });
            }
        });

        let mut hasher = DefaultHasher::new();
        user.hash(&mut hasher);
        let pool_identifier = format!(
            "{:x}-{application_name}-{}",
            hasher.finish(),
            pool_settings.adjusted_max_connections()
        );

        let command_deadline = command_deadline_for(setup_configuration);

        Ok(Self {
            pool,
            timeout_pool,
            last_used_nanos: AtomicU64::new(now_epoch_nanos()),
            metrics,
            identifier: pool_identifier,
            credential_fingerprint: credential_fingerprint(password),
            prune_task,
            command_deadline,
        })
    }

    /// Acquires a connection from the primary pool.
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
            fields(span.kind = "client", db.system.name = "postgresql", pool = "primary")
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

    /// Acquires a connection from the timeout pool.
    ///
    /// Connections from this pool have their session state reset (via
    /// `RecyclingMethod::Clean`) when they are checked back out, preventing
    /// session-level `SET statement_timeout` from leaking to subsequent
    /// requests. That reset covers GUCs, temp objects, cursors and advisory
    /// locks; it does not roll back an open transaction.
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
            fields(span.kind = "client", db.system.name = "postgresql", pool = "timeout")
        )
    )]
    pub async fn acquire_timeout_connection(
        &self,
    ) -> std::result::Result<PoolConnection, deadpool_postgres::PoolError> {
        self.touch();

        self.timeout_pool.get().await.inspect_err(|error| {
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
    /// [`Self::acquire_connection`] / [`Self::acquire_timeout_connection`].
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
        let status = self.combined_status();
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
            self.combined_status(),
            self.metrics.snapshot(),
        )
    }

    /// Returns the reporting snapshot for this logical pool and clears the
    /// interval counters used for pool metric reporting.
    pub fn report_status(&self) -> ConnectionPoolStatus {
        ConnectionPoolStatus::new_with_metric_snapshot(
            self.identifier.clone(),
            self.combined_status(),
            self.metrics.flush(),
        )
    }

    fn combined_status(&self) -> Status {
        let primary = self.pool.status();
        let timeout = self.timeout_pool.status();

        Status {
            max_size: primary.max_size + timeout.max_size,
            size: primary.size + timeout.size,
            available: primary.available + timeout.available,
            waiting: primary.waiting + timeout.waiting,
        }
    }
}

impl Drop for ConnectionPool {
    fn drop(&mut self) {
        // Stop the background pruner when the pool is dropped.
        self.prune_task.abort();
    }
}

#[cfg(test)]
mod tests {
    use tokio::task::yield_now;

    use super::*;
    use crate::{
        postgres::create_query_catalog,
        testing::{test_connection_pool, test_setup_configuration},
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
        assert_eq!(status.status().max_size, 10 * 2); // accounts for both primary and timeout pools
        assert_eq!(status.status().size, 0);
        assert_eq!(status.status().available, 0);
        assert_eq!(status.connections_created(), 0);
        assert_eq!(status.connection_create_time_us(), 0);
        assert_eq!(status.connection_timeouts(), 0);
    }

    #[tokio::test]
    async fn test_status_with_dual_pools_reports_combined_max_size() {
        yield_now().await;

        let setup_config = test_setup_configuration();
        let pool =
            test_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 5)
                .await;

        let status = pool.status();
        assert_eq!(status.status().max_size, 10);
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

    /// `last_used` feeds `PoolManager::clean_unused_pools`, so both acquire
    /// paths must record activity in the domain `last_used` decodes from.
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
        let _ = pool.acquire_timeout_connection().await;

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
        );
        let password = config.get_password().expect("password should be set");
        assert_eq!(password, b"secret");
    }

    #[test]
    fn test_pg_configuration_with_no_password_omits_password() {
        let setup_config = test_setup_configuration();
        let query_catalog = create_query_catalog();

        let config = pg_configuration(&setup_config, &query_catalog, "user", None, "app", 262_144);
        assert!(config.get_password().is_none());
    }
}
