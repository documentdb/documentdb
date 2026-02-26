/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/text_search.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use mongodb::{error::Error, Database};

// Error code constants (avoid circular dependency on documentdb_gateway)
const INDEX_NOT_FOUND_ERROR_CODE: i32 = 27;
const BAD_VALUE_ERROR_CODE: i32 = 2;

pub async fn validate_text_query_should_fail_no_index(db: &Database) -> Result<(), Error> {
    db.create_collection("coll").await?;

    let collection = db.collection::<Document>("coll");
    let filter = doc! { "$text": { "$search": "some search string" } };
    let result = collection.find(filter).await;

    match result {
        Err(e) => {
            if let mongodb::error::ErrorKind::Command(ref command_error) = *e.kind {
                let code_name = &command_error.code_name;
                assert_eq!(
                    "IndexNotFound", code_name,
                    "Expected codeName to be 'IndexNotFound', got: {code_name}"
                );

                let code = command_error.code;
                assert_eq!(
                    INDEX_NOT_FOUND_ERROR_CODE, code,
                    "Expected code to be {INDEX_NOT_FOUND_ERROR_CODE}, got: {code}",
                );

                let error_message = &command_error.message;
                assert_eq!(
                    "A text index is necessary to perform a $text query.",
                    error_message
                );
            } else {
                panic!("Expected Command error kind");
            }
        }
        Ok(_) => panic!("Expected error but got success"),
    }

    Ok(())
}

pub async fn validate_text_query_exceed_max_depth(db: &Database) -> Result<(), Error> {
    let collection = db.collection::<Document>("test");

    let index_result = db
        .collection::<Document>("test")
        .create_index(
            mongodb::IndexModel::builder()
                .keys(doc! {"a":"text"})
                .build(),
        )
        .await?;

    assert_eq!(index_result.index_name, "a_text");

    let indexes = db.collection::<Document>("test").list_index_names().await?;

    assert_eq!(indexes.len(), 2);

    // 32 levels of nested $text, should work
    let suc_filter = doc! { "$text": { "$search": "--------------------------------dummy" } };
    let suc_result = collection.find(suc_filter).await;
    assert!(suc_result.is_ok());

    // 33 levels of nested $text, exceeding the max depth of 32
    let filter = doc! { "$text": { "$search": "---------------------------------dummy" } };
    let result = collection.find(filter).await;

    match result {
        Err(e) => {
            if let mongodb::error::ErrorKind::Command(ref command_error) = *e.kind {
                let code = command_error.code;
                assert_eq!(
                    BAD_VALUE_ERROR_CODE, code,
                    "Expected code to be {BAD_VALUE_ERROR_CODE}, got: {code}",
                );

                let error_message = &command_error.message;
                assert_eq!(
                    "$text query is exceeding the maximum allowed depth(32), please simplify the query",
                    error_message
                );
            } else {
                panic!("Expected Command error kind");
            }
        }
        Ok(_) => panic!("Expected error but got success"),
    }

    Ok(())
}
