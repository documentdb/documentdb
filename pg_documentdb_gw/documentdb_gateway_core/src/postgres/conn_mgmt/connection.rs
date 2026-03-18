/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/connection.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    sync::atomic::{AtomicBool, Ordering},
    time::Duration,
};

use tokio_postgres::{
    types::{ToSql, Type},
    Row,
};

use crate::postgres::{conn_mgmt::PoolConnection, PgDocument};

// Provides functions which coerce bson to BYTEA. Any statement binding a PgDocument should use query_typed and not query
// WrongType { postgres: Other(Other { name: "bson", oid: 18934, kind: Simple, schema: "schema_name" }), rust: "document_gateway::postgres::document::PgDocument" })
// Will be occur if the wrong one is used.
#[derive(Debug)]
pub struct Connection {
    pool_connection: PoolConnection,
    /// Tracks whether a transaction is active on this connection (user-level
    /// or gateway-level).  Uses `AtomicBool` for interior mutability because
    /// `Connection` lives behind `Arc` and the gateway timeout layer may start
    /// a transaction after construction.
    in_transaction: AtomicBool,
}

impl Connection {
    #[must_use]
    pub const fn new(pool_connection: PoolConnection, in_transaction: bool) -> Self {
        Self {
            pool_connection,
            in_transaction: AtomicBool::new(in_transaction),
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

    /// Executes a parameterized query and returns all resulting rows.
    ///
    /// # Errors
    /// Returns a [`tokio_postgres::Error`] if preparing or executing the query fails.
    pub async fn query(
        &self,
        query: &str,
        parameter_types: &[Type],
        params: &[&(dyn ToSql + Sync)],
    ) -> std::result::Result<Vec<Row>, tokio_postgres::Error> {
        let statement = self
            .pool_connection
            .prepare_typed_cached(query, parameter_types)
            .await?;

        self.pool_connection.query(&statement, params).await
    }

    /// # Errors
    /// Returns error if the operation fails.
    pub async fn query_db_bson(
        &self,
        query: &str,
        db: &str,
        bson: &PgDocument<'_>,
    ) -> std::result::Result<Vec<Row>, tokio_postgres::Error> {
        self.query(query, &[Type::TEXT, Type::BYTEA], &[&db, bson])
            .await
    }

    /// Executes one or more SQL statements without returning rows.
    ///
    /// # Errors
    /// Returns a [`tokio_postgres::Error`] if execution fails.
    pub async fn batch_execute(
        &self,
        query: &str,
    ) -> std::result::Result<(), tokio_postgres::Error> {
        self.pool_connection.batch_execute(query).await
    }
}

/// Per-request options
///
/// Carries properties that are the same for every query within a single
/// client request (e.g. replica-cluster mode).
#[derive(Debug, Clone, Copy)]
pub struct RequestOptions {
    in_replica_cluster_mode: bool,
    command_timeout: Duration,
}

impl RequestOptions {
    #[must_use]
    pub const fn new(in_replica_cluster_mode: bool, command_timeout_secs: u64) -> Self {
        Self {
            in_replica_cluster_mode,
            command_timeout: Duration::from_secs(command_timeout_secs),
        }
    }

    #[must_use]
    pub const fn in_replica_cluster_mode(&self) -> bool {
        self.in_replica_cluster_mode
    }

    #[must_use]
    pub const fn command_timeout(&self) -> Duration {
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
