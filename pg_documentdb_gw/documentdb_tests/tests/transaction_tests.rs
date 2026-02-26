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
