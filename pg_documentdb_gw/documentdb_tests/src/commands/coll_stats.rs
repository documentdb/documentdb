/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/coll_stats.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Database};

pub async fn validate_coll_stats(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;

    let result = db.run_command(doc! {"collStats":"test"}).await?;
    assert_eq!(result.get_i32("ok").unwrap(), 1);

    Ok(())
}
