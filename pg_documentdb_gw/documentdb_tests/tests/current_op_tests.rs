/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/current_op_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::current_op, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn validate_empty_current_op() -> Result<(), Error> {
    let db = initialize::initialize_with_db("current_op").await?;

    current_op::validate_empty_current_op(&db).await
}

#[tokio::test]
async fn validate_current_op_with_long_running_task() -> Result<(), Error> {
    let db = initialize::initialize_with_db("current_op_long").await?;

    current_op::validate_current_op_with_long_running_task(&db).await
}

#[tokio::test]
async fn test_currentop_basic_structure() -> Result<(), Error> {
    let db = initialize::initialize_with_db("currentop_basic").await?;

    current_op::validate_currentop_basic_structure(&db).await
}

#[tokio::test]
async fn test_currentop_captures_mongodb_operations() -> Result<(), Error> {
    let db = initialize::initialize_with_db("currentop_capture_test").await?;

    current_op::validate_currentop_captures_mongodb_operations(&db).await
}
