/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/test_setup/pools.rs
 *
 * Connection pool and pool manager construction shared by the integration
 * tests that exercise pooling behaviour directly.
 *
 *-------------------------------------------------------------------------
 */

#![expect(
    clippy::expect_used,
    reason = "Test helper functions - expect failures indicate test failures"
)]

use std::sync::Arc;

use bson::{rawbson, RawBson};
use documentdb_gateway_core::{
    configuration::{DocumentDBSetupConfiguration, DynamicConfiguration, SetupConfiguration},
    postgres::{
        conn_mgmt::{
            ConnectionPool, PgPoolSettings, PoolManager, AUTHENTICATION_MAX_CONNECTIONS,
            SYSTEM_REQUESTS_MAX_CONNECTIONS,
        },
        create_query_catalog,
    },
};
use tokio::task::yield_now;

/// Dynamic configuration that answers every lookup with the caller's default,
/// so a test only has to reason about the pool settings it sets explicitly.
#[derive(Debug)]
pub struct TestConfiguration;

impl DynamicConfiguration for TestConfiguration {
    fn get_str(&self, _: &str) -> Option<String> {
        None
    }

    fn get_bool(&self, _: &str, default: bool) -> bool {
        default
    }

    fn get_i32(&self, _: &str, default: i32) -> i32 {
        default
    }

    fn get_u64(&self, _: &str, default: u64) -> u64 {
        default
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
        16
    }

    fn allow_transaction_snapshot(&self) -> bool {
        false
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

/// Builds a single pool bound to `user`.
///
/// # Panics
/// Panics if the pool cannot be constructed.
pub async fn build_connection_pool(
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

/// Builds a manager with the system and pre-auth pools a gateway starts with.
///
/// # Panics
/// Panics if either pool cannot be constructed.
#[must_use]
pub fn build_pool_manager(setup_config: &DocumentDBSetupConfiguration) -> PoolManager {
    let query_catalog = create_query_catalog();
    let postgres_system_user = setup_config.postgres_system_user();

    let system_requests_pool = ConnectionPool::new_with_user(
        setup_config,
        &query_catalog,
        postgres_system_user,
        None,
        &format!("{}-SystemRequests", setup_config.application_name()),
        PgPoolSettings::system_pool_settings(SYSTEM_REQUESTS_MAX_CONNECTIONS),
    )
    .expect("Failed to create system requests pool");

    let authentication_pool = ConnectionPool::new_with_user(
        setup_config,
        &query_catalog,
        postgres_system_user,
        None,
        &format!("{}-PreAuthRequests", setup_config.application_name()),
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

/// [`build_pool_manager`] for callers that need to share the manager.
///
/// # Panics
/// Panics if either pool cannot be constructed.
#[must_use]
pub fn build_shared_pool_manager(setup_config: &DocumentDBSetupConfiguration) -> Arc<PoolManager> {
    Arc::new(build_pool_manager(setup_config))
}
