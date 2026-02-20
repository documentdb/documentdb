/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/current_op.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{doc, Document};
use mongodb::{error::Error, Database};
use tokio::time::{sleep, Duration};

fn validate_current_op_response(current_op_response: &Document, inprog_present: bool) {
    assert!(
        current_op_response.contains_key("inprog"),
        "Response should contain 'inprog' field"
    );

    assert!(
        current_op_response.contains_key("ok"),
        "Response should contain 'ok' field"
    );
    assert_eq!(
        current_op_response.get_f64("ok").unwrap(),
        1.0,
        "'ok' field should equal 1"
    );

    if inprog_present {
        let inprog = current_op_response
            .get_array("inprog")
            .expect("'inprog' should be an array");
        assert!(
            !inprog.is_empty(),
            "'inprog' array should be non-empty when running concurrent operations"
        );

        for op in inprog {
            let op_doc = op
                .as_document()
                .expect("Each inprog item should be a document");

            // These are the common fields we expect in each operation document, we can add more as needed
            assert!(
                op_doc.contains_key("shard"),
                "Operation should contain 'shard' field"
            );

            assert!(
                op_doc.contains_key("active"),
                "Operation should contain 'active' field"
            );

            assert!(
                op_doc.contains_key("type"),
                "Operation should contain 'type' field"
            );

            let mut has_opid = true;

            // known case where opid and op_prefix are not present is createIndexes command,
            // as it's currently implemented as a background worker job without an associated PG backend process
            // see AddIndexBuilds at pg_documentdb/src/commands/current_op.c for details
            if op_doc.contains_key("command") {
                if let Ok(command) = op_doc.get_document("command") {
                    if command.contains_key("createIndexes") {
                        has_opid = false;
                    }
                }
            }

            if has_opid {
                assert!(
                    op_doc.contains_key("opid"),
                    "Operation should contain 'opid' field"
                );

                assert!(
                    op_doc.contains_key("op_prefix"),
                    "Operation should contain 'op_prefix' field"
                );
            }

            if let Ok(active) = op_doc.get_bool("active") {
                if active {
                    assert!(
                        op_doc.contains_key("op"),
                        "Operation should contain 'op' field"
                    );

                    assert!(
                        op_doc.contains_key("command"),
                        "Operation should contain 'command' field"
                    );

                    assert!(
                        op_doc.contains_key("secs_running"),
                        "Operation should contain 'secs_running' field"
                    );
                }
            }
        }
    }
}

pub async fn validate_empty_current_op(db: &Database) -> Result<(), Error> {
    let result = db.run_command(doc! { "currentOp": 1 }).await?;

    assert!(
        result.contains_key("inprog"),
        "Response should contain 'inprog' field"
    );

    assert!(
        result.contains_key("ok"),
        "Response should contain 'ok' field"
    );
    assert_eq!(
        result.get_f64("ok").unwrap(),
        1.0,
        "'ok' field should equal 1"
    );

    Ok(())
}

pub async fn validate_current_op_with_long_running_task(db: &Database) -> Result<(), Error> {
    let collection = db.collection::<Document>("test_collection");

    let docs: Vec<Document> = (0..1000)
        .map(|i| doc! { "field": i, "data": "some data" })
        .collect();
    let _ = collection.insert_many(docs).await?;

    async fn run_long_running_index_task(collection: &mongodb::Collection<Document>) {
        let res = collection
            .create_index(
                mongodb::IndexModel::builder()
                    .keys(doc! { "field": 1 })
                    .build(),
            )
            .await;
        assert!(
            res.is_ok(),
            "Index creation should succeed, got error: {:?}",
            res.err()
        );

        let res = collection.drop_index("field_1").await;
        assert!(
            res.is_ok(),
            "Index drop should succeed, got error: {:?}",
            res.err()
        );
    }

    let include_all = async {
        // Add a small delay to make sure that the long-running index creation is in progress when we run currentOp
        sleep(Duration::from_millis(50)).await;

        db.run_command(doc! { "currentOp": 1, "$all": true })
            .await
            .expect("Failed to run currentOp command")
    };

    let ((), result) = tokio::join!(run_long_running_index_task(&collection), include_all);
    validate_current_op_response(&result, true);

    let own_ops = async {
        db.run_command(doc! { "currentOp": 1, "$ownOps": true })
            .await
            .expect("Failed to run currentOp command")
    };

    let ((), result) = tokio::join!(run_long_running_index_task(&collection), own_ops);
    validate_current_op_response(&result, false);

    Ok(())
}

pub async fn validate_currentop_basic_structure(db: &Database) -> Result<(), Error> {
    let result = db.run_command(doc! {"currentOp": 1}).await?;

    assert!(result.contains_key("ok"), "Response should have 'ok' field");
    assert_eq!(result.get_f64("ok").unwrap(), 1.0, "Expected ok to be 1.0");

    assert!(
        result.contains_key("inprog"),
        "Response should have 'inprog' field"
    );
    assert!(
        result.get_array("inprog").is_ok(),
        "inprog should be an array"
    );

    Ok(())
}

pub async fn validate_currentop_captures_mongodb_operations(db: &Database) -> Result<(), Error> {
    let collection = db.collection::<Document>("large_test_collection");

    let mut docs = vec![];
    for i in 0..10000 {
        docs.push(doc! {
            "_id": i,
            "category": format!("cat_{}", i % 100),
            "value": i,
            "nested": {
                "field1": i * 2,
                "field2": i * 3,
                "field3": format!("data_{}", i)
            }
        });
    }
    collection.insert_many(docs).await?;

    let mut handles = vec![];
    for _ in 0..3 {
        let coll = collection.clone();
        let db_clone = db.clone();
        let handle = tokio::spawn(async move {
            let pipeline = vec![
                doc! {
                    "$project": {
                        "category": 1,
                        "value": 1,
                        "computed1": { "$multiply": ["$value", "$nested.field1"] },
                        "computed2": { "$add": ["$value", "$nested.field2"] },
                        "string_length": { "$strLenCP": "$nested.field3" }
                    }
                },
                doc! {
                    "$group": {
                        "_id": "$category",
                        "count": { "$sum": 1 },
                        "total_value": { "$sum": "$value" },
                        "avg_computed": { "$avg": "$computed1" },
                        "max_computed": { "$max": "$computed2" }
                    }
                },
                doc! { "$sort": { "total_value": -1 } },
                doc! {
                    "$project": {
                        "_id": 1,
                        "count": 1,
                        "total_value": 1,
                        "computed_ratio": { "$divide": ["$avg_computed", "$total_value"] }
                    }
                },
            ];
            let _ = coll.aggregate(pipeline).await;
            let _ = db_clone.run_command(doc! {"currentOp": 1}).await;
        });
        handles.push(handle);
    }

    sleep(Duration::from_millis(50)).await;

    let result = db
        .run_command(doc! {"currentOp": 1, "$all": true})
        .await
        .unwrap();

    let inprog = result.get_array("inprog").unwrap();
    for op in inprog.iter() {
        if let Some(doc) = op.as_document() {
            if let (Ok(active), Ok(ns)) = (doc.get_bool("active"), doc.get_str("ns")) {
                if active && ns.contains("large_test_collection") {
                    assert!(doc.contains_key("opid"));
                    assert!(doc.contains_key("type"));
                    if doc.contains_key("command") {
                        assert!(doc.get_document("command").is_ok());
                    }
                }
            }
        }
    }

    for handle in handles {
        let _ = handle.await;
    }

    let final_result = db.run_command(doc! {"currentOp": 1}).await?;
    assert_eq!(final_result.get_f64("ok").unwrap(), 1.0);

    Ok(())
}
