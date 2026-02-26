/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/killop.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{error::Error, Client};

pub async fn validate_killop_missing_op_field(client: &Client) {
    let db = client.database("admin");

    let result = db.run_command(doc! {"killOp": 1}).await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("Did not provide \"op\" field"),
                "Expected error to mention missing 'op' field, got: {msg}"
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }
}

pub async fn validate_killop_invalid_op_format_no_colon(client: &Client) {
    let db = client.database("admin");

    let result = db.run_command(doc! {"killOp": 1, "op": "12345"}).await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("The op argument to killOp must be of the format shardid:opid"),
                "Expected error to mention format 'shardid:opid', got: {msg}"
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }
}

pub async fn validate_killop_invalid_shard_id(client: &Client) {
    let db = client.database("admin");

    let result = db.run_command(doc! {"killOp": 1, "op": "foo:12345"}).await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("Invalid shardId"),
                "Expected error to mention invalid shardId, got: {msg}"
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }
}

pub async fn validate_killop_invalid_op_id(client: &Client) {
    let db = client.database("admin");

    let result = db
        .run_command(doc! {"killOp": 1, "op": "12345:1234C5"})
        .await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("Invalid opId"),
                "Expected error to mention invalid opId, got: {msg}"
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }
}

pub async fn validate_killop_non_admin_database(client: &Client) {
    let db = client.database("test");

    let result = db
        .run_command(doc! {"killOp": 1, "op": "10000000001:12345"})
        .await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("killOp may only be run against the admin database."),
                "Expected error to mention admin database requirement, got: {msg}",
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }
}

pub async fn validate_killop_valid_format(client: &Client) -> Result<(), Error> {
    let db = client.database("admin");

    let result = db
        .run_command(doc! {"killOp": 1, "op": "10000004122:12345"})
        .await?;

    assert!(result.contains_key("ok"));
    let ok_value = result.get_f64("ok").unwrap_or(0.0);
    assert_eq!(ok_value, 1.0, "Expected ok to be 1.0, got: {ok_value}");

    Ok(())
}

pub async fn validate_killop_invalid_shard_or_op_id(client: &Client, op_value: &str) {
    let db = client.database("admin");

    let result = db.run_command(doc! {"killOp": 1, "op": op_value}).await;

    match result {
        Err(e) => {
            let msg = e.to_string();
            assert!(
                msg.contains("Invalid shardid or opid"),
                "Expected error to mention invalid shardid or opid, got: {msg}"
            );
        }
        Ok(_) => panic!("Expected error but got success"),
    }
}
