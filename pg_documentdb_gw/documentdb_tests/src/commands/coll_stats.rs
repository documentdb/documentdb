/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/coll_stats.rs
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

pub async fn validate_coll_stats(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;

    let result = db.run_command(doc! {"collStats":"test"}).await?;
    assert_eq!(result.get_i32("ok").unwrap(), 1);

    Ok(())
}
