// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/*-------------------------------------------------------------------------
 * documentdb_tests/tests/query_dispatch_characterization_tests.rs
 *
 *-------------------------------------------------------------------------
 */

#![expect(
    clippy::unwrap_used,
    reason = "failed fixture setup or execution fails the test"
)]

use std::{
    sync::{
        atomic::{AtomicUsize, Ordering},
        Arc,
    },
    time::Duration,
};

use bson::rawdoc;
use documentdb_gateway_core::{
    context::RequestContext,
    error::{DocumentDBError, ErrorCode},
    postgres::conn_mgmt::{self, Connection, QueryFailureAction, QueryOptions, RequestOptions},
    requests::{request_tracker::RequestTracker, RequestExecutionMode, RequestType, WireRequest},
};
use documentdb_tests::test_setup::{config, pools};
use tokio_postgres::error::SqlState;

fn request() -> WireRequest<'static> {
    WireRequest::from_owned_command_document(
        RequestType::Ping,
        RequestExecutionMode::Normal,
        None,
        rawdoc! { "ping": 1, "$db": "admin" },
        None,
    )
    .unwrap()
}

async fn connection(in_transaction: bool) -> Arc<Connection> {
    let setup = config::setup_configuration();
    let pool = pools::build_connection_pool(&setup, &setup.postgres_system_user, 1).await;
    let connection = Arc::new(Connection::new(
        pool.acquire_connection().await.unwrap(),
        in_transaction,
        pool.command_deadline(),
    ));
    if in_transaction {
        connection.batch_execute("BEGIN").await.unwrap();
    }
    connection
}

fn failure_statement(code: &str) -> String {
    format!("DO $body$ BEGIN RAISE EXCEPTION SQLSTATE '{code}' USING MESSAGE = 'characterized failure'; END $body$")
}

async fn dispatched_failure(
    code: &str,
    options: QueryOptions,
    in_transaction: bool,
    failures_before_success: usize,
    action: QueryFailureAction,
) -> (Result<usize, DocumentDBError>, usize) {
    let connection = connection(in_transaction).await;
    let request = request();
    let tracker = RequestTracker::new();
    let context = RequestContext::new("", &request, &tracker);
    let configuration = pools::TestConfiguration::default();
    let calls = AtomicUsize::new(0);
    let acquired = AtomicUsize::new(0);
    let observed_failures = AtomicUsize::new(0);
    let statement = failure_statement(code);
    let result = conn_mgmt::run_request_with_retries_using(
        options,
        RequestOptions::new(false, None),
        Duration::from_mins(2),
        &configuration,
        &context,
        in_transaction,
        Arc::clone(&connection),
        async |source: &Arc<Connection>, _, _: &RequestTracker| {
            acquired.fetch_add(1, Ordering::Relaxed);
            Ok(Arc::clone(source))
        },
        |selected| {
            assert!(Arc::ptr_eq(&selected, &connection));
            let attempt = calls.fetch_add(1, Ordering::Relaxed);
            let statement = &statement;
            async move {
                if attempt < failures_before_success {
                    selected.batch_execute(statement).await?;
                }
                Ok(attempt + 1)
            }
        },
        |error| {
            observed_failures.fetch_add(1, Ordering::Relaxed);
            assert_eq!(
                error
                    .as_postgres_error()
                    .and_then(|error| error.code())
                    .map(SqlState::code),
                Some(code)
            );
            action
        },
    )
    .await;
    let attempts = calls.load(Ordering::Relaxed);
    assert_eq!(acquired.load(Ordering::Relaxed), attempts);
    assert_eq!(
        observed_failures.load(Ordering::Relaxed),
        attempts.min(failures_before_success)
    );
    if in_transaction {
        connection.batch_execute("ROLLBACK").await.unwrap();
        connection.set_in_transaction(false);
    }
    assert!(!connection.in_transaction());
    (result, attempts)
}

#[tokio::test]
async fn dispatched_readonly_and_deadlock_failures_retry_on_the_selected_source() {
    for code in ["25006", "40P01"] {
        let (result, attempts) = dispatched_failure(
            code,
            QueryOptions::builder().retry_deadlock(true).build(),
            false,
            1,
            QueryFailureAction::UseRetryPolicy,
        )
        .await;
        assert_eq!(result.unwrap(), 2);
        assert_eq!(attempts, 2);
    }
}

#[tokio::test]
async fn dispatched_terminal_errors_preserve_sqlstate_and_do_not_retry() {
    for code in ["53300", "22012", "40P01"] {
        let (result, attempts) = dispatched_failure(
            code,
            QueryOptions::default(),
            false,
            usize::MAX,
            QueryFailureAction::UseRetryPolicy,
        )
        .await;
        let error = result.expect_err("terminal backend errors must remain failures");
        assert_eq!(
            error
                .as_postgres_error()
                .and_then(|error| error.code())
                .map(SqlState::code),
            Some(code)
        );
        assert_eq!(attempts, 1);
    }
}

#[tokio::test]
async fn dispatched_transaction_and_procedural_errors_execute_only_once() {
    for in_transaction in [false, true] {
        let options = QueryOptions::builder()
            .retry_request(in_transaction)
            .build();
        let (result, attempts) = dispatched_failure(
            "25006",
            options,
            in_transaction,
            usize::MAX,
            QueryFailureAction::UseRetryPolicy,
        )
        .await;
        result.expect_err("transactional and procedural operations must not be replayed");
        assert_eq!(attempts, 1);
    }
}

#[tokio::test]
async fn caller_failure_disposition_intercepts_a_dispatched_retryable_error() {
    let (result, attempts) = dispatched_failure(
        "25006",
        QueryOptions::default(),
        false,
        usize::MAX,
        QueryFailureAction::Return,
    )
    .await;
    let error = result.expect_err("caller-directed return must preserve the backend error");
    assert_eq!(
        error
            .as_postgres_error()
            .and_then(|error| error.code())
            .map(SqlState::code),
        Some("25006")
    );
    assert_eq!(attempts, 1);
}

#[tokio::test]
async fn dispatched_short_retries_exhaust_without_losing_the_backend_error() {
    let (result, attempts) = dispatched_failure(
        "XX003",
        QueryOptions::default(),
        false,
        usize::MAX,
        QueryFailureAction::UseRetryPolicy,
    )
    .await;
    let error = result.expect_err("exhausted retry policy must return the last failure");
    assert_eq!(
        error
            .as_postgres_error()
            .and_then(|error| error.code())
            .map(SqlState::code),
        Some("XX003")
    );
    assert_eq!(attempts, 11);
}

#[tokio::test]
async fn explicit_and_configured_timeouts_bound_dispatched_work() {
    for timeout_ms in [Some(1), None] {
        let setup = config::setup_configuration();
        let pool = pools::build_connection_pool_with_command_timeout(
            &setup,
            &setup.postgres_system_user,
            1,
            1,
        )
        .await;
        let request = request();
        let tracker = RequestTracker::new();
        let context = RequestContext::new("", &request, &tracker);
        let configuration = pools::TestConfiguration::default();
        let calls = AtomicUsize::new(0);
        let error = conn_mgmt::run_request_with_retries(
            conn_mgmt::ConnectionSource::Pool(&pool),
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .retry_request(false)
                .build(),
            RequestOptions::new(false, timeout_ms),
            Duration::from_secs(1),
            &configuration,
            &context,
            |connection| {
                calls.fetch_add(1, Ordering::Relaxed);
                async move { connection.batch_execute("SELECT pg_sleep(2)").await }
            },
        )
        .await
        .expect_err("a dispatched operation must respect its timeout");
        assert_eq!(error.error_code(), ErrorCode::ExceededTimeLimit);
        assert_eq!(calls.load(Ordering::Relaxed), 1);
    }
}
