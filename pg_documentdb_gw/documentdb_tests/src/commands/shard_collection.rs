/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/shard_collection.rs
 *
 * Test logic for the shardCollection and reshardCollection commands.
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use mongodb::{error::Error, Database};

use crate::utils::commands;

const ERR_FAILED_TO_PARSE: i32 = 9;

pub async fn validate_shard_collection_basic(db: &Database) -> Result<(), Error> {
    db.collection::<Document>("test_coll")
        .insert_one(doc! { "_id": 1, "a": 1 })
        .await?;

    let result = db
        .run_command(doc! {
            "shardCollection": format!("{}.test_coll", db.name()),
            "key": { "a": "hashed" },
        })
        .await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    Ok(())
}

pub async fn validate_shard_collection_missing_key_error(db: &Database) {
    commands::execute_command_and_validate_error(
        db,
        doc! {
            "shardCollection": format!("{}.test_coll", db.name()),
        },
        ERR_FAILED_TO_PARSE,
        "The key parameter is required",
    )
    .await;
}

pub async fn validate_reshard_collection_missing_key_error(db: &Database) {
    db.collection::<Document>("test_coll")
        .insert_one(doc! { "_id": 1 })
        .await
        .unwrap();

    commands::execute_command_and_validate_error(
        db,
        doc! {
            "reshardCollection": format!("{}.test_coll", db.name()),
        },
        ERR_FAILED_TO_PARSE,
        "The key parameter is required",
    )
    .await;
}
