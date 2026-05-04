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
    utils::rbac_utils::RESERVED_ROLE_NAMES,
};
use mongodb::error::Error;

#[tokio::test]
async fn test_create_user() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    users::validate_create_user(&client).await
}

#[tokio::test]
async fn test_create_user_of_existing() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_create_user_of_existing(&db).await
}

#[tokio::test]
async fn test_create_user_of_reserved_username() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = client.database("admin");

    users::validate_create_user_of_reserved_name(&db, RESERVED_ROLE_NAMES).await
}

#[tokio::test]
#[ignore = "Error handling needs to be ported, we expect error code 2 for bad password, but currently we return 11"]
async fn test_create_user_with_bad_password() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_create_user_with_bad_password(&db).await
}

#[tokio::test]
async fn test_drop_user() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    users::validate_drop_user(&client).await
}

#[tokio::test]
async fn test_drop_user_of_not_existing() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_drop_user_of_not_existing(&db).await
}

#[tokio::test]
async fn test_cannot_drop_reserved_user_name() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_drop_user_of_reserved_names(&db, RESERVED_ROLE_NAMES).await
}

#[tokio::test]
async fn test_update_user_password() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    users::validate_update_user_password(&client).await
}

#[tokio::test]
async fn test_update_user_of_not_existing() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_update_user_of_not_existing(&db).await
}

#[tokio::test]
async fn test_cannot_update_reserved_user_name() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_update_user_of_reserved_names(&db, RESERVED_ROLE_NAMES).await
}

#[tokio::test]
async fn test_users_info() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    users::validate_users_info(&client).await
}

#[tokio::test]
async fn test_users_info_with_for_all_dbs() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_users_info_with_for_all_dbs(&db).await
}

#[tokio::test]
async fn test_users_info_with_user_and_db() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_users_info_with_user_and_db(&db).await
}

#[tokio::test]
async fn test_users_info_with_missing_db_or_user() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_users_info_with_missing_db_or_user(&db).await
}

#[tokio::test]
async fn test_users_info_with_empty_document() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_users_info_with_empty_document(&db).await
}

#[tokio::test]
async fn test_users_info_with_all_fields() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_users_info_with_all_fields(&db).await
}

#[tokio::test]
async fn test_users_info_excludes_system_user() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "admin").await?;

    users::validate_users_info_excludes_system_user(&db, "documentdb_readonly_role").await
}
