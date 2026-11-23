// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

/*-------------------------------------------------------------------------
 * documentdb_gateway_core/src/postgres/conn_mgmt/query_dispatch.rs
 *
 * Retry and transaction query dispatch logic
 *
 *-------------------------------------------------------------------------
 */

use std::{future::Future, io, sync::Arc};

use deadpool_postgres::{PoolError, TimeoutType};
use tokio::time::{Duration, Instant};
use tokio_postgres::error::SqlState;

use crate::{
    configuration::DynamicConfiguration,
    context::RequestContext,
    error::{
        backend_io_error_kind, is_transient_backend_io_error, DocumentDBError, ErrorCode, Result,
    },
    postgres::conn_mgmt::{
        connection::{Connection, QueryOptions, RequestOptions},
        retry_policies::{LongRetryPolicy, RetryPolicyBuilder, ShortRetryPolicy},
        ConnectionPool, StatementError,
    },
    requests::{request_tracker::RequestTracker, RequestIntervalKind},
    responses::map_pg_error,
    telemetry::context_propagation::mark_span_error,
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

impl ConnectionSource<'_> {
    #[must_use]
    pub const fn is_transaction(&self) -> bool {
        matches!(self, Self::Transaction(_))
    }

    /// Acquires a pooled connection or reuses a retained connection.
    ///
    /// # Errors
    /// Returns an acquisition error.
    pub async fn acquire(&self, tracker: &RequestTracker) -> Result<Arc<Connection>> {
        match self {
            Self::Pool(pool) => {
                let started = Instant::now();
                let acquired = pool.acquire_connection().await;
                tracker.record_duration(RequestIntervalKind::OpenBackendConnection, started);

                match acquired {
                    Ok(connection) => Ok(Arc::new(Connection::new(
                        connection,
                        false,
                        pool.command_deadline(),
                    ))),
                    Err(error) => Err(DocumentDBError::from(error)),
                }
            }
            Self::Cursor(connection) | Self::Transaction(connection) => Ok(Arc::clone(connection)),
        }
    }
}

/// Whether a failure returns to the caller or follows the retry policy.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum QueryFailureAction {
    /// Apply the normal retry, timeout and shutdown-conversion rules.
    UseRetryPolicy,
    /// Return the current error without retrying or applying terminal conversion.
    Return,
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

fn is_connectivity_error(error: &tokio_postgres::Error) -> bool {
    backend_io_error_kind(error).is_some_and(is_transient_backend_io_error)
}

fn is_timeout_error(error: &tokio_postgres::Error) -> bool {
    backend_io_error_kind(error).is_some_and(|kind| kind == io::ErrorKind::TimedOut)
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
        Some(code) if code == SqlState::CANNOT_CONNECT_NOW.code() => Some(Retry::Long),
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

/// How a failure should be retried, or `None` when it carries nothing to
/// classify and the request must end.
fn retry_for(
    error: &DocumentDBError,
    query_options: QueryOptions,
    request_options: RequestOptions,
) -> Option<Retry> {
    if let Some(pg_error) = extract_pg_error(error) {
        return Some(retry_policy(pg_error, query_options, request_options));
    }

    // Giving up while building a connection carries no backend error, because
    // the attempt never got far enough to produce one. It is still a transport
    // timeout, so it takes the policy one would get from the socket.
    matches!(
        error.as_pool_error(),
        Some(PoolError::Timeout(TimeoutType::Create))
    )
    .then_some(Retry::Short)
}

/// Extracts a `tokio_postgres::Error` from a `DocumentDBError`, if present.
///
/// Works for both pool-related errors and direct postgres errors
fn extract_pg_error(error: &DocumentDBError) -> Option<&tokio_postgres::Error> {
    if let Some(pg_error) = error.as_postgres_error() {
        return Some(pg_error);
    }

    if let Some(pool_error) = error.as_pool_error() {
        return match pool_error {
            deadpool_postgres::PoolError::Backend(e)
            | deadpool_postgres::PoolError::PostCreateHook(
                deadpool_postgres::HookError::Backend(e),
            ) => Some(e),
            _ => None,
        };
    }

    None
}

fn map_shutdown_connectivity_error(
    postgres_error: Option<&tokio_postgres::Error>,
    dynamic_configuration: &dyn DynamicConfiguration,
) -> Option<DocumentDBError> {
    (dynamic_configuration.send_shutdown_responses()
        && postgres_error.is_some_and(is_connectivity_error))
    .then(|| {
        DocumentDBError::documentdb_error(
            ErrorCode::ShutdownInProgress,
            "Graceful shutdown requested".to_owned(),
        )
    })
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

// For auth-related requests, request_options.command_timeout() will be None
// and the postgres client timeout is used instead.
fn check_for_command_timeout_error(
    request_options: &RequestOptions,
    elapsed: Duration,
) -> Result<()> {
    match request_options.command_timeout() {
        Some(command_timeout) if elapsed >= command_timeout => {
            Err(DocumentDBError::documentdb_error(
                ErrorCode::ExceededTimeLimit,
                format!(
                    "Query exceeded command timeout of {}ms",
                    command_timeout.as_millis()
                ),
            ))
        }
        _ => Ok(()),
    }
}

/// Maps a [`StatementError`] into a [`DocumentDBError`], applying the same
/// context-aware Postgres error mapping used elsewhere in this module for the
/// raw Postgres variant and surfacing a deadline expiry as an exceeded time
/// limit.
fn map_statement_error(
    error: StatementError,
    in_transaction: bool,
    is_replica_cluster: bool,
    activity_id: &str,
) -> DocumentDBError {
    match error {
        StatementError::Postgres(e) => {
            map_pg_error(e, in_transaction, is_replica_cluster, activity_id)
        }
        StatementError::Timeout(duration) => DocumentDBError::documentdb_error(
            ErrorCode::ExceededTimeLimit,
            format!("Statement timed out after {duration:?}"),
        ),
    }
}

/// Sets the `PostgreSQL` statement timeout
///
/// Returns `true` if a gateway transaction was started (caller must COMMIT/ROLLBACK).
async fn set_statement_timeout(
    connection: &Connection,
    max_time: Option<Duration>,
    query_options: &QueryOptions,
    in_user_transaction: bool,
    request_tracker: &RequestTracker,
) -> std::result::Result<bool, StatementError> {
    let max_time_ms = match max_time {
        Some(d) if !in_user_transaction && !query_options.supports_backend_timeout() => {
            d.as_millis()
        }
        _ => return Ok(false),
    };

    // Determine whether to wrap in a gateway transaction.
    // Since in_user_transaction == false here (checked above), we either
    // use BEGIN + SET LOCAL (supports_transaction_timeout) or session-level SET.
    let use_transaction = query_options.supports_transaction_timeout();

    // Start a gateway transaction if needed
    if use_transaction {
        let start = Instant::now();
        // Marked before the statement is issued. If the request is cancelled
        // while `BEGIN` is in flight the server may still have started the
        // transaction, and only a set flag triggers the rollback that keeps the
        // connection from being released to the pool dirty.
        connection.set_in_transaction(true);
        connection.batch_execute("BEGIN").await?;
        request_tracker.record_duration(RequestIntervalKind::PostgresBeginTransaction, start);
    }

    // SET [LOCAL] statement_timeout
    let set_cmd = if use_transaction {
        format!("set local statement_timeout to {max_time_ms}")
    } else {
        // A session-level setting outlives this request, so the pool must
        // reset it before the connection serves another borrower.
        connection.mark_session_state_modified();
        format!("set statement_timeout to {max_time_ms}")
    };

    let set_start = Instant::now();
    if let Err(e) = connection.batch_execute(&set_cmd).await {
        // Only clear the flag once the ROLLBACK is acknowledged. Clearing it
        // after a failed ROLLBACK would suppress the backstop rollback in
        // `Connection::drop` and return a connection with an open transaction
        // to the pool.
        if use_transaction && connection.batch_execute("ROLLBACK").await.is_ok() {
            connection.set_in_transaction(false);
        }
        return Err(e);
    }
    request_tracker.record_duration(RequestIntervalKind::PostgresSetStatementTimeout, set_start);

    Ok(use_transaction)
}

/// Executes a query with default acquisition, timeout and retry handling.
///
/// # Errors
/// Returns the terminal acquisition or statement error.
pub fn run_request_with_retries<'a, 'request, T, F, Fut>(
    source: ConnectionSource<'a>,
    query_options: QueryOptions,
    request_options: RequestOptions,
    max_time: Duration,
    dynamic_configuration: &'a dyn DynamicConfiguration,
    request_context: &'a RequestContext<'request>,
    run_func: F,
) -> impl Future<Output = Result<T>> + use<'a, 'request, T, F, Fut>
where
    F: Fn(Arc<Connection>) -> Fut,
    Fut: Future<Output = std::result::Result<T, StatementError>>,
{
    run_request_with_retries_using(
        query_options,
        request_options,
        max_time,
        dynamic_configuration,
        request_context,
        source.is_transaction(),
        source,
        async |source: &ConnectionSource<'_>, _, tracker: &RequestTracker| {
            source.acquire(tracker).await
        },
        run_func,
        |_| QueryFailureAction::UseRetryPolicy,
    )
}

/// Executes a query with caller-supplied acquisition and failure handling.
///
/// Owns the acquisition state and borrows it on each attempt.
/// `QueryFailureAction::Return` bypasses retries and terminal timeout/shutdown conversion.
/// Acquisition errors and mapped statement errors both reach the failure policy;
/// the original backend error remains available through the error's source.
///
/// The caller must preserve retained connection ownership, supply the correct
/// transaction state, and honor the requested timeout-pool choice. Returning a
/// failure does not itself authorize replay against another connection.
/// Request authentication remains the caller's responsibility.
///
/// # Errors
/// Returns an acquisition, statement or timeout error.
#[expect(
    clippy::too_many_arguments,
    reason = "keeps acquisition and failure policies independent of execution inputs"
)]
#[cfg_attr(
    feature = "request-tracing",
    tracing::instrument(
        name = "postgres.execute",
        skip_all,
        fields(
            span.kind = "client",
            span.status_code = tracing::field::Empty,
            span.status_message = tracing::field::Empty,
            db.system.name = "postgresql",
            retry.count = tracing::field::Empty,
        )
    )
)]
pub async fn run_request_with_retries_using<T, F, Fut, S, A, H>(
    query_options: QueryOptions,
    request_options: RequestOptions,
    max_time: Duration,
    dynamic_configuration: &dyn DynamicConfiguration,
    request_context: &RequestContext<'_>,
    in_transaction: bool,
    acquisition_state: S,
    acquire: A,
    mut run_func: F,
    on_failure: H,
) -> Result<T>
where
    F: FnMut(Arc<Connection>) -> Fut,
    Fut: Future<Output = std::result::Result<T, StatementError>>,
    A: AsyncFn(&S, bool, &RequestTracker) -> Result<Arc<Connection>>,
    H: Fn(&DocumentDBError) -> QueryFailureAction,
{
    let overall_command_timeout = request_options.command_timeout().unwrap_or(max_time);

    let mut retry_context = RetryContext {
        stopwatch: Instant::now(),
        retry_count: 0,
        short_retry_policy: None,
        long_retry_policy: None,
    };

    // Pre-compute whether set_statement_timeout can ever apply. When false
    // (the common path) we skip the function call entirely on every iteration.
    let needs_gateway_timeout = request_options.command_timeout().is_some()
        && !in_transaction
        && !query_options.supports_backend_timeout();
    let needs_timeout_pool = needs_gateway_timeout && !query_options.supports_transaction_timeout();
    let tracker = request_context.tracker;

    loop {
        let result = match acquire(&acquisition_state, needs_timeout_pool, tracker).await {
            Ok(connection) => {
                execute_on_connection(
                    connection,
                    query_options,
                    request_options,
                    in_transaction,
                    needs_gateway_timeout,
                    request_context,
                    &mut run_func,
                )
                .await
            }
            Err(error) => Err(error),
        };

        // Handle result / retry
        match result {
            Ok(value) => return Ok(value),

            Err(error) => {
                if on_failure(&error) == QueryFailureAction::Return {
                    mark_span_error(&tracing::Span::current());
                    return Err(error);
                }
                tracing::error!("Error executing postgres request: {error}");

                // a request is retriable if:
                // - it is a retriable error,
                // - we haven't exhausted retries
                // - it is retriable on a transient error, which means that it's not in a transaction.
                if let Some(retry) = retry_for(&error, query_options, request_options) {
                    if in_transaction {
                        if !matches!(retry, Retry::None) {
                            tracing::info!(
                                "Error is retriable ({retry:?}), but not getting retried \
                                     due to the request being in a transaction."
                            );
                        }
                    } else if query_options.retry_request()
                        && retry_context.stopwatch.elapsed() < overall_command_timeout
                    {
                        if let Some(interval) = get_retry_interval(&retry, &mut retry_context) {
                            // The point where a retry is due is also the point
                            // where it can be sent elsewhere. A caller that has
                            // somewhere else to send it takes over here rather
                            // than spending the rest of the deadline on a
                            // backend that just failed.
                            if dynamic_configuration.defer_retries_to_caller() {
                                tracing::warn!(
                                    attempted = retry_context.retry_count + 1,
                                    elapsed_ms = u64::try_from(
                                        retry_context.stopwatch.elapsed().as_millis()
                                    )
                                    .unwrap_or(u64::MAX),
                                    "Not retrying here so the request can be reissued elsewhere: {error}"
                                );
                                mark_span_error(&tracing::Span::current());
                                return Err(DocumentDBError::documentdb_error(
                                    ErrorCode::ShutdownInProgress,
                                    "Graceful shutdown requested".to_owned(),
                                ));
                            }

                            retry_context.retry_count += 1;
                            tracing::Span::current()
                                .record("retry.count", retry_context.retry_count);
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

                if let Err(timeout_error) = check_for_command_timeout_error(
                    &request_options,
                    retry_context.stopwatch.elapsed(),
                ) {
                    mark_span_error(&tracing::Span::current());
                    return Err(timeout_error);
                }

                mark_span_error(&tracing::Span::current());
                return Err(map_shutdown_connectivity_error(
                    extract_pg_error(&error),
                    dynamic_configuration,
                )
                .unwrap_or(error));
            }
        }
    }
}

async fn execute_on_connection<T, F, Fut>(
    connection: Arc<Connection>,
    query_options: QueryOptions,
    request_options: RequestOptions,
    in_transaction: bool,
    needs_gateway_timeout: bool,
    request_context: &RequestContext<'_>,
    run_func: &mut F,
) -> Result<T>
where
    F: FnMut(Arc<Connection>) -> Fut,
    Fut: Future<Output = std::result::Result<T, StatementError>>,
{
    let result = 'attempt: {
        connection.set_command_deadline(request_options.command_timeout());
        let in_gateway_txn = if needs_gateway_timeout {
            match set_statement_timeout(
                &connection,
                request_options.command_timeout(),
                &query_options,
                in_transaction,
                request_context.tracker,
            )
            .await
            {
                Ok(started) => started,
                Err(error) => {
                    break 'attempt Err(map_statement_error(
                        error,
                        in_transaction,
                        request_options.in_replica_cluster_mode(),
                        request_context.activity_id,
                    ));
                }
            }
        } else {
            false
        };

        let started = Instant::now();
        if !in_gateway_txn {
            let result = run_func(connection).await;
            request_context
                .tracker
                .record_duration(RequestIntervalKind::ProcessRequest, started);
            break 'attempt result.map_err(|error| {
                map_statement_error(
                    error,
                    in_transaction,
                    request_options.in_replica_cluster_mode(),
                    request_context.activity_id,
                )
            });
        }

        let result = run_func(Arc::clone(&connection)).await;
        request_context
            .tracker
            .record_duration(RequestIntervalKind::ProcessRequest, started);
        match result {
            Ok(value) => {
                let commit_start = Instant::now();
                let committed = connection.batch_execute("COMMIT").await;
                connection.set_in_transaction(false);
                match committed {
                    Ok(()) => {
                        request_context.tracker.record_duration(
                            RequestIntervalKind::PostgresCommitTransaction,
                            commit_start,
                        );
                        Ok(value)
                    }
                    Err(error) => Err(map_statement_error(
                        error,
                        in_transaction,
                        request_options.in_replica_cluster_mode(),
                        request_context.activity_id,
                    )),
                }
            }
            Err(error) => {
                if connection.batch_execute("ROLLBACK").await.is_ok() {
                    connection.set_in_transaction(false);
                }
                Err(map_statement_error(
                    error,
                    in_transaction,
                    request_options.in_replica_cluster_mode(),
                    request_context.activity_id,
                ))
            }
        }
    };
    result
}

#[cfg(test)]
mod tests {
    use std::{
        cell::Cell,
        sync::atomic::{AtomicBool, AtomicUsize, Ordering},
    };

    use bson::rawdoc;
    use tokio::net::TcpListener;
    use tokio_postgres::NoTls;

    use super::*;
    use crate::{
        error::ErrorKind,
        requests::{RequestExecutionMode, RequestType, WireRequest},
        testing::TestDynamicConfiguration,
    };

    fn execution_request() -> WireRequest<'static> {
        WireRequest::from_owned_command_document(
            RequestType::Ping,
            RequestExecutionMode::Normal,
            None,
            rawdoc! { "ping": 1, "$db": "admin" },
            None,
        )
        .unwrap()
    }

    #[tokio::test]
    async fn extraction_preserves_send_only_query_closures() {
        fn require_send<T: Send>(value: T) -> T {
            value
        }

        let request = execution_request();
        let tracker = RequestTracker::new();
        let context = RequestContext::new("", &request, &tracker);
        let configuration = TestDynamicConfiguration::default();
        let count = Cell::new(0);
        let future = run_request_with_retries_using(
            QueryOptions::default(),
            RequestOptions::new(false, Some(1_000)),
            Duration::from_secs(1),
            &configuration,
            &context,
            false,
            (),
            |(): &(), _, _: &RequestTracker| {
                std::future::ready(Err(DocumentDBError::bad_value("stop".to_owned())))
            },
            move |_| {
                count.set(count.get() + 1);
                std::future::ready(Err::<(), _>(StatementError::Timeout(Duration::ZERO)))
            },
            |_| QueryFailureAction::Return,
        );
        assert!(require_send(future).await.is_err());
    }

    #[tokio::test]
    async fn execution_reacquires_for_each_retry_without_dispatching_on_open_failure() {
        let request = execution_request();
        let tracker = RequestTracker::new();
        let context = RequestContext::new("", &request, &tracker);
        let configuration = TestDynamicConfiguration::default();
        let acquisitions = Arc::new(AtomicUsize::new(0));
        let queries = AtomicUsize::new(0);
        let result = run_request_with_retries_using(
            QueryOptions::default(),
            RequestOptions::new(false, Some(1_000)),
            Duration::from_secs(1),
            &configuration,
            &context,
            false,
            Arc::clone(&acquisitions),
            async |state: &Arc<AtomicUsize>, _, _: &RequestTracker| {
                tokio::task::yield_now().await;
                if state.fetch_add(1, Ordering::Relaxed) == 0 {
                    Err(DocumentDBError::from(PoolError::Timeout(
                        TimeoutType::Create,
                    )))
                } else {
                    Err(DocumentDBError::bad_value(
                        "terminal acquisition error".to_owned(),
                    ))
                }
            },
            |_| async {
                queries.fetch_add(1, Ordering::Relaxed);
                Err::<(), _>(StatementError::Timeout(Duration::ZERO))
            },
            |_| QueryFailureAction::UseRetryPolicy,
        )
        .await;
        assert_eq!(acquisitions.load(Ordering::Relaxed), 2);
        assert_eq!(queries.load(Ordering::Relaxed), 0);
        assert_eq!(
            result.unwrap_err().error_message_user(),
            "terminal acquisition error"
        );
    }

    #[test]
    fn dropping_execution_releases_owned_acquisition_state() {
        use std::task::{Context, Waker};

        struct AcquisitionState(Arc<AtomicUsize>);

        impl Drop for AcquisitionState {
            fn drop(&mut self) {
                self.0.fetch_add(1, Ordering::Relaxed);
            }
        }

        let request = execution_request();
        let tracker = RequestTracker::new();
        let context = RequestContext::new("", &request, &tracker);
        let configuration = TestDynamicConfiguration::default();

        for poll_once in [false, true] {
            let dropped = Arc::new(AtomicUsize::new(0));
            let acquired = AtomicBool::new(false);
            {
                let future = run_request_with_retries_using(
                    QueryOptions::default(),
                    RequestOptions::new(false, None),
                    Duration::from_secs(1),
                    &configuration,
                    &context,
                    false,
                    AcquisitionState(Arc::clone(&dropped)),
                    async |state: &AcquisitionState, _, _: &RequestTracker| {
                        acquired.store(true, Ordering::Relaxed);
                        std::future::pending::<()>().await;
                        assert_eq!(state.0.load(Ordering::Relaxed), 0);
                        Err(DocumentDBError::bad_value("unreachable".to_owned()))
                    },
                    |_| async { Ok(42) },
                    |_| QueryFailureAction::UseRetryPolicy,
                );
                let mut future = std::pin::pin!(future);
                assert!(!acquired.load(Ordering::Relaxed));
                assert_eq!(dropped.load(Ordering::Relaxed), 0);
                if poll_once {
                    assert!(future
                        .as_mut()
                        .poll(&mut Context::from_waker(Waker::noop()))
                        .is_pending());
                    assert!(acquired.load(Ordering::Relaxed));
                }
            }
            assert_eq!(dropped.load(Ordering::Relaxed), 1);
        }
    }

    #[tokio::test]
    async fn unpolled_local_execution_is_send_and_does_not_acquire() {
        use crate::{
            postgres::{conn_mgmt::PgPoolSettings, create_query_catalog},
            testing::test_setup_configuration,
        };

        fn require_send<T: Send>(value: T) -> T {
            value
        }

        let setup = test_setup_configuration();
        let pool = ConnectionPool::new_with_user(
            &setup,
            &create_query_catalog(),
            "user",
            None,
            "test",
            PgPoolSettings::system_pool_settings(1),
        )
        .unwrap();
        let request = execution_request();
        let tracker = RequestTracker::new();
        let context = RequestContext::new("", &request, &tracker);
        let configuration = TestDynamicConfiguration::default();
        let count = Cell::new(0);
        let future = require_send(run_request_with_retries(
            ConnectionSource::Pool(&pool),
            QueryOptions::default(),
            RequestOptions::new(false, None),
            Duration::from_secs(1),
            &configuration,
            &context,
            move |_| {
                count.set(count.get() + 1);
                std::future::ready(Ok(42))
            },
        ));
        assert_eq!(pool.status().connections_created(), 0);
        drop(future);
        assert_eq!(pool.status().connections_created(), 0);
    }

    #[tokio::test]
    async fn returning_a_failure_preserves_its_source_and_does_not_retry_or_defer() {
        let request = execution_request();
        let tracker = RequestTracker::new();
        let context = RequestContext::new("", &request, &tracker);
        let configuration = TestDynamicConfiguration::default();
        configuration.set_defer_retries_to_caller(true);
        let acquisitions = AtomicUsize::new(0);
        let error = run_request_with_retries_using(
            QueryOptions::default(),
            RequestOptions::new(false, Some(0)),
            Duration::ZERO,
            &configuration,
            &context,
            false,
            (),
            |(): &(), _, _: &RequestTracker| async {
                acquisitions.fetch_add(1, Ordering::Relaxed);
                Err(DocumentDBError::from(PoolError::Timeout(
                    TimeoutType::Create,
                )))
            },
            |_| async { Err::<(), _>(StatementError::Timeout(Duration::ZERO)) },
            |_| QueryFailureAction::Return,
        )
        .await
        .unwrap_err();
        assert_eq!(acquisitions.load(Ordering::Relaxed), 1);
        assert!(matches!(
            error.as_pool_error(),
            Some(PoolError::Timeout(TimeoutType::Create))
        ));
        assert_ne!(error.error_code(), ErrorCode::ShutdownInProgress);
        assert_eq!(error.error_code(), ErrorCode::ExceededTimeLimit);
        assert_eq!(error.kind(), &ErrorKind::Pool);
        assert_eq!(
            error.error_message_user(),
            "Timed out while acquiring a database connection."
        );
    }

    #[tokio::test]
    async fn default_failure_policy_preserves_shutdown_handoff() {
        let request = execution_request();
        let tracker = RequestTracker::new();
        let context = RequestContext::new("", &request, &tracker);
        let configuration = TestDynamicConfiguration::default();
        configuration.set_defer_retries_to_caller(true);
        let error = run_request_with_retries_using(
            QueryOptions::default(),
            RequestOptions::new(false, Some(1_000)),
            Duration::from_secs(1),
            &configuration,
            &context,
            false,
            (),
            |(): &(), _, _: &RequestTracker| async {
                Err(DocumentDBError::from(PoolError::Timeout(
                    TimeoutType::Create,
                )))
            },
            |_| async { Err::<(), _>(StatementError::Timeout(Duration::ZERO)) },
            |_| QueryFailureAction::UseRetryPolicy,
        )
        .await
        .unwrap_err();
        assert_eq!(error.error_code(), ErrorCode::ShutdownInProgress);
        assert_eq!(error.error_message_user(), "Graceful shutdown requested");
    }

    #[tokio::test]
    async fn transactions_and_nonretryable_commands_do_not_reacquire() {
        let request = execution_request();
        let tracker = RequestTracker::new();
        let context = RequestContext::new("", &request, &tracker);
        let configuration = TestDynamicConfiguration::default();
        for (in_transaction, retry_request) in [(true, true), (false, false)] {
            let acquisitions = AtomicUsize::new(0);
            let error = run_request_with_retries_using(
                QueryOptions::builder().retry_request(retry_request).build(),
                RequestOptions::new(false, Some(1_000)),
                Duration::from_secs(1),
                &configuration,
                &context,
                in_transaction,
                (),
                |(): &(), _, _: &RequestTracker| async {
                    acquisitions.fetch_add(1, Ordering::Relaxed);
                    Err(DocumentDBError::from(PoolError::Timeout(
                        TimeoutType::Create,
                    )))
                },
                |_| async { Err::<(), _>(StatementError::Timeout(Duration::ZERO)) },
                |_| QueryFailureAction::UseRetryPolicy,
            )
            .await
            .unwrap_err();
            assert_eq!(acquisitions.load(Ordering::Relaxed), 1);
            assert!(error.as_pool_error().is_some());
        }
    }

    #[tokio::test]
    async fn acquisition_receives_the_existing_timeout_source_choice() {
        let request = execution_request();
        let tracker = RequestTracker::new();
        let context = RequestContext::new("", &request, &tracker);
        let configuration = TestDynamicConfiguration::default();
        for (backend_timeout, transaction_timeout, timeout_ms, in_transaction, expected) in [
            (true, false, Some(100), false, false),
            (false, true, Some(100), false, false),
            (false, false, Some(100), false, true),
            (false, false, None, false, false),
            (false, false, Some(100), true, false),
        ] {
            let observed = AtomicBool::new(!expected);
            let result = run_request_with_retries_using(
                QueryOptions::builder()
                    .supports_backend_timeout(backend_timeout)
                    .supports_transaction_timeout(transaction_timeout)
                    .build(),
                RequestOptions::new(false, timeout_ms),
                Duration::from_secs(1),
                &configuration,
                &context,
                in_transaction,
                (),
                |(): &(), use_timeout_pool, _: &RequestTracker| {
                    observed.store(use_timeout_pool, Ordering::Relaxed);
                    async { Err(DocumentDBError::bad_value("stop".to_owned())) }
                },
                |_| async { Err::<(), _>(StatementError::Timeout(Duration::ZERO)) },
                |_| QueryFailureAction::Return,
            )
            .await;
            assert!(result.is_err());
            assert_eq!(observed.load(Ordering::Relaxed), expected);
        }
    }

    async fn mapped_connectivity_error() -> DocumentDBError {
        let listener = TcpListener::bind(("127.0.0.1", 0)).await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let accept_task = tokio::spawn(async move {
            let (socket, _) = listener.accept().await.unwrap();
            drop(socket);
        });

        let connection_string = format!("host=127.0.0.1 port={port} user=test connect_timeout=1");
        let Err(pg_error) = tokio_postgres::connect(&connection_string, NoTls).await else {
            panic!("connection should fail when the server closes during startup");
        };
        accept_task.await.unwrap();
        assert!(is_connectivity_error(&pg_error));

        map_pg_error(pg_error, false, false, "")
    }

    fn default_query_context() -> QueryOptions {
        QueryOptions::default()
    }

    fn deadlock_retry_query_context() -> QueryOptions {
        QueryOptions::builder().retry_deadlock(true).build()
    }

    fn non_replica_options() -> RequestOptions {
        RequestOptions::new(false, Some(30))
    }

    fn replica_options() -> RequestOptions {
        RequestOptions::new(true, Some(30))
    }

    #[test]
    fn giving_up_while_building_a_connection_is_retried_like_a_transport_timeout() {
        let error = DocumentDBError::from(PoolError::Timeout(TimeoutType::Create));

        assert!(matches!(
            retry_for(&error, default_query_context(), non_replica_options()),
            Some(Retry::Short)
        ));
    }

    #[test]
    fn waiting_for_a_free_connection_still_ends_the_request() {
        let error = DocumentDBError::from(PoolError::Timeout(TimeoutType::Wait));

        assert!(retry_for(&error, default_query_context(), non_replica_options()).is_none());
    }

    #[tokio::test]
    async fn test_shutdown_connectivity_error_when_enabled_returns_shutdown_in_progress() {
        let error = mapped_connectivity_error().await;
        let dynamic_configuration = TestDynamicConfiguration::default();
        dynamic_configuration.set_send_shutdown_responses(true);

        let error =
            map_shutdown_connectivity_error(extract_pg_error(&error), &dynamic_configuration)
                .expect("connectivity error should be mapped when shutdown responses are enabled");

        assert_eq!(error.error_code(), ErrorCode::ShutdownInProgress);
        assert_eq!(error.error_message_user(), "Graceful shutdown requested");
    }

    #[tokio::test]
    async fn test_shutdown_connectivity_error_when_disabled_preserves_error() {
        let error = mapped_connectivity_error().await;
        let dynamic_configuration = TestDynamicConfiguration::default();

        let shutdown_error =
            map_shutdown_connectivity_error(extract_pg_error(&error), &dynamic_configuration);

        assert!(shutdown_error.is_none());
        assert_eq!(error.error_code(), ErrorCode::InternalError);
        assert_eq!(error.kind(), &ErrorKind::Gateway);
        assert!(error.as_postgres_error().is_some());
    }

    // ── is_transient_io_error ──────────────────────────────────────────

    #[test]
    fn test_is_transient_io_error_with_timed_out_returns_true() {
        assert!(is_transient_backend_io_error(io::ErrorKind::TimedOut));
    }

    #[test]
    fn test_is_transient_io_error_with_connection_reset_returns_true() {
        assert!(is_transient_backend_io_error(
            io::ErrorKind::ConnectionReset
        ));
    }

    #[test]
    fn test_is_transient_io_error_with_connection_aborted_returns_true() {
        assert!(is_transient_backend_io_error(
            io::ErrorKind::ConnectionAborted
        ));
    }

    #[test]
    fn test_is_transient_io_error_with_not_connected_returns_true() {
        assert!(is_transient_backend_io_error(io::ErrorKind::NotConnected));
    }

    #[test]
    fn test_is_transient_io_error_with_broken_pipe_returns_true() {
        assert!(is_transient_backend_io_error(io::ErrorKind::BrokenPipe));
    }

    #[test]
    fn test_is_transient_io_error_with_unexpected_eof_returns_true() {
        assert!(is_transient_backend_io_error(io::ErrorKind::UnexpectedEof));
    }

    #[test]
    fn test_is_transient_io_error_with_permission_denied_returns_false() {
        assert!(!is_transient_backend_io_error(
            io::ErrorKind::PermissionDenied
        ));
    }

    #[test]
    fn test_is_transient_io_error_with_not_found_returns_false() {
        assert!(!is_transient_backend_io_error(io::ErrorKind::NotFound));
    }

    #[test]
    fn test_is_transient_io_error_with_addr_in_use_returns_false() {
        assert!(!is_transient_backend_io_error(io::ErrorKind::AddrInUse));
    }

    #[test]
    fn test_is_transient_io_error_with_would_block_returns_false() {
        assert!(!is_transient_backend_io_error(io::ErrorKind::WouldBlock));
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

    #[test]
    fn test_command_timeout_error_with_timeout_disabled_returns_none() {
        let result = check_for_command_timeout_error(
            &RequestOptions::new(false, None),
            Duration::from_secs(1),
        );

        result.unwrap();
    }

    #[test]
    fn test_command_timeout_error_with_elapsed_below_timeout_returns_none() {
        let result = check_for_command_timeout_error(
            &RequestOptions::new(false, Some(30)),
            Duration::from_millis(29),
        );

        result.unwrap();
    }

    #[test]
    fn test_command_timeout_error_with_elapsed_at_timeout_returns_exceeded_time_limit() {
        let error = check_for_command_timeout_error(
            &RequestOptions::new(false, Some(30)),
            Duration::from_millis(30),
        )
        .unwrap_err();

        assert_eq!(error.error_code(), ErrorCode::ExceededTimeLimit);
        assert!(error
            .to_string()
            .contains("Query exceeded command timeout of 30ms"));
    }

    #[test]
    fn test_command_timeout_error_with_zero_timeout_returns_exceeded_time_limit() {
        let error = check_for_command_timeout_error(
            &RequestOptions::new(false, Some(1)),
            Duration::from_millis(1),
        )
        .unwrap_err();

        assert_eq!(error.error_code(), ErrorCode::ExceededTimeLimit);
    }
}
