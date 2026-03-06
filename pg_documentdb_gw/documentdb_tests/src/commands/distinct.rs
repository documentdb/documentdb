/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/distinct.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Database};

pub async fn validate_distinct(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");
    coll.insert_one(doc! {"a": 1}).await?;
    coll.insert_one(doc! {"a": 2}).await?;

    let result = db
        .run_command(doc! {
            "distinct": "test",
            "key": "a",
        })
        .await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    let values: Vec<i32> = result
        .get_array("values")
        .unwrap()
        .iter()
        .map(|x| x.as_i32().unwrap())
        .collect();

    assert_eq!(values.len(), 2);
    assert!(values.contains(&2));
    assert!(values.contains(&1));

    Ok(())
}
