/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/tests/connection_pool_tests.rs
 *
 * Integration tests for `ConnectionPool` and `PoolManager` metric recording
 * paths that require a reachable local PostgreSQL instance.
 *
 *-------------------------------------------------------------------------
 */
#![allow(clippy::expect_used, reason = "test utility code")]
#![allow(clippy::unwrap_used, reason = "test utility code")]

use std::{
    sync::{Arc, Mutex},
    time::Duration,
};

use bson::rawdoc;
use deadpool_postgres::PoolError;
use documentdb_gateway_core::{
    context::{RequestContext, TransactionError},
    error::{DocumentDBError, ErrorCode, ErrorKind},
    postgres::{
        conn_mgmt::{
            run_request_with_retries, Connection, ConnectionSource, QueryOptions, RequestOptions,
            StatementError,
        },
        ScopedTransaction, Transaction,
    },
    requests::{request_tracker::RequestTracker, RequestExecutionMode, RequestType, WireRequest},
};
use documentdb_tests::test_setup::{
    config::{
        failing_setup_configuration, setup_configuration, setup_configuration_with_command_timeout,
    },
    pools::{build_connection_pool, build_pool_manager},
};
use tokio::time::{sleep, Instant};
use tokio_postgres::IsolationLevel;

fn ping_request() -> WireRequest<'static> {
    WireRequest::from_owned_command_document(
        RequestType::Ping,
        RequestExecutionMode::Normal,
        None,
        rawdoc! { "ping": 1, "$db": "admin" },
        None,
    )
    .expect("ping request should parse")
}

async fn wait_until_transaction_flag_clears(connection: &Connection) {
    for _ in 0..100 {
        if !connection.in_transaction() {
            return;
        }
        sleep(Duration::from_millis(10)).await;
    }

    assert!(
        !connection.in_transaction(),
        "transaction flag should clear after rollback"
    );
}

#[tokio::test]
async fn acquire_connection_records_connection_creation_metrics() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;

    let _connection = pool.acquire_connection().await.unwrap();
    let report = pool.report_status();

    assert_eq!(report.connections_created(), 1);
    assert!(report.connection_create_time_us() > 0);
    assert_eq!(report.connection_timeouts(), 0);
}

#[tokio::test]
async fn failed_connection_creation_does_not_record_creation_metrics() {
    let setup_config = failing_setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;

    let _error = pool
        .acquire_connection()
        .await
        .expect_err("connection creation should fail");

    let report = pool.report_status();

    assert_eq!(report.connections_created(), 0);
    assert_eq!(report.connection_create_time_us(), 0);
}

#[tokio::test]
async fn pool_backend_error_converts_to_pool_kind_documentdb_error() {
    let setup_config = failing_setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;

    let pool_error = pool
        .acquire_connection()
        .await
        .expect_err("connection to unreachable host should fail");

    // An unreachable backend surfaces as a PoolError::Backend wrapping the
    // underlying tokio_postgres connection error, exercising the pg-error arm
    // of the `From<PoolError>` conversion.
    assert!(
        matches!(pool_error, PoolError::Backend(_)),
        "expected PoolError::Backend, got {pool_error:?}"
    );

    let error = DocumentDBError::from(pool_error);

    assert_eq!(error.error_code(), ErrorCode::InternalError);
    assert_eq!(error.kind(), &ErrorKind::Pool);
    // The Backend arm stores the inner tokio_postgres error as the source, so it
    // downcasts to a postgres error rather than back to a PoolError.
    let pg_error = error
        .as_postgres_error()
        .expect("Backend arm should preserve the tokio_postgres error as source");
    assert!(error.as_pool_error().is_none());
    // The Backend arm has no DbError for a connection failure, so the internal
    // message is exactly the underlying postgres error's string. tokio_postgres
    // surfaces the connect failure as "error connecting to server" (the OS-level
    // detail is carried on the error's source, not its Display).
    assert_eq!(pg_error.to_string(), "error connecting to server");
    assert_eq!(
        error.error_message_internal(),
        Some("error connecting to server")
    );
}

#[tokio::test]
async fn acquire_connection_records_timeout_metric_on_pool_timeout() {
    let setup_config = setup_configuration_with_command_timeout(0);
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;

    let _held = pool.acquire_connection().await.unwrap();
    let error = pool
        .acquire_connection()
        .await
        .expect_err("expected pool acquisition timeout");

    assert!(matches!(error, PoolError::Timeout(_)));

    let report = pool.report_status();
    assert_eq!(report.connection_timeouts(), 1);
}

#[tokio::test]
async fn run_request_with_retries_counts_deadpool_timeouts_once() {
    let setup_config = setup_configuration_with_command_timeout(0);
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    let _held = pool.acquire_connection().await.unwrap();
    let _ = pool.report_status();
    let request_tracker = RequestTracker::new();
    let ping = ping_request();
    let ctx = RequestContext::new("", &ping, &request_tracker);

    let error = run_request_with_retries(
        ConnectionSource::Pool(&pool),
        QueryOptions::builder().retry_request(false).build(),
        RequestOptions::new(false, Some(30000)),
        Duration::from_secs(30),
        &ctx,
        |_| async { Ok::<(), StatementError>(()) },
    )
    .await
    .unwrap_err();

    assert_eq!(error.kind(), &ErrorKind::Pool);

    let report = pool.report_status();
    assert_eq!(report.connections_created(), 0);
    assert_eq!(report.connection_create_time_us(), 0);
    assert_eq!(report.connection_timeouts(), 1);
}

#[tokio::test]
async fn pool_manager_system_requests_connection_counts_deadpool_timeouts_once() {
    let mut setup_config = setup_configuration();
    setup_config.postgres_command_timeout_secs = Some(0);

    let pool_manager = build_pool_manager(&setup_config);

    // Saturate the system requests pool (max = SYSTEM_REQUESTS_MAX_CONNECTIONS = 2).
    let _first = pool_manager.system_requests_connection().await.unwrap();
    let _second = pool_manager.system_requests_connection().await.unwrap();

    // Flush the establishment metrics so the timeout is the only recorded event.
    let _ = pool_manager.report_pool_stats();

    let error = pool_manager.system_requests_connection().await.unwrap_err();
    assert_eq!(error.kind(), &ErrorKind::Pool);

    let reports = pool_manager.report_pool_stats();
    let system_report = reports
        .iter()
        .find(|report| report.identifier().contains("SystemRequests"))
        .expect("system requests pool report");

    assert_eq!(system_report.connections_created(), 0);
    assert_eq!(system_report.connection_create_time_us(), 0);
    assert_eq!(system_report.connection_timeouts(), 1);
}

#[tokio::test]
async fn run_request_with_retries_returns_exceeded_time_limit_when_command_timeout_exceeded() {
    let setup_config = setup_configuration_with_command_timeout(1);
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    // Hold the only connection so the next acquire will time out.
    let _held = pool.acquire_connection().await.unwrap();
    let _ = pool.report_status();

    let error = {
        let tracker = RequestTracker::new();
        let ping = ping_request();
        let ctx = RequestContext::new("", &ping, &tracker);
        run_request_with_retries(
            ConnectionSource::Pool(&pool),
            QueryOptions::builder().build(),
            // command_timeout_ms of 1 means elapsed time will exceed the limit almost instantly.
            RequestOptions::new(false, Some(1)),
            Duration::from_secs(1),
            &ctx,
            |_| async { Ok::<(), StatementError>(()) },
        )
        .await
        .unwrap_err()
    };

    assert_eq!(error.error_code(), ErrorCode::ExceededTimeLimit);
}

#[tokio::test]
async fn run_request_with_retries_returns_original_error_when_no_command_timeout() {
    let setup_config = setup_configuration_with_command_timeout(1);
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    // Hold the only connection so the next acquire will time out.
    let _held = pool.acquire_connection().await.unwrap();
    let _ = pool.report_status();

    // command_timeout_ms is None (auth-related flow), so ExceededTimeLimit is
    // never returned — the original pool error propagates instead.
    let error = {
        let tracker = RequestTracker::new();
        let ping = ping_request();
        let ctx = RequestContext::new("", &ping, &tracker);
        run_request_with_retries(
            ConnectionSource::Pool(&pool),
            QueryOptions::builder().build(),
            RequestOptions::new(false, None),
            Duration::from_secs(1),
            &ctx,
            |_| async { Ok::<(), StatementError>(()) },
        )
        .await
        .unwrap_err()
    };

    assert_eq!(error.kind(), &ErrorKind::Pool);
}

#[tokio::test]
async fn gateway_timeout_commit_clears_transaction_flag() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    let request_tracker = RequestTracker::new();
    let ping = ping_request();
    let ctx = RequestContext::new("", &ping, &request_tracker);
    let observed_connection = Arc::new(Mutex::new(None));
    let observed_for_request = Arc::clone(&observed_connection);

    run_request_with_retries(
        ConnectionSource::Pool(&pool),
        QueryOptions::builder()
            .retry_request(false)
            .supports_backend_timeout(false)
            .supports_transaction_timeout(true)
            .build(),
        RequestOptions::new(false, Some(30000)),
        Duration::from_secs(30),
        &ctx,
        move |connection| {
            let observed_for_request = Arc::clone(&observed_for_request);
            async move {
                assert!(connection.in_transaction());
                *observed_for_request
                    .lock()
                    .expect("observed connection mutex should not be poisoned") =
                    Some(Arc::clone(&connection));
                connection.batch_execute("SELECT 1").await
            }
        },
    )
    .await
    .unwrap();

    let connection = observed_connection
        .lock()
        .expect("observed connection mutex should not be poisoned")
        .take()
        .expect("request closure should capture its connection");

    assert!(!connection.in_transaction());
}

#[tokio::test]
async fn transaction_commit_clears_transaction_flag() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    let connection = Arc::new(Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        pool.command_deadline(),
    ));

    let mut transaction =
        Transaction::start(Arc::clone(&connection), IsolationLevel::ReadCommitted)
            .await
            .unwrap();
    assert!(connection.in_transaction());

    transaction.commit().await.unwrap();

    assert!(!connection.in_transaction());
}

#[tokio::test]
async fn transaction_abort_clears_transaction_flag() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    let connection = Arc::new(Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        pool.command_deadline(),
    ));

    let mut transaction =
        Transaction::start(Arc::clone(&connection), IsolationLevel::ReadCommitted)
            .await
            .unwrap();
    assert!(connection.in_transaction());

    transaction.abort().await.unwrap();

    assert!(!connection.in_transaction());
}

#[tokio::test]
async fn scoped_transaction_drop_clears_flag_after_rollback() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    let connection = Arc::new(Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        pool.command_deadline(),
    ));

    {
        let _transaction = ScopedTransaction::start_if_necessary(&connection)
            .await
            .unwrap();
        assert!(connection.in_transaction());
    }

    wait_until_transaction_flag_clears(&connection).await;
    connection
        .batch_execute("DISCARD ALL")
        .await
        .expect("rollback should finish before the flag clears");
}

/// A connection released while a transaction is still open must never be handed
/// to a later caller from inside that transaction.
///
/// The primary pool recycles with `RecyclingMethod::Fast`, so nothing else
/// resets the session, and the abandoned transaction's snapshot would silently
/// serve stale reads to unrelated requests.
#[tokio::test]
async fn dropping_connection_in_transaction_rolls_back_before_pool_reuse() {
    let setup_config = setup_configuration();
    // A single connection guarantees the second acquire reuses the same backend.
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;

    {
        let connection = Connection::new(
            pool.acquire_connection().await.unwrap(),
            false,
            pool.sql_commenter_enabled(),
            pool.command_deadline(),
        );
        connection
            .batch_execute("START TRANSACTION ISOLATION LEVEL REPEATABLE READ")
            .await
            .unwrap();
        connection.set_in_transaction(true);
        // Dropped without COMMIT or ROLLBACK, the way task cancellation leaves it.
    }

    let reused = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        pool.command_deadline(),
    );

    // `DISCARD ALL` is rejected inside a transaction block, so it succeeds only
    // if the abandoned transaction was rolled back before the connection was
    // released back to the pool.
    reused
        .batch_execute("DISCARD ALL")
        .await
        .expect("connection was released to the pool inside an open transaction");
}

/// A statement that runs past the connection's client-side deadline must be
/// abandoned and surfaced as [`StatementError::Timeout`], never as success.
/// The negative control keeps the assertion honest.
#[tokio::test]
async fn batch_execute_enforces_command_deadline() {
    let setup_config = setup_configuration();
    // Two backends so the negative control does not have to wait for a
    // replacement to be opened for the connection the first half closes.
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 2).await;

    let short_deadline = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        Duration::from_millis(50),
    );
    let timed_out = short_deadline.batch_execute("SELECT pg_sleep(1)").await;
    assert!(
        matches!(timed_out, Err(StatementError::Timeout(_))),
        "statement exceeding the deadline should time out, got {timed_out:?}"
    );

    let generous_deadline = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        Duration::from_secs(5),
    );
    generous_deadline
        .batch_execute("SELECT pg_sleep(1)")
        .await
        .expect("statement within the deadline should complete");
}

/// A gateway ROLLBACK that fails after a request error must leave the connection
/// marked in-transaction, so the backstop in `Connection::drop` still fires.
///
/// The request closure terminates its own backend, guaranteeing the ROLLBACK
/// that `run_request_with_retries` issues next cannot succeed.
#[tokio::test]
async fn failed_rollback_after_request_error_keeps_transaction_flag_set() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    let request_tracker = RequestTracker::new();
    let ping = ping_request();
    let ctx = RequestContext::new("", &ping, &request_tracker);
    let observed_connection = Arc::new(Mutex::new(None));
    let observed_for_request = Arc::clone(&observed_connection);

    let _error = run_request_with_retries(
        ConnectionSource::Pool(&pool),
        QueryOptions::builder()
            .retry_request(false)
            .supports_backend_timeout(false)
            .supports_transaction_timeout(true)
            .build(),
        RequestOptions::new(false, Some(30000)),
        Duration::from_secs(30),
        &ctx,
        move |connection| {
            let observed_for_request = Arc::clone(&observed_for_request);
            async move {
                assert!(connection.in_transaction());
                *observed_for_request
                    .lock()
                    .expect("observed connection mutex should not be poisoned") =
                    Some(Arc::clone(&connection));
                // Terminate this backend so the gateway ROLLBACK that follows
                // the request error cannot succeed.
                let _ = connection
                    .batch_execute("SELECT pg_terminate_backend(pg_backend_pid())")
                    .await;
                // Resolve to an error regardless of how the termination raced:
                // the backend is gone, so this statement cannot succeed.
                connection.batch_execute("SELECT 1").await
            }
        },
    )
    .await
    .expect_err("request should fail once its backend is terminated");

    let connection = observed_connection
        .lock()
        .expect("observed connection mutex should not be poisoned")
        .take()
        .expect("request closure should capture its connection");

    assert!(
        connection.in_transaction(),
        "a failed ROLLBACK must leave the connection marked in-transaction so the drop backstop still fires"
    );
}

/// The `Postgres` arm of `StatementError` must convert into a
/// `TransactionError::PostgresError` that still carries the raw backend error,
/// so the caller can apply its own error-mapping context later.
#[tokio::test]
async fn postgres_statement_error_maps_to_unmapped_transaction_postgres_error() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    let connection = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        pool.command_deadline(),
    );

    // A genuine backend error is the only way to obtain a real
    // `tokio_postgres::Error`; a missing relation reliably produces one.
    let statement_error = connection
        .query(
            "SELECT * FROM a_relation_that_does_not_exist_for_tests",
            &[],
            &[],
        )
        .await
        .expect_err("querying a missing relation should fail");
    let StatementError::Postgres(pg_error) = statement_error else {
        panic!("a missing relation must surface as a Postgres statement error");
    };
    let expected_code = pg_error.code().cloned();
    assert!(
        expected_code.is_some(),
        "a missing-relation error should carry a SQLSTATE"
    );

    match TransactionError::from(StatementError::Postgres(pg_error)) {
        TransactionError::PostgresError(inner) => {
            assert_eq!(
                inner.code().cloned(),
                expected_code,
                "the raw Postgres error must be carried through unmapped"
            );
        }
        TransactionError::SimpleError(code, message) => panic!(
            "a Postgres statement error must map to PostgresError, got SimpleError({code:?}, {message:?})"
        ),
    }
}

/// The `Postgres` arm of `StatementError` must expose the wrapped backend error
/// through `Error::source`, so error chains report the underlying cause.
#[tokio::test]
async fn postgres_statement_error_exposes_the_backend_error_as_its_source() {
    use std::error::Error as _;

    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    let connection = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        pool.command_deadline(),
    );

    let error = connection
        .query(
            "SELECT * FROM a_relation_that_does_not_exist_for_tests",
            &[],
            &[],
        )
        .await
        .expect_err("querying a missing relation should fail");
    assert!(
        matches!(error, StatementError::Postgres(_)),
        "a missing relation must surface as a Postgres statement error"
    );
    assert!(
        error.source().is_some(),
        "the Postgres arm must expose the underlying backend error as its source"
    );
}

/// When the in-transaction `SET LOCAL statement_timeout` itself fails, the
/// gateway must roll the just-opened transaction back and clear the
/// in-transaction flag before returning the error.
///
/// A command timeout above `PostgreSQL`'s 32-bit millisecond ceiling makes the
/// `SET LOCAL` fail after `BEGIN` has already flagged the transaction. Only the
/// successful-ROLLBACK half is reachable from a black-box test.
#[tokio::test]
async fn failed_set_statement_timeout_rolls_back_gateway_transaction_and_clears_flag() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    let connection = Arc::new(Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        pool.command_deadline(),
    ));

    let request_tracker = RequestTracker::new();
    let ping = ping_request();
    let ctx = RequestContext::new("", &ping, &request_tracker);

    // 3_000_000_000 ms exceeds PostgreSQL's 32-bit statement_timeout range, so
    // `SET LOCAL statement_timeout` is rejected while the gateway transaction is
    // open. The closure never runs — the failure happens in the SET step.
    let error = run_request_with_retries(
        ConnectionSource::Cursor(Arc::clone(&connection)),
        QueryOptions::builder()
            .retry_request(false)
            .supports_backend_timeout(false)
            .supports_transaction_timeout(true)
            .build(),
        RequestOptions::new(false, Some(3_000_000_000)),
        Duration::from_secs(30),
        &ctx,
        |_connection| async { Ok::<(), StatementError>(()) },
    )
    .await
    .expect_err("an out-of-range statement_timeout must fail the request");

    assert_eq!(
        error.kind(),
        &ErrorKind::Postgres,
        "the failure must originate from the rejected SET statement, got {error:?}"
    );
    assert!(
        !connection.in_transaction(),
        "a successful ROLLBACK after the failed SET must clear the in-transaction flag"
    );
    // The connection is reusable only if the aborted transaction was actually
    // rolled back rather than left open.
    connection
        .batch_execute("SELECT 1")
        .await
        .expect("the connection must be reusable once the gateway transaction is rolled back");
}

/// A COMMIT that outlives the connection's client-side deadline surfaces as
/// `StatementError::Timeout`, and the gateway must still clear the
/// in-transaction flag so the next borrower does not inherit it.
///
/// The request installs a deferred constraint trigger whose `pg_sleep` runs
/// only at COMMIT. `statement_timeout` does not cover commit processing, so the
/// client-side deadline is the only bound on this path.
#[tokio::test]
async fn gateway_commit_timeout_clears_transaction_flag() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;
    // Replaced by the request's own 1.5s timeout once dispatch starts: past
    // BEGIN, SET and the setup statements, short of the 3s the deferred trigger
    // spends inside COMMIT.
    let connection = Arc::new(Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        Duration::from_secs(1),
    ));

    let request_tracker = RequestTracker::new();
    let ping = ping_request();
    let ctx = RequestContext::new("", &ping, &request_tracker);

    let error = run_request_with_retries(
        ConnectionSource::Cursor(Arc::clone(&connection)),
        QueryOptions::builder()
            .retry_request(false)
            .supports_backend_timeout(false)
            .supports_transaction_timeout(true)
            .build(),
        RequestOptions::new(false, Some(1500)),
        Duration::from_secs(30),
        &ctx,
        |connection| async move {
            connection
                .batch_execute(
                    "CREATE OR REPLACE FUNCTION pg_temp.commit_deadline_sleep() \
                         RETURNS trigger LANGUAGE plpgsql AS $$ BEGIN PERFORM pg_sleep(3); RETURN NULL; END $$; \
                     CREATE TEMP TABLE commit_deadline_defer(id int); \
                     CREATE CONSTRAINT TRIGGER commit_deadline_trigger \
                         AFTER INSERT ON commit_deadline_defer \
                         DEFERRABLE INITIALLY DEFERRED \
                         FOR EACH ROW EXECUTE FUNCTION pg_temp.commit_deadline_sleep(); \
                     INSERT INTO commit_deadline_defer VALUES (1)",
                )
                .await
        },
    )
    .await
    .expect_err("a COMMIT that outlives the client deadline must surface as an error");

    assert_eq!(
        error.error_code(),
        ErrorCode::ExceededTimeLimit,
        "a COMMIT past the client deadline must map to ExceededTimeLimit, got {error:?}"
    );
    assert!(
        !connection.in_transaction(),
        "a timed-out COMMIT must clear the in-transaction flag so the connection is not reused dirty"
    );
}

/// Row-returning statements must be bounded by the same client-side deadline as
/// [`Connection::batch_execute`]. These carry the actual request payload, so a
/// backend that stops responding during one is the case the deadline exists for.
#[tokio::test]
async fn query_enforces_command_deadline() {
    let setup_config = setup_configuration();
    // Two backends so the negative control does not have to wait for a
    // replacement to be opened for the connection the first half closes.
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 2).await;

    let short_deadline = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        Duration::from_millis(50),
    );
    let timed_out = short_deadline.query("SELECT pg_sleep(1)", &[], &[]).await;
    assert!(
        matches!(timed_out, Err(StatementError::Timeout(_))),
        "query exceeding the deadline should time out, got {timed_out:?}"
    );

    let generous_deadline = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        Duration::from_secs(5),
    );
    generous_deadline
        .query("SELECT pg_sleep(1)", &[], &[])
        .await
        .expect("query within the deadline should complete");
}

/// The client-side deadline must follow the timeout of the request being run,
/// not the pool default and not a neighbouring request's — a cursor or
/// transaction connection outlives the request that opened it.
#[tokio::test]
async fn command_deadline_follows_the_current_request() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;

    let connection = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        Duration::from_secs(90),
    );

    connection.set_command_deadline(Some(Duration::from_secs(5)));
    assert_eq!(connection.command_deadline(), Duration::from_secs(5));

    // A request asking for less than its predecessor gets less, or a client
    // setting a short timeout would wait for the longest one this connection
    // has ever served.
    connection.set_command_deadline(Some(Duration::from_secs(2)));
    assert_eq!(connection.command_deadline(), Duration::from_secs(2));

    // Sub-second timeouts are floored so the deadline does not reliably beat
    // the backend's own timeout for the same request.
    connection.set_command_deadline(Some(Duration::from_millis(10)));
    assert_eq!(connection.command_deadline(), Duration::from_secs(1));

    // A request with no timeout of its own falls back to the pool default.
    connection.set_command_deadline(None);
    assert_eq!(connection.command_deadline(), Duration::from_secs(90));

    connection
        .query("SELECT pg_sleep(1)", &[], &[])
        .await
        .expect("a statement within the deadline should complete");
}

/// A drop-time rollback that cannot complete must discard the connection rather
/// than hold it checked out forever: `clean_unused_pools` refuses to dispose a
/// pool with connections checked out, so the pool would leak for the process
/// lifetime.
#[tokio::test]
async fn rollback_that_cannot_complete_on_drop_discards_the_connection() {
    let setup_config = setup_configuration();
    // A single connection makes the pool's checked-out count unambiguous.
    let pool = Arc::new(
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await,
    );

    {
        let connection = Connection::new(
            pool.acquire_connection().await.unwrap(),
            false,
            pool.sql_commenter_enabled(),
            Duration::from_millis(500),
        );
        connection.batch_execute("START TRANSACTION").await.unwrap();
        connection.set_in_transaction(true);

        // Abandon a long statement the way task cancellation does. The backend
        // keeps executing it, so the rollback issued on drop queues behind it
        // and cannot finish within the connection's deadline.
        let abandoned = tokio::time::timeout(
            Duration::from_millis(100),
            connection.batch_execute("SELECT pg_sleep(30)"),
        )
        .await;
        assert!(
            abandoned.is_err(),
            "the statement should still be running when the connection is dropped"
        );
    }

    // Long enough for the rollback to hit its deadline, far short of the
    // statement blocking it.
    sleep(Duration::from_secs(2)).await;

    let status = pool.status().status();
    assert_eq!(
        status.size.saturating_sub(status.available),
        0,
        "a connection whose rollback timed out must be taken out of the pool, \
         leaving it idle enough to be disposed"
    );
}

/// A connection whose statement was abandoned at the client-side deadline must
/// be closed, not released back to the pool: the backend is still working on it
/// and the driver queues anything sent afterwards behind it.
#[tokio::test]
async fn statement_abandoned_at_the_deadline_closes_the_connection() {
    let setup_config = setup_configuration();
    // A single connection makes the handover unambiguous: whatever the next
    // borrower gets is either the abandoned connection or its replacement.
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;

    {
        let connection = Connection::new(
            pool.acquire_connection().await.unwrap(),
            false,
            pool.sql_commenter_enabled(),
            Duration::from_millis(50),
        );
        let timed_out = connection.query("SELECT pg_sleep(30)", &[], &[]).await;
        assert!(
            matches!(timed_out, Err(StatementError::Timeout(_))),
            "the statement should be abandoned at the deadline, got {timed_out:?}"
        );
    }

    let next = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        Duration::from_millis(500),
    );
    next.query("SELECT 1", &[], &[])
        .await
        .expect("the next borrower must get a connection that is not still busy");
}

/// The cleanup a caller runs after a timeout travels the same connection as the
/// abandoned statement. Waiting out a second deadline there would double the
/// time a timed-out request takes to report.
#[tokio::test]
async fn statements_after_an_abandoned_one_fail_without_waiting() {
    let setup_config = setup_configuration();
    let pool =
        build_connection_pool(&setup_config, &setup_config.postgres_system_user.clone(), 1).await;

    let connection = Connection::new(
        pool.acquire_connection().await.unwrap(),
        false,
        pool.sql_commenter_enabled(),
        Duration::from_millis(200),
    );

    let timed_out = connection.query("SELECT pg_sleep(30)", &[], &[]).await;
    assert!(
        matches!(timed_out, Err(StatementError::Timeout(_))),
        "the statement should be abandoned at the deadline, got {timed_out:?}"
    );

    // Raised well above the deadline that was blown, so waiting rather than
    // short-circuiting is unmistakable in the elapsed time below.
    connection.set_command_deadline(Some(Duration::from_secs(10)));

    let started = Instant::now();
    let after = connection.batch_execute("ROLLBACK").await;
    let elapsed = started.elapsed();

    assert!(
        matches!(after, Err(StatementError::Timeout(deadline)) if deadline == Duration::from_millis(200)),
        "a statement on an abandoned connection must report the deadline that was blown, got {after:?}"
    );
    assert!(
        elapsed < Duration::from_secs(1),
        "it must fail immediately rather than waiting out the new deadline, took {elapsed:?}"
    );
}
