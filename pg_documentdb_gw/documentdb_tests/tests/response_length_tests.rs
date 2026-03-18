/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/response_length_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_gateway_core::responses::{PgResponse, Response};
use documentdb_tests::test_setup::postgres;

#[tokio::test]
async fn pg_response_byte_len_matches_query_result() {
    let pool_manager = postgres::get_pool_manager();
    let connection = pool_manager
        .authentication_connection()
        .await
        .expect("Failed to get connection");

    let rows = connection
        .query("SELECT 'hello'::text, 42::int4, true::bool", &[], &[])
        .await
        .expect("Query failed");

    let response = Response::Pg(PgResponse::new(rows));

    assert_eq!(response.response_byte_len(), 10);
}
