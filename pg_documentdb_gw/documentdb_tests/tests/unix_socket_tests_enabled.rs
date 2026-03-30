/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/unix_socket_tests_enabled.rs
 *
 *-------------------------------------------------------------------------
 */

use std::path::Path;
use std::time::Duration;

use bson::doc;
use documentdb_tests::test_setup::initialize;
use mongodb::Client;
use tokio::time::sleep;

async fn wait_for_unix_client_ready(unix_client: &Client) -> Result<(), mongodb::error::Error> {
    let mut last_error = None;

    for _attempt in 0..20 {
        match unix_client.list_database_names().await {
            Ok(_) => return Ok(()),
            Err(error) => {
                last_error = Some(error);
                sleep(Duration::from_millis(100)).await;
            }
        }
    }

    let Some(error) = last_error else {
        unreachable!("readiness loop should have returned early on success");
    };

    Err(error)
}

#[tokio::test]
async fn test_unix_socket_enabled() -> Result<(), mongodb::error::Error> {
    let socket_path = "/tmp/osddb.sock";
    let (_tcp, unix) =
        initialize::initialize_with_config_and_unix(Some(socket_path.to_owned())).await?;

    // Verify socket file exists
    assert!(Path::new(socket_path).exists());

    // Verify Unix client was created
    let unix_client = unix.expect("Unix client should exist");

    // Verify we can connect and make requests
    wait_for_unix_client_ready(&unix_client).await?;
    Ok(())
}

#[tokio::test]
async fn test_tcp_and_unix_both_work() -> Result<(), mongodb::error::Error> {
    let socket_path = "/tmp/osddb.sock";
    let (tcp, unix) =
        initialize::initialize_with_config_and_unix(Some(socket_path.to_owned())).await?;

    let unix_client = unix.expect("Unix client should exist");
    wait_for_unix_client_ready(&unix_client).await?;
    let tcp_db = tcp.database("test_both");
    let unix_db = unix_client.database("test_both");

    // Clean up database to ensure a fresh start
    tcp_db.drop().await.unwrap();

    let tcp_coll = tcp_db.collection::<bson::Document>("test");
    let unix_coll = unix_db.collection::<bson::Document>("test");

    tcp_coll.insert_one(doc! { "via": "tcp" }).await.unwrap();
    unix_coll.insert_one(doc! { "via": "unix" }).await.unwrap();

    // Verify TCP-inserted data can be read via Unix socket
    let tcp_data = unix_coll.find_one(doc! { "via": "tcp" }).await.unwrap();
    let tcp_doc = tcp_data.expect("TCP document should exist");
    assert_eq!(tcp_doc.get_str("via").unwrap(), "tcp");

    // Verify Unix-inserted data can be read via TCP
    let unix_data = tcp_coll.find_one(doc! { "via": "unix" }).await.unwrap();
    let unix_doc = unix_data.expect("Unix document should exist");
    assert_eq!(unix_doc.get_str("via").unwrap(), "unix");

    // Sanity check: Both clients should see the same total count (2 documents)
    let tcp_count = tcp_coll.count_documents(doc! {}).await.unwrap();
    let unix_count = unix_coll.count_documents(doc! {}).await.unwrap();
    assert_eq!(tcp_count, 2, "TCP client should see 2 documents");
    assert_eq!(unix_count, 2, "Unix client should see 2 documents");
    assert_eq!(
        tcp_count, unix_count,
        "Both clients should see the same count"
    );

    Ok(())
}
