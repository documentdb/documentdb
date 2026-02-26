/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/text_search_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::text_search, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn text_query_should_fail_no_index() -> Result<(), Error> {
    let db = initialize::initialize_with_db("text_query_should_fail_no_index").await?;

    text_search::validate_text_query_should_fail_no_index(&db).await
}

#[tokio::test]
async fn text_query_exceed_max_depth() -> Result<(), Error> {
    let db = initialize::initialize_with_db("text_query_exceed_max_depth").await?;

    text_search::validate_text_query_exceed_max_depth(&db).await
}
