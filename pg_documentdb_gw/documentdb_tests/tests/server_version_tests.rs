/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/server_version_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use bson::doc;
use documentdb_gateway_core::configuration::{
    DynamicConfiguration, PgConfiguration, DEFAULT_MAX_WIRE_VERSION, DEFAULT_SERVER_VERSION,
};
use documentdb_tests::test_setup::{
    clients, config::setup_configuration, initialize, postgres::get_pool_manager,
};
use mongodb::error::Error;

type TestResult = std::result::Result<(), Box<dyn std::error::Error>>;

async fn pg_configuration() -> documentdb_gateway_core::error::Result<Arc<PgConfiguration>> {
    PgConfiguration::new(
        &setup_configuration(),
        Arc::clone(&get_pool_manager()),
        vec!["documentdb.".to_owned()],
    )
    .await
}

#[tokio::test]
async fn defaults_match_guc_boot_values() -> TestResult {
    let config = pg_configuration().await?;
    assert_eq!(config.server_version(), DEFAULT_SERVER_VERSION);
    assert_eq!(config.max_wire_version(), DEFAULT_MAX_WIRE_VERSION);

    Ok(())
}

#[tokio::test]
async fn build_info_and_is_master_report_defaults() -> Result<(), Error> {
    let _ = initialize::initialize().await?;

    let client = clients::get_client_unauthenticated()?;
    let admin = client.database("admin");

    let build_info = admin.run_command(doc! {"buildInfo": 1}).await?;
    assert_eq!(
        build_info.get_str("version").expect("buildInfo version"),
        DEFAULT_SERVER_VERSION
    );

    let is_master = admin.run_command(doc! {"isMaster": 1}).await?;
    assert_eq!(
        is_master
            .get_i32("maxWireVersion")
            .expect("isMaster maxWireVersion"),
        DEFAULT_MAX_WIRE_VERSION
    );

    Ok(())
}
