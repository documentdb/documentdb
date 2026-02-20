/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/collection_cmd.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Database};

pub async fn validate_drop(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;

    coll.drop().await?;

    Ok(())
}

pub async fn validate_create(db: &Database) -> Result<(), Error> {
    let result = db.run_command(doc! {"create":"test"}).await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    Ok(())
}

pub async fn validate_shard_collections(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;

    db.run_command(doc! {"shardCollection": "shard_collections.test", "key": {"_id": "hashed"}})
        .await?;
    coll.drop().await?;

    Ok(())
}
