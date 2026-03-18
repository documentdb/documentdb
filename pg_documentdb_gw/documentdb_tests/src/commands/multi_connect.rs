/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/multi_connect.rs
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

use bson::{doc, Document};
use futures::StreamExt;
use mongodb::{error::Error, Database};

pub async fn validate_multi_connect(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");

    for _ in 0..1000 {
        let result: Vec<Result<Document, Error>> = coll.find(doc! {}).await?.collect().await;
        assert_eq!(result.len(), 0);
    }

    Ok(())
}
