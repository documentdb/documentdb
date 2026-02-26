/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/multi_connect.rs
 *
 *-------------------------------------------------------------------------
 */

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
