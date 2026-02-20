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
    let client = initialize::initialize().await;

    session::validate_processing(&client, "killSessions").await
}

#[tokio::test]
async fn validate_end_empty_sessions() -> Result<(), Error> {
    let client = initialize::initialize().await;

    session::validate_processing(&client, "endSessions").await
}

#[tokio::test]
async fn validate_kill_sessions_terminate() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "test_session_termination").await?;

    session::validate_session_termination(&client, &db, "test_collection", "killSessions").await
}

#[tokio::test]
async fn validate_end_sessions_terminate() -> Result<(), Error> {
    let client = initialize::initialize().await;
    let db = clients::setup_db(&client, "test_session_termination").await?;

    session::validate_session_termination(&client, &db, "test_collection", "endSessions").await
}
