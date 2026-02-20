/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/update.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use futures::StreamExt;
use mongodb::{error::Error, options::UpdateOptions, results::UpdateResult, Database};

pub async fn validate_update_one(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;
    coll.insert_one(doc! {"a": 1}).await?;

    coll.update_one(doc! {"a":1}, doc! {"$set": {"a": 2}})
        .await?;

    let result: Vec<Result<Document, Error>> = coll.find(doc! {"a":2}).await?.collect().await;
    assert_eq!(result.len(), 1);

    // updateOne with sort option
    coll.insert_many([
        doc! {"a":3, "_id":3},
        doc! {"a":-1, "_id":4},
        doc! {"a":0, "_id":5},
    ])
    .await?;

    let mut options: UpdateOptions = UpdateOptions::builder().sort(doc! { "a": 1 }).build();
    let mut update_result: UpdateResult = coll
        .update_one(doc! {}, doc! {"$set": {"a": -2}})
        .with_options(options)
        .await?;
    assert_eq!(update_result.modified_count, 1);

    let mut updated_doc = coll.find_one(doc! {"_id": 4}).await?;
    assert_eq!(updated_doc, Some(doc! {"_id": 4, "a": -2}));

    options = UpdateOptions::builder().sort(doc! { "a": -1 }).build();
    update_result = coll
        .update_one(doc! {}, doc! {"$set": {"a": -10}})
        .with_options(options)
        .await?;
    assert_eq!(update_result.modified_count, 1);

    updated_doc = coll.find_one(doc! {"_id": 3}).await?;
    assert_eq!(updated_doc, Some(doc! {"_id": 3, "a": -10}));

    //negative test
    let err_result = db
        .run_command(doc! {
            "update": "test",
            "updates": [
                {
                    "q": doc! {},
                    "u": {"$set": {"comment": "negative test"}},
                    "multi": true,
                    "sort": doc! { "_id": 1 }
                }
            ]
        })
        .await?;

    let errmsg = err_result
        .get_array("writeErrors")
        .ok()
        .and_then(|errors| errors.first())
        .and_then(|first| first.as_document())
        .and_then(|doc| doc.get_str("errmsg").ok())
        .expect("Expected error message");
    assert_eq!(errmsg, "sort option can not be set when multi=true");

    Ok(())
}

pub async fn validate_update_many(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;
    coll.insert_one(doc! {"a": 1}).await?;

    coll.update_many(doc! {"a":1}, doc! {"$set": {"a": 2}})
        .await?;

    let result: Vec<Result<Document, Error>> = coll.find(doc! {"a":2}).await?.collect().await;
    assert_eq!(result.len(), 2);

    Ok(())
}
