/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/insert.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use futures::StreamExt;
use mongodb::{error::Error, Database};

pub async fn validate_insert_one(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;

    let result: Vec<Result<Document, Error>> = coll.find(doc! {}).await?.collect().await;
    assert_eq!(result.len(), 1);

    Ok(())
}

pub async fn validate_insert_many(db: &Database) -> Result<(), Error> {
    let docs = vec![doc! {"a": 1}, doc! {"a": 2}, doc! {"a": 3}];

    let coll = db.collection("test");
    coll.insert_many(&docs).await?;

    let result: Vec<Result<Document, Error>> = coll.find(doc! {}).await?.collect().await;
    assert_eq!(result.len(), docs.len());

    Ok(())
}
