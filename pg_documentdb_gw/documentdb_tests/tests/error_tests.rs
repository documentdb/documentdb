/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/error_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::aggregate, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn concat_arrays_error() -> Result<(), Error> {
    let db = initialize::initialize_with_db("concat_arrays_error").await?;

    aggregate::validate_concat_arrays_error(&db).await
}
