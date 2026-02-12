/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/postgres/conn_mgmt/pool_settings.rs
 *
 *-------------------------------------------------------------------------
 */

use tokio::time::Duration;

use crate::configuration::DynamicConfiguration;

pub const CONN_PRUNE_INTERVAL_SECS: u64 = 10;
pub const CONN_IDLE_LIFETIME_SECS: u64 = 300;
pub const CONN_LIFETIME_SECS: u64 = 7200;

#[derive(Copy, Clone, Debug, Eq, Hash, PartialEq)]
pub struct PgPoolSettings {
    max_connections: usize,
    system_connection_budget: usize,
    connection_pruning_interval: Duration,
    connection_idle_lifetime: Duration,
    connection_lifetime: Duration,
}

impl PgPoolSettings {
    pub fn system_pool_settings(max_connections: usize) -> Self {
        PgPoolSettings {
            max_connections,
            system_connection_budget: 0,
            connection_pruning_interval: Duration::from_secs(CONN_PRUNE_INTERVAL_SECS),
            connection_idle_lifetime: Duration::from_secs(CONN_IDLE_LIFETIME_SECS),
            connection_lifetime: Duration::from_secs(CONN_LIFETIME_SECS),
        }
    }

    pub async fn from_configuration(config: &dyn DynamicConfiguration) -> Self {
        let max_connections = config.max_connections().await;
        let system_connection_budget = config.system_connection_budget().await;
        let connection_pruning_interval =
            Duration::from_secs(config.gateway_connection_pruning_interval_sec().await);
        let connection_idle_lifetime =
            Duration::from_secs(config.gateway_connection_idle_lifetime_sec().await);
        let connection_lifetime =
            Duration::from_secs(config.gateway_connection_lifetime_sec().await);

        PgPoolSettings {
            max_connections,
            system_connection_budget,
            connection_pruning_interval,
            connection_idle_lifetime,
            connection_lifetime,
        }
    }

    pub fn adjusted_max_connections(&self) -> usize {
        let real_max_connections = self.max_connections - self.system_connection_budget;

        if real_max_connections < self.system_connection_budget {
            self.system_connection_budget
        } else {
            real_max_connections
        }
    }

    pub fn connection_pruning_interval(&self) -> Duration {
        self.connection_pruning_interval
    }

    pub fn connection_idle_lifetime(&self) -> Duration {
        self.connection_idle_lifetime
    }

    pub fn connection_lifetime(&self) -> Duration {
        self.connection_lifetime
    }
}
