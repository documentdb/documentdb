/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/reindex_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{
    commands::reindex,
    test_setup::{clients, initialize},
};
use mongodb::error::Error;

#[tokio::test]
async fn validate_reindex_not_supported() -> Result<(), Error> {
    let db = initialize::initialize_with_db("reindex_tests_unsupported").await?;

    reindex::validate_reindex_not_supported(&db).await;
    Ok(())
}

#[tokio::test]
async fn validate_reindex_blocked_in_transaction() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let _ = clients::setup_db(&client, "reindex_tests_txn").await?;

    reindex::validate_reindex_blocked_in_transaction(&client, "reindex_tests_txn").await
}
