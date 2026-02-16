mod common;
use mongodb::bson::{doc, Document};
use std::time::Duration;

#[tokio::test]
async fn test_currentop_basic_structure() {
    let db = common::initialize_with_db("currentop_basic").await;
    let result = db.run_command(doc! {"currentOp": 1}).await.unwrap();

    // Verify response structure
    assert!(result.contains_key("ok"), "Response should have 'ok' field");
    assert_eq!(result.get_f64("ok").unwrap(), 1.0, "Expected ok to be 1.0");

    // Verify inprog array exists (may be empty)
    assert!(
        result.contains_key("inprog"),
        "Response should have 'inprog' field"
    );
    assert!(
        result.get_array("inprog").is_ok(),
        "inprog should be an array"
    );
}

#[tokio::test]
async fn test_currentop_captures_mongodb_operations() {
    let db = common::initialize_with_db("currentop_capture_test").await;
    let collection = db.collection::<Document>("large_test_collection");

    // Insert substantial dataset
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
    collection.insert_many(docs).await.unwrap();

    // Launch multiple concurrent complex aggregations
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

    // Give operations time to start
    tokio::time::sleep(Duration::from_millis(50)).await;

    // Call currentOp to capture the operations
    let result = db
        .run_command(doc! {"currentOp": 1, "$all": true})
        .await
        .unwrap();

    let inprog = result.get_array("inprog").unwrap();
    for op in inprog.iter() {
        if let Some(doc) = op.as_document() {
            if let Ok(active) = doc.get_bool("active") {
                if active {
                    if let Ok(ns) = doc.get_str("ns") {
                        if ns.contains("large_test_collection") {
                            // Verify operation has expected fields
                            assert!(doc.contains_key("opid"));
                            assert!(doc.contains_key("type"));
                            if doc.contains_key("command") {
                                assert!(doc.get_document("command").is_ok());
                            }
                        }
                    }
                }
            }
        }
    }

    // Wait for all operations to complete
    for handle in handles {
        let _ = handle.await;
    }

    // Verify we can still get currentOp output after operations complete
    let final_result = db.run_command(doc! {"currentOp": 1}).await.unwrap();
    assert_eq!(final_result.get_f64("ok").unwrap(), 1.0);
}
