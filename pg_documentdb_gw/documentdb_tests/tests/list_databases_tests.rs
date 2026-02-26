/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/list_databases_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::list_databases, test_setup::initialize};

#[tokio::test]
async fn list_databases() -> Result<(), mongodb::error::Error> {
    let client = initialize::initialize().await;

    list_databases::validate_list_databases(&client).await
}
