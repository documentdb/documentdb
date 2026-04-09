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
    sync::atomic::{AtomicU64, Ordering},
};

use deadpool_postgres::{Manager, ManagerConfig, Pool, RecyclingMethod, Runtime, Status};
use tokio::{
    task::JoinHandle,
    time::{Duration, Instant},
};
use tokio_postgres::NoTls;

use crate::{
    configuration::SetupConfiguration,
    error::Result,
    postgres::{conn_mgmt::PgPoolSettings, QueryCatalog},
};

fn pg_configuration(
    setup_configuration: &dyn SetupConfiguration,
    query_catalog: &QueryCatalog,
    user: &str,
    password: Option<&str>,
    application_name: &str,
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

    config
}

pub type PoolConnection = deadpool_postgres::Object;

#[derive(Debug)]
pub struct ConnectionPoolStatus {
    identifier: String,
    status: Status,
}

impl ConnectionPoolStatus {
    #[must_use]
    pub const fn new(identifier: String, status: Status) -> Self {
        Self { identifier, status }
    }

    #[must_use]
    pub fn identifier(&self) -> &str {
        &self.identifier
    }

    #[must_use]
    pub const fn status(&self) -> Status {
        self.status
    }
}

/// Monotonic epoch used to convert `Instant` to a storable `u64`.
/// Set once at pool creation; all subsequent timestamps are offsets from this.
static EPOCH: std::sync::OnceLock<Instant> = std::sync::OnceLock::new();

fn epoch() -> Instant {
    *EPOCH.get_or_init(Instant::now)
}

fn instant_to_u64(instant: Instant) -> u64 {
    u64::try_from(instant.duration_since(epoch()).as_nanos()).unwrap_or(u64::MAX)
}

fn u64_to_instant(nanos: u64) -> Instant {
    epoch() + Duration::from_nanos(nanos)
}

#[derive(Debug)]
pub struct ConnectionPool {
    pool: Pool,
    /// Secondary pool for connections that may have session-level state
    /// (e.g. `SET statement_timeout`) modified per-request. Uses
    /// `RecyclingMethod::Clean` to reset all session state when a
    /// connection is returned
    timeout_pool: Pool,
    /// Nanosecond offset from `EPOCH` of the last `acquire_connection` call.
    /// Uses `AtomicU64` instead of `RwLock<Instant>` to avoid async lock
    /// overhead on the hot acquire path.
    last_used_nanos: AtomicU64,
    identifier: String,
    prune_task: JoinHandle<()>,
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
        );

        let build_pool = |pg_config: tokio_postgres::Config, recycling_method: RecyclingMethod| {
            let manager =
                Manager::from_config(pg_config, NoTls, ManagerConfig { recycling_method });

            Pool::builder(manager)
                .runtime(Runtime::Tokio1)
                .max_size(pool_settings.adjusted_max_connections())
                .wait_timeout(Some(Duration::from_secs(
                    setup_configuration.postgres_command_timeout_secs(),
                )))
                .build()
        };

        // Primary pool — RecyclingMethod::Fast (no state reset on return)
        let pool = build_pool(config.clone(), RecyclingMethod::Fast)?;

        // Timeout pool — RecyclingMethod::Clean (resets session state on return)
        // Used for requests that SET statement_timeout at session level.
        let timeout_pool = build_pool(config, RecyclingMethod::Clean)?;

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

        Ok(Self {
            pool,
            timeout_pool,
            last_used_nanos: AtomicU64::new(instant_to_u64(Instant::now())),
            identifier: pool_identifier,
            prune_task,
        })
    }

    /// Acquires a connection from the primary pool.
    ///
    /// # Errors
    /// Returns a [`deadpool_postgres::PoolError`] if the pool is exhausted or
    /// the connection cannot be established.
    pub async fn acquire_connection(
        &self,
    ) -> std::result::Result<PoolConnection, deadpool_postgres::PoolError> {
        self.last_used_nanos
            .store(instant_to_u64(Instant::now()), Ordering::Relaxed);
        self.pool.get().await
    }

    /// Acquires a connection from the timeout pool.
    ///
    /// Connections from this pool have their session state reset (via
    /// `RecyclingMethod::Clean`) when returned, preventing session-level
    /// `SET statement_timeout` from leaking to subsequent requests.
    ///
    /// # Errors
    /// Returns a [`deadpool_postgres::PoolError`] if the pool is exhausted or
    /// the connection cannot be established.
    pub async fn acquire_timeout_connection(
        &self,
    ) -> std::result::Result<PoolConnection, deadpool_postgres::PoolError> {
        self.last_used_nanos
            .store(instant_to_u64(Instant::now()), Ordering::Relaxed);
        self.timeout_pool.get().await
    }

    pub fn last_used(&self) -> Instant {
        u64_to_instant(self.last_used_nanos.load(Ordering::Relaxed))
    }

    pub fn status(&self) -> ConnectionPoolStatus {
        let primary = self.pool.status();
        let timeout = self.timeout_pool.status();

        ConnectionPoolStatus {
            identifier: self.identifier.clone(),
            status: Status {
                max_size: primary.max_size + timeout.max_size,
                size: primary.size + timeout.size,
                available: primary.available + timeout.available,
                waiting: primary.waiting + timeout.waiting,
            },
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
    use super::*;
    use crate::{
        configuration::{CertInputType, CertificateOptions, DocumentDBSetupConfiguration},
        postgres::create_query_catalog,
    };
    use tokio::task::yield_now;

    fn setup_configuration() -> DocumentDBSetupConfiguration {
        let system_user = std::env::var("PostgresSystemUser").unwrap_or(whoami::username());

        DocumentDBSetupConfiguration {
            node_host_name: "localhost".to_owned(),
            blocked_role_prefixes: Vec::new(),
            gateway_listen_port: Some(10260),
            allow_transaction_snapshot: Some(false),
            certificate_options: CertificateOptions {
                cert_type: CertInputType::PemAutoGenerated,
                ..Default::default()
            },
            postgres_system_user: system_user.clone(),
            postgres_data_user: system_user,
            ..Default::default()
        }
    }

    // make this function fake-async so tests can `await`
    async fn test_pool(
        setup_config: &DocumentDBSetupConfiguration,
        user: &str,
        max_connections: usize,
    ) -> ConnectionPool {
        yield_now().await;

        let query_catalog = create_query_catalog();
        ConnectionPool::new_with_user(
            setup_config,
            &query_catalog,
            user,
            None,
            "test-app",
            PgPoolSettings::system_pool_settings(max_connections),
        )
        .expect("Failed to create connection pool")
    }

    #[expect(
        clippy::use_debug,
        reason = "we want to print the actual drift value in case of failure"
    )]
    #[test]
    fn test_instant_to_u64_with_roundtrip_preserves_value() {
        let _ = epoch();
        let now = Instant::now();
        let encoded = instant_to_u64(now);
        let decoded = u64_to_instant(encoded);

        let drift = if decoded > now {
            decoded - now
        } else {
            now - decoded
        };

        // Don't go above 100 microseconds since in this case you might have an
        // issue either with performance or with the precision of the encoding.
        // In practice, we expect this to be in the low microseconds or even nanoseconds, but
        // we see 20-30 microseconds in CI, so we use a more generous threshold to avoid flakes.
        println!("Duration for test_instant_to_u64_with_roundtrip_preserves_value: {drift:?}");
        assert!(drift < Duration::from_micros(100));
    }

    #[test]
    fn test_instant_to_u64_with_ordered_instants_preserves_ordering() {
        let first = Instant::now();
        let second = first + Duration::from_millis(50);

        assert!(instant_to_u64(second) > instant_to_u64(first));
    }

    #[tokio::test]
    async fn test_new_with_user_with_valid_config_creates_pool() {
        let setup_config = setup_configuration();
        let pool = test_pool(
            &setup_config,
            &setup_config.postgres_system_user.clone(),
            10,
        )
        .await;

        let status = pool.status();
        assert_eq!(status.status().max_size, 10 * 2); // accounts for both primary and timeout pools
        assert_eq!(status.status().size, 0);
        assert_eq!(status.status().available, 0);
    }

    #[tokio::test]
    async fn test_status_with_dual_pools_reports_combined_max_size() {
        yield_now().await;

        let setup_config = setup_configuration();
        let pool = test_pool(&setup_config, &setup_config.postgres_system_user.clone(), 5).await;

        let status = pool.status();
        assert_eq!(status.status().max_size, 10);
    }

    #[tokio::test]
    async fn test_new_with_user_with_different_users_produces_different_identifiers() {
        yield_now().await;

        let setup_config = setup_configuration();
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

        let setup_config = setup_configuration();
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

        let setup_config = setup_configuration();
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
        let setup_config = setup_configuration();
        let pool = test_pool(&setup_config, &setup_config.postgres_system_user.clone(), 2).await;

        assert!(pool.last_used() >= before);
        assert!(pool.last_used().elapsed() < Duration::from_secs(5));
    }

    #[test]
    fn test_connection_pool_status_new_with_values_stores_correctly() {
        let status = Status {
            max_size: 10,
            size: 3,
            available: 2,
            waiting: 1,
        };
        let pool_status = ConnectionPoolStatus::new("test-pool".to_owned(), status);

        assert_eq!(pool_status.identifier(), "test-pool");
        assert_eq!(pool_status.status().max_size, 10);
        assert_eq!(pool_status.status().size, 3);
        assert_eq!(pool_status.status().available, 2);
        assert_eq!(pool_status.status().waiting, 1);
    }

    #[test]
    fn test_pg_configuration_with_password_sets_password() {
        let setup_config = setup_configuration();
        let query_catalog = create_query_catalog();

        let config = pg_configuration(&setup_config, &query_catalog, "user", Some("secret"), "app");
        let password = config.get_password().expect("password should be set");
        assert_eq!(password, b"secret");
    }

    #[test]
    fn test_pg_configuration_with_no_password_omits_password() {
        let setup_config = setup_configuration();
        let query_catalog = create_query_catalog();

        let config = pg_configuration(&setup_config, &query_catalog, "user", None, "app");
        assert!(config.get_password().is_none());
    }
}
