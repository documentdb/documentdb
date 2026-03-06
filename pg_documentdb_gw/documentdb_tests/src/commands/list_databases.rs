/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/list_databases.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Client};

pub async fn validate_list_databases(client: &Client) -> Result<(), Error> {
    let db_name = "list_databases";
    let db = client.database(db_name);
    db.drop().await?;

    db.collection("test").insert_one(doc! {"a": 1}).await?;

    let result = client
        .database("admin")
        .run_command(doc! {"listDatabases": 1})
        .await?;
    assert!(!result.get_array("databases").unwrap().is_empty());

    let result = client
        .database("admin")
        .run_command(doc! {"listDatabases": 1, "filter":{"name":"list_databases"}})
        .await?;
    assert_eq!(result.get_array("databases").unwrap().len(), 1);

    Ok(())
}
