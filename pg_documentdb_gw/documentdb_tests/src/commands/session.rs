/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/session.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use mongodb::{
    bson::Uuid,
    error::{Error, ErrorKind},
    Client, Database,
};
use tokio::time::{sleep, Duration};

pub async fn validate_processing(client: &Client, command_name: &str) -> Result<(), Error> {
    let session = client.start_session().await?;

    if let Some(bson::Bson::Binary(binary)) = session.id().get("id") {
        let session_id_bytes: [u8; 16] = binary.bytes.as_slice().try_into().unwrap();
        let session_id = Uuid::from_bytes(session_id_bytes);
        let command = doc! {
            command_name: [ { "id": session_id } ]
        };

        let response = client.database("admin").run_command(command).await;

        assert!(response.is_ok());
        let ok_response = response.ok().unwrap();
        assert_eq!(ok_response.get_f64("ok").unwrap(), 1.0);
    }

    Ok(())
}

pub async fn validate_session_termination(
    client: &Client,
    db: &Database,
    collection_name: &str,
    command_name: &str,
) -> Result<(), Error> {
    let collection = db.collection::<bson::Document>(collection_name);

    // Ensure collection exists
    let _ = collection.insert_one(doc! { "field": 1 }).await;

    let mut session = client.start_session().await?;

    if let Some(bson::Bson::Binary(binary)) = session.id().get("id") {
        let session_id_bytes: [u8; 16] = binary.bytes.as_slice().try_into().unwrap();
        let session_id = Uuid::from_bytes(session_id_bytes);

        // Future 1: Start a long-running operation with the session
        let long_running_task = async {
            session
                .start_transaction()
                .await
                .expect("Failed to start transaction");

            collection
                .insert_many((0..6).map(|_| doc! { "a": 1 }))
                .session(&mut session)
                .await
                .expect("Failed to insert within transaction");

            let aggregate_result = db
                .run_command(doc! {
                    "aggregate": collection_name,
                    "pipeline": [{ "$match": { "a": 1 } }],
                    "cursor": { "batchSize": 2 }
                })
                .session(&mut session)
                .await
                .unwrap();

            let cursor_doc = aggregate_result.get_document("cursor").unwrap();
            let first_batch = cursor_doc.get_array("firstBatch").unwrap();
            assert_eq!(
                first_batch.len(),
                2,
                "First batch should contain 2 documents"
            );

            let cursor_id = cursor_doc.get_i64("id").unwrap();

            sleep(Duration::from_millis(100)).await;

            let transaction_response = session.commit_transaction().await;

            assert!(
                transaction_response.is_err(),
                "Transaction should fail due to session termination"
            );

            if let Err(e) = transaction_response {
                let error = e.kind.as_ref();
                if let ErrorKind::Command(cmd_err) = error {
                    assert_eq!(
                        cmd_err.code,
                        251, // NoSuchTransaction error code
                        "Expected NoSuchTransaction error, got: {:?}",
                        cmd_err
                    );
                } else {
                    panic!("Expected Command error, got: {:?}", error);
                }
            }

            let get_more_results = db
                .run_command(doc! {
                    "getMore": cursor_id,
                    "collection": collection_name
                })
                .await;

            assert!(
                get_more_results.is_err(),
                "getMore should fail on killed cursor"
            );

            if let Err(e) = get_more_results {
                if let ErrorKind::Command(ref cmd_err) = *e.kind {
                    assert_eq!(
                        cmd_err.code, 43,
                        "Expected CursorNotFound error code 43, but got {}",
                        cmd_err.code
                    );
                    assert!(
                        cmd_err.message.contains("Provided cursor was not found."),
                        "Error message should indicate cursor not found, got: {}",
                        cmd_err.message
                    );
                } else {
                    panic!("Expected Command error, but got: {:?}", e.kind);
                }
            }
        };

        // Future 2: Terminate the session
        let terminate_session = async {
            // Small delay to ensure the transaction has started
            sleep(Duration::from_millis(100)).await;

            let command = doc! {
                command_name: [ { "id": session_id } ]
            };
            let response = client.database("admin").run_command(command).await;

            assert!(response.is_ok());
            let ok_response = response.ok().unwrap();
            assert_eq!(ok_response.get_f64("ok").unwrap(), 1.0);
        };

        tokio::join!(long_running_task, terminate_session);
    }

    // Cleanup
    let _ = collection.drop().await;

    Ok(())
}
