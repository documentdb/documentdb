/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 *-------------------------------------------------------------------------
 */

//! Database execution for authentication mechanisms, separate from conversation state.

use std::{fmt::Debug, time::Duration};

use async_trait::async_trait;
use tokio_postgres::{
    types::{ToSql, Type},
    Row,
};

use crate::{
    configuration::DynamicConfiguration,
    context::{ConnectionContext, RequestContext},
    error::Result,
    postgres::conn_mgmt::{
        run_request_with_retries, ConnectionPool, ConnectionSource, QueryOptions, RequestOptions,
    },
};

/// Executes authentication queries without owning the authentication conversation.
#[async_trait]
pub trait AuthenticationQueryExecutor: Debug + Send + Sync {
    /// Executes a parameterized authentication query.
    ///
    /// # Errors
    /// Returns an error when the database operation cannot complete.
    async fn query(
        &self,
        connection: &ConnectionContext,
        request: &RequestContext<'_>,
        sql: &str,
        parameter_types: &[Type],
        parameters: &[&(dyn ToSql + Sync)],
    ) -> Result<Vec<Row>>;
}

/// Executes authentication queries using the service's authentication pool.
#[derive(Debug, Default)]
pub struct PostgresAuthenticationQueryExecutor;

#[async_trait]
impl AuthenticationQueryExecutor for PostgresAuthenticationQueryExecutor {
    async fn query(
        &self,
        connection: &ConnectionContext,
        request: &RequestContext<'_>,
        sql: &str,
        parameter_types: &[Type],
        parameters: &[&(dyn ToSql + Sync)],
    ) -> Result<Vec<Row>> {
        let configuration = connection.dynamic_configuration();
        run_auth_query(
            connection
                .service_context
                .connection_pool_manager()
                .system_auth_pool(),
            configuration.as_ref(),
            Duration::from_secs(configuration.max_request_timeout_sec()),
            request,
            sql,
            parameter_types,
            parameters,
        )
        .await
    }
}

/// Executes an authentication query with the supplied pool and retry budget.
///
/// # Errors
/// Returns the database, pool, or retry-budget error.
pub async fn run_auth_query(
    pool: &ConnectionPool,
    configuration: &dyn DynamicConfiguration,
    budget: Duration,
    request: &RequestContext<'_>,
    sql: &str,
    parameter_types: &[Type],
    parameters: &[&(dyn ToSql + Sync)],
) -> Result<Vec<Row>> {
    run_request_with_retries(
        ConnectionSource::Pool(pool),
        QueryOptions::default(),
        RequestOptions::new(false, None),
        budget,
        configuration,
        request,
        |connection| async move { connection.query(sql, parameter_types, parameters).await },
    )
    .await
}
