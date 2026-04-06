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

#[tokio::test]
async fn test_currentop_aggregation_basic() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_aggregation_basic(&client).await
}

#[tokio::test]
async fn test_currentop_aggregation_pipeline_composition() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_aggregation_pipeline_composition(&client).await
}

#[tokio::test]
async fn test_currentop_aggregation_requires_first_stage() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_aggregation_requires_first_stage(&client).await
}

#[tokio::test]
async fn test_currentop_aggregation_non_admin_db_error() -> Result<(), Error> {
    let db = initialize::initialize_with_db("currentop_nonadmin").await?;

    current_op::validate_currentop_aggregation_non_admin_db_error(&db).await
}

#[tokio::test]
async fn test_currentop_aggregation_nested_pipeline_errors() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_aggregation_nested_pipeline_errors(&client).await
}

#[tokio::test]
async fn test_currentop_aggregation_option_validation() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_aggregation_option_validation(&client).await
}

#[tokio::test]
async fn test_currentop_command_filter() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_command_filter(&client).await
}

#[tokio::test]
async fn test_currentop_opmetadata_fields() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_opmetadata_fields(&client).await
}

#[tokio::test]
async fn test_currentop_aggregation_transaction_error() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_aggregation_transaction_error(&client).await
}

#[tokio::test]
async fn test_currentop_lsid_binary_uuid() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_lsid_binary_uuid(&client).await
}

#[tokio::test]
async fn test_currentop_own_ops_filtering() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_own_ops_filtering(&client).await
}

#[tokio::test]
async fn test_currentop_allusers_aggregation() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_allusers_aggregation(&client).await
}

#[tokio::test]
async fn test_currentop_cursor_field() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_cursor_field(&client).await
}

#[tokio::test]
async fn test_currentop_transaction_fields() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_transaction_fields(&client).await
}

#[tokio::test]
async fn test_currentop_no_transaction_outside_txn() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_no_transaction_outside_txn(&client).await
}

#[tokio::test]
async fn test_currentop_cursor_originating_command() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_cursor_originating_command(&client).await
}

#[tokio::test]
async fn test_currentop_no_originating_command_without_cursor() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_no_originating_command_without_cursor(&client).await
}

#[tokio::test]
async fn test_currentop_lsid_value_matches_session() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_lsid_value_matches_session(&client).await
}

#[tokio::test]
async fn test_currentop_effectiveusers_value() -> Result<(), Error> {
    let client = initialize::initialize().await;

    current_op::validate_currentop_effectiveusers_value(&client).await
}
