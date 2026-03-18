/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/transaction.rs
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
use mongodb::{
    error::{Error, ErrorKind},
    Client, Database,
};

pub async fn validate_commit_transaction(client: &Client, db: &Database) -> Result<(), Error> {
    let mut session = client.start_session().await?;

    session.start_transaction().await?;

    let coll = db.collection("test");
    coll.insert_many([
        doc! {"a": 1},
        doc! {"a": 1},
        doc! {"a": 1},
        doc! {"a": 1},
        doc! {"a": 1},
        doc! {"a": 1},
    ])
    .session(&mut session)
    .await?;

    session.commit_transaction().await?;

    let result: Vec<Result<Document, Error>> = coll.find(doc! {}).await?.collect().await;
    assert_eq!(result.len(), 6);
    Ok(())
}

pub async fn validate_abort_transaction(client: &Client, db: &Database) -> Result<(), Error> {
    let mut session = client.start_session().await?;

    session.start_transaction().await?;

    let coll = db.collection("test");
    coll.insert_many([
        doc! {"a": 1},
        doc! {"a": 1},
        doc! {"a": 1},
        doc! {"a": 1},
        doc! {"a": 1},
        doc! {"a": 1},
    ])
    .session(&mut session)
    .await?;

    session.abort_transaction().await?;

    let result: Vec<Result<Document, Error>> = coll.find(doc! {}).await?.collect().await;
    assert_eq!(result.len(), 0);
    Ok(())
}

/// Asserts a command run inside a transaction returns error code 263
/// (`OperationNotSupportedInTransaction`).
async fn assert_blocked_in_transaction(
    client: &Client,
    db_name: &str,
    command: Document,
) -> Result<(), Error> {
    let mut session = client.start_session().await?;
    session.start_transaction().await?;

    let db = client.database(db_name);
    let result = db.run_command(command).session(&mut session).await;

    match result {
        Err(e) => {
            if let ErrorKind::Command(ref cmd_err) = *e.kind {
                assert_eq!(
                    cmd_err.code, 263,
                    "Expected error code 263 (OperationNotSupportedInTransaction), got: {}",
                    cmd_err.code
                );
            } else {
                panic!("Expected a Command error with code 263, got: {e:?}");
            }
        }
        Ok(resp) => {
            panic!("Expected command to be rejected inside transaction, but got success: {resp:?}")
        }
    }

    session.abort_transaction().await?;
    Ok(())
}

pub async fn validate_list_collections_blocked_in_transaction(
    client: &Client,
) -> Result<(), Error> {
    assert_blocked_in_transaction(client, "txn_list_coll_test", doc! { "listCollections": 1 }).await
}

pub async fn validate_drop_blocked_in_transaction(client: &Client) -> Result<(), Error> {
    assert_blocked_in_transaction(client, "txn_drop_test", doc! { "drop": "some_collection" }).await
}

pub async fn validate_current_op_blocked_in_transaction(client: &Client) -> Result<(), Error> {
    assert_blocked_in_transaction(client, "admin", doc! { "currentOp": 1 }).await
}

pub async fn validate_kill_op_blocked_in_transaction(client: &Client) -> Result<(), Error> {
    assert_blocked_in_transaction(client, "admin", doc! { "killOp": 1, "op": "1:1" }).await
}

pub async fn validate_rename_collection_blocked_in_transaction(
    client: &Client,
) -> Result<(), Error> {
    assert_blocked_in_transaction(
        client,
        "admin",
        doc! { "renameCollection": "txn_rename_test.old_name", "to": "txn_rename_test.new_name" },
    )
    .await
}

pub async fn validate_create_index_blocked_in_transaction(client: &Client) -> Result<(), Error> {
    assert_blocked_in_transaction(
        client,
        "txn_create_idx_test",
        doc! { "createIndex": "some_collection", "key": { "field": 1 }, "name": "field_1" },
    )
    .await
}

pub async fn validate_create_indexes_blocked_in_transaction(client: &Client) -> Result<(), Error> {
    assert_blocked_in_transaction(
        client,
        "txn_create_idxs_test",
        doc! {
            "createIndexes": "some_collection",
            "indexes": [{ "key": { "field": 1 }, "name": "field_1" }]
        },
    )
    .await
}
