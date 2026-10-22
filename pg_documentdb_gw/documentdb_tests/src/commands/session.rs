/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * documentdb_tests/src/commands/session.rs
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

use bson::doc;
use mongodb::{
    bson::Uuid,
    error::{Error, ErrorKind},
    Client, Database,
};

use crate::test_setup::clients;

pub async fn validate_processing(client: &Client, command_name: &str) -> Result<(), Error> {
    let session = client.start_session().await?;

    if let Some(bson::Bson::Binary(binary)) = session.id().get("id") {
        let lsid_bytes: [u8; 16] = binary.bytes.as_slice().try_into().unwrap();
        let lsid = Uuid::from_bytes(lsid_bytes);
        let command = doc! {
            command_name: [ { "id": lsid } ]
        };

        let response = client.database("admin").run_command(command).await;

        assert!(response.is_ok());
        let ok_response = response.ok().unwrap();
        assert_eq!(ok_response.get_f64("ok").unwrap(), 1.0);
    }

    Ok(())
}

/// Sends `killAllSessions` with the given user/db filter and asserts that the
/// gateway acknowledges it. An empty `filter` targets every session.
pub async fn validate_kill_all_sessions_processing(
    client: &Client,
    filter: bson::Array,
) -> Result<(), Error> {
    let command = doc! { "killAllSessions": filter };
    let response = client.database("admin").run_command(command).await;

    assert!(response.is_ok());
    let ok_response = response.ok().unwrap();
    assert_eq!(ok_response.get_f64("ok").unwrap(), 1.0);

    Ok(())
}

pub async fn validate_session_termination(
    client: &Client,
    db: &Database,
    collection_name: &str,
    command_name: &str,
) -> Result<(), Error> {
    validate_session_termination_with(client, db, collection_name, |lsid| {
        doc! { command_name: [ { "id": lsid } ] }
    })
    .await
}

/// Validates that a session's active transaction and cursor are terminated.
///
/// The termination command is produced from `build_termination_command`, which
/// receives the session's logical id. This generalizes
/// [`validate_session_termination`] so both the session-id-scoped commands
/// (`killSessions`/`endSessions`) and the user-scoped `killAllSessions` command
/// exercise the same assertions.
pub async fn validate_session_termination_with(
    client: &Client,
    db: &Database,
    collection_name: &str,
    build_termination_command: impl FnOnce(Uuid) -> bson::Document,
) -> Result<(), Error> {
    let collection = db.collection::<bson::Document>(collection_name);

    let mut session = client.start_session().await?;

    let Some(bson::Bson::Binary(binary)) = session.id().get("id") else {
        panic!("Expected a binary session id");
    };
    let lsid_bytes: [u8; 16] = binary.bytes.as_slice().try_into().unwrap();
    let lsid = Uuid::from_bytes(lsid_bytes);

    let cursor_id =
        open_transaction_and_cursor(db, &collection, collection_name, &mut session).await;

    // Termination must finish before commit; independent delays race with authorization.
    let command = build_termination_command(lsid);
    let response = client.database("admin").run_command(command).await?;
    assert_eq!(response.get_f64("ok").unwrap(), 1.0);

    assert_command_error_code(
        session.commit_transaction().await,
        251,
        "Transaction should fail due to session termination",
    );

    let get_more_results = db
        .run_command(doc! {
            "getMore": cursor_id,
            "collection": collection_name
        })
        .await;

    assert!(
        get_more_results.is_err(),
        "getMore should fail on killed cursor"
    );

    if let Err(e) = get_more_results {
        if let ErrorKind::Command(ref cmd_err) = *e.kind {
            assert_eq!(
                cmd_err.code, 43,
                "Expected CursorNotFound error code 43, but got {}",
                cmd_err.code
            );
            assert!(
                cmd_err.message.contains("Cursor not found in server"),
                "Error message should indicate cursor not found, got: {}",
                cmd_err.message
            );
        } else {
            panic!("Expected Command error, but got: {:?}", e.kind);
        }
    }

    // Cleanup
    let _ = collection.drop().await;

    Ok(())
}

/// Opens a transaction and a batched cursor owned by `session` against
/// `collection` in `db`, returning the cursor id so the caller can later
/// resume or verify the cursor.
async fn open_transaction_and_cursor(
    db: &Database,
    collection: &mongodb::Collection<bson::Document>,
    collection_name: &str,
    session: &mut mongodb::ClientSession,
) -> i64 {
    // Ensure the collection exists before opening the transaction.
    collection
        .insert_one(doc! { "field": 1 })
        .await
        .expect("Failed to create collection before transaction");

    session
        .start_transaction()
        .await
        .expect("Failed to start transaction");

    collection
        .insert_many((0..6).map(|_| doc! { "a": 1 }))
        .session(&mut *session)
        .await
        .expect("Failed to insert within transaction");

    let aggregate_result = db
        .run_command(doc! {
            "aggregate": collection_name,
            "pipeline": [{ "$match": { "a": 1 } }],
            "cursor": { "batchSize": 2 }
        })
        .session(&mut *session)
        .await
        .unwrap();

    let cursor_doc = aggregate_result.get_document("cursor").unwrap();
    let first_batch = cursor_doc.get_array("firstBatch").unwrap();
    assert_eq!(
        first_batch.len(),
        2,
        "First batch should contain 2 documents"
    );

    let cursor_id = cursor_doc.get_i64("id").unwrap();
    assert_ne!(cursor_id, 0, "Expected an open cursor to remain");
    cursor_id
}

/// Asserts that `result` is a command error carrying `expected_code`.
fn assert_command_error_code<T: std::fmt::Debug>(
    result: Result<T, Error>,
    expected_code: i32,
    context: &str,
) {
    match result {
        Err(e) => {
            if let ErrorKind::Command(ref cmd_err) = *e.kind {
                assert_eq!(
                    cmd_err.code, expected_code,
                    "{context}: expected error code {expected_code}, got {}",
                    cmd_err.code
                );
            } else {
                panic!("{context}: expected a command error, got: {:?}", e.kind);
            }
        }
        Ok(value) => panic!("{context}: expected an error, got success: {value:?}"),
    }
}

/// Asserts that the cursor identified by `cursor_id` has been terminated, by
/// confirming a `getMore` fails with `CursorNotFound` (43).
async fn assert_cursor_terminated(
    db: &Database,
    collection_name: &str,
    cursor_id: i64,
    context: &str,
) {
    let get_more = db
        .run_command(doc! {
            "getMore": cursor_id,
            "collection": collection_name
        })
        .await;
    assert_command_error_code(get_more, 43, context);
}

/// Provisions an authenticated user with the given built-in `roles`, dropping
/// any pre-existing user of the same name first.
async fn provision_user(
    admin: &Client,
    user: &str,
    password: &str,
    roles: bson::Array,
) -> Result<(), Error> {
    let _ = admin
        .database("admin")
        .run_command(doc! { "dropUser": user })
        .await;
    admin
        .database("admin")
        .run_command(doc! {
            "createUser": user,
            "pwd": password,
            "roles": roles,
        })
        .await?;
    Ok(())
}

/// Validates that a privileged caller can terminate another user's sessions by
/// name while leaving a third user's sessions intact.
///
/// `admin` must be authenticated as a caller that holds the `killAnySession`
/// privilege. Two write-capable users are provisioned: a target whose sessions
/// are terminated and a bystander whose sessions must survive. Both open a
/// transaction and a cursor; the caller issues `killAllSessions` naming only the
/// target, and the target's cursor and transaction must be terminated while the
/// bystander's remain usable.
pub async fn validate_kill_all_sessions_privileged_by_user(
    admin: &Client,
    target_user: &str,
    target_password: &str,
    bystander_user: &str,
    bystander_password: &str,
) -> Result<(), Error> {
    let roles = bson::bson!([
        { "role": "readWriteAnyDatabase", "db": "admin" },
        { "role": "clusterAdmin", "db": "admin" }
    ]);
    provision_user(
        admin,
        target_user,
        target_password,
        roles.as_array().unwrap().clone(),
    )
    .await?;
    provision_user(
        admin,
        bystander_user,
        bystander_password,
        roles.as_array().unwrap().clone(),
    )
    .await?;

    let target = clients::get_client_with_credentials(target_user, target_password)?;
    let target_db = target.database("test_kill_all_by_user_target");
    let target_collection_name = "target_collection";
    let target_collection = target_db.collection::<bson::Document>(target_collection_name);
    let mut target_session = target.start_session().await?;
    let target_cursor_id = open_transaction_and_cursor(
        &target_db,
        &target_collection,
        target_collection_name,
        &mut target_session,
    )
    .await;

    let bystander = clients::get_client_with_credentials(bystander_user, bystander_password)?;
    let bystander_db = bystander.database("test_kill_all_by_user_bystander");
    let bystander_collection_name = "bystander_collection";
    let bystander_collection = bystander_db.collection::<bson::Document>(bystander_collection_name);
    let mut bystander_session = bystander.start_session().await?;
    let bystander_cursor_id = open_transaction_and_cursor(
        &bystander_db,
        &bystander_collection,
        bystander_collection_name,
        &mut bystander_session,
    )
    .await;

    // The privileged caller terminates only the target user's sessions.
    let response = admin
        .database("admin")
        .run_command(doc! { "killAllSessions": [ { "user": target_user, "db": "admin" } ] })
        .await;
    assert!(
        response.is_ok(),
        "killAllSessions should succeed: {response:?}"
    );
    assert_eq!(response.ok().unwrap().get_f64("ok").unwrap(), 1.0);

    // The target's cursor and transaction are terminated.
    assert_cursor_terminated(
        &target_db,
        target_collection_name,
        target_cursor_id,
        "target cursor",
    )
    .await;
    assert!(
        target_session.commit_transaction().await.is_err(),
        "Target user's transaction should be terminated"
    );

    // The bystander's cursor survives and still returns its documents.
    let bystander_get_more = bystander_db
        .run_command(doc! {
            "getMore": bystander_cursor_id,
            "collection": bystander_collection_name
        })
        .session(&mut bystander_session)
        .await;
    assert!(
        bystander_get_more.is_ok(),
        "Bystander's cursor must survive: {:?}",
        bystander_get_more.err()
    );
    assert!(
        bystander_session.commit_transaction().await.is_ok(),
        "Bystander's transaction must survive"
    );

    // Cleanup
    let _ = target_collection.drop().await;
    let _ = bystander_collection.drop().await;
    let _ = target_db.drop().await;
    let _ = bystander_db.drop().await;
    let _ = admin
        .database("admin")
        .run_command(doc! { "dropUser": target_user })
        .await;
    let _ = admin
        .database("admin")
        .run_command(doc! { "dropUser": bystander_user })
        .await;

    Ok(())
}

/// Validates that a `killAllSessions` entry naming a database other than the
/// authentication database selects nothing, even for a privileged caller.
///
/// A supported user authenticates against the `admin` database, so an entry
/// such as `{ user, db: "other" }` refers to a principal that cannot own a
/// session. `admin` must hold the `killAnySession` privilege so the command is
/// authorized; the target user's cursor and transaction must survive because
/// the entry's database does not match.
pub async fn validate_kill_all_sessions_wrong_database(
    admin: &Client,
    target_user: &str,
    target_password: &str,
) -> Result<(), Error> {
    let roles = bson::bson!([
        { "role": "readWriteAnyDatabase", "db": "admin" },
        { "role": "clusterAdmin", "db": "admin" }
    ]);
    provision_user(
        admin,
        target_user,
        target_password,
        roles.as_array().unwrap().clone(),
    )
    .await?;

    let target = clients::get_client_with_credentials(target_user, target_password)?;
    let target_db = target.database("test_kill_all_wrong_db_target");
    let target_collection_name = "target_collection";
    let target_collection = target_db.collection::<bson::Document>(target_collection_name);
    let mut target_session = target.start_session().await?;
    let target_cursor_id = open_transaction_and_cursor(
        &target_db,
        &target_collection,
        target_collection_name,
        &mut target_session,
    )
    .await;

    // The entry names a database other than the authentication database, so it
    // selects no session even though the caller is privileged.
    let response = admin
        .database("admin")
        .run_command(doc! { "killAllSessions": [ { "user": target_user, "db": "other" } ] })
        .await;
    assert!(
        response.is_ok(),
        "killAllSessions should succeed: {response:?}"
    );
    assert_eq!(response.ok().unwrap().get_f64("ok").unwrap(), 1.0);

    // The target's cursor and transaction survive because the entry's database
    // did not match the authentication database.
    let target_get_more = target_db
        .run_command(doc! {
            "getMore": target_cursor_id,
            "collection": target_collection_name
        })
        .session(&mut target_session)
        .await;
    assert!(
        target_get_more.is_ok(),
        "Target's cursor must survive a non-admin database entry: {:?}",
        target_get_more.err()
    );
    assert!(
        target_session.commit_transaction().await.is_ok(),
        "Target's transaction must survive a non-admin database entry"
    );

    // Cleanup
    let _ = target_collection.drop().await;
    let _ = target_db.drop().await;
    let _ = admin
        .database("admin")
        .run_command(doc! { "dropUser": target_user })
        .await;

    Ok(())
}

/// Validates that a privileged caller's empty `killAllSessions` filter
/// terminates every session, including both the caller's own and another
/// user's.
///
/// `admin` must be authenticated as a caller that holds the `killAnySession`
/// privilege. A second write-capable user is provisioned; both the caller and
/// that user open a transaction and a cursor, the caller issues an empty
/// `killAllSessions`, and both users' cursors and transactions must be
/// terminated.
pub async fn validate_kill_all_sessions_privileged_empty(
    admin: &Client,
    admin_db: &Database,
    admin_collection_name: &str,
    other_user: &str,
    other_password: &str,
) -> Result<(), Error> {
    let roles = bson::bson!([
        { "role": "readWriteAnyDatabase", "db": "admin" },
        { "role": "clusterAdmin", "db": "admin" }
    ]);
    provision_user(
        admin,
        other_user,
        other_password,
        roles.as_array().unwrap().clone(),
    )
    .await?;

    let other = clients::get_client_with_credentials(other_user, other_password)?;
    let other_db = other.database("test_kill_all_empty_other");
    let other_collection_name = "other_collection";
    let other_collection = other_db.collection::<bson::Document>(other_collection_name);
    let mut other_session = other.start_session().await?;
    let other_cursor_id = open_transaction_and_cursor(
        &other_db,
        &other_collection,
        other_collection_name,
        &mut other_session,
    )
    .await;

    let admin_collection = admin_db.collection::<bson::Document>(admin_collection_name);
    let mut admin_session = admin.start_session().await?;
    let admin_cursor_id = open_transaction_and_cursor(
        admin_db,
        &admin_collection,
        admin_collection_name,
        &mut admin_session,
    )
    .await;

    let response = admin
        .database("admin")
        .run_command(doc! { "killAllSessions": [] })
        .await;
    assert!(
        response.is_ok(),
        "killAllSessions should succeed: {response:?}"
    );
    assert_eq!(response.ok().unwrap().get_f64("ok").unwrap(), 1.0);

    // Both the caller's and the other user's sessions are terminated.
    assert_cursor_terminated(
        admin_db,
        admin_collection_name,
        admin_cursor_id,
        "caller cursor",
    )
    .await;
    assert!(
        admin_session.commit_transaction().await.is_err(),
        "Caller's transaction should be terminated"
    );
    assert_cursor_terminated(
        &other_db,
        other_collection_name,
        other_cursor_id,
        "other user cursor",
    )
    .await;
    assert!(
        other_session.commit_transaction().await.is_err(),
        "Other user's transaction should be terminated"
    );

    // Cleanup
    let _ = admin_collection.drop().await;
    let _ = other_collection.drop().await;
    let _ = other_db.drop().await;
    let _ = admin
        .database("admin")
        .run_command(doc! { "dropUser": other_user })
        .await;

    Ok(())
}

/// Validates that a caller lacking the `killAnySession` privilege is authorized
/// only for the caller-scoped form of `killAllSessions`.
///
/// A non-privileged, read-only user is provisioned. The empty filter and any
/// filter naming another principal (including one that also names the caller)
/// must be rejected with `Unauthorized` (13) and terminate nothing. A filter
/// naming only the caller must be authorized and must terminate the caller's
/// own cursor.
pub async fn validate_kill_all_sessions_requires_privilege(
    admin: &Client,
    user: &str,
    password: &str,
) -> Result<(), Error> {
    let roles = bson::bson!([{ "role": "readAnyDatabase", "db": "admin" }]);
    provision_user(admin, user, password, roles.as_array().unwrap().clone()).await?;

    let client = clients::get_client_with_credentials(user, password)?;
    let other_user = "kill_all_unrelated_user";

    // An empty filter requires the privilege.
    assert_command_error_code(
        client
            .database("admin")
            .run_command(doc! { "killAllSessions": [] })
            .await,
        13,
        "empty filter without privilege",
    );

    // A filter naming another principal requires the privilege.
    assert_command_error_code(
        client
            .database("admin")
            .run_command(doc! {
                "killAllSessions": [ { "user": other_user, "db": "admin" } ]
            })
            .await,
        13,
        "other-user filter without privilege",
    );

    // Mixing the caller with another principal cannot bypass the check.
    assert_command_error_code(
        client
            .database("admin")
            .run_command(doc! {
                "killAllSessions": [
                    { "user": user, "db": "admin" },
                    { "user": other_user, "db": "admin" }
                ]
            })
            .await,
        13,
        "mixed caller/other filter without privilege",
    );

    // The caller-scoped form is authorized and terminates the caller's own
    // cursor. The read-only user cannot write, so the admin seeds a collection
    // the user can read a cursor over.
    let read_db_name = "test_kill_all_requires_privilege";
    let collection_name = "self_collection";
    let seed_collection = admin
        .database(read_db_name)
        .collection::<bson::Document>(collection_name);
    seed_collection
        .insert_many((0..6).map(|_| doc! { "a": 1 }))
        .await?;

    let db = client.database(read_db_name);
    let find_result = db
        .run_command(doc! {
            "find": collection_name,
            "filter": {},
            "batchSize": 2
        })
        .await?;
    let cursor_id = find_result
        .get_document("cursor")
        .unwrap()
        .get_i64("id")
        .unwrap();
    assert_ne!(cursor_id, 0, "expected an open cursor to remain");

    let response = client
        .database("admin")
        .run_command(doc! {
            "killAllSessions": [ { "user": user, "db": "admin" } ]
        })
        .await;
    assert!(
        response.is_ok(),
        "caller-scoped killAllSessions should be authorized: {response:?}"
    );
    assert_eq!(response.ok().unwrap().get_f64("ok").unwrap(), 1.0);

    assert_cursor_terminated(&db, collection_name, cursor_id, "caller-scoped self cursor").await;

    // Cleanup
    let _ = seed_collection.drop().await;
    let _ = admin.database(read_db_name).drop().await;
    let _ = admin
        .database("admin")
        .run_command(doc! { "dropUser": user })
        .await;

    Ok(())
}
