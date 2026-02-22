/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/constant.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Client, Database};

pub async fn validate_rw_concern(client: &Client) -> Result<(), Error> {
    let db = client.database("admin");

    let result = db.run_command(doc! {"getDefaultRWConcern": 1}).await?;

    assert_eq!(
        result
            .get_document("defaultReadConcern")
            .unwrap()
            .get_str("level")
            .unwrap(),
        "majority"
    );
    assert_eq!(
        result
            .get_document("defaultWriteConcern")
            .unwrap()
            .get_str("w")
            .unwrap(),
        "majority"
    );
    assert_eq!(
        result
            .get_document("defaultWriteConcern")
            .unwrap()
            .get_i32("wtimeout")
            .unwrap(),
        0
    );
    assert_eq!(
        result.get_str("defaultReadConcernSource").unwrap(),
        "implicit"
    );
    assert_eq!(
        result.get_str("defaultWriteConcernSource").unwrap(),
        "implicit"
    );

    Ok(())
}

pub async fn validate_get_log(db: &Database) -> Result<(), Error> {
    let result = db.run_command(doc! {"getLog": 1}).await?;

    assert_eq!(result.get_array("log").unwrap().len(), 0);
    assert_eq!(result.get_i32("totalLinesWritten").unwrap(), 0);

    Ok(())
}

pub async fn validate_is_db_grid(db: &Database) -> Result<(), Error> {
    let result = db.run_command(doc! {"isdbgrid": 1}).await?;

    assert_eq!(result.get_f64("isdbgrid").unwrap(), 1.0);
    assert_eq!(result.get_str("hostname").unwrap(), "localhost");

    Ok(())
}

pub async fn validate_host_info(db: &Database) -> Result<(), Error> {
    let result = db.run_command(doc! {"hostInfo":1}).await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    Ok(())
}

pub async fn validate_get_cmd_line_opts(db: &Database) -> Result<(), Error> {
    let result = db.run_command(doc! {"getCmdLineOpts":1}).await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);

    Ok(())
}

pub async fn validate_connectivity(client: &Client) -> Result<(), Error> {
    let _ = client
        .database("ssl_connection")
        .list_collection_names()
        .await?;

    Ok(())
}

pub async fn validate_is_master_unauthenticated(client: &Client) -> Result<(), Error> {
    let result = client
        .database("admin")
        .run_command(doc! {"isMaster":1})
        .await?;

    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    assert_eq!(result.get_str("msg").unwrap(), "isdbgrid");

    // Validate the internal.documentdb_versions structure
    let internal = result
        .get_document("internal")
        .expect("hello response must contain 'internal' document");
    let versions = internal
        .get_array("documentdb_versions")
        .expect("internal must contain 'documentdb_versions' array");
    assert!(
        !versions.is_empty(),
        "documentdb_versions array must not be empty"
    );
    for (i, v) in versions.iter().enumerate() {
        assert!(
            v.as_str().is_some(),
            "documentdb_versions[{i}] must be a string"
        );
    }

    Ok(())
}
