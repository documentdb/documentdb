/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/explain_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::explain, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn explain() -> Result<(), Error> {
    let db = initialize::initialize_with_db("explain").await?;

    explain::validate_explain(&db).await
}
