/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/test_setup/postgres.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::{Arc, OnceLock};

use documentdb_gateway_core::{
    configuration::SetupConfiguration,
    error::{DocumentDBError, Result},
    postgres::{
        conn_mgmt::{
            ConnectionPool, PgPoolSettings, PoolManager, AUTHENTICATION_MAX_CONNECTIONS,
            SYSTEM_REQUESTS_MAX_CONNECTIONS,
        },
        create_query_catalog,
    },
    requests::request_tracker::RequestTracker,
};
use tokio_postgres::error::SqlState;

use crate::test_setup::config::setup_configuration;

static POOL_MANAGER: OnceLock<Arc<PoolManager>> = OnceLock::new();

pub fn get_pool_manager() -> Arc<PoolManager> {
    Arc::clone(POOL_MANAGER.get_or_init(|| {
        let query_catalog = create_query_catalog();
        let setup_config = setup_configuration();
        let postgres_system_user = setup_config.postgres_system_user();

        let system_requests_pool = ConnectionPool::new_with_user(
            &setup_config,
            &query_catalog,
            postgres_system_user,
            None,
            format!("{}-SystemRequests", setup_config.application_name()),
            PgPoolSettings::system_pool_settings(SYSTEM_REQUESTS_MAX_CONNECTIONS),
        )
        .expect("Failed to create system requests pool");

        let authentication_pool = ConnectionPool::new_with_user(
            &setup_config,
            &query_catalog,
            postgres_system_user,
            None,
            format!("{}-PreAuthRequests", setup_config.application_name()),
            PgPoolSettings::system_pool_settings(AUTHENTICATION_MAX_CONNECTIONS),
        )
        .expect("Failed to create authentication pool");

        Arc::new(PoolManager::new(
            query_catalog,
            Box::new(setup_config.clone()),
            system_requests_pool,
            authentication_pool,
        ))
    }))
}

pub async fn create_user(user: &str, pass: &str) -> Result<()> {
    let pool_manager = get_pool_manager();

    let statement = pool_manager.query_catalog().create_db_user(user, pass);
    if let Err(docdb_error) = pool_manager
        .authentication_connection()
        .await?
        .batch_execute(&statement)
        .await
    {
        match docdb_error {
            DocumentDBError::PostgresError(tokio_error, _) => {
                if let Some(sql_state) = tokio_error.code() {
                    if sql_state == &SqlState::DUPLICATE_OBJECT {
                        return Ok(());
                    }
                }
            }
            _ => return Err(docdb_error),
        }
    };

    pool_manager
        .authentication_connection()
        .await?
        .batch_execute(&format!("ALTER ROLE {user} SUPERUSER"))
        .await?;

    if let Some(user_created) = pool_manager
        .authentication_connection()
        .await?
        .query(
            &format!("SELECT * FROM pg_roles WHERE rolname = '{user}'"),
            &[],
            &[],
            None,
            &RequestTracker::new(),
        )
        .await?
        .first()
    {
        tracing::info!(
            "{user} can create more roles: {:?}",
            user_created.get::<_, bool>("rolcreaterole")
        );
    }

    Ok(())
}
