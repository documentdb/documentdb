/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/user_crud_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{
    commands::users,
    test_setup::{clients, initialize},
};
use mongodb::error::Error;

#[tokio::test]
#[ignore = "Error handling needs to be ported, we expect error code 2 for bad password, but currently we return 11"]
async fn test_createuser_with_bad_password() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_createuser_with_bad_password(&db).await
}

#[tokio::test]
async fn test_usersinfo_with_foralldbs() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_usersinfo_with_foralldbs(&db).await
}

#[tokio::test]
async fn test_usersinfo_with_user_and_db() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_usersinfo_with_user_and_db(&db).await
}

#[tokio::test]
async fn test_usersinfo_with_missing_db_or_user() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_usersinfo_with_missing_db_or_user(&db).await
}

#[tokio::test]
async fn test_usersinfo_with_empty_document() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_usersinfo_with_empty_document(&db).await
}

#[tokio::test]
async fn test_usersinfo_with_all_fields() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_usersinfo_with_all_fields(&db).await
}

#[tokio::test]
async fn test_createuser_of_existing() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_createuser_of_existing(&db).await
}

#[tokio::test]
async fn test_dropuser_of_not_existing() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_dropuser_of_not_existing(&db).await
}

#[tokio::test]
#[ignore = "Error handling needs to be ported, we expect error code 2 for bad password, but currently we return 11"]
async fn test_drop_system_user() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_drop_system_user(&db).await
}

#[tokio::test]
async fn test_usersinfo_excludes_system_user() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_usersinfo_excludes_system_user(&db).await
}

#[tokio::test]
async fn test_update_user_of_not_existing() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_update_user_of_not_existing(&db).await
}
