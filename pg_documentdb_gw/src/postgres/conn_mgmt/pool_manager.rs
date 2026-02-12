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

    pub async fn allocate_data_pool(
        &self,
        username: &str,
        password: &str,
        dynamic_configuration: &dyn DynamicConfiguration,
    ) -> Result<()> {
        let settings = PgPoolSettings::from_configuration(dynamic_configuration).await;
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

    pub async fn get_data_pool(
        &self,
        username: &str,
        dynamic_configuration: &dyn DynamicConfiguration,
    ) -> Result<Arc<ConnectionPool>> {
        let settings = PgPoolSettings::from_configuration(dynamic_configuration).await;

        match self.user_data_pools.get(&(username.to_string(), settings)) {
            None => Err(DocumentDBError::internal_error(
                "Connection pool missing for user.".to_string(),
            )),
            Some(pool_ref) => Ok(Arc::clone(pool_ref.value())),
        }
    }

    pub async fn get_system_shared_pool(
        &self,
        dynamic_configuration: &dyn DynamicConfiguration,
    ) -> Result<Arc<ConnectionPool>> {
        let settings = PgPoolSettings::from_configuration(dynamic_configuration).await;

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

    pub async fn report_pool_stats(&self) -> Vec<ConnectionPoolStatus> {
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
