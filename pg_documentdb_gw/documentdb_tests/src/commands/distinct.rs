/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/commands/distinct.rs
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
    clippy::float_cmp,
    reason = "Test assertions compare exact float values returned from database"
)]

use bson::{doc, Bson, Document};
use mongodb::{error::Error, Database};

async fn distinct_values(db: &Database, command: Document) -> Result<Vec<Bson>, Error> {
    let result = db.run_command(command).await?;
    assert_eq!(result.get_f64("ok").unwrap(), 1.0);
    Ok(result.get_array("values").unwrap().clone())
}

async fn insert_collation_documents(db: &Database) -> Result<(), Error> {
    let coll = db.collection::<Document>("distinct_collation");
    coll.insert_many([
        doc! {"_id": 1, "value": "cafe", "nested": {"value": "cafe"}, "array": ["cafe", "Tea"], "object": {"value": "cafe"}, "numeric": "2", "punct": "ab"},
        doc! {"_id": 2, "value": "CAF\u{00c9}", "nested": {"value": "CAF\u{00c9}"}, "array": ["CAF\u{00c9}", "tea"], "object": {"value": "CAF\u{00c9}"}, "numeric": "02", "punct": "a-b"},
        doc! {"_id": 3, "value": "Cafe", "nested": {"value": "Cafe"}, "array": ["Cafe"], "object": {"value": "Cafe"}, "numeric": "10", "punct": "a b"},
        doc! {"_id": 4, "value": "tea", "nested": {"value": "tea"}, "array": [Bson::Null, Bson::Int32(1)], "object": {"value": "tea"}, "numeric": "a2", "punct": "a_b"},
        doc! {"_id": 5, "value": "TEA", "nested": {}, "array": [], "object": {"value": "TEA"}, "numeric": "a10", "punct": "ab"},
        doc! {"_id": 6, "value": Bson::Null, "array": [Bson::Null], "object": Bson::Null, "numeric": 2, "punct": Bson::Null},
        doc! {"_id": 7, "value": "\u{1f600}a", "nested": {"value": "\u{1f600}a"}, "array": ["\u{1f600}a"], "object": {"value": "\u{1f600}a"}},
        doc! {"_id": 8, "value": "\u{1f600}A", "nested": {"value": "\u{1f600}A"}, "array": ["\u{1f600}A"], "object": {"value": "\u{1f600}A"}},
    ])
    .await?;
    Ok(())
}

async fn validate_scalar_collations(db: &Database) -> Result<(), Error> {
    for collation in [
        Bson::Document(doc! {}),
        Bson::Null,
        Bson::Document(doc! {"locale": "simple", "strength": 1}),
    ] {
        let values = distinct_values(
            db,
            doc! {
                "distinct": "distinct_collation",
                "key": "value",
                "collation": collation,
            },
        )
        .await?;
        assert_eq!(values.len(), 8);
    }

    for (collation, expected_count) in [
        (doc! {"locale": "en", "strength": 1}, 4),
        (doc! {"locale": "en", "strength": 2}, 5),
        (doc! {"locale": "en", "strength": 3}, 8),
        (doc! {"locale": "en", "strength": 1, "caseLevel": true}, 8),
    ] {
        let values = distinct_values(
            db,
            doc! {
                "distinct": "distinct_collation",
                "key": "value",
                "collation": collation,
            },
        )
        .await?;
        assert_eq!(values.len(), expected_count);
        assert!(values
            .iter()
            .all(|value| matches!(value, Bson::String(_) | Bson::Null)));
    }

    let values = distinct_values(
        db,
        doc! {
            "distinct": "distinct_collation",
            "key": "numeric",
            "collation": {"locale": "en", "numericOrdering": true},
        },
    )
    .await?;
    assert_eq!(values.len(), 5);

    let values = distinct_values(
        db,
        doc! {
            "distinct": "distinct_collation",
            "key": "punct",
            "collation": {
                "locale": "en",
                "strength": 1,
                "alternate": "shifted",
                "maxVariable": "punct",
            },
        },
    )
    .await?;
    assert_eq!(values.len(), 2);

    Ok(())
}

async fn validate_path_and_filter_collations(db: &Database) -> Result<(), Error> {
    for (key, expected_count) in [("nested.value", 3), ("array", 5), ("object", 4)] {
        let values = distinct_values(
            db,
            doc! {
                "distinct": "distinct_collation",
                "key": key,
                "collation": {"locale": "en", "strength": 1},
            },
        )
        .await?;
        assert_eq!(values.len(), expected_count);
        assert!(values.iter().all(|value| {
            value
                .as_document()
                .is_none_or(|document| !document.contains_key("collation"))
        }));
    }

    let values = distinct_values(
        db,
        doc! {
            "distinct": "distinct_collation",
            "key": "numeric",
            "query": {"value": "CAFE"},
            "collation": {"locale": "en", "strength": 1, "numericOrdering": true},
        },
    )
    .await?;
    assert_eq!(values.len(), 2);

    let values = distinct_values(
        db,
        doc! {
            "distinct": "distinct_collation",
            "key": "value",
            "query": {"value": "\u{1f600}A"},
            "collation": {"locale": "en", "strength": 1},
        },
    )
    .await?;
    assert_eq!(values.len(), 1);

    let values = distinct_values(
        db,
        doc! {
            "distinct": "missing_collection",
            "key": "value",
            "collation": {"locale": "en", "strength": 1},
        },
    )
    .await?;
    assert!(values.is_empty());

    Ok(())
}

pub async fn validate_distinct_collations(db: &Database) -> Result<(), Error> {
    insert_collation_documents(db).await?;
    validate_scalar_collations(db).await?;
    validate_path_and_filter_collations(db).await
}

pub async fn validate_distinct(db: &Database) -> Result<(), Error> {
    let coll = db.collection::<Document>("test");
    coll.insert_one(doc! {"a": 1}).await?;
    coll.insert_one(doc! {"a": 2}).await?;

    let values = distinct_values(
        db,
        doc! {
            "distinct": "test",
            "key": "a",
        },
    )
    .await?;

    assert_eq!(values.len(), 2);
    assert!(values.contains(&Bson::Int32(2)));
    assert!(values.contains(&Bson::Int32(1)));

    Ok(())
}
