/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/find_and_modify.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use futures::StreamExt;
use mongodb::{error::Error, Database};

pub async fn validate_find_and_modify(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;
    coll.insert_one(doc! {"a": 1}).await?;

    let result = db
        .run_command(doc! {
            "findAndModify": "test",
            "query": {"a": 1},
            "update": {"$set": {"b": 1}}
        })
        .await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    assert_eq!(
        result.get_document("value").unwrap().get_i32("a").unwrap(),
        1
    );

    let results: Vec<Result<Document, Error>> = coll.find(doc! {"b":1}).await?.collect().await;
    assert_eq!(results.len(), 1);

    Ok(())
}
