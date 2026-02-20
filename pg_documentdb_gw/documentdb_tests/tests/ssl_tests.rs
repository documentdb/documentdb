/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/ssl_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::constant, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn ssl_connection() -> Result<(), Error> {
    let client = initialize::initialize().await;

    constant::validate_connectivity(&client).await
}
