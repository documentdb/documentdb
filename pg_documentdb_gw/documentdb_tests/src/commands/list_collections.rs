/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/list_collections.rs
 *
 *-------------------------------------------------------------------------
 */

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
