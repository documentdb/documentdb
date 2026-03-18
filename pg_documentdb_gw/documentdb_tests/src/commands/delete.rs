/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/delete.rs
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

pub async fn validate_delete_one(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;
    coll.insert_one(doc! {"a": 1}).await?;

    coll.delete_one(doc! {"a":1}).await?;

    let result: Vec<Result<Document, Error>> = coll.find(doc! {}).await?.collect().await;
    assert_eq!(result.len(), 1);

    Ok(())
}

pub async fn validate_delete_many(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;
    coll.insert_one(doc! {"a": 1}).await?;

    coll.delete_many(doc! {"a":1}).await?;

    let result: Vec<Result<Document, Error>> = coll.find(doc! {"a":2}).await?.collect().await;
    assert_eq!(result.len(), 0);

    Ok(())
}
