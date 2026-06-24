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

use std::time::Duration;

use bson::rawdoc;
use deadpool_postgres::PoolError;
use documentdb_gateway_core::{
    configuration::{DocumentDBSetupConfiguration, SetupConfiguration},
    context::RequestContext,
    error::{ErrorCode, ErrorKind},
    postgres::{
        conn_mgmt::{
            run_request_with_retries, ConnectionPool, ConnectionSource, PgPoolSettings,
            PoolManager, QueryOptions, RequestOptions, AUTHENTICATION_MAX_CONNECTIONS,
            SYSTEM_REQUESTS_MAX_CONNECTIONS,
        },
        create_query_catalog,
    },
    requests::{request_tracker::RequestTracker, RequestExecutionMode, RequestType, WireRequest},
};
use documentdb_tests::test_setup::config::{
    failing_setup_configuration, setup_configuration, setup_configuration_with_command_timeout,
};
use tokio::task::yield_now;

async fn build_connection_pool(
    setup_config: &DocumentDBSetupConfiguration,
    user: &str,
    max_connections: usize,
) -> ConnectionPool {
    yield_now().await;

    let query_catalog = create_query_catalog();
    ConnectionPool::new_with_user(
        setup_config,
        &query_catalog,
        user,
        None,
        "test-app",
        PgPoolSettings::system_pool_settings(max_connections),
    )
    .expect("Failed to create connection pool")
}

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

fn build_pool_manager(setup_config: &DocumentDBSetupConfiguration) -> PoolManager {
    let query_catalog = create_query_catalog();
    let postgres_system_user = setup_config.postgres_system_user();

    let system_requests_pool = ConnectionPool::new_with_user(
        setup_config,
        &query_catalog,
        postgres_system_user,
        None,
        &format!("{}-SystemRequests", setup_config.application_name()),
        PgPoolSettings::system_pool_settings(SYSTEM_REQUESTS_MAX_CONNECTIONS),
    )
    .expect("Failed to create system requests pool");

    let authentication_pool = ConnectionPool::new_with_user(
        setup_config,
        &query_catalog,
        postgres_system_user,
        None,
        &format!("{}-PreAuthRequests", setup_config.application_name()),
        PgPoolSettings::system_pool_settings(AUTHENTICATION_MAX_CONNECTIONS),
    )
    .expect("Failed to create authentication pool");

    PoolManager::new(
        query_catalog,
        Box::new(setup_config.clone()),
        system_requests_pool,
        authentication_pool,
    )
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
        |_| async { Ok::<(), tokio_postgres::Error>(()) },
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
            |_| async { Ok::<(), tokio_postgres::Error>(()) },
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
            |_| async { Ok::<(), tokio_postgres::Error>(()) },
        )
        .await
        .unwrap_err()
    };

    assert_eq!(error.kind(), &ErrorKind::Pool);
}
