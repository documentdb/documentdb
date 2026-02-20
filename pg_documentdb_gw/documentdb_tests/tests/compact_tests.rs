/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/compact_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::compact, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn validate_compact_basic() -> Result<(), Error> {
    let db = initialize::initialize_with_db("compact_tests_basic").await?;

    compact::validate_compact_basic(&db).await
}

#[tokio::test]
async fn validate_compact_with_force() -> Result<(), Error> {
    let db = initialize::initialize_with_db("compact_tests_force").await?;

    compact::validate_compact_with_force(&db).await
}

#[tokio::test]
async fn validate_compact_with_padding_factor() -> Result<(), Error> {
    let db = initialize::initialize_with_db("compact_tests_padding_factor").await?;

    compact::validate_compact_with_padding_factor(&db).await
}

#[tokio::test]
async fn validate_compact_with_padding_bytes() -> Result<(), Error> {
    let db = initialize::initialize_with_db("compact_tests_padding_bytes").await?;

    compact::validate_compact_with_padding_bytes(&db).await
}

#[tokio::test]
async fn validate_compact_nonexistent_collection() -> Result<(), Error> {
    let db = initialize::initialize_with_db("compact_tests_nonexistent").await?;

    compact::validate_compact_nonexistent_collection(&db).await;
    Ok(())
}

#[tokio::test]
async fn validate_compact_invalid_arguments() -> Result<(), Error> {
    let db = initialize::initialize_with_db("compact_tests_invalid").await?;

    compact::validate_compact_invalid_arguments(&db).await;
    Ok(())
}
