/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/rbac_permission_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{
    commands::rbac_builtin_read_any_database_tests,
    test_setup::{clients, initialize},
};
use mongodb::error::Error;

#[tokio::test]
async fn test_create_readonly_user() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    clients::setup_db(&client, "admin").await?;

    rbac_builtin_read_any_database_tests::validate_read_any_database_role(&client).await
}
