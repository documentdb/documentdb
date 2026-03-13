/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/shard_collection_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::shard_collection, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn validate_shard_collection_basic() -> Result<(), Error> {
    let db = initialize::initialize_with_db("shard_coll_tests_basic").await?;

    shard_collection::validate_shard_collection_basic(&db).await
}

#[tokio::test]
async fn validate_shard_collection_missing_key_error() -> Result<(), Error> {
    let db = initialize::initialize_with_db("shard_coll_tests_missing_key").await?;

    shard_collection::validate_shard_collection_missing_key_error(&db).await;
    Ok(())
}

#[tokio::test]
async fn validate_reshard_collection_missing_key_error() -> Result<(), Error> {
    let db = initialize::initialize_with_db("shard_coll_tests_reshard_missing_key").await?;

    shard_collection::validate_reshard_collection_missing_key_error(&db).await;
    Ok(())
}
