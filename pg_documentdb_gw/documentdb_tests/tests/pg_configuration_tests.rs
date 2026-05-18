/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/pg_configuration_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use documentdb_gateway_core::configuration::{DynamicConfiguration, PgConfiguration};
use documentdb_gateway_core::error::Result;
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
