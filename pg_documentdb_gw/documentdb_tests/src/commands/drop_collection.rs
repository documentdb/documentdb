/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/drop_collection.rs
 *
 * Test logic for the drop command (drop_collection).
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use mongodb::{error::Error, Database};

use crate::utils::commands;

// Error codes from all_error_mappings_oss_generated.csv, verified against MongoDB shell output
const ERR_UNKNOWN_BSON_FIELD: i32 = 40415; // ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD (M0088)

pub async fn validate_drop_collection_basic(db: &Database) -> Result<(), Error> {
    db.collection::<Document>("test_coll")
        .insert_one(doc! { "_id": 1, "a": 1 })
        .await?;

    let result = db.run_command(doc! { "drop": "test_coll" }).await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    let count = db
        .collection::<Document>("test_coll")
        .count_documents(doc! {})
        .await?;
    assert_eq!(count, 0, "Collection should be empty after drop");

    Ok(())
}

pub async fn validate_drop_collection_with_data(db: &Database) -> Result<(), Error> {
    let coll = db.collection::<Document>("data_coll");
    coll.insert_many(vec![
        doc! { "_id": 1 },
        doc! { "_id": 2 },
        doc! { "_id": 3 },
    ])
    .await?;

    assert_eq!(coll.count_documents(doc! {}).await?, 3);

    let result = db.run_command(doc! { "drop": "data_coll" }).await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    assert_eq!(
        coll.count_documents(doc! {}).await?,
        0,
        "Collection should be gone after drop"
    );

    Ok(())
}

pub async fn validate_drop_collection_unknown_field_error(db: &Database) {
    db.collection::<Document>("coll_unknown")
        .insert_one(doc! { "_id": 1 })
        .await
        .unwrap();

    commands::execute_command_and_validate_error(
        db,
        doc! { "drop": "coll_unknown", "unknownField": true },
        ERR_UNKNOWN_BSON_FIELD,
        "not recognized as a valid field",
    )
    .await;
}
