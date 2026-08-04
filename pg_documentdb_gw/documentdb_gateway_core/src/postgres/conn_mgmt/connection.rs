/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/connection.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    future::Future,
    sync::atomic::{AtomicBool, AtomicU64, Ordering},
    time::Duration,
};

use tokio_postgres::{
    types::{ToSql, Type},
    Row,
};

use crate::{
    postgres::{conn_mgmt::PoolConnection, PgDocument},
    telemetry::sql_commenter,
};

/// Failure executing a SQL statement against the backend: either the backend
/// rejected the statement or the connection's deadline expired first.
#[derive(Debug)]
pub enum StatementError {
    /// A raw `PostgreSQL` error, left unmapped so callers can apply their own
    /// error-mapping context.
    Postgres(tokio_postgres::Error),
    /// The statement did not complete within the connection's deadline.
    Timeout(Duration),
}

impl std::fmt::Display for StatementError {
    #[expect(
        clippy::use_debug,
        reason = "Duration has no Display implementation; Debug is its standard representation"
    )]
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Postgres(e) => e.fmt(f),
            Self::Timeout(d) => write!(f, "statement timed out after {d:?}"),
        }
    }
}

impl std::error::Error for StatementError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Postgres(e) => Some(e),
            Self::Timeout(_) => None,
        }
    }
}

impl From<tokio_postgres::Error> for StatementError {
    fn from(error: tokio_postgres::Error) -> Self {
        Self::Postgres(error)
    }
}

/// Floor for a client-side deadline derived from a request timeout.
///
/// A sub-second deadline would reliably beat the backend's own
/// `statement_timeout` for the same request, costing the connection and the
/// server's descriptive error in exchange for nothing.
const MIN_COMMAND_DEADLINE: Duration = Duration::from_secs(1);

/// Saturating conversion for storing a deadline in an [`AtomicU64`]. A duration
/// beyond `u64::MAX` nanoseconds (~584 years) clamps to "effectively never".
fn duration_to_nanos(duration: Duration) -> u64 {
    u64::try_from(duration.as_nanos()).unwrap_or(u64::MAX)
}

// Provides functions which coerce bson to BYTEA. Any statement binding a PgDocument should use query_typed and not query
// WrongType { postgres: Other(Other { name: "bson", oid: 18934, kind: Simple, schema: "schema_name" }), rust: "document_gateway::postgres::document::PgDocument" })
// Will be occur if the wrong one is used.
#[derive(Debug)]
pub struct Connection {
    /// `None` only while [`Drop`] disposes of it: both releasing and closing a
    /// pooled object take it by value.
    inner: Option<PoolConnection>,
    /// Whether a transaction is active. Atomic because `Connection` lives
    /// behind `Arc` and the gateway timeout layer may begin one after
    /// construction.
    in_transaction: AtomicBool,
    /// Nanoseconds of the deadline a statement was abandoned at, or `0` while
    /// healthy. Deadlines are floored at [`MIN_COMMAND_DEADLINE`], so a real
    /// one is never `0`. See [`Self::with_command_deadline`].
    abandoned_deadline_nanos: AtomicU64,
    /// Whether sampled queries on this connection should carry a `SQLCommenter`
    /// `traceparent` comment for Postgres log correlation. Inherited from the
    /// owning pool's telemetry configuration.
    sql_commenter_enabled: bool,
    /// Nanoseconds of the deadline for the current request; see
    /// [`Self::set_command_deadline`].
    command_deadline_nanos: AtomicU64,
    /// Deadline to fall back to for a request that carries no timeout of its
    /// own. Inherited from the owning pool and never changes.
    default_command_deadline: Duration,
}

impl Connection {
    #[must_use]
    pub fn new(
        pool_connection: PoolConnection,
        in_transaction: bool,
        sql_commenter_enabled: bool,
        command_deadline: Duration,
    ) -> Self {
        Self {
            inner: Some(pool_connection),
            in_transaction: AtomicBool::new(in_transaction),
            abandoned_deadline_nanos: AtomicU64::new(0),
            sql_commenter_enabled,
            command_deadline_nanos: AtomicU64::new(duration_to_nanos(command_deadline)),
            default_command_deadline: command_deadline,
        }
    }

    pub fn in_transaction(&self) -> bool {
        self.in_transaction.load(Ordering::Relaxed)
    }

    /// Mark the connection as being inside (or outside) a transaction.
    ///
    /// Called by the gateway timeout layer after issuing `BEGIN` so that
    /// downstream closures can avoid issuing a redundant `BEGIN`.
    pub fn set_in_transaction(&self, value: bool) {
        self.in_transaction.store(value, Ordering::Relaxed);
    }

    /// Atomically start a transaction if one is not already active.
    ///
    /// Returns `true` if this call successfully transitioned the flag from
    /// `false` to `true`, indicating the caller should proceed with `START TRANSACTION`.
    /// Returns `false` if the flag was already `true`, indicating another caller
    /// or the timeout layer has already started a transaction.
    pub fn try_start_transaction(&self) -> bool {
        self.in_transaction
            .compare_exchange(false, true, Ordering::Relaxed, Ordering::Relaxed)
            .is_ok()
    }

    /// The pooled connection backing this handle.
    ///
    /// Only [`Drop`] ever clears the slot, and it takes `&mut self`, so no
    /// shared-reference method can observe it empty.
    #[expect(
        clippy::expect_used,
        reason = "Drop is the sole consumer of the slot and holds &mut self, so this is unreachable"
    )]
    const fn client(&self) -> &PoolConnection {
        self.inner
            .as_ref()
            .expect("pooled connection is taken only while dropping")
    }

    /// Client-side deadline currently applied to statements on this connection.
    pub fn command_deadline(&self) -> Duration {
        Duration::from_nanos(self.command_deadline_nanos.load(Ordering::Relaxed))
    }

    /// Sets the client-side deadline for the request about to run, falling back
    /// to the pool default when the request carries none. Floored at
    /// [`MIN_COMMAND_DEADLINE`].
    ///
    /// Assigned, not accumulated: a cursor or transaction connection outlives
    /// the request that opened it and must not carry a neighbour's bound.
    pub fn set_command_deadline(&self, request_timeout: Option<Duration>) {
        let deadline = request_timeout.map_or(self.default_command_deadline, |timeout| {
            timeout.max(MIN_COMMAND_DEADLINE)
        });
        self.command_deadline_nanos
            .store(duration_to_nanos(deadline), Ordering::Relaxed);
    }

    /// Runs `statement` under the connection's client-side deadline.
    ///
    /// Abandoning a statement does not cancel it: the backend keeps working and
    /// the driver queues anything sent after it. The connection is marked for
    /// disposal, and every later statement fails immediately rather than
    /// queueing behind work it cannot beat.
    async fn with_command_deadline<T>(
        &self,
        statement: impl Future<Output = std::result::Result<T, StatementError>>,
    ) -> std::result::Result<T, StatementError> {
        if let Some(abandoned) = self.abandoned_deadline() {
            return Err(StatementError::Timeout(abandoned));
        }

        let deadline = self.command_deadline();
        let Ok(result) = tokio::time::timeout(deadline, statement).await else {
            self.abandoned_deadline_nanos
                .store(duration_to_nanos(deadline), Ordering::Relaxed);
            return Err(StatementError::Timeout(deadline));
        };
        result
    }

    /// The deadline a statement was abandoned at, if this connection has one
    /// and can therefore no longer carry statements.
    fn abandoned_deadline(&self) -> Option<Duration> {
        match self.abandoned_deadline_nanos.load(Ordering::Relaxed) {
            0 => None,
            nanos => Some(Duration::from_nanos(nanos)),
        }
    }

    /// Executes a parameterized query and returns all resulting rows.
    ///
    /// Bounded by the connection's deadline; see
    /// [`Self::set_command_deadline`].
    ///
    /// # Errors
    /// Returns [`StatementError::Postgres`] if preparing or executing the query
    /// fails, or [`StatementError::Timeout`] if the deadline expires first.
    pub async fn query(
        &self,
        query: &str,
        parameter_types: &[Type],
        params: &[&(dyn ToSql + Sync)],
    ) -> std::result::Result<Vec<Row>, StatementError> {
        self.with_command_deadline(self.query_unbounded(query, parameter_types, params))
            .await
    }

    async fn query_unbounded(
        &self,
        query: &str,
        parameter_types: &[Type],
        params: &[&(dyn ToSql + Sync)],
    ) -> std::result::Result<Vec<Row>, StatementError> {
        if self.sql_commenter_enabled && parameter_types.len() == params.len() {
            if let Some(comment) = sql_commenter::current_trace_comment() {
                // A per-request comment changes the statement text, so execute it
                // as an ephemeral unnamed statement rather than caching it. This
                // keeps the prepared-statement cache free of high-cardinality,
                // single-use entries while still binding parameters by type.
                let commented = format!("{query} {comment}");
                let typed_params: Vec<(&(dyn ToSql + Sync), Type)> = params
                    .iter()
                    .copied()
                    .zip(parameter_types.iter().cloned())
                    .collect();
                return self
                    .client()
                    .query_typed(&commented, &typed_params)
                    .await
                    .map_err(StatementError::Postgres);
            }
        }

        let statement = self
            .client()
            .prepare_typed_cached(query, parameter_types)
            .await?;

        self.client()
            .query(&statement, params)
            .await
            .map_err(StatementError::Postgres)
    }

    /// # Errors
    /// Returns error if the operation fails.
    pub async fn query_db_bson(
        &self,
        query: &str,
        db: &str,
        bson: &PgDocument<'_>,
    ) -> std::result::Result<Vec<Row>, StatementError> {
        self.query(query, &[Type::TEXT, Type::BYTEA], &[&db, bson])
            .await
    }

    /// Executes one or more SQL statements without returning rows.
    ///
    /// The call is bounded by the connection's deadline: statement execution is
    /// also limited server-side by `statement_timeout`, but that does not cover
    /// a connection that stops responding, and callers such as the drop-time
    /// rollback have no request deadline above them.
    ///
    /// # Errors
    /// Returns [`StatementError::Postgres`] if execution fails, or
    /// [`StatementError::Timeout`] if the deadline expires first.
    pub async fn batch_execute(&self, query: &str) -> std::result::Result<(), StatementError> {
        self.with_command_deadline(async {
            self.client()
                .batch_execute(query)
                .await
                .map_err(StatementError::Postgres)
        })
        .await
    }
}

impl Drop for Connection {
    /// `RecyclingMethod::Fast` only checks that the socket is open, so this is
    /// the last place a connection unsafe to reuse can be caught.
    ///
    /// An abandoned statement is closed — that aborts the backend's work,
    /// including any open transaction. An open transaction alone is rolled back
    /// from a spawned task, since `Drop` cannot await.
    fn drop(&mut self) {
        let Some(connection) = self.inner.take() else {
            return;
        };

        if self.abandoned_deadline().is_some() {
            drop(PoolConnection::take(connection));
            return;
        }

        if !self.in_transaction() {
            return;
        }

        let Ok(handle) = tokio::runtime::Handle::try_current() else {
            // Closing is the only option left that cannot leak the open
            // transaction into the pool.
            tracing::error!("No runtime available to roll back abandoned transaction; closing it");
            drop(PoolConnection::take(connection));
            return;
        };

        // The pool default, not the last request's: this rollback is the
        // gateway's own housekeeping.
        let deadline = self.default_command_deadline;
        handle.spawn(async move {
            match tokio::time::timeout(deadline, connection.batch_execute("ROLLBACK")).await {
                Ok(Ok(())) => (),
                Ok(Err(e)) => {
                    tracing::error!("Failed to roll back abandoned transaction: {e}");
                }
                Err(_) => {
                    // Holding it would keep the pool non-idle, blocking
                    // `clean_unused_pools` from ever reclaiming it.
                    tracing::error!(
                        "Timed out rolling back abandoned transaction; closing the connection"
                    );
                    drop(PoolConnection::take(connection));
                }
            }
        });
    }
}

/// Per-request options
///
/// Carries properties that are the same for every query within a single
/// client request (e.g. replica-cluster mode).
#[derive(Debug, Clone, Copy)]
pub struct RequestOptions {
    in_replica_cluster_mode: bool,
    command_timeout: Option<Duration>,
}

impl RequestOptions {
    #[must_use]
    pub const fn new(in_replica_cluster_mode: bool, command_timeout_ms: Option<u64>) -> Self {
        Self {
            in_replica_cluster_mode,
            command_timeout: match command_timeout_ms {
                Some(ms) => Some(Duration::from_millis(ms)),
                None => None,
            },
        }
    }

    #[must_use]
    pub const fn in_replica_cluster_mode(&self) -> bool {
        self.in_replica_cluster_mode
    }

    #[must_use]
    pub const fn command_timeout(&self) -> Option<Duration> {
        self.command_timeout
    }
}

/// Per-method query execution flags
#[expect(
    clippy::struct_excessive_bools,
    reason = "fine-grained control is needed and the number of options is unlikely to grow much"
)]
#[derive(Debug, Clone, Copy)]
pub struct QueryOptions {
    retry_request: bool,
    retry_deadlock: bool,
    /// If true, the backend extension handles timeout internally via the command
    /// document — the gateway does NOT set `statement_timeout`.
    supports_backend_timeout: bool,
    /// If true, the gateway can use BEGIN + SET LOCAL (auto-reverts at COMMIT).
    /// If false, uses session-level SET (for cursor ops that outlive a transaction).
    /// Only relevant when `supports_backend_timeout` is false.
    supports_transaction_timeout: bool,
}

impl Default for QueryOptions {
    fn default() -> Self {
        Self {
            retry_request: true,
            retry_deadlock: false,
            supports_backend_timeout: false,
            supports_transaction_timeout: true,
        }
    }
}

/// Builder for constructing a [`QueryOptions`] with fine-grained control.
///
/// Start from [`QueryOptions::builder()`] (which uses the same defaults as
/// [`QueryOptions::default()`]) and override only the fields you need.
#[derive(Debug, Clone, Copy)]
pub struct QueryOptionsBuilder {
    inner: QueryOptions,
}

impl QueryOptionsBuilder {
    #[must_use]
    pub const fn retry_request(mut self, value: bool) -> Self {
        self.inner.retry_request = value;
        self
    }

    #[must_use]
    pub const fn retry_deadlock(mut self, value: bool) -> Self {
        self.inner.retry_deadlock = value;
        self
    }

    #[must_use]
    pub const fn supports_backend_timeout(mut self, value: bool) -> Self {
        self.inner.supports_backend_timeout = value;
        self
    }

    #[must_use]
    pub const fn supports_transaction_timeout(mut self, value: bool) -> Self {
        self.inner.supports_transaction_timeout = value;
        self
    }

    #[must_use]
    pub const fn build(self) -> QueryOptions {
        self.inner
    }
}

impl QueryOptions {
    /// Returns a builder initialised with the default values.
    #[must_use]
    pub fn builder() -> QueryOptionsBuilder {
        QueryOptionsBuilder {
            inner: Self::default(),
        }
    }

    #[must_use]
    pub const fn retry_request(self) -> bool {
        self.retry_request
    }

    #[must_use]
    pub const fn retry_deadlock(self) -> bool {
        self.retry_deadlock
    }

    #[must_use]
    pub const fn supports_backend_timeout(self) -> bool {
        self.supports_backend_timeout
    }

    #[must_use]
    pub const fn supports_transaction_timeout(self) -> bool {
        self.supports_transaction_timeout
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The timeout variant wraps no source error, so its `Display` is the only
    /// place the elapsed deadline is reported and must include it.
    #[test]
    fn timed_out_statement_error_display_includes_the_deadline() {
        let deadline = Duration::from_millis(1500);
        let rendered = StatementError::Timeout(deadline).to_string();
        assert!(
            rendered.contains(&format!("{deadline:?}")),
            "Display should include the deadline, got {rendered:?}"
        );
    }
}
