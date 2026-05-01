/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/role_crud_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{
    commands::roles,
    test_setup::{configuration_utils, initialize},
    utils::rbac_utils::{NATIVE_BUILTIN_ROLE_NAMES, RESERVED_ROLE_NAMES},
};
use mongodb::error::Error;

#[tokio::test]
async fn test_create_role_of_reserved_name() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let _guc = configuration_utils::set_guc("documentdb.enableRoleCrud", "on")
        .await
        .expect("Failed to enable role CRUD");
    let db = client.database("admin");

    roles::validate_create_role_of_reserved_name(&db, RESERVED_ROLE_NAMES).await;

    Ok(())
}

#[tokio::test]
async fn test_create_role_of_native_built_in_name() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let _guc = configuration_utils::set_guc("documentdb.enableRoleCrud", "on")
        .await
        .expect("Failed to enable role CRUD");
    let db = client.database("admin");

    roles::validate_create_role_of_native_built_in_name(&db, NATIVE_BUILTIN_ROLE_NAMES).await;

    Ok(())
}

#[tokio::test]
async fn test_drop_role_of_reserved_name() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let _guc = configuration_utils::set_guc("documentdb.enableRoleCrud", "on")
        .await
        .expect("Failed to enable role CRUD");
    let db = client.database("admin");

    roles::validate_drop_role_of_reserved_name(&db, RESERVED_ROLE_NAMES).await;

    Ok(())
}

#[tokio::test]
async fn test_drop_role_of_native_built_in_name() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let _guc = configuration_utils::set_guc("documentdb.enableRoleCrud", "on")
        .await
        .expect("Failed to enable role CRUD");
    let db = client.database("admin");

    roles::validate_drop_role_of_native_built_in_name(&db, NATIVE_BUILTIN_ROLE_NAMES).await;

    Ok(())
}
