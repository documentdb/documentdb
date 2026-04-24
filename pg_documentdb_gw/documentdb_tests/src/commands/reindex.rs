/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/reindex.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Client, Database};

use crate::utils::commands;

/// Verifies that `reIndex` is rejected as unsupported (error code 115).
pub async fn validate_reindex_not_supported(db: &Database) {
    commands::execute_command_and_validate_error(
        db,
        doc! { "reIndex": "reindex_test_coll" },
        115,
        "Not supported operation. Use collMod: \"reindex\" instead.",
        "CommandNotSupported",
    )
    .await;
}

/// Verifies that `reIndex` is rejected inside an active transaction with
/// error code 263 (`OperationNotSupportedInTransaction`).
///
/// # Errors
///
/// Returns an error if session or transaction setup fails.
pub async fn validate_reindex_blocked_in_transaction(
    client: &Client,
    db_name: &str,
) -> Result<(), Error> {
    let mut session = client.start_session().await?;
    session.start_transaction().await?;

    let db = client.database(db_name);
    let result = db
        .run_command(doc! { "reIndex": "reindex_test_coll" })
        .session(&mut session)
        .await;

    commands::validate_error(
        result,
        263,
        "Cannot run 'ReIndex' in a multi-document transaction.",
        "OperationNotSupportedInTransaction",
    );

    session.abort_transaction().await
}
