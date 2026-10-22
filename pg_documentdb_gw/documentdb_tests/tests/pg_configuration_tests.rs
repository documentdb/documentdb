/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/pg_configuration_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{sync::Arc, time::Duration};

use documentdb_gateway_core::{
    configuration::{
        DocumentDBSetupConfiguration, DynamicConfiguration, PgConfiguration, SetupConfiguration,
    },
    error::Result,
    postgres::{
        conn_mgmt::{
            ConnectionPool, PgPoolSettings, PoolManager, AUTHENTICATION_MAX_CONNECTIONS,
            SYSTEM_REQUESTS_MAX_CONNECTIONS,
        },
        create_query_catalog, QueryCatalog,
    },
};
use documentdb_tests::test_setup::{config::setup_configuration, postgres::get_pool_manager};

type TestResult = std::result::Result<(), Box<dyn std::error::Error>>;

/// Helper that creates a `PgConfiguration` with the given
/// `enable_pg_file_settings_refresh` override.
async fn create_pg_configuration(enable_refresh: Option<bool>) -> Result<Arc<PgConfiguration>> {
    let mut setup_config = setup_configuration();
    setup_config.enable_pg_file_settings_refresh = enable_refresh;

    let pool_manager = get_pool_manager();

    let config = PgConfiguration::new(
        &setup_config,
        Arc::clone(&pool_manager),
        vec!["documentdb.".to_owned()],
    )
    .await?;

    Ok(config)
}

fn create_pool_manager_with_query_catalog(
    setup_config: &DocumentDBSetupConfiguration,
    query_catalog: QueryCatalog,
) -> Result<Arc<PoolManager>> {
    let postgres_system_user = setup_config.postgres_system_user();
    let system_requests_pool = ConnectionPool::new_with_user(
        setup_config,
        &query_catalog,
        postgres_system_user,
        None,
        &format!("{}-SystemRequests", setup_config.application_name()),
        PgPoolSettings::system_pool_settings(SYSTEM_REQUESTS_MAX_CONNECTIONS),
    )?;
    let authentication_pool = ConnectionPool::new_with_user(
        setup_config,
        &query_catalog,
        postgres_system_user,
        None,
        &format!("{}-PreAuthRequests", setup_config.application_name()),
        PgPoolSettings::system_pool_settings(AUTHENTICATION_MAX_CONNECTIONS),
    )?;

    Ok(Arc::new(PoolManager::new(
        query_catalog,
        Box::new(setup_config.clone()),
        system_requests_pool,
        authentication_pool,
    )))
}

#[tokio::test]
async fn load_configurations_without_file_settings_refresh() -> TestResult {
    let config = create_pg_configuration(None).await?;

    // pg_settings should always return max_connections
    let max_connections = config.get_i32("max_connections", -1);
    assert!(
        max_connections > 0,
        "Expected max_connections > 0, got {max_connections}"
    );

    // Recovery state should be populated
    assert!(
        config.get_str("IsPostgresInRecovery").is_some(),
        "Expected IsPostgresInRecovery to be present"
    );

    Ok(())
}

#[tokio::test]
async fn load_configurations_with_file_settings_refresh_enabled() -> TestResult {
    // When enabled, the pg_file_settings query runs. In CI/dev the referenced
    // conf file typically doesn't exist, so the query returns empty results.
    // The key assertion is that enabling the flag does not cause an error and
    // that pg_settings values are still loaded normally.
    let config = create_pg_configuration(Some(true)).await?;

    let max_connections = config.get_i32("max_connections", -1);
    assert!(
        max_connections > 0,
        "Expected max_connections > 0, got {max_connections}"
    );

    assert!(
        config.get_str("IsPostgresInRecovery").is_some(),
        "Expected IsPostgresInRecovery to be present"
    );

    Ok(())
}

#[tokio::test]
async fn load_configurations_with_file_settings_refresh_disabled() -> TestResult {
    let config = create_pg_configuration(Some(false)).await?;

    let max_connections = config.get_i32("max_connections", -1);
    assert!(
        max_connections > 0,
        "Expected max_connections > 0, got {max_connections}"
    );

    assert!(
        config.get_str("IsPostgresInRecovery").is_some(),
        "Expected IsPostgresInRecovery to be present"
    );

    Ok(())
}

#[tokio::test]
async fn refresh_configuration_with_file_settings_enabled() -> TestResult {
    let config = create_pg_configuration(Some(true)).await?;

    // Refresh should succeed without errors
    config.refresh_configuration().await?;

    // Values should still be present after refresh
    let max_connections = config.get_i32("max_connections", -1);
    assert!(
        max_connections > 0,
        "Expected max_connections > 0 after refresh, got {max_connections}"
    );

    Ok(())
}

#[tokio::test]
async fn failed_refresh_preserves_last_known_good_configuration() -> TestResult {
    let setup_config = setup_configuration();
    let table_name = format!(
        "public.pg_configuration_refresh_test_{}",
        std::process::id()
    );
    // Scoped so the shared system pool slot is released for the rest of the
    // test: that pool has very few slots and sibling tests contend for it.
    {
        let control_connection = get_pool_manager().system_requests_connection().await?;
        control_connection
            .batch_execute(&format!(
                "DROP TABLE IF EXISTS {table_name}; \
             CREATE TABLE {table_name} (enabled boolean); \
             INSERT INTO {table_name} VALUES (true)"
            ))
            .await?;
    }

    let mut query_catalog = create_query_catalog();
    query_catalog.pg_settings = format!(
        "SELECT name, setting FROM pg_settings \
         WHERE (name LIKE 'documentdb.%' OR name IN ('max_connections', 'default_transaction_read_only')) \
         AND EXISTS (SELECT 1 FROM {table_name})"
    );
    let pool_manager = create_pool_manager_with_query_catalog(&setup_config, query_catalog)?;
    let config =
        PgConfiguration::new(&setup_config, pool_manager, vec!["documentdb.".to_owned()]).await?;
    let original_max_connections = config.get_i32("max_connections", -1);
    assert!(
        original_max_connections > 0,
        "Expected initial configuration load to return max_connections"
    );
    let original_last_update_at = config.last_update_at();

    {
        let control_connection = get_pool_manager().system_requests_connection().await?;
        control_connection
            .batch_execute(&format!("DROP TABLE {table_name}"))
            .await?;
    }
    tokio::time::sleep(Duration::from_millis(1)).await;

    assert!(
        config.refresh_configuration().await.is_err(),
        "Expected refresh to fail when pg_settings cannot be queried"
    );
    assert_eq!(
        original_max_connections,
        config.get_i32("max_connections", -1),
        "Failed refresh replaced the last-known-good configuration"
    );
    assert_eq!(
        original_last_update_at,
        config.last_update_at(),
        "Failed refresh advanced the configuration freshness timestamp"
    );

    Ok(())
}

// Startup tolerates an unavailable topology, but a refresh must not: blanking an
// already-known cluster version turns every version gate off, and advancing the
// freshness timestamp would hide that from the health probe.
#[tokio::test]
async fn failed_topology_refresh_preserves_freshness() -> TestResult {
    let setup_config = setup_configuration();
    let mut query_catalog = create_query_catalog();
    query_catalog.extension_versions =
        "SELECT * FROM pg_configuration_topology_missing_relation".to_owned();
    let pool_manager = create_pool_manager_with_query_catalog(&setup_config, query_catalog)?;

    let config =
        PgConfiguration::new(&setup_config, pool_manager, vec!["documentdb.".to_owned()]).await?;
    let original_last_update_at = config.last_update_at();
    tokio::time::sleep(Duration::from_millis(1)).await;

    assert!(
        config.refresh_configuration().await.is_err(),
        "Expected refresh to fail when the topology query cannot be executed"
    );
    assert_eq!(
        original_last_update_at,
        config.last_update_at(),
        "Failed topology refresh advanced the configuration freshness timestamp"
    );

    Ok(())
}

#[tokio::test]
async fn missing_recovery_state_fails_configuration_load() -> TestResult {
    let setup_config = setup_configuration();
    let mut query_catalog = create_query_catalog();
    query_catalog.pg_is_in_recovery = "SELECT pg_is_in_recovery() WHERE false".to_owned();
    let pool_manager = create_pool_manager_with_query_catalog(&setup_config, query_catalog)?;

    let result =
        PgConfiguration::new(&setup_config, pool_manager, vec!["documentdb.".to_owned()]).await;

    match result {
        Ok(_) => {
            return Err(std::io::Error::other(
                "Expected configuration load to fail when recovery state is unknown",
            )
            .into());
        }
        Err(error) => assert!(
            error
                .to_string()
                .contains("pg_is_in_recovery query returned no rows"),
            "Unexpected error for missing recovery state: {error}"
        ),
    }

    Ok(())
}

// The pg_file_settings branch only runs when the refresh is enabled and the
// query is non-empty, which the OSS catalog leaves blank by default.
#[tokio::test]
async fn failed_pg_file_settings_query_fails_configuration_load() -> TestResult {
    let mut setup_config = setup_configuration();
    setup_config.enable_pg_file_settings_refresh = Some(true);

    let mut query_catalog = create_query_catalog();
    query_catalog.pg_file_settings =
        "SELECT name, setting FROM pg_configuration_file_settings_missing_relation".to_owned();
    let pool_manager = create_pool_manager_with_query_catalog(&setup_config, query_catalog)?;

    PgConfiguration::new(&setup_config, pool_manager, vec!["documentdb.".to_owned()])
        .await
        .expect_err("Expected load to fail when pg_file_settings cannot be queried");

    Ok(())
}

// Positive control for the freshness contract the failure tests pin from the
// other side: the health probe reads this timestamp to decide staleness.
#[tokio::test]
async fn successful_refresh_advances_freshness_timestamp() -> TestResult {
    let setup_config = setup_configuration();
    let pool_manager =
        create_pool_manager_with_query_catalog(&setup_config, create_query_catalog())?;
    let config =
        PgConfiguration::new(&setup_config, pool_manager, vec!["documentdb.".to_owned()]).await?;

    let original_last_update_at = config.last_update_at();
    tokio::time::sleep(Duration::from_millis(1)).await;

    config.refresh_configuration().await?;

    assert!(
        config.last_update_at() > original_last_update_at,
        "Successful refresh did not advance the configuration freshness timestamp"
    );

    Ok(())
}

// Guards the weak capture in the background tasks: an owning capture would keep
// the configuration alive after its last owner is gone, making `Drop`
// unreachable and leaking the refresh loop for the life of the process.
#[tokio::test]
async fn dropping_last_owner_releases_background_tasks() -> TestResult {
    let mut setup_config = setup_configuration();
    // Long timers so both tasks are parked on their intervals, rather than
    // momentarily holding an upgraded handle, when the owner is dropped.
    setup_config.dynamic_configuration_refresh_interval_secs = Some(3600);
    setup_config.host_configuration_watch_interval_ms = Some(3_600_000);

    let pool_manager =
        create_pool_manager_with_query_catalog(&setup_config, create_query_catalog())?;
    let config =
        PgConfiguration::new(&setup_config, pool_manager, vec!["documentdb.".to_owned()]).await?;

    let weak_config = Arc::downgrade(&config);
    // Let the runtime poll both spawned tasks before the owner goes away.
    tokio::time::sleep(Duration::from_millis(50)).await;
    assert!(
        weak_config.upgrade().is_some(),
        "Configuration should still be reachable while it is owned"
    );

    drop(config);

    assert!(
        weak_config.upgrade().is_none(),
        "Background tasks still retain the configuration after its last owner was dropped"
    );

    Ok(())
}
