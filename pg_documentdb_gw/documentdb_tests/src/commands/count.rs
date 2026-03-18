/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/count.rs
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
#![expect(
    clippy::float_cmp,
    reason = "Test assertions compare exact float values returned from database"
)]

use bson::doc;
use mongodb::{error::Error, Database};

pub async fn validate_count(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;
    coll.insert_one(doc! {"a": 2}).await?;

    let result = db.run_command(doc! {"count": "test"}).await?;
    assert_eq!(result.get_i32("n").unwrap(), 2);
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    Ok(())
}
