/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/drop_database.rs
 *
 * Test logic for the dropDatabase command.
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use mongodb::{error::Error, Database};

use crate::utils::commands;

// Error codes from all_error_mappings_oss_generated.csv, verified against MongoDB shell output
const ERR_UNKNOWN_BSON_FIELD: i32 = 40415; // ERRCODE_DOCUMENTDB_UNKNOWNBSONFIELD (M0088)

pub async fn validate_drop_database_basic(db: &Database) -> Result<(), Error> {
    db.collection::<Document>("coll1")
        .insert_one(doc! { "_id": 1 })
        .await?;
    db.collection::<Document>("coll2")
        .insert_one(doc! { "_id": 2 })
        .await?;

    let result = db.run_command(doc! { "dropDatabase": 1 }).await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    // verify all collections gone
    let collections = db.list_collection_names().await?;
    assert!(
        collections.is_empty(),
        "All collections should be dropped after dropDatabase"
    );

    Ok(())
}

pub async fn validate_drop_database_unknown_field_error(db: &Database) {
    commands::execute_command_and_validate_error(
        db,
        doc! { "dropDatabase": 1, "unknownField": true },
        ERR_UNKNOWN_BSON_FIELD,
        "not recognized as a valid field",
    )
    .await;
}
