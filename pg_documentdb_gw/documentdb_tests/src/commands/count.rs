/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/count.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Database};

pub async fn validate_count(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;
    coll.insert_one(doc! {"a": 2}).await?;

    let result = db.run_command(doc! {"count": "test"}).await?;
    assert_eq!(result.get_i32("n").unwrap(), 2);
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    Ok(())
}
