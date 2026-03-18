/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/list_collections.rs
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

pub async fn validate_list_collections(db: &Database) -> Result<(), Error> {
    db.collection("test").insert_one(doc! {"a": 1}).await?;
    db.collection("test2").insert_one(doc! {"a": 1}).await?;

    let result = db.run_command(doc! {"listCollections": 1}).await?;
    assert_eq!(
        result
            .get_document("cursor")
            .unwrap()
            .get_array("firstBatch")
            .unwrap()
            .len(),
        2
    );

    Ok(())
}
