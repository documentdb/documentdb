// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

//! Tests termination logging, including cancellation and panic cleanup.

use tokio::sync::oneshot;
use tracing::Level;
use tracing_subscriber::prelude::*;
use uuid::Uuid;

use super::ConnectionLog;
use crate::{
    error::DocumentDBError,
    testing::logs::{CapturedEvent, LogCapture},
};

fn assert_close_event(events: &[CapturedEvent], connection_id: Uuid, reason: &str) {
    let closes: Vec<_> = events
        .iter()
        .filter(|event| event.fields.contains_key("close_reason"))
        .collect();
    assert_eq!(closes.len(), 1, "expected one close event: {events:?}");
    let event = closes[0];
    assert_eq!(event.level, Level::INFO);
    assert_eq!(event.fields["connection_id"], connection_id.to_string());
    assert_eq!(event.fields["activity_id"], connection_id.to_string());
    assert_eq!(event.fields["close_reason"], reason);
    assert_eq!(event.fields["client_ip"], "127.0.0.1");
    assert_eq!(event.fields["transport"], "TCP");
}

#[test]
fn completed_connection_logs_one_info_close() {
    let capture = LogCapture::new("documentdb_gateway_core::runtime::connection_log");
    let _guard =
        tracing::subscriber::set_default(tracing_subscriber::registry().with(capture.clone()));
    tracing::callsite::rebuild_interest_cache();
    let connection_id = Uuid::new_v4();
    {
        let mut log = ConnectionLog::new(connection_id, "127.0.0.1".to_owned(), "TCP");
        log.finish(&Ok(()));
    }
    let events = capture.events();
    assert_eq!(events.len(), 1);
    assert_close_event(&events, connection_id, "completed");
}

#[test]
fn failed_connection_logs_correlated_error_and_one_close() {
    let capture = LogCapture::new("documentdb_gateway_core::runtime::connection_log");
    let _guard =
        tracing::subscriber::set_default(tracing_subscriber::registry().with(capture.clone()));
    tracing::callsite::rebuild_interest_cache();
    let connection_id = Uuid::new_v4();
    {
        let mut log = ConnectionLog::new(connection_id, "127.0.0.1".to_owned(), "TCP");
        log.finish(&Err(DocumentDBError::internal_error(
            "synthetic connection failure".to_owned(),
        )));
    }
    let events = capture.events();
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].level, Level::ERROR);
    assert_eq!(events[0].fields["connection_id"], connection_id.to_string());
    assert_eq!(events[0].fields["activity_id"], connection_id.to_string());
    assert!(events[0].fields["error"].contains("synthetic connection failure"));
    assert_close_event(&events, connection_id, "error");
}

#[tokio::test]
async fn cancelled_connection_logs_one_close() {
    let capture = LogCapture::new("documentdb_gateway_core::runtime::connection_log");
    let _guard =
        tracing::subscriber::set_default(tracing_subscriber::registry().with(capture.clone()));
    tracing::callsite::rebuild_interest_cache();
    let connection_id = Uuid::new_v4();
    let (started, ready) = oneshot::channel();
    let task = tokio::spawn(async move {
        let _log = ConnectionLog::new(connection_id, "127.0.0.1".to_owned(), "TCP");
        started.send(()).expect("test should await task startup");
        std::future::pending::<()>().await;
    });
    ready.await.expect("connection task should start");
    task.abort();
    assert!(task
        .await
        .expect_err("task should be cancelled")
        .is_cancelled());
    assert_close_event(&capture.events(), connection_id, "cancelled");
}

#[tokio::test]
async fn panicking_connection_logs_correlated_error_and_one_close() {
    let capture = LogCapture::new("documentdb_gateway_core::runtime::connection_log");
    let _guard =
        tracing::subscriber::set_default(tracing_subscriber::registry().with(capture.clone()));
    tracing::callsite::rebuild_interest_cache();
    let connection_id = Uuid::new_v4();
    let task = tokio::spawn(async move {
        let _log = ConnectionLog::new(connection_id, "127.0.0.1".to_owned(), "TCP");
        panic!("synthetic connection task panic");
    });
    assert!(task.await.expect_err("task should panic").is_panic());
    let events = capture.events();
    assert_eq!(events.len(), 2);
    assert_eq!(events[0].level, Level::ERROR);
    assert_eq!(events[0].fields["connection_id"], connection_id.to_string());
    assert_close_event(&events, connection_id, "panicked");
}
