/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/session_reaper_tests.rs
 *
 * Integration tests for the session manager's expired-transaction cleanup
 * pass against a reachable local PostgreSQL instance: a single cleanup tick
 * rolls expired gateway transactions back and invalidates their cursors.
 *
 *-------------------------------------------------------------------------
 */
#![allow(clippy::expect_used, reason = "test utility code")]
#![allow(clippy::unwrap_used, reason = "test utility code")]

use std::{sync::Arc, time::Duration};

use bson::RawDocumentBuf;
use documentdb_gateway_core::{
    context::{
        Cursor, CursorId, CursorKey, CursorStore, CursorStoreEntry, GatewayTransaction,
        LogicalSessionId, RequestTransactionInfo, SessionManager, StoreKey, TransactionNumber,
        TransactionStore,
    },
    postgres::conn_mgmt::Connection,
    principal,
};
use documentdb_tests::test_setup::{config::setup_configuration, pools::build_connection_pool};
use tokio::time::{sleep, Instant};
use tokio_postgres::IsolationLevel;

/// The session manager's cleanup pass must, within a single tick, roll back
/// every expired gateway transaction and invalidate the cursors tied to it.
///
/// Cursor invalidation is the reaper-specific observable — nothing else
/// invalidates cursors by transaction number. The rollback is asserted too, but
/// `GatewayTransaction::drop` would eventually clear that flag anyway.
#[tokio::test]
async fn session_reaper_rolls_back_expired_transactions_and_invalidates_their_cursors() {
    // Number of expired transactions (each with a matching cursor) to seed.
    const SEEDED: u8 = 3;

    let setup_config = setup_configuration();
    // One backend per seeded transaction, plus headroom.
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 4).await;

    let owner = principal!("session-reaper-test", 1);
    let transaction_store = TransactionStore::new(Duration::from_hours(1));
    // A store with no reaper of its own and a long cursor timeout, so only the
    // session manager's cleanup pass can remove these cursors.
    let cursor_store = CursorStore::new();

    let mut connections = Vec::new();
    let mut cursor_keys = Vec::new();

    for i in 1..=SEEDED {
        let lsid = LogicalSessionId::new(vec![i]);
        let transaction_number = TransactionNumber::new(i64::from(i));

        let connection = Arc::new(Connection::new(
            pool.acquire_connection().await.unwrap(),
            false,
            pool.sql_commenter_enabled(),
            pool.command_deadline(),
        ));

        let transaction_info = RequestTransactionInfo {
            transaction_number,
            auto_commit: false,
            start_transaction: true,
            is_request_within_transaction: false,
            isolation_level: Some(IsolationLevel::ReadCommitted),
        };

        let gateway_transaction = GatewayTransaction::start(
            &transaction_info,
            Arc::clone(&connection),
            IsolationLevel::ReadCommitted,
            lsid.clone(),
            owner.clone(),
        )
        .await
        .unwrap();
        assert!(
            connection.in_transaction(),
            "a freshly started gateway transaction must flag its connection in-transaction"
        );

        // Expiry timestamp 0 is always in the past, so `evict_expired` treats
        // the entry as expired on the first cleanup tick.
        transaction_store.transactions.insert(
            StoreKey::new(lsid.clone(), owner.clone()),
            (0, gateway_transaction),
        );

        let cursor_key = CursorKey::new(CursorId::new(i64::from(i)), owner.clone());
        cursor_store.add_cursor(
            cursor_key.clone(),
            CursorStoreEntry {
                conn: None,
                cursor: Cursor {
                    continuation: RawDocumentBuf::new(),
                    cursor_id: CursorId::new(i64::from(i)),
                },
                db: "reaper_db".to_owned(),
                collection: "reaper_collection".to_owned(),
                timestamp: Instant::now(),
                cursor_timeout: Duration::from_hours(1),
                lsid: Some(lsid),
                transaction_number: Some(transaction_number),
            },
        );

        connections.push(connection);
        cursor_keys.push(cursor_key);
    }

    // A large cleanup interval makes the reaper's first (immediate) tick the
    // only pass that runs during the test.
    let session_manager =
        SessionManager::new(transaction_store, cursor_store, Duration::from_hours(1));

    // Poll until the single cleanup pass has invalidated every cursor, rolled
    // back every transaction, and drained the transaction store.
    let mut cursors_cleared = false;
    let mut flags_cleared = false;
    let mut store_drained = false;
    for _ in 0..200 {
        cursors_cleared = cursor_keys
            .iter()
            .all(|key| session_manager.cursors().get_cursor_ref(key).is_none());
        flags_cleared = connections
            .iter()
            .all(|connection| !connection.in_transaction());
        store_drained = session_manager.transactions().transactions.is_empty();
        if cursors_cleared && flags_cleared && store_drained {
            break;
        }
        sleep(Duration::from_millis(25)).await;
    }

    assert!(
        cursors_cleared,
        "the cleanup pass must invalidate every cursor tied to an expired transaction"
    );
    assert!(
        store_drained,
        "the cleanup pass must evict every expired transaction from the store"
    );
    assert!(
        flags_cleared,
        "every expired transaction must be rolled back so its connection is no longer in-transaction"
    );
}
