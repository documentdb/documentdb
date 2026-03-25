/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/rbac_builtin_read_any_database_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Client};

use crate::{
    test_setup::clients,
    utils::rbac_validator::{AuthorizationStatus, RbacValidator},
};

const USER_NAME: &str = "read_any_database_user_test";
const USER_PASSWORD: &str = "NewPassword$1";
const DB_NAME: &str = "readAnyDatabaseTestDb";
const COLLECTION_NAME: &str = "testCollection";

async fn setup(admin_client: &Client) -> Result<Client, Error> {
    // Ignore UserNotFound error if the user doesn't exist yet.
    let _ = admin_client
        .database("admin")
        .run_command(doc! { "dropUser": USER_NAME })
        .await;

    admin_client
        .database("admin")
        .run_command(doc! {
            "createUser": USER_NAME,
            "pwd": USER_PASSWORD,
            "roles": [{"role": "readAnyDatabase", "db": "admin"}]
        })
        .await?;

    let user_client = clients::get_client_with_credentials(USER_NAME, USER_PASSWORD)?;
    Ok(user_client)
}

async fn cleanup(admin_client: &Client) -> Result<(), Error> {
    admin_client.database(DB_NAME).drop().await?;
    admin_client
        .database("admin")
        .run_command(doc! {"dropUser": USER_NAME})
        .await?;
    Ok(())
}

// -------------------------------------------------------------------
// Grouped validation scenarios
// -------------------------------------------------------------------

async fn validate_crud_scenarios(rbac_validator: &RbacValidator<'_>) -> Result<(), Error> {
    rbac_validator
        .validate_find(AuthorizationStatus::Authorized)
        .await?;
    rbac_validator
        .validate_count(AuthorizationStatus::Authorized)
        .await?;

    rbac_validator
        .validate_insert(AuthorizationStatus::Denied)
        .await?;

    rbac_validator
        .validate_update(AuthorizationStatus::Denied)
        .await?;
    rbac_validator
        .validate_find_and_modify(AuthorizationStatus::Denied)
        .await?;

    rbac_validator
        .validate_delete(AuthorizationStatus::Denied)
        .await
}

async fn validate_db_command_scenarios(rbac_validator: &RbacValidator<'_>) -> Result<(), Error> {
    rbac_validator
        .validate_list_databases(AuthorizationStatus::Authorized)
        .await?;
    rbac_validator
        .validate_db_stats(AuthorizationStatus::Authorized)
        .await?;
    rbac_validator
        .validate_drop_database(AuthorizationStatus::Denied)
        .await?;

    rbac_validator
        .validate_list_collections(AuthorizationStatus::Authorized)
        .await?;
    rbac_validator
        .validate_coll_stats(AuthorizationStatus::Authorized)
        .await?;
    rbac_validator
        .validate_drop_collection(AuthorizationStatus::Denied)
        .await?;

    rbac_validator
        .validate_distinct(AuthorizationStatus::Authorized)
        .await
}

async fn validate_aggregate_read_scenarios(
    rbac_validator: &RbacValidator<'_>,
) -> Result<(), Error> {
    rbac_validator
        .validate_aggregate_count(AuthorizationStatus::Authorized)
        .await
}

async fn validate_aggregate_write_scenarios(
    rbac_validator: &RbacValidator<'_>,
) -> Result<(), Error> {
    rbac_validator
        .validate_aggregate_out(AuthorizationStatus::Denied)
        .await?;
    rbac_validator
        .validate_aggregate_merge(AuthorizationStatus::Denied)
        .await
}

async fn validate_index_scenarios(rbac_validator: &RbacValidator<'_>) -> Result<(), Error> {
    rbac_validator
        .validate_list_indexes(AuthorizationStatus::Authorized)
        .await?;
    rbac_validator
        .validate_create_indexes(AuthorizationStatus::Denied)
        .await?;
    rbac_validator
        .validate_drop_indexes(AuthorizationStatus::Denied)
        .await
}

async fn validate_sharding_scenarios(rbac_validator: &RbacValidator<'_>) -> Result<(), Error> {
    rbac_validator
        .validate_shard_collection(AuthorizationStatus::Denied)
        .await
}

/// # Errors
/// Returns an error if setup, validation, or cleanup fails.
pub async fn validate_read_any_database_role(admin_client: &Client) -> Result<(), Error> {
    let user_client = setup(admin_client).await?;
    let rbac_validator = RbacValidator::new(&user_client, admin_client, DB_NAME, COLLECTION_NAME);
    rbac_validator.populate_test_data().await?;

    validate_crud_scenarios(&rbac_validator).await?;
    validate_db_command_scenarios(&rbac_validator).await?;
    validate_aggregate_read_scenarios(&rbac_validator).await?;
    validate_aggregate_write_scenarios(&rbac_validator).await?;
    validate_index_scenarios(&rbac_validator).await?;
    validate_sharding_scenarios(&rbac_validator).await?;

    cleanup(admin_client).await
}
