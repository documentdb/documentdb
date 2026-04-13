/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/query_dispatch.rs
 *
 * Retry and transaction query dispatch logic
 *
 *-------------------------------------------------------------------------
 */

use std::{backtrace::Backtrace, future::Future, io, sync::Arc};

use deadpool_postgres::{HookError, PoolError};
use tokio::time::{Duration, Instant};
use tokio_postgres::error::SqlState;

use crate::{
    error::{DocumentDBError, ErrorCode, ErrorKind, Result},
    postgres::conn_mgmt::{
        connection::{Connection, QueryOptions, RequestOptions},
        retry_policies::{LongRetryPolicy, RetryPolicyBuilder, ShortRetryPolicy},
        ConnectionPool,
    },
    requests::{request_tracker::RequestTracker, RequestIntervalKind},
};

/// Caller-facing enum describing how to obtain a connection for a query.
#[derive(Debug)]
pub enum PullConnection {
    /// Acquire from the connection pool (or use an active transaction).
    PoolOrTransaction,
    /// Reuse a pinned cursor connection.
    Cursor(Arc<Connection>),
}

/// Describes where to obtain a connection on each retry iteration.
#[derive(Debug)]
pub enum ConnectionSource<'a> {
    /// Acquire a fresh connection from the pool on each retry attempt.
    Pool(&'a ConnectionPool),
    /// Reuse the provided cursor connection on each retry attempt.
    Cursor(Arc<Connection>),
    /// Use the transaction connection; retry is suppressed.
    Transaction(Arc<Connection>),
}

#[derive(Debug, Eq, PartialEq)]
enum Retry {
    Long,
    Short,
    None,
}

struct RetryContext {
    stopwatch: Instant,
    retry_count: u32,
    short_retry_policy: Option<ShortRetryPolicy>,
    long_retry_policy: Option<LongRetryPolicy>,
}

const fn is_transient_io_error(kind: io::ErrorKind) -> bool {
    matches!(
        kind,
        io::ErrorKind::TimedOut
            | io::ErrorKind::ConnectionReset
            | io::ErrorKind::ConnectionAborted
            | io::ErrorKind::NotConnected
            | io::ErrorKind::BrokenPipe
            | io::ErrorKind::UnexpectedEof
    )
}

fn is_connectivity_error(error: &tokio_postgres::Error) -> bool {
    use std::error::Error;

    let mut source = error.source();
    while let Some(err) = source {
        if let Some(io_err) = err.downcast_ref::<io::Error>() {
            return is_transient_io_error(io_err.kind());
        }
        source = err.source();
    }
    false
}

fn is_timeout_error(error: &tokio_postgres::Error) -> bool {
    use std::error::Error;

    let mut source = error.source();
    while let Some(err) = source {
        if let Some(io_err) = err.downcast_ref::<io::Error>() {
            return io_err.kind() == io::ErrorKind::TimedOut;
        }
        source = err.source();
    }
    false
}

fn classify_retry(
    error_code: Option<&str>,
    query_options: QueryOptions,
    request_options: RequestOptions,
    is_closed: bool,
    is_connectivity: bool,
    is_timeout: bool,
) -> Retry {
    // If the connection is already closed, it's a transient error and we should retry
    if is_closed {
        return Retry::Short;
    }

    let retry_from_error = match error_code {
        Some(code) if code == SqlState::READ_ONLY_SQL_TRANSACTION.code() => {
            Some(if request_options.in_replica_cluster_mode() {
                Retry::None
            } else {
                Retry::Long
            })
        }
        Some(code) if code == SqlState::ADMIN_SHUTDOWN.code() => Some(Retry::Long),
        // Peer authentication failed for user
        Some(code) if code == SqlState::INVALID_AUTHORIZATION_SPECIFICATION.code() => {
            Some(Retry::Long)
        }
        // Lost path write error
        Some("XX003") => Some(Retry::Short),
        Some(code) if code == SqlState::CONNECTION_FAILURE.code() => Some(Retry::Long),
        Some(code) if code == SqlState::T_R_SERIALIZATION_FAILURE.code() => Some(Retry::Long),
        Some(code)
            if code == SqlState::DISK_FULL.code()
                || code == SqlState::OUT_OF_MEMORY.code()
                || code == SqlState::TOO_MANY_CONNECTIONS.code()
                || code == SqlState::INSUFFICIENT_RESOURCES.code() =>
        {
            Some(Retry::None)
        }
        Some(code) if code == SqlState::T_R_DEADLOCK_DETECTED.code() => {
            if query_options.retry_deadlock() {
                tracing::info!("Retrying deadlock for current request");

                Some(Retry::Long)
            } else {
                Some(Retry::None)
            }
        }
        Some(_) | None => None,
    };

    if let Some(retry) = retry_from_error {
        return retry;
    }

    // Timeout transport errors are retried with short policy,
    // other connectivity errors with long policy
    if is_timeout {
        return Retry::Short;
    }

    // Connectivity errors are usually transient and should be retried
    // but for backend errors we should give system some time to recover
    if is_connectivity {
        Retry::Long
    } else {
        Retry::None
    }
}

fn retry_policy(
    error: &tokio_postgres::Error,
    query_options: QueryOptions,
    request_options: RequestOptions,
) -> Retry {
    classify_retry(
        error.code().map(tokio_postgres::error::SqlState::code),
        query_options,
        request_options,
        error.is_closed(),
        is_connectivity_error(error),
        is_timeout_error(error),
    )
}

/// Extracts a `tokio_postgres::Error` from a `DocumentDBError`, if present.
///
/// Works for both pool-related errors and direct postgres errors
const fn extract_pg_error(error: &DocumentDBError) -> Option<&tokio_postgres::Error> {
    match error.kind() {
        ErrorKind::PoolError(
            PoolError::Backend(e) | PoolError::PostCreateHook(HookError::Backend(e)),
            _,
        )
        | ErrorKind::PostgresError(e, _) => Some(e),
        _ => None,
    }
}

/// Returns the retry interval for the given retry classification, or `None` if exhausted.
fn get_retry_interval(retry: &Retry, retry_context: &mut RetryContext) -> Option<Duration> {
    match retry {
        Retry::Short => {
            let policy = retry_context
                .short_retry_policy
                .get_or_insert_with(RetryPolicyBuilder::build_short);
            policy.next_interval()
        }
        Retry::Long => {
            let policy = retry_context
                .long_retry_policy
                .get_or_insert_with(RetryPolicyBuilder::build_long);
            policy.next_interval()
        }
        Retry::None => None,
    }
}

/// Sets the `PostgreSQL` statement timeout
///
/// Returns `true` if a gateway transaction was started (caller must COMMIT/ROLLBACK).
async fn set_statement_timeout(
    connection: &Connection,
    max_time_ms: Option<i64>,
    query_options: &QueryOptions,
    in_user_transaction: bool,
    request_tracker: &RequestTracker,
) -> std::result::Result<bool, tokio_postgres::Error> {
    let max_time_ms = match max_time_ms {
        Some(ms) if !in_user_transaction && !query_options.supports_backend_timeout() => ms,
        _ => return Ok(false),
    };

    // Determine whether to wrap in a gateway transaction.
    // Since in_user_transaction == false here (checked above), we either
    // use BEGIN + SET LOCAL (supports_transaction_timeout) or session-level SET.
    let use_transaction = query_options.supports_transaction_timeout();

    // Start a gateway transaction if needed
    if use_transaction {
        let start = Instant::now();
        connection.batch_execute("BEGIN").await?;
        request_tracker.record_duration(RequestIntervalKind::PostgresBeginTransaction, start);

        connection.set_in_transaction(true);
    }

    // SET [LOCAL] statement_timeout
    let set_cmd = if use_transaction {
        format!("set local statement_timeout to {max_time_ms}")
    } else {
        format!("set statement_timeout to {max_time_ms}")
    };

    let set_start = Instant::now();
    if let Err(e) = connection.batch_execute(&set_cmd).await {
        if use_transaction {
            let _ = connection.batch_execute("ROLLBACK").await;
            connection.set_in_transaction(false);
        }
        return Err(e);
    }
    request_tracker.record_duration(RequestIntervalKind::PostgresSetStatementTimeout, set_start);

    Ok(use_transaction)
}

/// Unified query execution with connection resolution, gateway timeout, and retry logic.
///
/// - Resolves a connection via [`ConnectionSource`]
/// - Applies gateway timeout if needed
/// - Executes the query closure
/// - Commits gateway transaction if one was started
/// - On error, classifies and retries
///
/// # Errors
/// Returns an error if the query fails after exhausting all retry attempts,
/// or if the command timeout is exceeded.
#[expect(
    clippy::too_many_lines,
    reason = "complex logic that would be harder to read if split across multiple functions"
)]
pub async fn run_request_with_retries<T, F, Fut>(
    source: ConnectionSource<'_>,
    query_options: QueryOptions,
    request_options: RequestOptions,
    max_time_ms: Option<i64>,
    request_tracker: &RequestTracker,
    run_func: F,
) -> Result<T>
where
    F: Fn(Arc<Connection>) -> Fut,
    Fut: Future<Output = std::result::Result<T, tokio_postgres::Error>>,
{
    let command_timeout = max_time_ms.map_or_else(
        || request_options.command_timeout(),
        |ms| Duration::from_millis(ms.cast_unsigned()),
    );

    let mut retry_context = RetryContext {
        stopwatch: Instant::now(),
        retry_count: 0,
        short_retry_policy: None,
        long_retry_policy: None,
    };

    let in_transaction = matches!(source, ConnectionSource::Transaction(_));

    // Pre-compute whether set_statement_timeout can ever apply. When false
    // (the common path) we skip the function call entirely on every iteration.
    let needs_gateway_timeout =
        max_time_ms.is_some() && !in_transaction && !query_options.supports_backend_timeout();

    // Use the timeout pool only when session-level SET statement_timeout will
    // be issued (no transaction wrapping). SET LOCAL auto-reverts on COMMIT so
    // the primary pool is safe for that path.
    let needs_timeout_pool = needs_gateway_timeout && !query_options.supports_transaction_timeout();

    loop {
        let result: std::result::Result<T, DocumentDBError> = 'attempt: {
            let connection = match &source {
                // Use the timeout pool when session-level
                // SET statement_timeout will be issued, so the connection state
                // is reset on return and won't leak the setting to other requests.
                ConnectionSource::Pool(pool) => {
                    let open_backend_connection_start = Instant::now();
                    let acquire = if needs_timeout_pool {
                        pool.acquire_timeout_connection().await
                    } else {
                        pool.acquire_connection().await
                    };
                    request_tracker.record_duration(
                        RequestIntervalKind::OpenBackendConnection,
                        open_backend_connection_start,
                    );

                    match acquire {
                        Ok(pool_conn) => Arc::new(Connection::new(pool_conn, false)),
                        Err(e) => {
                            if needs_timeout_pool {
                                tracing::warn!(
                                    "Failed to acquire connection from timeout pool: {e:?}"
                                );
                            }

                            break 'attempt Err(DocumentDBError::new(ErrorKind::PoolError(
                                e,
                                Backtrace::capture(),
                            )));
                        }
                    }
                }
                ConnectionSource::Cursor(conn) | ConnectionSource::Transaction(conn) => {
                    Arc::clone(conn)
                }
            };

            // Set statement timeout (only when needed)
            let in_gateway_txn = if needs_gateway_timeout {
                match set_statement_timeout(
                    &connection,
                    max_time_ms,
                    &query_options,
                    in_transaction,
                    request_tracker,
                )
                .await
                {
                    Ok(v) => v,
                    Err(e) => {
                        break 'attempt Err(DocumentDBError::new(ErrorKind::PostgresError(
                            e,
                            Backtrace::capture(),
                        )))
                    }
                }
            } else {
                false
            };

            // Execute the query
            let request_start = Instant::now();
            if in_gateway_txn {
                // Gateway transaction active — clone Arc because we need
                // the connection afterwards for COMMIT/ROLLBACK.
                let query_result = run_func(Arc::clone(&connection)).await;
                request_tracker.record_duration(RequestIntervalKind::ProcessRequest, request_start);

                match query_result {
                    Ok(value) => {
                        let commit_start = Instant::now();
                        match connection.batch_execute("COMMIT").await {
                            Ok(()) => {
                                request_tracker.record_duration(
                                    RequestIntervalKind::PostgresCommitTransaction,
                                    commit_start,
                                );
                                Ok(value)
                            }
                            Err(e) => {
                                // PostgreSQL auto-rolls-back a failed COMMIT, so the
                                // connection is no longer in a transaction.
                                connection.set_in_transaction(false);
                                Err(DocumentDBError::new(ErrorKind::PostgresError(
                                    e,
                                    Backtrace::capture(),
                                )))
                            }
                        }
                    }
                    Err(e) => {
                        let _ = connection.batch_execute("ROLLBACK").await;
                        connection.set_in_transaction(false);
                        Err(DocumentDBError::new(ErrorKind::PostgresError(
                            e,
                            Backtrace::capture(),
                        )))
                    }
                }
            } else {
                // No gateway transaction -> move the Arc directly into the
                // closure call, avoiding an Arc::clone + drop pair.
                let query_result = run_func(connection).await;
                request_tracker.record_duration(RequestIntervalKind::ProcessRequest, request_start);
                query_result.map_err(|e| {
                    DocumentDBError::new(ErrorKind::PostgresError(e, Backtrace::capture()))
                })
            }
        };

        // Handle result / retry
        match result {
            Ok(value) => return Ok(value),

            Err(error) => {
                tracing::error!("Error executing postgres request: {error}");

                // a request is retriable if:
                // - it is a retriable error,
                // - we haven't exhausted retries
                // - it is retriable on a transient error, which means that it's not in a transaction.
                if let Some(pg_error) = extract_pg_error(&error) {
                    let retry = retry_policy(pg_error, query_options, request_options);

                    if in_transaction {
                        if !matches!(retry, Retry::None) {
                            tracing::info!(
                                "Error is retriable ({retry:?}), but not getting retried \
                                 due to the request being in a transaction."
                            );
                        }
                    } else if query_options.retry_request()
                        && retry_context.stopwatch.elapsed() < command_timeout
                    {
                        if let Some(interval) = get_retry_interval(&retry, &mut retry_context) {
                            retry_context.retry_count += 1;
                            tracing::warn!(
                                "Retrying request (attempt {}): {}",
                                retry_context.retry_count,
                                error
                            );
                            tokio::time::sleep(interval).await;
                            continue;
                        }
                    } else if !query_options.retry_request() {
                        tracing::info!(
                            "Error is not retriable, as it is a procedural bulk write request."
                        );
                    }
                }

                if retry_context.stopwatch.elapsed() >= command_timeout {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::ExceededTimeLimit,
                        format!(
                            "Query exceeded command timeout of {}ms",
                            command_timeout.as_millis()
                        ),
                    ));
                }

                return Err(error);
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn default_query_context() -> QueryOptions {
        QueryOptions::default()
    }

    fn deadlock_retry_query_context() -> QueryOptions {
        QueryOptions::builder().retry_deadlock(true).build()
    }

    fn non_replica_options() -> RequestOptions {
        RequestOptions::new(false, 30)
    }

    fn replica_options() -> RequestOptions {
        RequestOptions::new(true, 30)
    }

    // ── is_transient_io_error ──────────────────────────────────────────

    #[test]
    fn test_is_transient_io_error_with_timed_out_returns_true() {
        assert!(is_transient_io_error(io::ErrorKind::TimedOut));
    }

    #[test]
    fn test_is_transient_io_error_with_connection_reset_returns_true() {
        assert!(is_transient_io_error(io::ErrorKind::ConnectionReset));
    }

    #[test]
    fn test_is_transient_io_error_with_connection_aborted_returns_true() {
        assert!(is_transient_io_error(io::ErrorKind::ConnectionAborted));
    }

    #[test]
    fn test_is_transient_io_error_with_not_connected_returns_true() {
        assert!(is_transient_io_error(io::ErrorKind::NotConnected));
    }

    #[test]
    fn test_is_transient_io_error_with_broken_pipe_returns_true() {
        assert!(is_transient_io_error(io::ErrorKind::BrokenPipe));
    }

    #[test]
    fn test_is_transient_io_error_with_unexpected_eof_returns_true() {
        assert!(is_transient_io_error(io::ErrorKind::UnexpectedEof));
    }

    #[test]
    fn test_is_transient_io_error_with_permission_denied_returns_false() {
        assert!(!is_transient_io_error(io::ErrorKind::PermissionDenied));
    }

    #[test]
    fn test_is_transient_io_error_with_not_found_returns_false() {
        assert!(!is_transient_io_error(io::ErrorKind::NotFound));
    }

    #[test]
    fn test_is_transient_io_error_with_addr_in_use_returns_false() {
        assert!(!is_transient_io_error(io::ErrorKind::AddrInUse));
    }

    #[test]
    fn test_is_transient_io_error_with_would_block_returns_false() {
        assert!(!is_transient_io_error(io::ErrorKind::WouldBlock));
    }

    // ── classify_retry: closed connection ──────────────────────────────

    #[test]
    fn test_classify_retry_with_closed_connection_returns_short() {
        let result = classify_retry(
            None,
            default_query_context(),
            non_replica_options(),
            true,
            false,
            false,
        );
        assert_eq!(result, Retry::Short);
    }

    #[test]
    fn test_classify_retry_with_closed_and_error_code_returns_short() {
        let result = classify_retry(
            Some(SqlState::ADMIN_SHUTDOWN.code()),
            default_query_context(),
            non_replica_options(),
            true,
            false,
            false,
        );
        assert_eq!(result, Retry::Short);
    }

    // ── classify_retry: READ_ONLY_SQL_TRANSACTION ──────────────────────

    #[test]
    fn test_classify_retry_with_read_only_on_primary_returns_long() {
        let result = classify_retry(
            Some(SqlState::READ_ONLY_SQL_TRANSACTION.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::Long);
    }

    #[test]
    fn test_classify_retry_with_read_only_on_replica_returns_none() {
        let result = classify_retry(
            Some(SqlState::READ_ONLY_SQL_TRANSACTION.code()),
            default_query_context(),
            replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::None);
    }

    // ── classify_retry: ADMIN_SHUTDOWN ─────────────────────────────────

    #[test]
    fn test_classify_retry_with_admin_shutdown_returns_long() {
        let result = classify_retry(
            Some(SqlState::ADMIN_SHUTDOWN.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::Long);
    }

    // ── classify_retry: INVALID_AUTHORIZATION_SPECIFICATION ────────────

    #[test]
    fn test_classify_retry_with_invalid_auth_returns_long() {
        let result = classify_retry(
            Some(SqlState::INVALID_AUTHORIZATION_SPECIFICATION.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::Long);
    }

    // ── classify_retry: XX003 (lost write path) ────────────────────────

    #[test]
    fn test_classify_retry_with_xx003_returns_short() {
        let result = classify_retry(
            Some("XX003"),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::Short);
    }

    // ── classify_retry: CONNECTION_FAILURE ──────────────────────────────

    #[test]
    fn test_classify_retry_with_connection_failure_returns_long() {
        let result = classify_retry(
            Some(SqlState::CONNECTION_FAILURE.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::Long);
    }

    // ── classify_retry: T_R_SERIALIZATION_FAILURE ──────────────────────

    #[test]
    fn test_classify_retry_with_serialization_failure_returns_long() {
        let result = classify_retry(
            Some(SqlState::T_R_SERIALIZATION_FAILURE.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::Long);
    }

    // ── classify_retry: resource exhaustion errors ─────────────────────

    #[test]
    fn test_classify_retry_with_disk_full_returns_none() {
        let result = classify_retry(
            Some(SqlState::DISK_FULL.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::None);
    }

    #[test]
    fn test_classify_retry_with_out_of_memory_returns_none() {
        let result = classify_retry(
            Some(SqlState::OUT_OF_MEMORY.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::None);
    }

    #[test]
    fn test_classify_retry_with_too_many_connections_returns_none() {
        let result = classify_retry(
            Some(SqlState::TOO_MANY_CONNECTIONS.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::None);
    }

    #[test]
    fn test_classify_retry_with_insufficient_resources_returns_none() {
        let result = classify_retry(
            Some(SqlState::INSUFFICIENT_RESOURCES.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::None);
    }

    // ── classify_retry: deadlock ───────────────────────────────────────

    #[test]
    fn test_classify_retry_with_deadlock_and_retry_enabled_returns_long() {
        let result = classify_retry(
            Some(SqlState::T_R_DEADLOCK_DETECTED.code()),
            deadlock_retry_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::Long);
    }

    #[test]
    fn test_classify_retry_with_deadlock_and_retry_disabled_returns_none() {
        let result = classify_retry(
            Some(SqlState::T_R_DEADLOCK_DETECTED.code()),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::None);
    }

    // ── classify_retry: unrecognized sql codes ─────────────────────────

    #[test]
    fn test_classify_retry_with_unknown_code_and_connectivity_returns_long() {
        let result = classify_retry(
            Some("99999"),
            default_query_context(),
            non_replica_options(),
            false,
            true,
            false,
        );
        assert_eq!(result, Retry::Long);
    }

    #[test]
    fn test_classify_retry_with_unknown_code_and_timeout_returns_short() {
        let result = classify_retry(
            Some("99999"),
            default_query_context(),
            non_replica_options(),
            false,
            true,
            true,
        );
        assert_eq!(result, Retry::Short);
    }

    #[test]
    fn test_classify_retry_with_unknown_code_and_no_connectivity_returns_none() {
        let result = classify_retry(
            Some("99999"),
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::None);
    }

    // ── classify_retry: no error code ──────────────────────────────────

    #[test]
    fn test_classify_retry_with_no_code_and_connectivity_returns_long() {
        let result = classify_retry(
            None,
            default_query_context(),
            non_replica_options(),
            false,
            true,
            false,
        );
        assert_eq!(result, Retry::Long);
    }

    #[test]
    fn test_classify_retry_with_no_code_and_timeout_returns_short() {
        let result = classify_retry(
            None,
            default_query_context(),
            non_replica_options(),
            false,
            true,
            true,
        );
        assert_eq!(result, Retry::Short);
    }

    #[test]
    fn test_classify_retry_with_no_code_and_no_connectivity_returns_none() {
        let result = classify_retry(
            None,
            default_query_context(),
            non_replica_options(),
            false,
            false,
            false,
        );
        assert_eq!(result, Retry::None);
    }

    // ── classify_retry: closed takes precedence ────────────────────────

    #[test]
    fn test_classify_retry_with_closed_and_connectivity_returns_short() {
        let result = classify_retry(
            None,
            default_query_context(),
            non_replica_options(),
            true,
            true,
            false,
        );
        assert_eq!(result, Retry::Short);
    }
}
