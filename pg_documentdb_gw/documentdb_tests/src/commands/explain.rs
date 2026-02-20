/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/explain.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Database};

pub async fn validate_explain(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");

    coll.insert_one(doc! {"a":1}).await?;
    coll.insert_one(doc! {"a":2}).await?;
    coll.insert_one(doc! {"a":3}).await?;

    let _result = db
        .run_command(doc! {
            "aggregate": "test",
            "explain": true,
            "pipeline":[{"$group": {
                "_id": 1,
                "sum": {"$sum":"$a"}
            }}]
        })
        .await?;

    db.run_command(doc! {
        "explain": {
            "aggregate": "test",
            "cursor": {},
            "pipeline":[{"$group": {
                "_id": 1,
                "sum": {"$sum":"$a"}
            }}]
        }
    })
    .await?;

    Ok(())
}
