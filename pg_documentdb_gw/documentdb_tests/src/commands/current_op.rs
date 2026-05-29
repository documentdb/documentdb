/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/current_op.rs
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
#![expect(
    clippy::unwrap_used,
    reason = "Test helper functions - unwrap failures indicate test failures"
)]
#![expect(
    clippy::expect_used,
    reason = "Test helper functions - expect failures indicate test failures"
)]
#![expect(
    clippy::float_cmp,
    reason = "Test assertions compare exact float values returned from database"
)]

use bson::{doc, Document};
use mongodb::{error::Error, Client, Database};
use tokio::time::{sleep, Duration};

use crate::utils::commands;

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

    let collection = db.collection::<Document>("test_collection");

    let docs: Vec<Document> = (0..1000)
        .map(|i| doc! { "field": i, "data": "some data" })
        .collect();
    let _ = collection.insert_many(docs).await?;

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
    for op in inprog {
        if let Some(doc) = op.as_document() {
            if let (Ok(active), Ok(ns)) = (doc.get_bool("active"), doc.get_str("ns")) {
                if active && ns.contains("large_test_collection") {
                    assert!(doc.contains_key("opid"));
                    assert!(doc.contains_key("type"));
                    if doc.contains_key("command") {
                        doc.get_document("command").unwrap();
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

pub async fn validate_currentop_aggregation_basic(client: &Client) -> Result<(), Error> {
    let db = client.database("admin");

    let result: Document = db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {}}],
            "cursor": {}
        })
        .await?;

    let cursor = result
        .get_document("cursor")
        .expect("Response should contain 'cursor' field");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("cursor should contain 'firstBatch' array");

    let mut found_active = false;
    for op in first_batch {
        let op_doc = op
            .as_document()
            .expect("Each item in firstBatch should be a document");

        if let Ok(true) = op_doc.get_bool("active") {
            found_active = true;
            for field in &[
                "shard",
                "active",
                "type",
                "opid",
                "secs_running",
                "connectionId",
                "effectiveUsers",
                "killPending",
                "waitingForLock",
                "command",
                "op",
            ] {
                assert!(
                    op_doc.contains_key(*field),
                    "Active op should contain '{field}' field"
                );
            }
        }
    }
    assert!(found_active, "Should find at least one active operation");

    Ok(())
}

pub async fn validate_currentop_aggregation_pipeline_composition(
    client: &Client,
) -> Result<(), Error> {
    let db = client.database("admin");

    let result: Document = db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [
                {"$currentOp": {}},
                {"$match": {"active": true}},
                {"$project": {"opid": 1, "type": 1, "active": 1}},
                {"$limit": 5}
            ],
            "cursor": {}
        })
        .await?;

    let cursor = result
        .get_document("cursor")
        .expect("Response should contain 'cursor' field");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("cursor should contain 'firstBatch' array");

    assert!(first_batch.len() <= 5, "Should have at most 5 results");

    for op in first_batch {
        let op_doc = op.as_document().expect("Each item should be a document");
        assert_eq!(
            op_doc.get_bool("active").unwrap(),
            true,
            "Matched result should have active=true"
        );
        assert!(
            op_doc.contains_key("opid"),
            "Projected result should contain 'opid'"
        );
        assert!(
            op_doc.contains_key("type"),
            "Projected result should contain 'type'"
        );
        assert!(
            op_doc.contains_key("active"),
            "Projected result should contain 'active'"
        );
        assert!(
            !op_doc.contains_key("secs_running"),
            "Projected result should not contain 'secs_running'"
        );
        assert!(
            !op_doc.contains_key("command"),
            "Projected result should not contain 'command'"
        );
    }

    Ok(())
}

pub async fn validate_currentop_aggregation_requires_first_stage(
    client: &Client,
) -> Result<(), Error> {
    let db = client.database("admin");

    commands::execute_command_and_validate_error(
        &db,
        doc! {
            "aggregate": 1,
            "pipeline": [{"$match": {}}, {"$currentOp": {}}],
            "cursor": {}
        },
        73,
        "collection input",
        "InvalidNamespace",
    )
    .await;

    Ok(())
}

pub async fn validate_currentop_aggregation_non_admin_db_error(db: &Database) -> Result<(), Error> {
    commands::execute_command_and_validate_error(
        db,
        doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {}}],
            "cursor": {}
        },
        73,
        "admin",
        "InvalidNamespace",
    )
    .await;

    Ok(())
}

pub async fn validate_currentop_aggregation_nested_pipeline_errors(
    client: &Client,
) -> Result<(), Error> {
    let admin_db = client.database("admin");
    let test_db = client.database("currentop_nested_err");

    // $currentOp inside $facet — namespace validation fires first since $facet is the first stage
    commands::execute_command_and_validate_error(
        &admin_db,
        doc! {
            "aggregate": 1,
            "pipeline": [{"$facet": {"ops": [{"$currentOp": {}}]}}],
            "cursor": {}
        },
        73,
        "collection input",
        "InvalidNamespace",
    )
    .await;

    // $currentOp inside $lookup
    commands::execute_command_and_validate_error(
        &test_db,
        doc! {
            "aggregate": "test",
            "pipeline": [{"$lookup": {"from": "other", "pipeline": [{"$currentOp": {}}], "as": "ops"}}],
            "cursor": {}
        },
        73,
        "admin",
        "InvalidNamespace",
    )
    .await;

    // $currentOp inside $unionWith
    commands::execute_command_and_validate_error(
        &test_db,
        doc! {
            "aggregate": "test",
            "pipeline": [{"$unionWith": {"coll": "other", "pipeline": [{"$currentOp": {}}]}}],
            "cursor": {}
        },
        73,
        "admin",
        "InvalidNamespace",
    )
    .await;

    Ok(())
}

pub async fn validate_currentop_aggregation_option_validation(
    client: &Client,
) -> Result<(), Error> {
    let db = client.database("admin");

    // Non-document value for $currentOp
    commands::execute_command_and_validate_error(
        &db,
        doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": 1}],
            "cursor": {}
        },
        14,
        "$currentOp",
        "TypeMismatch",
    )
    .await;

    // Empty doc should succeed
    let result: Document = db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {}}],
            "cursor": {}
        })
        .await?;
    assert!(
        result.contains_key("cursor"),
        "Empty options should succeed"
    );

    Ok(())
}

pub async fn validate_currentop_command_filter(client: &Client) -> Result<(), Error> {
    let db = client.database("admin");

    let result: Document = db
        .run_command(doc! { "currentOp": 1, "$all": true, "active": true })
        .await?;
    let inprog = result
        .get_array("inprog")
        .expect("Response should have 'inprog'");
    assert!(
        !inprog.is_empty(),
        "active:true filter should return at least the currentOp command itself"
    );
    for op in inprog {
        let op_doc = op.as_document().expect("Each item should be a document");
        assert_eq!(
            op_doc.get_bool("active").unwrap(),
            true,
            "Filtered ops should all be active"
        );
    }

    let result: Document = db
        .run_command(doc! { "currentOp": 1, "$all": true, "op": "query" })
        .await?;
    let inprog = result
        .get_array("inprog")
        .expect("Response should have 'inprog'");
    for op in inprog {
        let op_doc = op.as_document().expect("Each item should be a document");
        assert_eq!(
            op_doc.get_str("op").unwrap(),
            "query",
            "Filtered ops should all have op 'query'"
        );
    }

    Ok(())
}

pub async fn validate_currentop_opmetadata_fields(client: &Client) -> Result<(), Error> {
    let test_db = client.database("currentop_opmetadata");
    let admin_db = client.database("admin");
    let collection = test_db.collection::<Document>("test_collection");

    let docs: Vec<Document> = (0..10000)
        .map(|i| doc! { "field": i, "data": "some data to make documents larger for slower indexing" })
        .collect();
    let _ = collection.insert_many(docs).await?;

    let coll_clone = collection.clone();
    let index_task = async move {
        let _ = coll_clone
            .create_index(
                mongodb::IndexModel::builder()
                    .keys(doc! { "field": 1 })
                    .build(),
            )
            .await;
    };

    let check_task = async {
        sleep(Duration::from_millis(50)).await;
        admin_db
            .run_command(doc! {
                "aggregate": 1,
                "pipeline": [{"$currentOp": {"allUsers": true}}],
                "cursor": {}
            })
            .await
            .expect("Failed to run $currentOp aggregation")
    };

    let ((), result): ((), Document) = tokio::join!(index_task, check_task);

    let cursor = result
        .get_document("cursor")
        .expect("Response should contain 'cursor'");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("cursor should contain 'firstBatch'");

    let mut validated_active_op = false;
    for op in first_batch {
        let op_doc = op.as_document().expect("Each item should be a document");
        if let Ok(true) = op_doc.get_bool("active") {
            validated_active_op = true;

            assert!(
                op_doc.contains_key("effectiveUsers"),
                "Active op should have 'effectiveUsers' field"
            );
            let users = op_doc
                .get_array("effectiveUsers")
                .expect("effectiveUsers should be an array");
            assert!(!users.is_empty(), "effectiveUsers should not be empty");
            let user_doc = users[0]
                .as_document()
                .expect("effectiveUsers entry should be a document");
            assert!(user_doc.contains_key("user"), "Should have 'user' field");
            assert!(user_doc.contains_key("db"), "Should have 'db' field");

            assert!(
                op_doc.contains_key("microsecs_running"),
                "Active op should have 'microsecs_running' field"
            );

            assert!(
                op_doc.contains_key("command"),
                "Active op should have 'command' field"
            );
            assert!(
                op_doc.get_document("command").is_ok(),
                "command should be a document"
            );

            assert_eq!(
                op_doc
                    .get_bool("killPending")
                    .expect("Active op should have 'killPending' field"),
                false,
                "killPending should be false for normal ops"
            );
        }
    }
    assert!(
        validated_active_op,
        "Should have found at least one active operation to validate OpMetadata fields"
    );

    Ok(())
}

pub async fn validate_currentop_aggregation_transaction_error(
    client: &Client,
) -> Result<(), Error> {
    let mut session = client.start_session().await?;
    session.start_transaction().await?;

    let db = client.database("admin");

    let _ = client
        .database("currentop_txn_test")
        .collection::<Document>("test")
        .find_one(doc! {})
        .session(&mut session)
        .await;

    let result = db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {}}],
            "cursor": {}
        })
        .session(&mut session)
        .await;

    match result {
        Err(e) => {
            if let mongodb::error::ErrorKind::Command(ref cmd_err) = *e.kind {
                assert_eq!(
                    cmd_err.code, 263,
                    "Expected OperationNotSupportedInTransaction (263), got {}",
                    cmd_err.code
                );
            } else {
                panic!("Expected CommandError but got different error type: {e:?}");
            }
        }
        Ok(_) => panic!("Expected error but command succeeded"),
    }

    session.abort_transaction().await?;

    Ok(())
}

pub async fn validate_currentop_lsid_binary_uuid(client: &Client) -> Result<(), Error> {
    let admin_db = client.database("admin");

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {"allUsers": true}}],
            "cursor": {}
        })
        .await?;

    let cursor = result
        .get_document("cursor")
        .expect("Response should contain 'cursor'");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("cursor should contain 'firstBatch'");

    for op in first_batch {
        let op_doc = op.as_document().expect("Each item should be a document");
        if let Ok(lsid_doc) = op_doc.get_document("lsid") {
            let id_val = lsid_doc.get("id").expect("lsid should have 'id' field");
            assert!(
                matches!(id_val, bson::Bson::Binary(_)),
                "lsid.id should be Binary UUID type, got {:?}",
                id_val
            );
            if let bson::Bson::Binary(bin) = id_val {
                assert_eq!(
                    bin.subtype,
                    bson::spec::BinarySubtype::Uuid,
                    "lsid.id binary subtype should be UUID"
                );
                assert_eq!(bin.bytes.len(), 16, "UUID should be 16 bytes");
            }
        }
    }

    Ok(())
}

pub async fn validate_currentop_own_ops_filtering(client: &Client) -> Result<(), Error> {
    let admin_db = client.database("admin");

    let result: Document = admin_db.run_command(doc! { "currentOp": 1 }).await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    assert!(result.contains_key("inprog"), "Should have 'inprog'");

    let result: Document = admin_db
        .run_command(doc! { "currentOp": 1, "$ownOps": true })
        .await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    assert!(result.contains_key("inprog"), "Should have 'inprog'");

    let result: Document = admin_db
        .run_command(doc! { "currentOp": 1, "$all": true })
        .await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    let inprog = result.get_array("inprog").expect("Should have 'inprog'");
    assert!(!inprog.is_empty(), "$all:true should return operations");

    let result: Document = admin_db
        .run_command(doc! { "currentOp": 1, "$all": true, "$ownOps": true })
        .await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    assert!(result.contains_key("inprog"), "Should have 'inprog'");

    Ok(())
}

pub async fn validate_currentop_allusers_aggregation(client: &Client) -> Result<(), Error> {
    let admin_db = client.database("admin");

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {}}],
            "cursor": {}
        })
        .await?;
    let cursor = result.get_document("cursor").expect("Should have cursor");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("Should have firstBatch");
    assert!(
        !first_batch.is_empty(),
        "Default $currentOp should return at least self"
    );

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {"allUsers": true}}],
            "cursor": {}
        })
        .await?;
    let cursor = result.get_document("cursor").expect("Should have cursor");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("Should have firstBatch");
    assert!(
        !first_batch.is_empty(),
        "allUsers:true should return operations"
    );

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {"allUsers": false}}],
            "cursor": {}
        })
        .await?;
    assert!(
        result.contains_key("cursor"),
        "allUsers:false should succeed"
    );

    Ok(())
}

pub async fn validate_currentop_cursor_field(client: &Client) -> Result<(), Error> {
    let admin_db = client.database("admin");

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {"allUsers": true}}],
            "cursor": {}
        })
        .await?;

    let cursor = result
        .get_document("cursor")
        .expect("Response should contain 'cursor'");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("cursor should contain 'firstBatch'");

    for op in first_batch {
        let op_doc = op.as_document().expect("Each item should be a document");
        if let Ok(true) = op_doc.get_bool("active") {
            if let Ok(op_type) = op_doc.get_str("op") {
                if op_type == "getmore" {
                    let cursor_doc = op_doc
                        .get_document("cursor")
                        .expect("getMore op should have 'cursor' sub-document");
                    assert!(
                        cursor_doc.contains_key("cursorId"),
                        "cursor sub-document should contain 'cursorId'"
                    );
                } else {
                    assert!(
                        !op_doc.contains_key("cursor"),
                        "Non-getMore op '{}' should not have 'cursor' field",
                        op_type
                    );
                }
            }
        }
    }

    Ok(())
}

pub async fn validate_currentop_transaction_fields(client: &Client) -> Result<(), Error> {
    let test_db = client.database("currentop_txn_fields");
    test_db.drop().await?;
    let admin_db = client.database("admin");
    let collection = test_db.collection::<Document>("test_collection");

    let _ = collection.insert_one(doc! { "x": 1 }).await?;

    let mut session = client.start_session().await?;
    session.start_transaction().await?;

    let coll_clone = collection.clone();
    let txn_task = tokio::spawn(async move {
        let pipeline = vec![
            doc! { "$match": { "x": 1 } },
            doc! { "$lookup": {
                "from": "test_collection",
                "localField": "x",
                "foreignField": "x",
                "as": "joined"
            }},
        ];
        let docs: Vec<Document> = (0..5000)
            .map(|i| doc! { "x": 1, "pad": format!("data_{}", i) })
            .collect();
        let _ = coll_clone.insert_many(docs).session(&mut session).await;
        let _ = coll_clone.aggregate(pipeline).session(&mut session).await;
        session.abort_transaction().await.ok();
    });

    sleep(Duration::from_millis(50)).await;

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {"allUsers": true}}],
            "cursor": {}
        })
        .await?;

    let cursor = result.get_document("cursor").expect("Should have cursor");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("Should have firstBatch");

    let mut found_txn = false;
    for op in first_batch {
        let op_doc = op.as_document().expect("Should be a document");
        if op_doc.contains_key("transaction") {
            found_txn = true;
            let txn_doc = op_doc
                .get_document("transaction")
                .expect("transaction should be a document");
            let params = txn_doc
                .get_document("parameters")
                .expect("transaction should have 'parameters'");
            assert!(
                params.get_i64("txnNumber").is_ok(),
                "parameters should have 'txnNumber' as i64"
            );
            assert_eq!(
                params.get_bool("autocommit").unwrap(),
                false,
                "autocommit should be false"
            );
            if let Ok(time_open) = txn_doc.get_i64("timeOpenMicros") {
                assert!(time_open >= 0, "timeOpenMicros should be non-negative");
            }
        }
    }
    assert!(
        found_txn,
        "Should have found at least one operation with 'transaction' field"
    );

    let _ = txn_task.await;

    Ok(())
}

pub async fn validate_currentop_no_transaction_outside_txn(client: &Client) -> Result<(), Error> {
    let admin_db = client.database("admin");

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [
                {"$currentOp": {}},
                {"$match": {"op": "aggregate"}}
            ],
            "cursor": {}
        })
        .await?;

    let cursor = result.get_document("cursor").expect("Should have cursor");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("Should have firstBatch");

    assert!(!first_batch.is_empty(), "Should have at least one aggregate op (our own query)");

    let mut found_non_txn_aggregate = false;
    for op in first_batch {
        let op_doc = op.as_document().expect("Should be a document");
        if !op_doc.contains_key("transaction") {
            found_non_txn_aggregate = true;
        }
    }
    assert!(
        found_non_txn_aggregate,
        "At least one aggregate op should not have 'transaction' field"
    );

    Ok(())
}

pub async fn validate_currentop_cursor_originating_command(client: &Client) -> Result<(), Error> {
    let test_db = client.database("currentop_orig_cmd");
    test_db.drop().await?;
    let admin_db = client.database("admin");
    let collection = test_db.collection::<Document>("test_collection");

    let docs: Vec<Document> = (0..10000)
        .map(|i| doc! { "field": i, "data": format!("padding_{}", i) })
        .collect();
    let _ = collection.insert_many(docs).await?;

    let coll_clone = collection.clone();
    let cursor_task = tokio::spawn(async move {
        use futures::stream::StreamExt;
        let mut cursor = coll_clone
            .find(doc! {})
            .batch_size(2)
            .await
            .expect("find should succeed");
        while cursor.next().await.is_some() {
            sleep(Duration::from_millis(5)).await;
        }
    });

    sleep(Duration::from_millis(100)).await;

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {"allUsers": true}}],
            "cursor": {}
        })
        .await?;

    let cursor_doc = result
        .get_document("cursor")
        .expect("Should have cursor");
    let first_batch = cursor_doc
        .get_array("firstBatch")
        .expect("Should have firstBatch");

    for op in first_batch {
        let op_doc = op.as_document().expect("Should be a document");
        if let Ok(op_type) = op_doc.get_str("op") {
            if op_type == "getmore" {
                if let Ok(cursor_info) = op_doc.get_document("cursor") {
                    assert!(
                        cursor_info.get_i64("cursorId").is_ok(),
                        "cursor should have cursorId"
                    );
                }
            }
        }
    }

    cursor_task.abort();
    let _ = cursor_task.await;

    Ok(())
}

pub async fn validate_currentop_no_originating_command_without_cursor(
    client: &Client,
) -> Result<(), Error> {
    let admin_db = client.database("admin");

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {"allUsers": true}}],
            "cursor": {}
        })
        .await?;

    let cursor = result
        .get_document("cursor")
        .expect("Should have cursor");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("Should have firstBatch");

    for op in first_batch {
        let op_doc = op.as_document().expect("Should be a document");
        if let Ok(op_type) = op_doc.get_str("op") {
            if op_type == "getmore" {
                assert!(
                    op_doc.contains_key("cursor"),
                    "getMore op should have 'cursor' field"
                );
            } else {
                assert!(
                    !op_doc.contains_key("cursor"),
                    "Non-getMore op '{}' should not have 'cursor' field",
                    op_type
                );
            }
        }
    }

    Ok(())
}

pub async fn validate_currentop_lsid_value_matches_session(client: &Client) -> Result<(), Error> {
    let admin_db = client.database("admin");

    let mut session = client.start_session().await?;

    let session_uuid_bytes = match session.id().get("id") {
        Some(bson::Bson::Binary(bin)) => bin.bytes.clone(),
        other => panic!("Session lsid.id should be Binary, got {:?}", other),
    };

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {"allUsers": true}}],
            "cursor": {}
        })
        .session(&mut session)
        .await?;

    let cursor = result
        .get_document("cursor")
        .expect("Should have cursor");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("Should have firstBatch");

    let mut found_matching_lsid = false;
    for op in first_batch {
        let op_doc = op.as_document().expect("Should be a document");
        if let Ok(lsid_doc) = op_doc.get_document("lsid") {
            if let Some(bson::Bson::Binary(bin)) = lsid_doc.get("id") {
                if bin.bytes == session_uuid_bytes {
                    found_matching_lsid = true;
                    break;
                }
            }
        }
    }
    assert!(
        found_matching_lsid,
        "Should find an operation with lsid matching our session UUID"
    );

    Ok(())
}

pub async fn validate_currentop_effectiveusers_value(client: &Client) -> Result<(), Error> {
    let admin_db = client.database("admin");

    let result: Document = admin_db
        .run_command(doc! {
            "aggregate": 1,
            "pipeline": [{"$currentOp": {"allUsers": true}}],
            "cursor": {}
        })
        .await?;

    let cursor = result
        .get_document("cursor")
        .expect("Should have cursor");
    let first_batch = cursor
        .get_array("firstBatch")
        .expect("Should have firstBatch");

    let mut found_test_user = false;
    for op in first_batch {
        let op_doc = op.as_document().expect("Should be a document");
        if let Ok(true) = op_doc.get_bool("active") {
            if let Ok(users) = op_doc.get_array("effectiveUsers") {
                for user_entry in users {
                    if let Some(user_doc) = user_entry.as_document() {
                        if let Ok(username) = user_doc.get_str("user") {
                            if username == "test" {
                                found_test_user = true;
                                assert!(
                                    user_doc.get_str("db").is_ok(),
                                    "effectiveUsers entry should have 'db' field"
                                );
                            }
                        }
                    }
                }
            }
        }
    }
    assert!(
        found_test_user,
        "Should find an active operation with effectiveUsers containing user 'test'"
    );

    Ok(())
}
