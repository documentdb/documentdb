/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/sessions_tests.rs
 *
 *-------------------------------------------------------------------------
 */

use documentdb_tests::{
    commands::session,
    test_setup::{
        clients::{self, TEST_USERNAME},
        initialize,
    },
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
async fn validate_kill_all_sessions_empty() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    session::validate_kill_all_sessions(&client, vec![]).await
}

#[tokio::test]
async fn validate_kill_all_sessions_with_users() -> Result<(), Error> {
    let client = initialize::initialize().await?;

    session::validate_kill_all_sessions(
        &client,
        vec![bson::doc! { "user": TEST_USERNAME, "db": "admin" }],
    )
    .await
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
