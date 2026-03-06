/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/cursor_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::cursor, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
pub async fn validate_batch_size() -> Result<(), Error> {
    let db = initialize::initialize_with_db("cursor_tests_batch_size").await?;

    cursor::validate_batch_size(&db).await
}

#[tokio::test]
pub async fn test_cursor_default_batch_size() -> Result<(), Error> {
    let db = initialize::initialize_with_db("cursor_tests_101_kill").await?;

    cursor::validate_cursor_default_batch_size(&db).await
}

#[tokio::test]
pub async fn test_cursor_kill_multiple_cursors() -> Result<(), Error> {
    let db = initialize::initialize_with_db("cursor_tests_kill_multiple").await?;

    cursor::validate_cursor_kill_multiple_cursors(&db).await
}

#[tokio::test]
async fn test_kill_cursor() -> Result<(), Error> {
    let db = initialize::initialize_with_db("cursor_tests_kill_behavior").await?;

    cursor::validate_kill_cursor(&db).await
}
