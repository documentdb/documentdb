/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/sessions_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{
    commands::session,
    test_setup::{clients, initialize},
};
use mongodb::error::Error;

#[tokio::test]
async fn validate_kill_empty_sessions() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    session::validate_processing(&client, "killSessions").await
}

#[tokio::test]
async fn validate_end_empty_sessions() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    session::validate_processing(&client, "endSessions").await
}

#[tokio::test]
async fn validate_kill_sessions_terminate() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "test_session_termination").await?;

    session::validate_session_termination(&client, &db, "test_collection", "killSessions").await
}

#[tokio::test]
async fn validate_end_sessions_terminate() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "test_session_termination").await?;

    session::validate_session_termination(&client, &db, "test_collection", "endSessions").await
}

#[tokio::test]
async fn validate_kill_all_empty_sessions() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    session::validate_kill_all_sessions_processing(&client, bson::Array::new()).await
}

#[tokio::test]
async fn validate_kill_all_sessions_terminate() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "test_kill_all_termination").await?;

    // The default test caller holds the killAnySession privilege, so an empty
    // filter targets every session and the active session's transaction and
    // cursor must be terminated.
    session::validate_session_termination_with(&client, &db, "kill_all_collection", |_lsid| {
        bson::doc! { "killAllSessions": [] }
    })
    .await
}

#[tokio::test]
async fn validate_kill_all_sessions_filter_matches_caller() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "test_kill_all_filter_caller").await?;

    // A filter naming the caller selects the caller's own sessions, so the
    // active session's transaction and cursor must be terminated.
    session::validate_session_termination_with(
        &client,
        &db,
        "kill_all_filter_collection",
        |_lsid| {
            bson::doc! { "killAllSessions": [ { "user": clients::TEST_USERNAME, "db": "admin" } ] }
        },
    )
    .await
}

#[tokio::test]
async fn validate_kill_all_sessions_privileged_by_user() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    // A privileged caller terminates another user's sessions by name while a
    // third user's sessions survive.
    session::validate_kill_all_sessions_privileged_by_user(
        &client,
        "kill_all_target_user",
        "Valid$1Pass",
        "kill_all_bystander_user",
        "Valid$1Pass",
    )
    .await
}

#[tokio::test]
async fn validate_kill_all_sessions_privileged_empty_terminates_all() -> Result<(), Error> {
    let client = initialize::initialize().await?;
    let db = clients::setup_db(&client, "test_kill_all_empty_all").await?;

    // A privileged caller's empty filter terminates every session, including
    // both the caller's own and another user's.
    session::validate_kill_all_sessions_privileged_empty(
        &client,
        &db,
        "kill_all_admin_collection",
        "kill_all_empty_other_user",
        "Valid$1Pass",
    )
    .await
}

#[tokio::test]
async fn validate_kill_all_sessions_wrong_database() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    // An entry naming a database other than the authentication database selects
    // nothing, so the target user's sessions survive even for a privileged
    // caller.
    session::validate_kill_all_sessions_wrong_database(
        &client,
        "kill_all_wrong_db_user",
        "Valid$1Pass",
    )
    .await
}

#[tokio::test]
async fn validate_kill_all_sessions_requires_privilege() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    // A non-privileged caller is authorized only for the caller-scoped form;
    // the empty and other-user forms are rejected with Unauthorized.
    session::validate_kill_all_sessions_requires_privilege(
        &client,
        "kill_all_unprivileged_user",
        "Valid$1Pass",
    )
    .await
}
