/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/mod.rs
 *
 *-------------------------------------------------------------------------
 */

mod connection;
mod connection_pool;
mod pool_manager;
mod pool_settings;
mod query_dispatch;
mod retry_policies;

pub use connection::{Connection, QueryOptions, QueryOptionsBuilder, RequestOptions};
pub use connection_pool::{ConnectionPool, ConnectionPoolStatus, PoolConnection};
pub use pool_manager::{
    clean_unused_pools, create_connection_pool_manager, PoolManager,
    AUTHENTICATION_MAX_CONNECTIONS, SYSTEM_REQUESTS_MAX_CONNECTIONS,
};
pub use pool_settings::{
    PgPoolSettings, CONN_IDLE_LIFETIME_SECS, CONN_LIFETIME_SECS, CONN_PRUNE_INTERVAL_SECS,
};
pub use query_dispatch::{run_request_with_retries, ConnectionSource, PullConnection};
