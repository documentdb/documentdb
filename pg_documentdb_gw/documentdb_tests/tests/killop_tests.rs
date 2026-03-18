/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/killop_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::killop, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn validate_killop_missing_op_field() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    killop::validate_killop_missing_op_field(&client).await;
    Ok(())
}

#[tokio::test]
async fn validate_killop_invalid_op_format_no_colon() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    killop::validate_killop_invalid_op_format_no_colon(&client).await;
    Ok(())
}

#[tokio::test]
async fn validate_killop_invalid_shard_id() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    killop::validate_killop_invalid_shard_id(&client).await;
    Ok(())
}

#[tokio::test]
async fn validate_killop_invalid_op_id() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    killop::validate_killop_invalid_op_id(&client).await;
    Ok(())
}

#[tokio::test]
async fn validate_killop_non_admin_database() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    killop::validate_killop_non_admin_database(&client).await;
    Ok(())
}

#[tokio::test]
async fn validate_killop_valid_format() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    killop::validate_killop_valid_format(&client).await
}
