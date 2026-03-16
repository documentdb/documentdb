/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/transaction_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{
    commands::transaction,
    test_setup::{clients, initialize},
};
use mongodb::error::Error;

#[tokio::test]
async fn session() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "session").await?;

    transaction::validate_commit_transaction(&client, &db).await
}

#[tokio::test]
async fn abort() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "abort").await?;

    transaction::validate_abort_transaction(&client, &db).await
}

#[tokio::test]
async fn list_collections_blocked_in_transaction() -> Result<(), Error> {
    let client = initialize::initialize().await;
    transaction::validate_list_collections_blocked_in_transaction(&client).await
}

#[tokio::test]
async fn drop_blocked_in_transaction() -> Result<(), Error> {
    let client = initialize::initialize().await;
    transaction::validate_drop_blocked_in_transaction(&client).await
}

#[tokio::test]
async fn current_op_blocked_in_transaction() -> Result<(), Error> {
    let client = initialize::initialize().await;
    transaction::validate_current_op_blocked_in_transaction(&client).await
}

#[tokio::test]
async fn kill_op_blocked_in_transaction() -> Result<(), Error> {
    let client = initialize::initialize().await;
    transaction::validate_kill_op_blocked_in_transaction(&client).await
}

#[tokio::test]
async fn rename_collection_blocked_in_transaction() -> Result<(), Error> {
    let client = initialize::initialize().await;
    transaction::validate_rename_collection_blocked_in_transaction(&client).await
}

#[tokio::test]
async fn create_index_blocked_in_transaction() -> Result<(), Error> {
    let client = initialize::initialize().await;
    transaction::validate_create_index_blocked_in_transaction(&client).await
}

#[tokio::test]
async fn create_indexes_blocked_in_transaction() -> Result<(), Error> {
    let client = initialize::initialize().await;
    transaction::validate_create_indexes_blocked_in_transaction(&client).await
}
