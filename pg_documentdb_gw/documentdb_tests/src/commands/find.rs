/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/find.rs
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

use bson::{doc, Document};
use futures::StreamExt;
use mongodb::{error::Error, Database};

pub async fn validate_find(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    let result: Vec<Result<Document, Error>> = coll.find(doc! {}).await?.collect().await;
    assert_eq!(result.len(), 0);

    coll.insert_one(doc! {"a":1}).await?;
    coll.insert_one(doc! {"a":2}).await?;
    coll.insert_one(doc! {"a":3}).await?;

    let result: Vec<Result<Document, Error>> = coll.find(doc! {}).await?.collect().await;
    assert_eq!(result.len(), 3);

    Ok(())
}
