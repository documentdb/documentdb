/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * documentdb_tests/tests/sorted_cursor_tests.rs
 *
 *-------------------------------------------------------------------------
 */

#![expect(clippy::expect_used, clippy::unwrap_used, reason = "Test assertions")]

use std::{future::IntoFuture, sync::Arc, time::Duration};

use bson::{doc, Document};
use documentdb_gateway_core::{
    auth::AuthenticationManager,
    context::{CursorKey, ServiceContext},
    principal, run_gateway,
    service::{DefaultRequestRouter, TlsProvider},
};
use documentdb_tests::test_setup::{
    clients::{TEST_PASSWORD, TEST_USERNAME},
    config::setup_configuration,
    pools::{build_pool_manager, TestConfiguration},
    postgres,
};
use mongodb::{options::ClientOptions, Client, Database};
use tokio::{net::TcpListener, time::Instant};
use tokio_util::sync::{CancellationToken, DropGuard};

struct TestGateway {
    service: ServiceContext,
    options: ClientOptions,
    db: Database,
    _shutdown: DropGuard,
}

impl TestGateway {
    async fn new(database: &str) -> Self {
        postgres::create_user(TEST_USERNAME, TEST_PASSWORD)
            .await
            .unwrap();
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        drop(listener);
        let mut setup = setup_configuration();
        setup.gateway_listen_port = Some(port);
        let tls = TlsProvider::new(&setup.certificate_options, None, None)
            .await
            .unwrap();
        let pool_manager = Arc::new(build_pool_manager(&setup));
        let service = ServiceContext::new(
            Box::new(setup),
            Arc::new(TestConfiguration::default()),
            pool_manager,
            tls,
            AuthenticationManager::new(),
        );
        let cancellation = CancellationToken::new();
        let shutdown = cancellation.clone().drop_guard();
        let gateway_service = service.clone();
        tokio::spawn(async move {
            run_gateway::<documentdb_gateway_core::postgres::DocumentDBDataClient, _>(
                gateway_service,
                None,
                DefaultRequestRouter {},
                cancellation,
            )
            .await
            .unwrap();
        });

        let mut options = ClientOptions::parse(format!(
            "mongodb://{TEST_USERNAME}:{TEST_PASSWORD}@127.0.0.1:{port}/?tls=true&tlsAllowInvalidCertificates=true&directConnection=true&authMechanism=SCRAM-SHA-256"
        )).await.unwrap();
        options.server_selection_timeout = Some(Duration::from_secs(5));
        let client = Client::with_options(options.clone()).unwrap();
        let db = client.database(database);
        db.drop().await.unwrap();
        db.collection::<Document>("items")
            .insert_many((0..20).map(|i| doc! { "_id": i, "amount": 20 - i }))
            .await
            .unwrap();
        Self {
            service,
            options,
            db,
            _shutdown: shutdown,
        }
    }

    async fn open_cursor(&self, command: Document) -> i64 {
        self.db
            .run_command(command)
            .await
            .unwrap()
            .get_document("cursor")
            .unwrap()
            .get_i64("id")
            .unwrap()
    }

    async fn get_more(&self, id: i64) -> Document {
        self.db
            .run_command(doc! { "getMore": id, "collection": "items", "batchSize": 1 })
            .await
            .expect("idle sorted cursor should still be usable")
    }
}

#[tokio::test]
async fn sorted_find_and_aggregate_survive_the_old_idle_timeout() {
    let gateway = TestGateway::new("sorted_cursor_idle_timeout").await;
    let commands = [
        doc! { "find": "items", "batchSize": 1 },
        doc! { "find": "items", "sort": { "_id": 1 }, "batchSize": 1 },
        doc! { "find": "items", "sort": { "amount": 1 }, "batchSize": 1 },
        doc! { "aggregate": "items", "pipeline": [{ "$sort": { "amount": 1 } }],
        "cursor": { "batchSize": 1 } },
    ];
    let connection = gateway
        .service
        .connection_pool_manager()
        .system_requests_connection()
        .await
        .unwrap();
    let rows = connection
        .query("SELECT oid FROM pg_roles WHERE rolname = 'test'", &[], &[])
        .await
        .unwrap();
    let owner = principal!(TEST_USERNAME, rows[0].get::<_, u32>(0));
    drop(connection);
    let mut ids = Vec::new();
    for command in commands {
        let id = gateway.open_cursor(command).await;
        assert_ne!(id, 0);
        let key = CursorKey::new(id.into(), owner.clone());
        let mut entry = gateway.service.cursor_store().get_cursor(&key).unwrap();
        // Age the real gateway cursor rather than waiting over a minute.
        entry.timestamp = Instant::now() - Duration::from_secs(70);
        gateway.service.cursor_store().add_cursor(key, entry);
        ids.push(id);
    }
    // Allow the production cursor reaper (5-second interval) to inspect every entry.
    tokio::time::sleep(Duration::from_secs(6)).await;
    for &id in &ids {
        let response = gateway.get_more(id).await;
        assert_eq!(
            response
                .get_document("cursor")
                .unwrap()
                .get_array("nextBatch")
                .unwrap()
                .len(),
            1
        );
        let key = CursorKey::new(id.into(), owner.clone());
        let mut entry = gateway.service.cursor_store().get_cursor(&key).unwrap();
        assert!(
            entry.timestamp.elapsed() < Duration::from_secs(6),
            "getMore must refresh the idle timestamp"
        );
        entry.timestamp = Instant::now() - Duration::from_secs(601);
        gateway.service.cursor_store().add_cursor(key, entry);
    }
    tokio::time::sleep(Duration::from_secs(6)).await;
    for id in ids {
        let error = gateway
            .db
            .run_command(doc! {
                "getMore": id, "collection": "items", "batchSize": 1
            })
            .await
            .expect_err("cursors must still expire after ten idle minutes");
        let mongodb::error::ErrorKind::Command(command) = error.kind.as_ref() else {
            panic!("expected a command error: {error}");
        };
        assert_eq!(command.code, 43);
    }
    assert!(gateway.service.cursor_store().is_empty());
}

#[tokio::test]
async fn no_cursor_timeout_is_rejected_instead_of_silently_ignored() {
    let gateway = TestGateway::new("sorted_cursor_no_timeout").await;
    for command in [
        doc! { "find": "items", "batchSize": 1, "noCursorTimeout": true },
        doc! { "find": "items", "sort": { "amount": 1 }, "batchSize": 1,
        "noCursorTimeout": true },
    ] {
        let error = gateway
            .db
            .run_command(command)
            .await
            .expect_err("unsupported noCursorTimeout must be rejected");
        let mongodb::error::ErrorKind::Command(command) = error.kind.as_ref() else {
            panic!("expected a command error: {error}");
        };
        assert_eq!(command.code, 115);
        assert!(command.message.contains("noCursorTimeout"));
    }
    let id = gateway
        .open_cursor(doc! {
            "find": "items", "sort": { "amount": 1 }, "batchSize": 1, "noCursorTimeout": false
        })
        .await;
    gateway.get_more(id).await;
    let error = gateway
        .db
        .run_command(doc! {
            "find": "items", "noCursorTimeout": "true"
        })
        .await
        .expect_err("non-boolean noCursorTimeout must be rejected");
    let mongodb::error::ErrorKind::Command(command) = error.kind.as_ref() else {
        panic!("expected a command error: {error}");
    };
    assert_eq!(command.code, 14);
}

#[tokio::test]
async fn idle_sorted_cursors_leave_capacity_for_other_clients() {
    let gateway = TestGateway::new("sorted_cursor_pool_capacity").await;
    // TestConfiguration has 16 total connections and a system budget of 7:
    // eight persistent cursors must leave the ninth data connection available.
    let mut ids = Vec::new();
    for _ in 0..8 {
        ids.push(
            gateway
                .open_cursor(doc! {
                    "find": "items", "sort": { "amount": 1 }, "batchSize": 1
                })
                .await,
        );
    }
    for command in [
        doc! { "find": "items", "sort": { "amount": 1 }, "batchSize": 1 },
        doc! { "aggregate": "items", "pipeline": [{ "$sort": { "amount": 1 } }],
        "cursor": { "batchSize": 1 } },
    ] {
        let result = tokio::time::timeout(
            Duration::from_secs(5),
            gateway.db.run_command(command).into_future(),
        )
        .await
        .expect("cursor admission must not wait for idle cursors");
        let error = result.expect_err("another persistent cursor must leave data capacity free");
        let mongodb::error::ErrorKind::Command(command) = error.kind.as_ref() else {
            panic!("expected a command error: {error}");
        };
        assert_eq!(command.code, 261);
        assert!(
            error.to_string().contains("cursor"),
            "unexpected error: {error}"
        );
    }
    assert_eq!(
        gateway.service.cursor_store().len(),
        8,
        "rejected cursors must not be stored"
    );
    let plain = gateway
        .open_cursor(doc! { "find": "items", "batchSize": 1 })
        .await;
    assert_ne!(
        plain, 0,
        "stateless cursors must not consume persistent cursor capacity"
    );

    let other = Client::with_options(gateway.options.clone()).unwrap();
    tokio::time::timeout(
        Duration::from_secs(5),
        other
            .database(gateway.db.name())
            .collection::<Document>("items")
            .find_one(doc! { "_id": 1 })
            .into_future(),
    )
    .await
    .expect("another client's read must not wait for cursor expiry")
    .unwrap()
    .expect("document should exist");
    // getMore must keep its existing reservation, even when admission is full.
    gateway.get_more(ids[0]).await;
    gateway
        .db
        .run_command(doc! { "killCursors": "items", "cursors": [ids[0]] })
        .await
        .unwrap();
    let replacement = gateway
        .open_cursor(doc! {
            "find": "items", "sort": { "amount": 1 }, "batchSize": 1
        })
        .await;
    assert_ne!(
        replacement, 0,
        "killing a cursor must release its reservation"
    );
    let drained = gateway
        .db
        .run_command(doc! {
            "getMore": replacement, "collection": "items", "batchSize": 100
        })
        .await
        .unwrap();
    assert_eq!(
        drained
            .get_document("cursor")
            .unwrap()
            .get_i64("id")
            .unwrap(),
        0
    );
    let after_exhaustion = gateway
        .open_cursor(doc! {
            "find": "items", "sort": { "amount": 1 }, "batchSize": 1
        })
        .await;
    assert_ne!(
        after_exhaustion, 0,
        "exhausting a cursor must release its reservation"
    );
}
