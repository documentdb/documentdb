/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/explain.rs
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
    clippy::expect_used,
    reason = "Test helper functions - expect failures indicate test failures"
)]

use bson::{doc, Bson};
use mongodb::{error::Error, Database};

/// Extract an integer stat regardless of whether it was encoded as Int32,
/// Int64, or Double (the gateway picks the smallest representation).
fn stat_i64(stats: &bson::Document, key: &str) -> Option<i64> {
    match stats.get(key) {
        Some(Bson::Int32(v)) => Some(i64::from(*v)),
        Some(Bson::Int64(v)) => Some(*v),
        #[expect(clippy::cast_possible_truncation, reason = "counter is a whole number")]
        Some(Bson::Double(v)) => Some(*v as i64),
        _ => None,
    }
}

pub async fn validate_explain(db: &Database) -> Result<(), Error> {
    let coll = db.collection("test");

    coll.insert_one(doc! {"a":1}).await?;
    coll.insert_one(doc! {"a":2}).await?;
    coll.insert_one(doc! {"a":3}).await?;

    let _result = db
        .run_command(doc! {
            "aggregate": "test",
            "explain": true,
            "pipeline":[{"$group": {
                "_id": 1,
                "sum": {"$sum":"$a"}
            }}]
        })
        .await?;

    db.run_command(doc! {
        "explain": {
            "aggregate": "test",
            "cursor": {},
            "pipeline":[{"$group": {
                "_id": 1,
                "sum": {"$sum":"$a"}
            }}]
        }
    })
    .await?;

    // Validate that executionStats counters come back as correct integers (not
    // just that the command succeeds). `test` holds 3 documents, so a scan
    // returns all 3. On PG18 these counters arrive as fractional numbers (e.g.
    // 3.00) and must round to whole integers. `nReturned` is plan-independent;
    // `totalDocsExamined` depends on the plan, so we only require it to be a
    // sane count (>= nReturned) rather than an exact value.
    let find_stats = db
        .run_command(doc! {
            "explain": { "find": "test", "filter": { "a": { "$gte": 1 } } },
            "verbosity": "executionStats"
        })
        .await?;

    let execution_stats = find_stats
        .get_document("executionStats")
        .expect("executionStats present in find explain");
    let returned = stat_i64(execution_stats, "nReturned").expect("nReturned present");
    let examined =
        stat_i64(execution_stats, "totalDocsExamined").expect("totalDocsExamined present");
    assert_eq!(returned, 3, "nReturned should count all 3 documents");
    assert!(
        examined >= returned,
        "totalDocsExamined ({examined}) should be at least nReturned ({returned})"
    );

    let lookup_from = db.collection("test_lookup_from");
    for i in 0..20 {
        lookup_from.insert_one(doc! {"k": i % 3, "v": i}).await?;
    }

    db.run_command(doc! {
        "explain": {
            "aggregate": "test",
            "cursor": {},
            "pipeline": [{
                "$lookup": {
                    "from": "test_lookup_from",
                    "localField": "a",
                    "foreignField": "k",
                    "as": "matched"
                }
            }]
        },
        "verbosity": "executionStats"
    })
    .await?;

    Ok(())
}
