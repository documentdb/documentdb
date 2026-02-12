/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * tests/invalid_index_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use mongodb::error::WriteFailure;

mod common;

#[tokio::test(flavor = "multi_thread", worker_threads = 2)]
async fn test_index_key_too_large_error() -> Result<(), mongodb::error::Error> {
    let db_name = "test_index_key_db";
    let coll_name = "test_index_key_coll";
    let db = common::initialize_with_db(db_name).await;
    let collection = db.collection::<Document>(coll_name);

    // Drop collection if it exists
    collection.drop().await.ok();

    // Create the collection
    db.create_collection(coll_name).await?;

    // Create index with enableLargeIndexKeys set to false
    let create_index_command = doc! {
        "createIndexes": coll_name,
        "indexes": [
            {
                "key": { "$**": 1 },
                "name": "ikey_1",
                "enableLargeIndexKeys": false,
                "enableOrderedIndex": false,
            }
        ]
    };
    db.run_command(create_index_command).await?;

    // Create a very large string
    let large_value = "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";

    // Try to insert a document with a very large index key
    let result = collection.insert_one(doc! { "ikey": large_value }).await;

    match result {
        Err(e) => {
            if let mongodb::error::ErrorKind::Write(WriteFailure::WriteError(write_error)) = *e.kind
            {
                assert_eq!(
                    write_error.code, 201,
                    "Expected error code 201 (CannotBuildIndexKeys), but got {}",
                    write_error.code
                );
                assert_eq!(
                    write_error.message, "Index key is too large.",
                    "Expected error message 'Index key is too large.', but got '{}'",
                    write_error.message
                );
            } else {
                panic!("Expected WriteFailure error but got different error type: {e:?}");
            }
        }
        Ok(_) => {
            panic!("Expected error but insert succeeded");
        }
    }

    Ok(())
}
