/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/postgres/conn_mgmt/pool_manager.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{hash::Hash, sync::Arc};

use dashmap::{mapref::entry::Entry, DashMap};
use tokio::time::{interval, Duration};

use crate::{
    configuration::{DynamicConfiguration, SetupConfiguration},
    context::ServiceContext,
    error::{DocumentDBError, Result},
    postgres::{
        conn_mgmt::{Connection, ConnectionPool, ConnectionPoolStatus, PgPoolSettings},
        QueryCatalog,
    },
    startup,
    telemetry::event_id::EventId,
};

type ClientKey = (String, PgPoolSettings);

pub const SYSTEM_REQUESTS_MAX_CONNECTIONS: usize = 2;
pub const AUTHENTICATION_MAX_CONNECTIONS: usize = 5;

/// How often we need to cleanup the old connection pools
const POSTGRES_POOL_CLEANUP_INTERVAL_SEC: u64 = 300;
/// The threshold when a connection pool needs to be disposed
const POSTGRES_POOL_DISPOSE_INTERVAL_SEC: u64 = 7200;

#[derive(Debug)]
pub struct PoolManager {
    query_catalog: QueryCatalog,
    setup_configuration: Box<dyn SetupConfiguration>,

    system_requests_pool: ConnectionPool,
    system_auth_pool: ConnectionPool,

    // Maps user credentials to their respective connection pools
    // We need Arc on the ConnectionPool to allow sharing across threads from different connections
    user_data_pools: DashMap<ClientKey, Arc<ConnectionPool>>,
    shared_data_pools: DashMap<PgPoolSettings, Arc<ConnectionPool>>,
}

impl PoolManager {
    pub fn new(
        query_catalog: QueryCatalog,
        setup_configuration: Box<dyn SetupConfiguration>,
        system_requests_pool: ConnectionPool,
        system_auth_pool: ConnectionPool,
    ) -> Self {
        PoolManager {
            query_catalog,
            setup_configuration,
            system_requests_pool,
            system_auth_pool,
            user_data_pools: DashMap::new(),
            shared_data_pools: DashMap::new(),
        }
    }

    pub async fn system_requests_connection(&self) -> Result<Connection> {
        Ok(Connection::new(
            self.system_requests_pool.acquire_connection().await?,
            false,
        ))
    }

    pub async fn authentication_connection(&self) -> Result<Connection> {
        Ok(Connection::new(
            self.system_auth_pool.acquire_connection().await?,
            false,
        ))
    }

    pub fn allocate_data_pool(
        &self,
        username: &str,
        password: &str,
        dynamic_configuration: &dyn DynamicConfiguration,
    ) -> Result<()> {
        let settings = PgPoolSettings::from_configuration(dynamic_configuration);
        let key = (username.to_string(), settings);

        let user_data_pool = Arc::new(ConnectionPool::new_with_user(
            self.setup_configuration.as_ref(),
            &self.query_catalog,
            username,
            Some(password),
            format!("{}-UserData", self.setup_configuration.application_name()),
            settings,
        )?);

        self.user_data_pools.insert(key, user_data_pool);

        Ok(())
    }

    pub fn get_data_pool(
        &self,
        username: &str,
        dynamic_configuration: &dyn DynamicConfiguration,
    ) -> Result<Arc<ConnectionPool>> {
        let settings = PgPoolSettings::from_configuration(dynamic_configuration);

        match self.user_data_pools.get(&(username.to_string(), settings)) {
            None => Err(DocumentDBError::internal_error(
                "Connection pool missing for user.".to_string(),
            )),
            Some(pool_ref) => Ok(Arc::clone(pool_ref.value())),
        }
    }

    pub fn get_system_shared_pool(
        &self,
        dynamic_configuration: &dyn DynamicConfiguration,
    ) -> Result<Arc<ConnectionPool>> {
        let settings = PgPoolSettings::from_configuration(dynamic_configuration);

        match self.shared_data_pools.entry(settings) {
            Entry::Occupied(pool_ref) => Ok(Arc::clone(pool_ref.get())),
            Entry::Vacant(entry) => {
                let system_shared_pool = Arc::new(ConnectionPool::new_with_user(
                    self.setup_configuration.as_ref(),
                    &self.query_catalog,
                    self.setup_configuration.postgres_data_user(),
                    self.setup_configuration.postgres_data_user_password(),
                    format!("{}-SharedData", self.setup_configuration.application_name()),
                    settings,
                )?);

                entry.insert(Arc::clone(&system_shared_pool));
                Ok(system_shared_pool)
            }
        }
    }

    pub async fn clean_unused_pools(&self, max_age: Duration) {
        async fn clean<K>(map: &DashMap<K, Arc<ConnectionPool>>, max_age: Duration)
        where
            K: Clone + Eq + Hash,
        {
            let entries: Vec<(K, Arc<ConnectionPool>)> = map
                .iter()
                .map(|entry| (entry.key().clone(), Arc::clone(entry.value())))
                .collect();

            for (key, pool) in entries {
                if pool.last_used().await.elapsed() > max_age {
                    map.remove(&key);
                }
            }
        }

        clean(&self.user_data_pools, max_age).await;
        clean(&self.shared_data_pools, max_age).await;
    }

    pub fn report_pool_stats(&self) -> Vec<ConnectionPoolStatus> {
        fn report<K>(map: &DashMap<K, Arc<ConnectionPool>>, reports: &mut Vec<ConnectionPoolStatus>)
        where
            K: Eq + Hash,
        {
            for entry in map.iter() {
                reports.push(entry.value().status())
            }
        }

        let mut pool_stats = vec![
            self.system_auth_pool.status(),
            self.system_requests_pool.status(),
        ];

        report(&self.user_data_pools, &mut pool_stats);
        report(&self.shared_data_pools, &mut pool_stats);

        pool_stats
    }

    pub fn query_catalog(&self) -> &QueryCatalog {
        &self.query_catalog
    }
}

pub fn clean_unused_pools(service_context: ServiceContext) {
    tokio::spawn(async move {
        let mut cleanup_interval =
            interval(Duration::from_secs(POSTGRES_POOL_CLEANUP_INTERVAL_SEC));

        let max_age = Duration::from_secs(POSTGRES_POOL_DISPOSE_INTERVAL_SEC);

        loop {
            cleanup_interval.tick().await;

            tracing::info!(
                event_id = EventId::ConnectionPool.code(),
                "Performing the cleanup of unused pools"
            );

            service_context
                .connection_pool_manager()
                .clean_unused_pools(max_age)
                .await;
        }
    });
}

async fn get_system_connection_pool(
    setup_configuration: &dyn SetupConfiguration,
    query_catalog: &QueryCatalog,
    pool_name: &str,
    max_connections: usize,
) -> ConnectionPool {
    // Capture necessary values to avoid lifetime issues
    let postgres_system_user = setup_configuration.postgres_system_user();
    let full_pool_name = format!("{}-{}", setup_configuration.application_name(), pool_name);

    startup::create_postgres_object(
        || async {
            ConnectionPool::new_with_user(
                setup_configuration,
                query_catalog,
                postgres_system_user,
                None,
                full_pool_name.clone(),
                PgPoolSettings::system_pool_settings(max_connections),
            )
        },
        setup_configuration,
    )
    .await
}

pub async fn create_connection_pool_manager(
    query_catalog: QueryCatalog,
    setup_configuration: Box<dyn SetupConfiguration>,
) -> Arc<PoolManager> {
    let system_requests_pool = get_system_connection_pool(
        setup_configuration.as_ref(),
        &query_catalog,
        "SystemRequests",
        SYSTEM_REQUESTS_MAX_CONNECTIONS,
    )
    .await;

    tracing::info!("SystemRequests pool initialized.");

    let authentication_pool = get_system_connection_pool(
        setup_configuration.as_ref(),
        &query_catalog,
        "PreAuthRequests",
        AUTHENTICATION_MAX_CONNECTIONS,
    )
    .await;

    tracing::info!("PreAuthRequests pool initialized.");

    Arc::new(PoolManager::new(
        query_catalog,
        setup_configuration,
        system_requests_pool,
        authentication_pool,
    ))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::{
        configuration::{
            CertInputType, CertificateOptions, DocumentDBSetupConfiguration, DynamicConfiguration,
            SetupConfiguration,
        },
        error::{DocumentDBError, ErrorCode},
        postgres::{conn_mgmt::ConnectionPool, create_query_catalog},
    };
    use bson::{rawbson, RawBson};
    use std::sync::atomic::{AtomicUsize, Ordering};
    use tokio::{
        task::yield_now,
        time::{sleep, Duration},
    };

    #[derive(Debug)]
    struct MaxConnectionConfig {
        // Needed for interior mutability in tests.
        max_conn: AtomicUsize,
    }

    impl MaxConnectionConfig {
        fn max_conn(&self) -> usize {
            self.max_conn.load(Ordering::Relaxed)
        }

        fn set_max_conn(&self, value: usize) {
            self.max_conn.store(value, Ordering::Relaxed)
        }
    }

    impl DynamicConfiguration for MaxConnectionConfig {
        fn get_str(&self, _: &str) -> Option<String> {
            Option::None
        }

        fn get_bool(&self, _: &str, _: bool) -> bool {
            false
        }

        fn get_i32(&self, _: &str, _: i32) -> i32 {
            i32::default()
        }

        fn get_u64(&self, _: &str, _: u64) -> u64 {
            u64::default()
        }

        fn equals_value(&self, _: &str, _: &str) -> bool {
            false
        }

        fn topology(&self) -> RawBson {
            rawbson!({})
        }

        fn enable_developer_explain(&self) -> bool {
            false
        }

        fn max_connections(&self) -> usize {
            self.max_conn()
        }

        fn allow_transaction_snapshot(&self) -> bool {
            false
        }

        fn as_any(&self) -> &dyn std::any::Any {
            self
        }

        // For testing simplicity set system_budget to be 0.
        fn system_connection_budget(&self) -> usize {
            0
        }
    }

    fn setup_configuration() -> DocumentDBSetupConfiguration {
        let system_user = std::env::var("PostgresSystemUser").unwrap_or(whoami::username());

        DocumentDBSetupConfiguration {
            node_host_name: "localhost".to_string(),
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

    fn test_pool_manager() -> PoolManager {
        let query_catalog = create_query_catalog();
        let setup_config = setup_configuration();
        let postgres_system_user = setup_config.postgres_system_user();

        let system_requests_pool = ConnectionPool::new_with_user(
            &setup_config,
            &query_catalog,
            postgres_system_user,
            None,
            format!("{}-SystemRequests", setup_config.application_name()),
            PgPoolSettings::system_pool_settings(SYSTEM_REQUESTS_MAX_CONNECTIONS),
        )
        .expect("Failed to create system requests pool");

        let authentication_pool = ConnectionPool::new_with_user(
            &setup_config,
            &query_catalog,
            postgres_system_user,
            None,
            format!("{}-PreAuthRequests", setup_config.application_name()),
            PgPoolSettings::system_pool_settings(AUTHENTICATION_MAX_CONNECTIONS),
        )
        .expect("Failed to create authentication pool");

        PoolManager::new(
            query_catalog,
            Box::new(setup_config.clone()),
            system_requests_pool,
            authentication_pool,
        )
    }

    #[tokio::test]
    async fn validate_pool_reusage() {
        // We still need an async context to create the connection pool (see ConnectionPool::new_with_user),
        // but the test itself doesn't need to be async since we are not awaiting anything after the pool creation,
        // so we can use yield_now to just get into async context and then proceed with sync code.
        yield_now().await;

        let pool_manager = test_pool_manager();

        assert_eq!(
            2,
            pool_manager.report_pool_stats().len(),
            "by default only 2 system pools exist"
        );

        let dynamic_configuration = MaxConnectionConfig {
            max_conn: 100.into(),
        };

        for _ in 0..10 {
            let shared_pool_result = pool_manager.get_system_shared_pool(&dynamic_configuration);
            assert!(
                shared_pool_result.is_ok(),
                "Couldn't allocate shared system pool"
            );

            let shared_pool = shared_pool_result.unwrap();
            assert_eq!(
                dynamic_configuration.max_conn(),
                shared_pool.status().status().max_size,
                "Should have the same size as declared by MaxConnectionConfig"
            );

            assert_eq!(
                3,
                pool_manager.report_pool_stats().len(),
                "2 system pools + 1 shared pool"
            )
        }
    }

    #[tokio::test]
    async fn validate_max_conn_change() {
        // We still need an async context to create the connection pool (see ConnectionPool::new_with_user),
        // but the test itself doesn't need to be async since we are not awaiting anything after the pool creation,
        // so we can use yield_now to just get into async context and then proceed with sync code.
        yield_now().await;

        let dynamic_configuration = MaxConnectionConfig {
            max_conn: 100.into(),
        };
        let pool_manager = test_pool_manager();

        let shared_pool = pool_manager
            .get_system_shared_pool(&dynamic_configuration)
            .unwrap();

        // change the max connection
        dynamic_configuration.set_max_conn(42);

        let new_shared_pool = pool_manager
            .get_system_shared_pool(&dynamic_configuration)
            .unwrap();

        assert_ne!(
            shared_pool.status().status().max_size,
            new_shared_pool.status().status().max_size,
            "New pool doesn't have updated size"
        );

        assert_eq!(
            4,
            pool_manager.report_pool_stats().len(),
            "2 system pool + 2 shared system pool"
        );
    }

    #[tokio::test]
    async fn validate_user_pwd_change() {
        // We still need an async context to create the connection pool (see ConnectionPool::new_with_user),
        // but the test itself doesn't need to be async since we are not awaiting anything after the pool creation,
        // so we can use yield_now to just get into async context and then proceed with sync code.
        yield_now().await;

        let dynamic_configuration = MaxConnectionConfig {
            max_conn: 100.into(),
        };
        let pool_manager = test_pool_manager();

        // on first iteration it will allocate the user pool and all the rest iterations will be no-op
        for _ in 0..10 {
            pool_manager
                .allocate_data_pool("user", "before", &dynamic_configuration)
                .unwrap();

            assert_eq!(
                3,
                pool_manager.report_pool_stats().len(),
                "2 system pool + 1 user pool"
            );
        }

        // change of password doesn't trigger creation of a new pool since we are using the same credentials (username)
        // as a key in the map, but for testing purposes let's validate that it doesn't create a new pool with same credentials
        pool_manager
            .allocate_data_pool("user", "after", &dynamic_configuration)
            .unwrap();

        assert_eq!(
            3,
            pool_manager.report_pool_stats().len(),
            "2 system pool + 1 user pool"
        );

        // but now let's change the system settings and validate that it creates a new pool with same credentials
        dynamic_configuration.set_max_conn(42);

        pool_manager
            .allocate_data_pool("user", "after", &dynamic_configuration)
            .unwrap();

        assert_eq!(
            4,
            pool_manager.report_pool_stats().len(),
            "2 system pool + 2 user pool"
        );
    }

    #[tokio::test]
    async fn test_get_data_pool_with_missing_user_returns_internal_error() {
        // We still need an async context to create the connection pool (see ConnectionPool::new_with_user),
        // but the test itself doesn't need to be async since we are not awaiting anything after the pool creation,
        // so we can use yield_now to just get into async context and then proceed with sync code.
        yield_now().await;

        let dynamic_configuration = MaxConnectionConfig {
            max_conn: 100.into(),
        };
        let pool_manager = test_pool_manager();

        let err = pool_manager
            .get_data_pool("missing-user", &dynamic_configuration)
            .unwrap_err();

        assert!(matches!(
            err,
            DocumentDBError::DocumentDBError(ErrorCode::InternalError, _, _)
        ));
    }

    #[tokio::test]
    async fn test_get_data_pool_with_allocated_pool_returns_expected_size() {
        // We still need an async context to create the connection pool (see ConnectionPool::new_with_user),
        // but the test itself doesn't need to be async since we are not awaiting anything after the pool creation,
        // so we can use yield_now to just get into async context and then proceed with sync code.
        yield_now().await;

        let dynamic_configuration = MaxConnectionConfig {
            max_conn: 100.into(),
        };
        let pool_manager = test_pool_manager();

        pool_manager
            .allocate_data_pool("user", "password", &dynamic_configuration)
            .unwrap();

        let user_pool = pool_manager
            .get_data_pool("user", &dynamic_configuration)
            .unwrap();

        assert_eq!(
            dynamic_configuration.max_conn(),
            user_pool.status().status().max_size
        );
    }

    #[tokio::test]
    async fn test_clean_unused_pools_with_expired_pools_removes_user_and_shared() {
        let dynamic_configuration = MaxConnectionConfig {
            max_conn: 100.into(),
        };
        let pool_manager = test_pool_manager();

        pool_manager
            .allocate_data_pool("user", "password", &dynamic_configuration)
            .unwrap();
        pool_manager
            .get_system_shared_pool(&dynamic_configuration)
            .unwrap();

        assert_eq!(4, pool_manager.report_pool_stats().len());

        sleep(Duration::from_millis(1)).await;
        pool_manager
            .clean_unused_pools(Duration::from_millis(0))
            .await;

        // only 2 system pools should remain since user and shared pools are expired
        assert_eq!(2, pool_manager.report_pool_stats().len());
    }
}
