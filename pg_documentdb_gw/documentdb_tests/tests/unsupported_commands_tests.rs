/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/unsupported_commands_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{commands::unsupported_commands, test_setup::initialize};
use mongodb::error::Error;

#[tokio::test]
async fn command_not_found() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_command_not_found").await?;

    unsupported_commands::validate_command_not_found(&db).await;
    Ok(())
}

#[tokio::test]
async fn command_not_supported() -> Result<(), Error> {
    let db = initialize::initialize_with_db("commands_tests_command_not_supported").await?;

    unsupported_commands::validate_commands_not_supported(&db).await;
    Ok(())
}
