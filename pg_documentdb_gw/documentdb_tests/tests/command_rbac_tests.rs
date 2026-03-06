/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/command_rbac_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::commands::users;
use documentdb_tests::test_setup::initialize;
use mongodb::error::Error;

#[tokio::test]
async fn test_create_user() -> Result<(), Error> {
    let client = initialize::initialize().await;

    users::validate_create_user(&client).await
}

#[tokio::test]
async fn test_drop_user() -> Result<(), Error> {
    let client = initialize::initialize().await;

    users::validate_drop_user(&client).await
}

#[tokio::test]
async fn test_cannot_drop_system_users() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = client.database("drop_user");

    users::validate_cannot_drop_system_users(&db).await
}

#[tokio::test]
async fn test_update_user_password() -> Result<(), Error> {
    let client = initialize::initialize().await;

    users::validate_update_user_password(&client).await
}

#[tokio::test]
async fn test_users_info() -> Result<(), Error> {
    let client = initialize::initialize().await;

    users::validate_users_info(&client).await
}
