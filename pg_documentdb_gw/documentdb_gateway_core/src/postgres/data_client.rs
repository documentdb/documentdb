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
use tokio::time::Duration;
use tokio_postgres::Row;

use crate::{
    auth::AuthState,
    context::{ConnectionContext, Cursor, RequestContext, ServiceContext},
    error::Result,
    explain::Verbosity,
    postgres::{
        conn_mgmt::{
            run_request_with_retries, Connection, ConnectionPool, ConnectionSource, PoolConnection,
            PullConnection, QueryOptions, RequestOptions,
        },
        PgDocument,
    },
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

        Ok(Connection::new(pool_connection, in_transaction))
    }

    /// Returns the underlying connection pool.
    ///
    /// # Errors
    /// Returns an error if no pool is available for this client.
    fn connection_pool(&self) -> Result<&ConnectionPool>;

    fn request_options(&self) -> RequestOptions {
        RequestOptions::new(
            self.service_context()
                .dynamic_configuration()
                .is_replica_cluster(),
            self.service_context()
                .setup_configuration()
                .postgres_command_timeout_secs(),
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
        Fut: Future<Output = std::result::Result<T, tokio_postgres::Error>> + Send,
    {
        let source = if let Some((session_id, _)) = connection_context.transaction.as_ref() {
            if let Some(connection) = self
                .service_context()
                .transaction_store()
                .get_connection(session_id)
            {
                ConnectionSource::Transaction(connection)
            } else {
                // This should not happen because we check transaction existence at the beginning of each request handling,
                // but we add this fallback just in case to avoid panicking and to allow the retry logic to kick in.
                tracing::error!("Transaction connection not found for session_id {:?}, falling back to pool connection", session_id);
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

        let (_, request_info, request_tracker) = request_context.get_components();
        let max_time_ms = request_info.max_time_ms;
        let req_opts = self.request_options();

        run_request_with_retries(
            source,
            query_options,
            req_opts,
            max_time_ms,
            request_tracker,
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
        Fut: Future<Output = std::result::Result<(Vec<Row>, Arc<Connection>), tokio_postgres::Error>>
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

            let dynamic_config = self.service_context().dynamic_configuration();

            let cursor_timeout = Duration::from_secs(
                if dynamic_config.enable_stateless_cursor_timeout() && connection.is_none() {
                    dynamic_config.stateless_cursor_idle_timeout_sec()
                } else {
                    dynamic_config.default_cursor_idle_timeout_sec()
                },
            );

            let request_info = request_context.info();

            connection_context.add_cursor(
                connection,
                cursor,
                connection_context.auth_state.username()?,
                request_info.db()?,
                request_info.collection()?,
                cursor_timeout,
                request_info.session_id.map(<[u8]>::to_vec),
            );
        }

        Ok(Response::Pg(response))
    }
}
