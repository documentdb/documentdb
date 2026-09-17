/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/data_client.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{future::Future, sync::Arc};

use async_trait::async_trait;
use bson::RawDocument;
use tokio::time::{Duration, Instant};
use tokio_postgres::Row;

use crate::{
    auth::AuthState,
    configuration::DynamicConfiguration,
    context::{ConnectionContext, Cursor, RequestContext, ServiceContext},
    error::Result,
    explain::Verbosity,
    postgres::{
        conn_mgmt::{
            command_deadline_for, run_request_with_retries, Connection, ConnectionPool,
            ConnectionSource, PoolConnection, PullConnection, QueryOptions, RequestOptions,
            StatementError,
        },
        PgDocument,
    },
    requests::ExplainTarget,
    responses::{PgResponse, Response},
};

#[async_trait]
pub trait PgDataClient: Send + Sync {
    /// Creates a new client authorized with the given [`AuthState`].
    ///
    /// # Errors
    /// Returns an error if the client cannot be constructed (e.g. missing
    /// connection pool for the authorized user).
    fn new_authorized(service_context: &ServiceContext, authorization: &AuthState) -> Result<Self>
    where
        Self: Sized;

    /// Creates a new client for unauthenticated operations.
    ///
    /// # Errors
    /// Returns an error if the client cannot be constructed.
    fn new_unauthorized(service_context: &ServiceContext) -> Result<Self>
    where
        Self: Sized;

    fn service_context(&self) -> &ServiceContext;

    async fn acquire_pool_connection(&self) -> Result<PoolConnection>;

    async fn pull_connection_with_transaction(&self, in_transaction: bool) -> Result<Connection> {
        let pool_connection = self.acquire_pool_connection().await?;

        // Mirror the pool's deadline when one is available; otherwise derive it
        // from the same configuration the pool would have used, so a connection
        // built without a pool is never left without a client-side bound.
        let command_deadline = self.connection_pool().map_or_else(
            |_| command_deadline_for(self.dynamic_configuration().as_ref()),
            ConnectionPool::command_deadline,
        );

        Ok(Connection::new(
            pool_connection,
            in_transaction,
            command_deadline,
        ))
    }

    /// Returns the underlying connection pool.
    ///
    /// # Errors
    /// Returns an error if no pool is available for this client.
    fn connection_pool(&self) -> Result<&ConnectionPool>;

    /// Returns the maximum request timeout for data operations.
    fn max_request_timeout(&self) -> Duration {
        Duration::from_secs(self.dynamic_configuration().max_request_timeout_sec())
    }

    /// The configuration this client reads. Every other method here goes through
    /// it, so a client that must answer differently from the process overrides
    /// this one method rather than each of them.
    fn dynamic_configuration(&self) -> Arc<dyn DynamicConfiguration> {
        self.service_context().dynamic_configuration()
    }

    fn request_options(&self, command_timeout_ms: Option<u64>) -> RequestOptions {
        RequestOptions::new(
            self.dynamic_configuration().is_replica_cluster(),
            command_timeout_ms,
        )
    }

    async fn execute_aggregate(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_coll_stats(
        &self,
        request_context: &RequestContext<'_>,
        scale: f64,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_count_query(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_create_collection(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_create_indexes(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>>;

    async fn execute_wait_for_index(
        &self,
        request_context: &RequestContext<'_>,
        index_build_id: &PgDocument<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>>;

    async fn execute_delete(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        enable_write_procedures: bool,
    ) -> Result<Vec<Row>>;

    async fn execute_delete_when_readonly(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>>;

    async fn execute_distinct_query(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_drop_collection(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        collection: &str,
        connection_context: &ConnectionContext,
    ) -> Result<()>;

    async fn execute_drop_collection_when_readonly(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        collection: &str,
        connection_context: &ConnectionContext,
    ) -> Result<()>;

    async fn execute_drop_database(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        connection_context: &ConnectionContext,
    ) -> Result<()>;

    async fn execute_drop_database_when_readonly(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        connection_context: &ConnectionContext,
    ) -> Result<()>;

    async fn execute_explain(
        &self,
        request_context: &RequestContext<'_>,
        explain_target: &ExplainTarget<'_>,
        query_base: &str,
        verbosity: Verbosity,
        connection_context: &ConnectionContext,
    ) -> Result<(Option<serde_json::Value>, String)>;

    async fn execute_find(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_find_and_modify(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_cursor_get_more(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        cursor: &Cursor,
        pull_connection: PullConnection,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>>;

    async fn execute_insert(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        enable_write_procedures: bool,
        enable_write_procedures_with_batch_commit: bool,
    ) -> Result<Vec<Row>>;

    async fn execute_list_collections(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_list_databases(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_list_indexes(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_update(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        enable_write_procedures: bool,
        enable_write_procedures_with_batch_commit: bool,
    ) -> Result<Vec<Row>>;

    async fn execute_validate(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_drop_indexes(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<PgResponse>;

    async fn execute_shard_collection(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        collection: &str,
        key: &RawDocument,
        reshard: bool,
        connection_context: &ConnectionContext,
    ) -> Result<()>;

    async fn execute_reindex(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_current_op(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_kill_op(
        &self,
        request_context: &RequestContext<'_>,
        operation_id: &str,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_coll_mod(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_get_parameter(
        &self,
        request_context: &RequestContext<'_>,
        all: bool,
        show_details: bool,
        params: Vec<String>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_db_stats(
        &self,
        request_context: &RequestContext<'_>,
        scale: f64,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_rename_collection(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>>;

    async fn execute_create_user(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_drop_user(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_update_user(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_users_info(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_connection_status(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_compact(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_kill_cursors(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        cursor_ids: &[i64],
    ) -> Result<Response>;

    async fn execute_create_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_update_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_drop_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_roles_info(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_grant_roles_to_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_grant_privileges_to_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_grant_roles_to_user(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_revoke_roles_from_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_revoke_privileges_from_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_revoke_roles_from_user(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    // TODO: This is a temporary solution to get the index build ID from the create indexes response.
    // it's a processing logic, not a data client logic, but for sake of simplicity, we put it here.
    // It should be refactored later to a more appropriate place related to the processing
    /// # Errors
    /// Returns error if the operation fails.
    fn get_index_build_id<'a>(&self, index_response: &'a PgResponse) -> Result<PgDocument<'a>>;

    async fn execute_unshard_collection(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<()>;

    async fn execute_get_shard_map(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_list_shards(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_balancer_start(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_balancer_status(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_balancer_stop(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_move_collection(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response>;

    async fn execute_create_search_indexes(
        &self,
        _request_context: &RequestContext<'_>,
        _connection_context: &ConnectionContext,
    ) -> Result<(bool, PgResponse)> {
        Err(crate::error::DocumentDBError::documentdb_error(
            crate::error::ErrorCode::CommandNotSupported,
            "Command 'createSearchIndexes' not supported.".to_owned(),
        ))
    }

    async fn execute_wait_for_search_index(
        &self,
        _request_context: &RequestContext<'_>,
        _index_build_id: &PgDocument<'_>,
        _connection_context: &ConnectionContext,
    ) -> Result<(bool, bool, PgResponse)> {
        Err(crate::error::DocumentDBError::documentdb_error(
            crate::error::ErrorCode::CommandNotSupported,
            "Command 'createSearchIndexes' not supported.".to_owned(),
        ))
    }

    /// Unified query execution that resolves a connection and dispatches to
    /// the retry loop.
    async fn run_query<T, F, Fut>(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        pull_connection: PullConnection,
        query_options: QueryOptions,
        run_func: F,
    ) -> Result<T>
    where
        T: Send,
        F: Fn(Arc<Connection>) -> Fut + Send + Sync,
        Fut: Future<Output = std::result::Result<T, StatementError>> + Send,
    {
        let source = if let Some((lsid, _)) = connection_context.transaction.as_ref() {
            let caller = connection_context.auth_state.principal()?;

            if let Some(connection) = self
                .service_context()
                .transaction_store()
                .get_connection(lsid, caller)
            {
                ConnectionSource::Transaction(connection)
            } else {
                // This should not happen because we check transaction existence at the beginning of each request handling,
                // but we add this fallback just in case to avoid panicking and to allow the retry logic to kick in.
                tracing::error!("Transaction connection not found for lsid {:?}, falling back to pool connection", lsid);
                ConnectionSource::Pool(self.connection_pool()?)
            }
        } else {
            match pull_connection {
                PullConnection::Cursor(conn) => ConnectionSource::Cursor(conn),
                PullConnection::PoolOrTransaction => {
                    ConnectionSource::Pool(self.connection_pool()?)
                }
            }
        };

        let request = request_context.request();
        let command_timeout_ms = bounded_by_deadline(
            request.max_time_ms().map(i64::cast_unsigned),
            request_context.deadline(),
        );
        let req_opts = self.request_options(command_timeout_ms);
        let dynamic_configuration = self.dynamic_configuration();

        run_request_with_retries(
            source,
            query_options,
            req_opts,
            self.max_request_timeout(),
            dynamic_configuration.as_ref(),
            request_context,
            run_func,
        )
        .await
    }

    /// Runs a cursor-returning query: executes the closure, wraps in
    /// `PgResponse`, and saves cursor state if a continuation is present.
    async fn run_cursor_query<F, Fut>(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        query_options: QueryOptions,
        run_func: F,
    ) -> Result<Response>
    where
        F: Fn(Arc<Connection>) -> Fut + Send + Sync,
        Fut: Future<Output = std::result::Result<(Vec<Row>, Arc<Connection>), StatementError>>
            + Send,
    {
        let (rows, connection) = self
            .run_query(
                request_context,
                connection_context,
                PullConnection::PoolOrTransaction,
                query_options,
                run_func,
            )
            .await?;
        let response = PgResponse::new(rows);

        // Save cursor state after a first-page query if the response contains a continuation.
        if let Some((persist, cursor)) = response.get_cursor()? {
            let connection = persist.then_some(connection);

            // Surface the backend cursor id for diagnostics: find/aggregate first pages
            // open a cursor here when the result spans multiple batches. The same request
            // tracker instance is read back at telemetry-emission time.
            request_context
                .tracker
                .set_cursor_id(cursor.cursor_id.into());

            let dynamic_config = self.dynamic_configuration();

            let cursor_timeout = Duration::from_secs(if connection.is_none() {
                dynamic_config.stateless_cursor_idle_timeout_sec()
            } else {
                dynamic_config.default_cursor_idle_timeout_sec()
            });

            let request = request_context.request();
            let lsid = request.lsid().cloned();
            let transaction_number = request
                .transaction_info()
                .map(|txn_info| txn_info.transaction_number);

            connection_context.add_cursor(
                connection,
                cursor,
                request.db(),
                request.collection()?,
                cursor_timeout,
                lsid,
                transaction_number,
                connection_context.auth_state.principal()?,
            );
        }

        Ok(Response::Pg(response))
    }
}

/// Bounds a requested timeout by what remains of a deadline.
///
/// A requested `None` means unbounded, so the deadline replaces it rather than
/// being ignored.
fn bounded_by_deadline(requested_ms: Option<u64>, deadline: Option<Instant>) -> Option<u64> {
    let Some(deadline) = deadline else {
        return requested_ms;
    };

    let remaining = deadline.saturating_duration_since(Instant::now());
    let remaining_ms = u64::try_from(remaining.as_millis()).unwrap_or(u64::MAX);

    Some(requested_ms.map_or(remaining_ms, |requested| requested.min(remaining_ms)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn deadline_in(seconds: u64) -> Instant {
        Instant::now() + Duration::from_secs(seconds)
    }

    #[test]
    fn a_request_without_a_bound_inherits_the_deadline() {
        // Returning None here would let the reissued attempt run for the pool's
        // full configured statement timeout.
        let bounded =
            bounded_by_deadline(None, Some(deadline_in(10))).expect("the deadline applies");

        assert!((9_000..=10_000).contains(&bounded), "got {bounded}");
    }

    #[test]
    fn the_tighter_of_the_two_wins() {
        let widened =
            bounded_by_deadline(Some(30_000), Some(deadline_in(10))).expect("the deadline applies");
        assert!(
            (9_000..=10_000).contains(&widened),
            "an inherited deadline must not be widened by the request, got {widened}"
        );

        assert_eq!(
            bounded_by_deadline(Some(5_000), Some(deadline_in(10))),
            Some(5_000),
            "a request may ask for less than what remains"
        );
    }

    #[test]
    fn without_a_deadline_the_request_is_unchanged() {
        assert_eq!(bounded_by_deadline(None, None), None);
        assert_eq!(bounded_by_deadline(Some(30_000), None), Some(30_000));
    }

    #[test]
    fn a_spent_deadline_leaves_nothing() {
        assert_eq!(
            bounded_by_deadline(Some(30_000), Some(Instant::now())),
            Some(0)
        );
    }
}
