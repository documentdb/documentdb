/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/validate_cmd.rs
 *
 *-------------------------------------------------------------------------
 */

#![expect(
    clippy::missing_panics_doc,
    reason = "Test helper functions - panics are expected test failures"
)]
#![expect(
    clippy::missing_errors_doc,
    reason = "Test helper functions - error conditions are self-explanatory"
)]
#![expect(
    clippy::unwrap_used,
    reason = "Test helper functions - unwrap failures indicate test failures"
)]

use bson::doc;
use mongodb::{error::Error, Database};

pub async fn validate_command_validate(db: &Database) -> Result<(), Error> {
    db.collection("test").insert_one(doc! {"a": 1}).await?;
    let result = db.run_command(doc! {"validate": "test"}).await?;

    assert!(result.get_bool("valid").unwrap());
    assert!(!result.get_bool("repaired").unwrap());

    Ok(())
}
