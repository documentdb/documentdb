/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/drop_collection_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::drop_collection, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn validate_drop_collection_basic() -> Result<(), Error> {
    let db = initialize::initialize_with_db("drop_coll_tests_basic").await?;

    drop_collection::validate_drop_collection_basic(&db).await
}

#[tokio::test]
async fn validate_drop_collection_with_data() -> Result<(), Error> {
    let db = initialize::initialize_with_db("drop_coll_tests_data").await?;

    drop_collection::validate_drop_collection_with_data(&db).await
}

#[tokio::test]
async fn validate_drop_collection_unknown_field_error() -> Result<(), Error> {
    let db = initialize::initialize_with_db("drop_coll_tests_unknown_field").await?;

    drop_collection::validate_drop_collection_unknown_field_error(&db).await;
    Ok(())
}
