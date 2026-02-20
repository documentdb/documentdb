/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/compact.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use mongodb::{error::Error, Database};

pub async fn validate_compact_basic(db: &Database) -> Result<(), Error> {
    let collection = db.collection::<Document>("test_collection");
    collection
        .insert_one(doc! {"_id": 1, "name": "test"})
        .await?;

    let result = db.run_command(doc! {"compact": "test_collection"}).await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    assert!(result.contains_key("bytesFreed"));

    Ok(())
}

pub async fn validate_compact_with_force(db: &Database) -> Result<(), Error> {
    let collection = db.collection::<Document>("test_collection");
    collection
        .insert_one(doc! {"_id": 1, "name": "test"})
        .await?;

    let result = db
        .run_command(doc! {"compact": "test_collection", "force": true})
        .await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    assert!(result.contains_key("bytesFreed"));

    Ok(())
}

pub async fn validate_compact_with_padding_factor(db: &Database) -> Result<(), Error> {
    let collection = db.collection::<Document>("test_collection");
    collection
        .insert_one(doc! {"_id": 1, "name": "test"})
        .await?;

    let result = db
        .run_command(doc! {"compact": "test_collection", "paddingFactor": 1.5})
        .await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("UnknownBsonField"),
                "Expected error to contain 'UnknownBsonField', got: {msg}"
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }

    Ok(())
}

pub async fn validate_compact_with_padding_bytes(db: &Database) -> Result<(), Error> {
    let collection = db.collection::<Document>("test_collection");
    collection
        .insert_one(doc! {"_id": 1, "name": "test"})
        .await?;

    let result = db
        .run_command(doc! {"compact": "test_collection", "paddingBytes": 1024})
        .await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("UnknownBsonField"),
                "Expected error to contain 'UnknownBsonField', got: {msg}"
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }

    Ok(())
}

pub async fn validate_compact_nonexistent_collection(db: &Database) {
    let result = db
        .run_command(doc! {"compact": "nonexistent_collection"})
        .await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("NamespaceNotFound"),
                "Expected error to contain 'NamespaceNotFound', got: {msg}"
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }
}

pub async fn validate_compact_invalid_arguments(db: &Database) {
    let result = db.run_command(doc! {"compact": 123}).await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("TypeMismatch"),
                "Expected error to contain 'TypeMismatch', got: {msg}"
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }
}
