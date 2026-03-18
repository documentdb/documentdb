/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/documentdb_data_client.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use async_trait::async_trait;
use bson::RawDocument;
use tokio_postgres::{error::SqlState, types::Type, Row};

use crate::{
    auth::AuthState,
    context::{ConnectionContext, Cursor, RequestContext, ServiceContext},
    error::{DocumentDBError, Result},
    explain::Verbosity,
    postgres::{
        conn_mgmt::{Connection, ConnectionPool, PoolConnection, PullConnection, QueryOptions},
        PgDataClient, PgDocument, ScopedTransaction,
    },
    responses::{PgResponse, Response},
};

/// Remaps a `DocumentDBError::PostgresError` based of its `sql_state`, to a more meaningful and accurate `DocumentDBError`
///
/// For example, if we get a `PostgresError` with `sql_state` of "42704" (undefined object),
/// we can remap it to a `DocumentDBError::user_not_found` error which is more meaningful
/// in the context of user operations, instead of returning a generic `PostgresError` to the caller.
pub fn remap_error(
    error: DocumentDBError,
    source_sql_state: &SqlState,
    remap_func: fn(String) -> DocumentDBError,
    target_error_message: &str,
) -> DocumentDBError {
    if let DocumentDBError::PostgresError(ref pg_error, _) = error {
        if let Some(code) = pg_error.code() {
            if code == source_sql_state {
                return remap_func(target_error_message.to_owned());
            }
        }
    }
    error
}

#[derive(Debug)]
pub struct DocumentDBDataClient {
    connection_pool: Option<Arc<ConnectionPool>>,
    service_context: ServiceContext,
}

impl DocumentDBDataClient {
    /// Runs a db+bson query returning the raw rows.
    async fn run_db_bson_rows(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        query: &str,
        query_options: QueryOptions,
    ) -> Result<Vec<Row>> {
        let db = request_context.info().db()?;
        let doc = request_context.payload().document();

        let run_db_bson = |conn: Arc<Connection>| async move {
            conn.query_db_bson(query, db, &PgDocument(doc)).await
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            query_options,
            run_db_bson,
        )
        .await
    }

    /// Runs a db+bson query and wraps the result in `Response::Pg`.
    async fn run_db_bson(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        query: &str,
        query_options: QueryOptions,
    ) -> Result<Response> {
        let rows = self
            .run_db_bson_rows(request_context, connection_context, query, query_options)
            .await?;
        Ok(Response::Pg(PgResponse::new(rows)))
    }

    /// Runs a db+bson cursor query and saves cursor state.
    async fn run_db_bson_cursor(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        query: &str,
        query_options: QueryOptions,
    ) -> Result<Response> {
        let db = request_context.info().db()?;
        let doc = request_context.payload().document();

        let run_cursor = |conn: Arc<Connection>| async move {
            let rows = conn.query_db_bson(query, db, &PgDocument(doc)).await?;
            Ok((rows, conn))
        };

        self.run_cursor_query(
            request_context,
            connection_context,
            query_options,
            run_cursor,
        )
        .await
    }

    /// Runs a document-only query (single BYTEA param) and wraps the result.
    async fn run_doc_only(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        query: &str,
        query_options: QueryOptions,
    ) -> Result<Response> {
        let doc = request_context.payload().document();

        let run_doc = |conn: Arc<Connection>| async move {
            let rows = conn
                .query(query, &[Type::BYTEA], &[&PgDocument(doc)])
                .await?;
            Ok(Response::Pg(PgResponse::new(rows)))
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            query_options,
            run_doc,
        )
        .await
    }
}

#[async_trait]
impl PgDataClient for DocumentDBDataClient {
    fn new_authorized(service_context: &ServiceContext, authorization: &AuthState) -> Result<Self> {
        let user = authorization.username()?;
        let dynamic_configuration = service_context.dynamic_configuration();

        let connection_pool = Some(
            service_context
                .connection_pool_manager()
                .get_data_pool(user, dynamic_configuration.as_ref())?,
        );

        Ok(Self {
            connection_pool,
            service_context: service_context.clone(),
        })
    }

    fn new_unauthorized(service_context: &ServiceContext) -> Result<Self> {
        Ok(Self {
            connection_pool: None,
            service_context: service_context.clone(),
        })
    }

    async fn acquire_pool_connection(&self) -> Result<PoolConnection> {
        self.connection_pool
            .as_ref()
            .ok_or(DocumentDBError::internal_error(
                "Acquiring connection to postgres on unauthorized data client".to_owned(),
            ))?
            .acquire_connection()
            .await
            .map_err(DocumentDBError::from)
    }

    fn service_context(&self) -> &ServiceContext {
        &self.service_context
    }

    fn connection_pool(&self) -> Result<&ConnectionPool> {
        self.connection_pool
            .as_deref()
            .ok_or(DocumentDBError::internal_error(
                "No connection pool available on unauthorized data client".to_owned(),
            ))
    }

    async fn execute_aggregate(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_db_bson_cursor(
            request_context,
            connection_context,
            self.service_context
                .query_catalog()
                .aggregate_cursor_first_page(),
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .supports_transaction_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_coll_stats(
        &self,
        request_context: &RequestContext<'_>,
        scale: f64,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        let request_info = request_context.info();

        let db = request_info.db()?;
        let coll = request_info.collection()?;

        let run_coll_stats = |conn: Arc<Connection>| {
            let db_str = db.to_owned();
            let coll_str = coll.to_owned();
            async move {
                let rows = conn
                    .query(
                        self.service_context.query_catalog().coll_stats(),
                        &[Type::TEXT, Type::TEXT, Type::FLOAT8],
                        &[&db_str, &coll_str, &scale],
                    )
                    .await?;
                Ok(Response::Pg(PgResponse::new(rows)))
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_coll_stats,
        )
        .await
    }

    async fn execute_count_query(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_db_bson(
            request_context,
            connection_context,
            self.service_context.query_catalog().count_query(),
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .build(),
        )
        .await
    }

    async fn execute_create_collection(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_db_bson(
            request_context,
            connection_context,
            self.service_context
                .query_catalog()
                .create_collection_view(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_create_indexes(
        &self,
        request_context: &RequestContext<'_>,

        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>> {
        self.run_db_bson_rows(
            request_context,
            connection_context,
            self.service_context
                .query_catalog()
                .create_indexes_background(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .supports_transaction_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_wait_for_index(
        &self,
        request_context: &RequestContext<'_>,
        index_build_id: &PgDocument<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>> {
        let run_wait_index = |conn: Arc<Connection>| async move {
            conn.query(
                self.service_context
                    .query_catalog()
                    .check_build_index_status(),
                &[Type::BYTEA],
                &[&index_build_id],
            )
            .await
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .supports_transaction_timeout(false)
                .build(),
            run_wait_index,
        )
        .await
    }

    async fn execute_delete(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>> {
        let (request, request_info, _) = request_context.get_components();

        let db = request_info.db()?;
        let doc = request.document();
        let extra = request.extra();

        let run_delete = |conn: Arc<Connection>| {
            let db_str = db.to_owned();
            async move {
                conn.query(
                    self.service_context.query_catalog().delete(),
                    &[Type::TEXT, Type::BYTEA, Type::BYTEA],
                    &[&db_str, &PgDocument(doc), &extra],
                )
                .await
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .build(),
            run_delete,
        )
        .await
    }

    async fn execute_delete_when_readonly(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>> {
        let (request, request_info, _) = request_context.get_components();

        let db = request_info.db()?;
        let doc = request.document();
        let extra = request.extra();

        let run_delete_readonly = |conn: Arc<Connection>| {
            let db_str = db.to_owned();
            async move {
                let mut txn = ScopedTransaction::start_if_necessary(&conn).await?;
                conn.batch_execute(self.service_context.query_catalog().set_allow_write())
                    .await?;
                let rows = conn
                    .query(
                        self.service_context.query_catalog().delete(),
                        &[Type::TEXT, Type::BYTEA, Type::BYTEA],
                        &[&db_str, &PgDocument(doc), &extra],
                    )
                    .await;
                if rows.is_ok() {
                    txn.commit().await?;
                }
                rows
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .build(),
            run_delete_readonly,
        )
        .await
    }

    async fn execute_distinct_query(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_db_bson(
            request_context,
            connection_context,
            self.service_context.query_catalog().distinct_query(),
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .build(),
        )
        .await
    }

    async fn execute_drop_collection(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        collection: &str,
        connection_context: &ConnectionContext,
    ) -> Result<()> {
        let run_drop_collection = |conn: Arc<Connection>| async move {
            conn.query(
                self.service_context.query_catalog().drop_collection(),
                &[Type::TEXT, Type::TEXT],
                &[&db, &collection],
            )
            .await
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_drop_collection,
        )
        .await?;

        Ok(())
    }

    async fn execute_drop_collection_when_readonly(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        collection: &str,
        connection_context: &ConnectionContext,
    ) -> Result<()> {
        let run_drop_collection_readonly = |conn: Arc<Connection>| async move {
            let mut txn = ScopedTransaction::start_if_necessary(&conn).await?;
            conn.batch_execute(self.service_context.query_catalog().set_allow_write())
                .await?;
            let rows = conn
                .query(
                    self.service_context.query_catalog().drop_collection(),
                    &[Type::TEXT, Type::TEXT],
                    &[&db, &collection],
                )
                .await;
            if rows.is_ok() {
                txn.commit().await?;
            }
            rows
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_drop_collection_readonly,
        )
        .await?;

        Ok(())
    }

    async fn execute_drop_database(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        connection_context: &ConnectionContext,
    ) -> Result<()> {
        let run_drop_db = |conn: Arc<Connection>| async move {
            conn.query(
                self.service_context.query_catalog().drop_database(),
                &[Type::TEXT],
                &[&db],
            )
            .await
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_drop_db,
        )
        .await?;

        Ok(())
    }

    async fn execute_drop_database_when_readonly(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        connection_context: &ConnectionContext,
    ) -> Result<()> {
        let run_drop_db_readonly = |conn: Arc<Connection>| async move {
            let mut txn = ScopedTransaction::start_if_necessary(&conn).await?;
            conn.batch_execute(self.service_context.query_catalog().set_allow_write())
                .await?;
            let rows = conn
                .query(
                    self.service_context.query_catalog().drop_database(),
                    &[Type::TEXT],
                    &[&db],
                )
                .await;
            if rows.is_ok() {
                txn.commit().await?;
            }
            rows
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_drop_db_readonly,
        )
        .await?;

        Ok(())
    }

    async fn execute_explain(
        &self,
        request_context: &RequestContext<'_>,
        query_base: &str,
        verbosity: Verbosity,
        connection_context: &ConnectionContext,
    ) -> Result<(Option<serde_json::Value>, String)> {
        let (request, request_info, _) = request_context.get_components();
        let analyze = match verbosity {
            Verbosity::QueryPlanner | Verbosity::AllShardsQueryPlan => "False",
            _ => "True",
        };

        let explain_query = self
            .service_context
            .query_catalog()
            .explain(analyze, query_base);

        let db = request_info.db()?;
        let doc = request.document();
        let explain_query_str = explain_query.as_str();

        let explain_config = match verbosity {
            Verbosity::AllShardsQueryPlan | Verbosity::AllShardsExecution => self
                .service_context
                .query_catalog()
                .set_explain_all_tasks_true(),
            Verbosity::AllPlansExecution => self
                .service_context
                .query_catalog()
                .set_explain_all_plans_true(),
            _ => "",
        };
        let needs_transaction = !explain_config.is_empty();

        let run_explain = |conn: Arc<Connection>| async move {
            let mut txn = if needs_transaction {
                let t = ScopedTransaction::start_if_necessary(&conn).await?;
                conn.batch_execute(explain_config).await?;
                Some(t)
            } else {
                None
            };

            let rows = conn
                .query_db_bson(explain_query_str, db, &PgDocument(doc))
                .await;

            if let Some(ref mut t) = txn {
                if rows.is_ok() {
                    t.commit().await?;
                }
            }

            rows
        };

        let explain_rows = self
            .run_query(
                request_context,
                connection_context,
                PullConnection::PoolOrTransaction,
                QueryOptions::builder()
                    .supports_backend_timeout(false)
                    .build(),
                run_explain,
            )
            .await?;

        let explain_response = match explain_rows.first() {
            Some(row) => {
                let explain_json: serde_json::Value = row.try_get(0)?;
                Some(explain_json)
            }
            None => None,
        };

        Ok((explain_response, explain_query))
    }

    async fn execute_find(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_db_bson_cursor(
            request_context,
            connection_context,
            self.service_context
                .query_catalog()
                .find_cursor_first_page(),
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .supports_transaction_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_find_and_modify(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_db_bson(
            request_context,
            connection_context,
            self.service_context.query_catalog().find_and_modify(),
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .build(),
        )
        .await
    }

    async fn execute_cursor_get_more(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        cursor: &Cursor,
        pull_connection: PullConnection,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>> {
        let doc = request_context.payload().document();
        let continuation = &cursor.continuation;

        let run_get_more = |conn: Arc<Connection>| async move {
            conn.query(
                self.service_context.query_catalog().cursor_get_more(),
                &[Type::TEXT, Type::BYTEA, Type::BYTEA],
                &[&db, &PgDocument(doc), &PgDocument(continuation)],
            )
            .await
        };

        self.run_query(
            request_context,
            connection_context,
            pull_connection,
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .supports_transaction_timeout(false)
                .build(),
            run_get_more,
        )
        .await
    }

    async fn execute_insert(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        enable_write_procedures: bool,
        enable_write_procedures_with_batch_commit: bool,
    ) -> Result<Vec<Row>> {
        let (request, request_info, _) = request_context.get_components();

        let is_batch_commit =
            enable_write_procedures_with_batch_commit && connection_context.transaction.is_none();

        let mut query: &str = self.service_context.query_catalog().insert();

        if is_batch_commit {
            query = self.service_context.query_catalog().insert_bulk();
        } else if enable_write_procedures {
            query = self.service_context.query_catalog().insert_txn_proc();
        }

        let db = request_info.db()?;
        let doc = request.document();
        let extra = request.extra();

        let mut query_options_builder = QueryOptions::builder().supports_backend_timeout(true);
        if is_batch_commit {
            query_options_builder = query_options_builder.retry_request(false);
        }

        let run_insert = |conn: Arc<Connection>| {
            let db_str = db.to_owned();
            async move {
                conn.query(
                    query,
                    &[Type::TEXT, Type::BYTEA, Type::BYTEA],
                    &[&db_str, &PgDocument(doc), &extra],
                )
                .await
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            query_options_builder.build(),
            run_insert,
        )
        .await
    }

    async fn execute_list_collections(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_db_bson_cursor(
            request_context,
            connection_context,
            self.service_context.query_catalog().list_collections(),
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .supports_transaction_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_list_databases(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        // TODO: Handle the case where !nameOnly - the legacy gateway simply returns 0s in the appropriate format
        let filter = request_context
            .payload()
            .document()
            .get_document("filter")
            .ok();
        let filter_string = filter.map_or("", |_| "WHERE document @@ $1");

        let list_db_query = self
            .service_context
            .query_catalog()
            .list_databases(filter_string);
        let list_db_query_str = list_db_query.as_str();

        let run_list_dbs = |conn: Arc<Connection>| async move {
            let rows = match filter {
                None => conn.query(list_db_query_str, &[], &[]).await,
                Some(filter) => {
                    conn.query(list_db_query_str, &[Type::BYTEA], &[&PgDocument(filter)])
                        .await
                }
            }?;

            Ok(Response::Pg(PgResponse::new(rows)))
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .build(),
            run_list_dbs,
        )
        .await
    }

    async fn execute_list_indexes(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_db_bson_cursor(
            request_context,
            connection_context,
            self.service_context
                .query_catalog()
                .list_indexes_cursor_first_page(),
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .supports_transaction_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_update(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        enable_write_procedures: bool,
        enable_write_procedures_with_batch_commit: bool,
    ) -> Result<Vec<Row>> {
        let (request, request_info, _) = request_context.get_components();

        let is_batch_commit =
            enable_write_procedures_with_batch_commit && connection_context.transaction.is_none();

        let mut query_str: &str = self.service_context.query_catalog().process_update();
        let mut query_options_builder = QueryOptions::builder()
            .supports_backend_timeout(true)
            .retry_deadlock(true);

        if is_batch_commit {
            query_str = self.service_context.query_catalog().update_bulk();
            query_options_builder = query_options_builder
                .retry_request(false)
                .retry_deadlock(false); // turn off deadlock retry
        } else if enable_write_procedures {
            query_str = self.service_context.query_catalog().update_txn_proc();
        }

        let db = request_info.db()?;
        let doc = request.document();
        let extra = request.extra();

        let run_update = |conn: Arc<Connection>| {
            let db_str = db.to_owned();
            async move {
                conn.query(
                    query_str,
                    &[Type::TEXT, Type::BYTEA, Type::BYTEA],
                    &[&db_str, &PgDocument(doc), &extra],
                )
                .await
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            query_options_builder.build(),
            run_update,
        )
        .await
    }

    async fn execute_validate(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_db_bson(
            request_context,
            connection_context,
            self.service_context.query_catalog().validate(),
            QueryOptions::builder()
                .supports_backend_timeout(true)
                .build(),
        )
        .await
    }

    async fn execute_drop_indexes(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<PgResponse> {
        let rows = self
            .run_db_bson_rows(
                request_context,
                connection_context,
                self.service_context.query_catalog().drop_indexes(),
                QueryOptions::builder()
                    .supports_backend_timeout(false)
                    .build(),
            )
            .await?;
        Ok(PgResponse::new(rows))
    }

    async fn execute_shard_collection(
        &self,
        request_context: &RequestContext<'_>,
        db: &str,
        collection: &str,
        key: &RawDocument,
        reshard: bool,
        connection_context: &ConnectionContext,
    ) -> Result<()> {
        let run_shard = |conn: Arc<Connection>| {
            let db_str = db.to_owned();
            let coll_str = collection.to_owned();
            async move {
                conn.query(
                    self.service_context.query_catalog().shard_collection(),
                    &[Type::TEXT, Type::TEXT, Type::BYTEA, Type::BOOL],
                    &[&db_str, &coll_str, &PgDocument(key), &reshard],
                )
                .await
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_shard,
        )
        .await?;

        Ok(())
    }

    async fn execute_reindex(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        let request_info = request_context.info();

        let db = request_info.db()?;
        let coll = request_info.collection()?;

        let run_reindex = |conn: Arc<Connection>| {
            let db_str = db.to_owned();
            let coll_str = coll.to_owned();
            async move {
                let rows = conn
                    .query(
                        self.service_context.query_catalog().re_index(),
                        &[Type::TEXT, Type::TEXT],
                        &[&db_str, &coll_str],
                    )
                    .await?;

                Ok(Response::Pg(PgResponse::new(rows)))
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .supports_transaction_timeout(false)
                .build(),
            run_reindex,
        )
        .await
    }

    async fn execute_current_op(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().current_op(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_kill_op(
        &self,
        request_context: &RequestContext<'_>,
        _: &str,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().kill_op(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_coll_mod(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        let (request, request_info, _) = request_context.get_components();

        let db = request_info.db()?;
        let coll = request_info.collection()?;
        let doc = request.document();

        let run_coll_mod = |conn: Arc<Connection>| {
            let db_str = db.to_owned();
            let coll_str = coll.to_owned();
            async move {
                let rows = conn
                    .query(
                        self.service_context.query_catalog().coll_mod(),
                        &[Type::TEXT, Type::TEXT, Type::BYTEA],
                        &[&db_str, &coll_str, &PgDocument(doc)],
                    )
                    .await?;

                Ok(Response::Pg(PgResponse::new(rows)))
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_coll_mod,
        )
        .await
    }

    async fn execute_get_parameter(
        &self,
        request_context: &RequestContext<'_>,
        all: bool,
        show_details: bool,
        params: Vec<String>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        let run_get_param = |conn: Arc<Connection>| {
            let params = params.clone();
            async move {
                let rows = conn
                    .query(
                        self.service_context.query_catalog().get_parameter(),
                        &[Type::BOOL, Type::BOOL, Type::TEXT_ARRAY],
                        &[&all, &show_details, &params],
                    )
                    .await?;

                Ok(Response::Pg(PgResponse::new(rows)))
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_get_param,
        )
        .await
    }

    async fn execute_db_stats(
        &self,
        request_context: &RequestContext<'_>,
        scale: f64,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        let db = request_context.info().db()?;

        let run_db_stats = |conn: Arc<Connection>| {
            let db_str = db.to_owned();
            async move {
                let rows = conn
                    .query(
                        self.service_context.query_catalog().db_stats(),
                        &[Type::TEXT, Type::FLOAT8, Type::BOOL],
                        &[&db_str, &scale, &false],
                    )
                    .await?;

                Ok(Response::Pg(PgResponse::new(rows)))
            }
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_db_stats,
        )
        .await
    }

    async fn execute_rename_collection(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Vec<Row>> {
        let doc = request_context.payload().document();
        let run_rename = |conn: Arc<Connection>| async move {
            conn.query(
                self.service_context.query_catalog().rename_collection(),
                &[Type::BYTEA],
                &[&PgDocument(doc)],
            )
            .await
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_rename,
        )
        .await
    }

    async fn execute_create_user(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().create_user(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
        .map_err(|e| {
            remap_error(
                e,
                &SqlState::DUPLICATE_OBJECT,
                DocumentDBError::duplicate_user,
                "The specified user already exists.",
            )
        })
    }

    async fn execute_drop_user(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().drop_user(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
        .map_err(|e| {
            remap_error(
                e,
                &SqlState::UNDEFINED_OBJECT,
                DocumentDBError::user_not_found,
                "The specified user does not exist.",
            )
        })
    }

    async fn execute_update_user(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().update_user(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
        .map_err(|e| {
            remap_error(
                e,
                &SqlState::UNDEFINED_OBJECT,
                DocumentDBError::user_not_found,
                "The specified user does not exist.",
            )
        })
    }

    async fn execute_users_info(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().users_info(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
    }

    fn get_index_build_id<'a>(&self, index_response: &'a PgResponse) -> Result<PgDocument<'a>> {
        Ok(index_response.first()?.get(2))
    }

    async fn execute_unshard_collection(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<()> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().unshard_collection(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await?;

        Ok(())
    }

    async fn execute_get_shard_map(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        let run_get_shard_map = |conn: Arc<Connection>| async move {
            let rows = conn
                .query(
                    self.service_context.query_catalog().get_shard_map(),
                    &[],
                    &[],
                )
                .await?;

            Ok(Response::Pg(PgResponse::new(rows)))
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_get_shard_map,
        )
        .await
    }

    async fn execute_list_shards(
        &self,
        _request_context: &RequestContext<'_>,
        _connection_context: &ConnectionContext,
    ) -> Result<Response> {
        Err(DocumentDBError::command_not_supported(
            "Not supported operation.".to_owned(),
        ))
    }

    async fn execute_connection_status(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().connection_status(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_compact(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().compact(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_kill_cursors(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
        cursor_ids: &[i64],
    ) -> Result<Response> {
        let run_kill_cursors = |conn: Arc<Connection>| async move {
            let rows = conn
                .query(
                    self.service_context.query_catalog().kill_cursors(),
                    &[Type::INT8_ARRAY],
                    &[&cursor_ids],
                )
                .await?;

            Ok(Response::Pg(PgResponse::new(rows)))
        };

        self.run_query(
            request_context,
            connection_context,
            PullConnection::PoolOrTransaction,
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
            run_kill_cursors,
        )
        .await
    }

    async fn execute_create_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().create_role(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
        .map_err(|e| {
            remap_error(
                e,
                &SqlState::DUPLICATE_OBJECT,
                DocumentDBError::duplicate_role,
                "The specified role already exists.",
            )
        })
    }

    async fn execute_update_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().update_role(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
        .map_err(|e| {
            remap_error(
                e,
                &SqlState::UNDEFINED_OBJECT,
                DocumentDBError::role_not_found,
                "The specified role does not exist.",
            )
        })
    }

    async fn execute_drop_role(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().drop_role(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
        .map_err(|e| {
            remap_error(
                e,
                &SqlState::UNDEFINED_OBJECT,
                DocumentDBError::role_not_found,
                "The specified role does not exist.",
            )
        })
    }

    async fn execute_roles_info(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &ConnectionContext,
    ) -> Result<Response> {
        self.run_doc_only(
            request_context,
            connection_context,
            self.service_context.query_catalog().roles_info(),
            QueryOptions::builder()
                .supports_backend_timeout(false)
                .build(),
        )
        .await
    }

    async fn execute_balancer_start(
        &self,
        _request_context: &RequestContext<'_>,
        _connection_context: &ConnectionContext,
    ) -> Result<Response> {
        Err(DocumentDBError::command_not_supported(
            "Not supported operation.".to_owned(),
        ))
    }

    async fn execute_balancer_status(
        &self,
        _request_context: &RequestContext<'_>,
        _connection_context: &ConnectionContext,
    ) -> Result<Response> {
        Err(DocumentDBError::command_not_supported(
            "Not supported operation.".to_owned(),
        ))
    }

    async fn execute_balancer_stop(
        &self,
        _request_context: &RequestContext<'_>,
        _connection_context: &ConnectionContext,
    ) -> Result<Response> {
        Err(DocumentDBError::command_not_supported(
            "Not supported operation.".to_owned(),
        ))
    }

    async fn execute_move_collection(
        &self,
        _request_context: &RequestContext<'_>,
        _connection_context: &ConnectionContext,
    ) -> Result<Response> {
        Err(DocumentDBError::command_not_supported(
            "Not supported operation.".to_owned(),
        ))
    }
}
