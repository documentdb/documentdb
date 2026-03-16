/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/drop_database_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::drop_database, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn validate_drop_database_basic() -> Result<(), Error> {
    let db = initialize::initialize_with_db("drop_db_tests_basic").await?;

    drop_database::validate_drop_database_basic(&db).await
}

#[tokio::test]
async fn validate_drop_database_unknown_field_error() -> Result<(), Error> {
    let db = initialize::initialize_with_db("drop_db_tests_unknown_field").await?;

    drop_database::validate_drop_database_unknown_field_error(&db).await;
    Ok(())
}
