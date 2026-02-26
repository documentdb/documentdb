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
async fn validate_killop_missing_op_field() {
    let client = initialize::initialize().await;

    killop::validate_killop_missing_op_field(&client).await;
}

#[tokio::test]
async fn validate_killop_invalid_op_format_no_colon() {
    let client = initialize::initialize().await;

    killop::validate_killop_invalid_op_format_no_colon(&client).await;
}

#[tokio::test]
async fn validate_killop_invalid_shard_id() {
    let client = initialize::initialize().await;

    killop::validate_killop_invalid_shard_id(&client).await;
}

#[tokio::test]
async fn validate_killop_invalid_op_id() {
    let client = initialize::initialize().await;

    killop::validate_killop_invalid_op_id(&client).await;
}

#[tokio::test]
async fn validate_killop_non_admin_database() {
    let client = initialize::initialize().await;

    killop::validate_killop_non_admin_database(&client).await;
}

#[tokio::test]
async fn validate_killop_valid_format() -> Result<(), Error> {
    let client = initialize::initialize().await;

    killop::validate_killop_valid_format(&client).await
}
