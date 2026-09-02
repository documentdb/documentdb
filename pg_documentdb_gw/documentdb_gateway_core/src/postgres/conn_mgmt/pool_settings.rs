/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/pool_settings.rs
 *
 *-------------------------------------------------------------------------
 */

use tokio::time::Duration;

use crate::configuration::{
    DynamicConfiguration, MAX_REQUEST_TIMEOUT_DEFAULT_SEC, TRANSACTION_TIMEOUT_DEFAULT_SEC,
};

/// Data connection buffer size (in bytes).
pub const CONN_BUFFER_SIZE: usize = 262_144;
pub const CONN_PRUNE_INTERVAL_SECS: u64 = 10;
pub const CONN_IDLE_LIFETIME_SECS: u64 = 300;
pub const CONN_LIFETIME_SECS: u64 = 3600;

#[derive(Copy, Clone, Debug, Eq, Hash, PartialEq)]
pub struct PgPoolSettings {
    max_connections: usize,
    system_connection_budget: usize,
    connection_buffer_size: usize,
    connection_pruning_interval: Duration,
    connection_idle_lifetime: Duration,
    connection_lifetime: Duration,
    max_request_timeout: Duration,
    transaction_timeout: Duration,
}

impl PgPoolSettings {
    #[must_use]
    pub const fn system_pool_settings(max_connections: usize) -> Self {
        Self::system_pool_settings_with_command_timeout(
            max_connections,
            MAX_REQUEST_TIMEOUT_DEFAULT_SEC,
        )
    }

    #[must_use]
    pub const fn system_pool_settings_with_command_timeout(
        max_connections: usize,
        command_timeout_sec: u64,
    ) -> Self {
        Self {
            max_connections,
            system_connection_budget: 0,
            connection_buffer_size: CONN_BUFFER_SIZE,
            connection_pruning_interval: Duration::from_secs(CONN_PRUNE_INTERVAL_SECS),
            connection_idle_lifetime: Duration::from_secs(CONN_IDLE_LIFETIME_SECS),
            connection_lifetime: Duration::from_secs(CONN_LIFETIME_SECS),
            max_request_timeout: Duration::from_secs(command_timeout_sec),
            transaction_timeout: Duration::from_secs(TRANSACTION_TIMEOUT_DEFAULT_SEC),
        }
    }

    pub fn from_configuration(config: &dyn DynamicConfiguration) -> Self {
        let max_connections = config.max_connections();
        let system_connection_budget = config.system_connection_budget();
        let connection_pruning_interval =
            Duration::from_secs(config.gateway_connection_pruning_interval_sec());
        let connection_idle_lifetime =
            Duration::from_secs(config.gateway_connection_idle_lifetime_sec());
        let connection_lifetime = Duration::from_secs(config.gateway_connection_lifetime_sec());
        let connection_buffer_size = config.gateway_connection_buffer_size();
        let max_request_timeout = Duration::from_secs(config.max_request_timeout_sec());
        let transaction_timeout = Duration::from_secs(config.transaction_timeout_sec());

        Self {
            max_connections,
            system_connection_budget,
            connection_buffer_size,
            connection_pruning_interval,
            connection_idle_lifetime,
            connection_lifetime,
            max_request_timeout,
            transaction_timeout,
        }
    }

    #[must_use]
    pub const fn adjusted_max_connections(&self) -> usize {
        // Reserve the system budget out of the total, but never let the data
        // pool fall below the budget itself. `saturating_sub` is required
        // because the budget can exceed `max_connections` (e.g. when the
        // backend client-connection limit is configured below the budget); an
        // unchecked `usize` subtraction would wrap to a near-`usize::MAX`
        // value and blow up the downstream pool capacity allocation.
        let real_max_connections = self
            .max_connections
            .saturating_sub(self.system_connection_budget);

        if real_max_connections < self.system_connection_budget {
            self.system_connection_budget
        } else {
            real_max_connections
        }
    }

    #[must_use]
    pub const fn connection_pruning_interval(&self) -> Duration {
        self.connection_pruning_interval
    }

    #[must_use]
    pub const fn connection_idle_lifetime(&self) -> Duration {
        self.connection_idle_lifetime
    }

    #[must_use]
    pub const fn connection_lifetime(&self) -> Duration {
        self.connection_lifetime
    }

    #[must_use]
    pub const fn connection_buffer_size(&self) -> usize {
        self.connection_buffer_size
    }

    /// Returns the dynamically configured maximum request timeout.
    #[must_use]
    pub const fn max_request_timeout(&self) -> Duration {
        self.max_request_timeout
    }

    /// Returns the dynamically configured transaction timeout.
    #[must_use]
    pub const fn transaction_timeout(&self) -> Duration {
        self.transaction_timeout
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(max_connections: usize, system_connection_budget: usize) -> PgPoolSettings {
        PgPoolSettings {
            max_connections,
            system_connection_budget,
            connection_buffer_size: CONN_BUFFER_SIZE,
            connection_pruning_interval: Duration::from_secs(CONN_PRUNE_INTERVAL_SECS),
            connection_idle_lifetime: Duration::from_secs(CONN_IDLE_LIFETIME_SECS),
            connection_lifetime: Duration::from_secs(CONN_LIFETIME_SECS),
            max_request_timeout: Duration::from_secs(MAX_REQUEST_TIMEOUT_DEFAULT_SEC),
            transaction_timeout: Duration::from_secs(TRANSACTION_TIMEOUT_DEFAULT_SEC),
        }
    }

    #[test]
    fn adjusted_max_connections_reserves_budget() {
        assert_eq!(settings(25, 10).adjusted_max_connections(), 15);
    }

    #[test]
    fn adjusted_max_connections_floors_to_budget_when_remainder_is_small() {
        // 12 - 10 = 2, which is below the budget, so it floors to the budget.
        assert_eq!(settings(12, 10).adjusted_max_connections(), 10);
    }

    #[test]
    fn adjusted_max_connections_does_not_underflow_when_budget_exceeds_max() {
        // Regression: when the client-connection limit is below the system
        // budget, the unsigned subtraction must not wrap to a near-`usize::MAX`
        // value (which previously caused a capacity-overflow panic when the
        // result was used as a connection-pool capacity).
        assert_eq!(settings(5, 10).adjusted_max_connections(), 10);
        assert_eq!(settings(0, 10).adjusted_max_connections(), 10);
    }
}
