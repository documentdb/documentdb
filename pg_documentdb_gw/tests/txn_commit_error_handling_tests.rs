/*-------------------------------------------------------------------------
 * tests/txn_commit_error_handling_tests.rs
 *
 * Tests to verify that the expected error messages are thrown when missing various fields in the
 * commitTransaction admin database command.
 *
 * To run this test individually:
 * cargo test --test txn_commit_error_handling_tests -- --test-threads=1
 *-------------------------------------------------------------------------
 */
pub mod common;
use crate::common::validation_utils;
use mongodb::bson::{doc, Binary, Uuid};
use mongodb::{Client, ClientSession, Database};

async fn setup_transaction_with_insert(db_name: &str) -> (Client, Database, ClientSession) {
    let client = common::initialize().await;
    let db = common::setup_db(&client, db_name).await;
    let coll = db.collection::<mongodb::bson::Document>("test");

    let mut session = client.start_session().await.unwrap();
    session.start_transaction().await.unwrap();

    coll.insert_one(doc! {"a": 1})
        .session(&mut session)
        .await
        .unwrap();

    (client, db, session)
}

#[tokio::test]
async fn test_commit_transaction_success() {
    let (client, db, mut session) = setup_transaction_with_insert("txn_commit_success").await;

    let admin_db = client.database("admin");
    let result = admin_db
        .run_command(doc! {
            "commitTransaction": 1,
            "lsid": session.id(),
            "txnNumber": 1_i64,
            "autocommit": false
        })
        .session(&mut session)
        .await;

    assert!(
        result.is_ok(),
        "Expected successful commitTransaction with all fields present: {:?}",
        result
    );

    let coll = db.collection::<mongodb::bson::Document>("test");
    let expected_doc = doc! {"a": 1};
    let doc = coll.find_one(expected_doc).await.unwrap();
    assert!(
        doc.is_some(),
        "Expected to find document {{a:1}} after commit"
    );

    let _ = db
        .run_command(doc! {
            "endSessions": [session.id()]
        })
        .await;
}

#[tokio::test]
async fn test_commit_transaction_missing_multiple_fields() {
    let (client, db, session) = setup_transaction_with_insert("txn_commit_missing_multiple").await;

    let admin_db = client.database("admin");
    validation_utils::execute_command_and_validate_error(
        &admin_db,
        doc! {"commitTransaction": 1},
        125,
        "CommitTransaction must be run within a transaction",
    )
    .await;

    let _ = db
        .run_command(doc! {
            "endSessions": [session.id()]
        })
        .await;
}

#[tokio::test]
async fn test_commit_transaction_missing_lsid() {
    let (client, db, session) = setup_transaction_with_insert("txn_commit_missing_lsid").await;

    let admin_db = client.database("admin");
    validation_utils::execute_command_and_validate_error(
        &admin_db,
        doc! {
            "commitTransaction": 1,
            "txnNumber": 1_i64,
            "autocommit": false
        },
        251,
        "Given transaction number 1 does not match any in-progress transactions",
    )
    .await;

    let _ = db
        .run_command(doc! {
            "endSessions": [session.id()]
        })
        .await;
}

#[tokio::test]
async fn test_commit_transaction_missing_txn_number() {
    let (client, db, session) =
        setup_transaction_with_insert("txn_commit_missing_txn_number").await;

    let uuid = Uuid::new();
    let admin_db = client.database("admin");
    validation_utils::execute_command_and_validate_error(
        &admin_db,
        doc! {
            "commitTransaction": 1,
            "lsid": {"id": Binary { subtype: mongodb::bson::spec::BinarySubtype::Uuid, bytes: uuid.bytes().to_vec() }},
            "autocommit": false
        },
        72,
        "'autocommit' field requires a transaction number to also be specified"
    ).await;

    let _ = db
        .run_command(doc! {
            "endSessions": [session.id()]
        })
        .await;
}

#[tokio::test]
async fn test_commit_transaction_missing_autocommit() {
    let (client, db, session) =
        setup_transaction_with_insert("txn_commit_missing_autocommit").await;

    let uuid = Uuid::new();
    let admin_db = client.database("admin");
    validation_utils::execute_command_and_validate_error(
        &admin_db,
        doc! {
            "commitTransaction": 1,
            "lsid": {"id": Binary { subtype: mongodb::bson::spec::BinarySubtype::Uuid, bytes: uuid.bytes().to_vec() }},
            "txnNumber": 1_i64
        },
        50768,
        "txnNumber may only be provided for multi-document transactions and retryable write commands. autocommit:false was not provided, and CommitTransaction is not a retryable write command."
    ).await;

    let _ = db
        .run_command(doc! {
            "endSessions": [session.id()]
        })
        .await;
}
