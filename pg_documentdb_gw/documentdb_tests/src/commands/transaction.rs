/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/transaction.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use futures::StreamExt;
use mongodb::{error::Error, Client, Database};

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
