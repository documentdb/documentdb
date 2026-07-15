/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/write_errors_tests.rs
 *
 * Regression tests for the `p_success` gate in `PgResponse::write_success`
 * and `transform_write_errors`.
 *
 *-------------------------------------------------------------------------
 */

use documentdb_gateway_core::responses::PgResponse;
use documentdb_tests::test_setup::postgres;

/// When the query returns `(bson, false)`, `write_success` returns `false`.
#[tokio::test]
async fn write_success_returns_false_when_p_success_is_false() {
    let pool_manager = postgres::get_pool_manager();
    let connection = pool_manager
        .authentication_connection()
        .await
        .expect("Failed to get connection");

    let rows = connection
        .query(
            "SELECT '{ \"ok\": 1 }'::documentdb_core.bson, false::bool",
            &[],
            &[],
        )
        .await
        .expect("Query failed");

    let response = PgResponse::new(rows);
    assert!(!response.write_success().expect("write_success failed"));
}

/// When the query returns `(bson, true)`, `write_success` returns `true`.
#[tokio::test]
async fn write_success_returns_true_when_p_success_is_true() {
    let pool_manager = postgres::get_pool_manager();
    let connection = pool_manager
        .authentication_connection()
        .await
        .expect("Failed to get connection");

    let rows = connection
        .query(
            "SELECT '{ \"ok\": 1 }'::documentdb_core.bson, true::bool",
            &[],
            &[],
        )
        .await
        .expect("Query failed");

    let response = PgResponse::new(rows);
    assert!(response.write_success().expect("write_success failed"));
}

/// When the query returns only a single BSON column (no `p_success`),
/// `write_success` defaults to `true`.
#[tokio::test]
async fn write_success_defaults_to_true_when_column_absent() {
    let pool_manager = postgres::get_pool_manager();
    let connection = pool_manager
        .authentication_connection()
        .await
        .expect("Failed to get connection");

    let rows = connection
        .query("SELECT '{ \"ok\": 1 }'::documentdb_core.bson", &[], &[])
        .await
        .expect("Query failed");

    let response = PgResponse::new(rows);
    assert!(response.write_success().expect("write_success failed"));
}

/// An empty response (no rows) returns an error from `write_success`.
#[tokio::test]
async fn write_success_errors_on_empty_response() {
    let response = PgResponse::new(vec![]);
    response.write_success().unwrap_err();
}
