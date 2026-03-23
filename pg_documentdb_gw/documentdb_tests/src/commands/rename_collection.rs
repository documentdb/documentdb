/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/rename_collection.rs
 *
 * Test logic for the renameCollection command.
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
#![expect(
    clippy::unwrap_used,
    reason = "Test helper functions - unwrap failures indicate test failures"
)]
#![expect(
    clippy::float_cmp,
    reason = "Test assertions compare exact float values returned from database"
)]

use bson::{doc, Document};
use mongodb::{error::Error, Database};

use crate::utils::commands;

// Error code constants
const ERR_COMMAND_NOT_SUPPORTED: i32 = 115;
const ERR_ILLEGAL_OPERATION: i32 = 20;
const ERR_NAMESPACE_NOT_FOUND: i32 = 26;
const ERR_UNKNOWN_BSON_FIELD: i32 = 40415;

/// Returns a fully-qualified namespace string "db.collection".
fn ns(db: &Database, coll: &str) -> String {
    format!("{}.{}", db.name(), coll)
}

pub async fn validate_rename_collection_basic(db: &Database) -> Result<(), Error> {
    db.collection::<Document>("source_coll")
        .insert_one(doc! { "_id": 1, "a": 1 })
        .await?;

    let result = db
        .run_command(doc! {
            "renameCollection": ns(db, "source_coll"),
            "to": ns(db, "target_coll"),
        })
        .await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    let count = db
        .collection::<Document>("target_coll")
        .count_documents(doc! {})
        .await?;
    assert_eq!(count, 1, "Document should have moved to target_coll");

    Ok(())
}

pub async fn validate_rename_collection_with_drop_target(db: &Database) -> Result<(), Error> {
    db.collection::<Document>("coll_a")
        .insert_one(doc! { "_id": 1, "from": "a" })
        .await?;
    db.collection::<Document>("coll_b")
        .insert_one(doc! { "_id": 2, "from": "b" })
        .await?;

    let result = db
        .run_command(doc! {
            "renameCollection": ns(db, "coll_a"),
            "to": ns(db, "coll_b"),
            "dropTarget": true,
        })
        .await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    let doc = db
        .collection::<Document>("coll_b")
        .find_one(doc! {})
        .await?
        .unwrap();
    assert_eq!(
        doc.get_str("from").unwrap(),
        "a",
        "coll_b should contain coll_a's data after dropTarget"
    );

    Ok(())
}

pub async fn validate_rename_collection_cross_db_error(db: &Database) {
    commands::execute_command_and_validate_error(
        db,
        doc! {
            "renameCollection": ns(db, "coll1"),
            "to": "other_db.coll1",
        },
        ERR_COMMAND_NOT_SUPPORTED,
        "cannot change databases",
        "CommandNotSupported",
    )
    .await;
}

pub async fn validate_rename_collection_self_rename_error(db: &Database) {
    db.collection::<Document>("same_coll")
        .insert_one(doc! { "_id": 1 })
        .await
        .unwrap();

    commands::execute_command_and_validate_error(
        db,
        doc! {
            "renameCollection": ns(db, "same_coll"),
            "to": ns(db, "same_coll"),
        },
        ERR_ILLEGAL_OPERATION,
        "rename a collection to itself",
        "IllegalOperation",
    )
    .await;
}

pub async fn validate_rename_collection_not_found_error(db: &Database) {
    commands::execute_command_and_validate_error(
        db,
        doc! {
            "renameCollection": ns(db, "no_such_coll"),
            "to": ns(db, "target"),
        },
        ERR_NAMESPACE_NOT_FOUND,
        "does not exist",
        "NamespaceNotFound",
    )
    .await;
}

pub async fn validate_rename_collection_unknown_field_error(db: &Database) {
    db.collection::<Document>("coll_unknown")
        .insert_one(doc! { "_id": 1 })
        .await
        .unwrap();

    commands::execute_command_and_validate_error(
        db,
        doc! {
            "renameCollection": ns(db, "coll_unknown"),
            "to": ns(db, "coll_unknown_target"),
            "unknownField": true,
        },
        ERR_UNKNOWN_BSON_FIELD,
        "not recognized as a valid field",
        "UnknownBsonField",
    )
    .await;
}
