/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/postgres/conn_mgmt/mod.rs
 *
 *-------------------------------------------------------------------------
 */

mod connection;
mod connection_pool;
mod pool_manager;
mod pool_settings;

pub use connection::{Connection, Timeout, TimeoutType};
pub use connection_pool::{ConnectionPool, ConnectionPoolStatus, PoolConnection};
pub use pool_manager::{
    clean_unused_pools, create_connection_pool_manager, PoolManager,
    AUTHENTICATION_MAX_CONNECTIONS, SYSTEM_REQUESTS_MAX_CONNECTIONS,
};
pub use pool_settings::{
    PgPoolSettings, CONN_IDLE_LIFETIME_SECS, CONN_LIFETIME_SECS, CONN_PRUNE_INTERVAL_SECS,
};
