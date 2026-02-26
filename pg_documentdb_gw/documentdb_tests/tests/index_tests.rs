/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/index_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::indexing, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn create_index() -> Result<(), Error> {
    let db = initialize::initialize_with_db("create_index").await?;

    indexing::validate_create_index(&db).await
}

#[tokio::test]
async fn create_list_drop_index() -> Result<(), Error> {
    let db = initialize::initialize_with_db("drop_indexes").await?;

    indexing::validate_create_list_drop_index(&db).await
}

#[tokio::test]
async fn create_index_with_long_name_should_fail() -> Result<(), Error> {
    let db = initialize::initialize_with_db("long_index_name").await?;

    indexing::validate_create_index_with_long_name_should_fail(&db).await;
    Ok(())
}
