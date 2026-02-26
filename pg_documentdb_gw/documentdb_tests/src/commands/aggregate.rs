/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/aggregate.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use futures::StreamExt;
use mongodb::{error::Error, Database};

pub async fn validate_aggregate(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");

    coll.insert_one(doc! {"a":1}).await?;
    coll.insert_one(doc! {"a":2}).await?;
    coll.insert_one(doc! {"a":3}).await?;

    let results: Vec<Result<Document, Error>> = coll
        .aggregate(vec![doc! {
            "$group": {
                "_id": 1,
                "sum": {"$sum":"$a"}
            }
        }])
        .await?
        .collect()
        .await;

    let result = results[0].as_ref().unwrap();
    assert_eq!(result.get_i32("sum").unwrap(), 6);

    let result = db
        .run_command(doc! {
            "aggregate":"test",
            "cursor": {},
            "pipeline":[{"$group": {
                "_id": 1,
                "sum": {"$sum":"$a"}
            }}]
        })
        .await?;

    let batch = result
        .get_document("cursor")
        .unwrap()
        .get_array("firstBatch")
        .unwrap();
    assert_eq!(batch[0].as_document().unwrap().get_i32("sum").unwrap(), 6);

    Ok(())
}

pub async fn validate_concat_arrays_error(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;

    let results = coll
        .aggregate(vec![
            doc! {"$project": {"_id": 0, "all": {"$concatArrays": ["$a", "$str"]}}},
        ])
        .await;

    assert!(results.is_err_and(|_| true));

    Ok(())
}
