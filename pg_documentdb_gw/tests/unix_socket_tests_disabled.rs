/*-------------------------------------------------------------------------
 *
 * tests/unix_socket_tests_disabled.rs
 *
 * Tests Unix socket when disabled.
 *
 *-------------------------------------------------------------------------
 */

use bson::doc;
use std::path::Path;

pub mod common;

#[tokio::test]
async fn test_unix_socket_disabled() {
    // Clean up socket files from other test files (they never shutdown)
    let _ = std::fs::remove_file("/tmp/osddb.sock");
    let _ = std::fs::remove_file("/tmp/custom_osddb.sock");

    // When no path is provided, Unix socket should be disabled by default
    let (tcp, unix) = common::initialize_with_config_and_unix(None).await;

    // Verify Unix socket is disabled
    assert!(unix.is_none());
    assert!(!Path::new("/tmp/osddb.sock").exists());

    // Verify TCP still works when Unix socket is disabled
    let db = tcp.database("test_disabled");
    let coll = db.collection::<bson::Document>("test");
    coll.insert_one(doc! { "test": "tcp works" }).await.unwrap();
    let result = coll.find_one(doc! { "test": "tcp works" }).await.unwrap();
    let doc = result.expect("Document should exist");
    assert_eq!(doc.get_str("test").unwrap(), "tcp works");
}

#[tokio::test]
async fn test_unix_socket_connection_fails_when_disabled() {
    let _ = std::fs::remove_file("/tmp/osddb.sock");

    let (_tcp, unix) = common::initialize_with_config_and_unix(None).await;
    assert!(unix.is_none());

    let socket_path = "/tmp/osddb.sock";
    assert!(!Path::new(socket_path).exists());

    // Attempt to create Unix socket client
    let unix_client = common::get_unix_socket_client_custom(socket_path);

    // Try to perform an operation - should fail since socket doesn't exist
    let result = unix_client.list_database_names().await;
    assert!(
        result.is_err(),
        "Unix socket connection should fail when socket is disabled"
    );
}
