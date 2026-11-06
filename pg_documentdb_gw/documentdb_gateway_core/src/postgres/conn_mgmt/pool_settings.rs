/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/postgres/conn_mgmt/pool_settings.rs
 *
 *-------------------------------------------------------------------------
 */

use tokio::time::Duration;

use crate::{
    configuration::{
        DynamicConfiguration, MAX_REQUEST_TIMEOUT_DEFAULT_SEC, TRANSACTION_TIMEOUT_DEFAULT_SEC,
    },
    telemetry::event_id::EventId,
};

/// Data connection buffer size (in bytes).
pub const CONN_BUFFER_SIZE: usize = 262_144;
pub const CONN_PRUNE_INTERVAL_SECS: u64 = 10;
pub const CONN_IDLE_LIFETIME_SECS: u64 = 900;
pub const CONN_LIFETIME_SECS: u64 = 1800;
const DEFAULT_UNCHECKED_DATA_POOL_SIZE: usize = 2;

#[derive(Copy, Clone, Debug, Eq, Hash, PartialEq)]
pub struct PgPoolSettings {
    max_connections: usize,
    min_data_pool_size_percent: usize,
    system_connection_budget: usize,
    connection_buffer_size: usize,
    connection_pruning_interval: Duration,
    connection_idle_lifetime: Duration,
    connection_lifetime: Duration,
    max_request_timeout: Duration,
    transaction_timeout: Duration,
    connect_timeout: Option<Duration>,
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
            min_data_pool_size_percent: 0,
            system_connection_budget: 0,
            connection_buffer_size: CONN_BUFFER_SIZE,
            connection_pruning_interval: Duration::from_secs(CONN_PRUNE_INTERVAL_SECS),
            connection_idle_lifetime: Duration::from_secs(CONN_IDLE_LIFETIME_SECS),
            connection_lifetime: Duration::from_secs(CONN_LIFETIME_SECS),
            max_request_timeout: Duration::from_secs(command_timeout_sec),
            transaction_timeout: Duration::from_secs(TRANSACTION_TIMEOUT_DEFAULT_SEC),
            connect_timeout: None,
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
        let connect_timeout = config.connect_timeout();
        let min_data_pool_size_percent = config.min_data_pool_size_percent();

        Self {
            max_connections,
            min_data_pool_size_percent,
            system_connection_budget,
            connection_buffer_size,
            connection_pruning_interval,
            connection_idle_lifetime,
            connection_lifetime,
            max_request_timeout,
            transaction_timeout,
            connect_timeout,
        }
    }

    /// Bounds connection establishment and pool-object creation.
    #[must_use]
    pub const fn with_connect_timeout(mut self, connect_timeout: Duration) -> Self {
        self.connect_timeout = Some(connect_timeout);
        self
    }

    /// Sets the minimum data-pool size as a percentage of its maximum size.
    #[must_use]
    pub const fn with_min_pool_size_percent(mut self, min_pool_size_percent: usize) -> Self {
        self.min_data_pool_size_percent = min_pool_size_percent;
        self
    }

    /// Removes the minimum data-pool size.
    #[must_use]
    pub const fn without_min_pool_size(mut self) -> Self {
        self.min_data_pool_size_percent = 0;
        self
    }

    #[must_use]
    pub const fn connect_timeout(&self) -> Option<Duration> {
        self.connect_timeout
    }

    /// Returns the capacity remaining after reserving the system budget.
    /// If none remains, logs a warning and uses the fallback data pool size.
    #[must_use]
    pub fn data_pool_max_connections(&self) -> usize {
        let data_pool_max_connections = self
            .max_connections
            .saturating_sub(self.system_connection_budget);

        if data_pool_max_connections == 0 {
            tracing::warn!(
                event_id = EventId::ConnectionPool.code(),
                max_connections = self.max_connections,
                system_connection_budget = self.system_connection_budget,
                data_pool_max_connections,
                fallback_data_pool_size = DEFAULT_UNCHECKED_DATA_POOL_SIZE,
                "Configured connection limit leaves no capacity for data connections \
                 after reserving the system budget; using the fallback data pool size, \
                 which may exceed the configured total connection limit"
            );

            return DEFAULT_UNCHECKED_DATA_POOL_SIZE;
        }

        data_pool_max_connections
    }

    #[must_use]
    pub fn data_pool_min_connections(&self) -> usize {
        let max_data_pool_size = self.data_pool_max_connections();

        // Zero disables the minimum so system pools remain lazy.
        if self.min_data_pool_size_percent == 0 {
            return 0;
        }

        if self.min_data_pool_size_percent >= 100 {
            return max_data_pool_size;
        }

        let min_data_pool_size = (max_data_pool_size / 100) * self.min_data_pool_size_percent
            + ((max_data_pool_size % 100) * self.min_data_pool_size_percent) / 100;

        min_data_pool_size.max(1)
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
    use crate::{
        postgres::conn_mgmt::pool_manager::fe_system_connection_budget_for_cpu_count,
        testing::TestDynamicConfiguration,
    };

    fn settings(max_connections: usize, system_connection_budget: usize) -> PgPoolSettings {
        PgPoolSettings {
            max_connections,
            min_data_pool_size_percent: 0,
            system_connection_budget,
            connection_buffer_size: CONN_BUFFER_SIZE,
            connection_pruning_interval: Duration::from_secs(CONN_PRUNE_INTERVAL_SECS),
            connection_idle_lifetime: Duration::from_secs(CONN_IDLE_LIFETIME_SECS),
            connection_lifetime: Duration::from_secs(CONN_LIFETIME_SECS),
            max_request_timeout: Duration::from_secs(MAX_REQUEST_TIMEOUT_DEFAULT_SEC),
            transaction_timeout: Duration::from_secs(TRANSACTION_TIMEOUT_DEFAULT_SEC),
            connect_timeout: None,
        }
    }

    #[test]
    fn data_pool_max_connections_reserves_budget() {
        assert_eq!(settings(25, 10).data_pool_max_connections(), 15);
        assert_eq!(settings(20, 15).data_pool_max_connections(), 5);
        assert_eq!(settings(20, 10).data_pool_max_connections(), 10);
        assert_eq!(settings(13, 10).data_pool_max_connections(), 3);
        assert_eq!(settings(12, 10).data_pool_max_connections(), 2);
        assert_eq!(settings(11, 10).data_pool_max_connections(), 1);
        assert_eq!(settings(1, 0).data_pool_max_connections(), 1);
        assert_eq!(
            settings(usize::MAX, 0).data_pool_max_connections(),
            usize::MAX
        );
    }

    #[test]
    fn system_pool_settings_preserve_zero_minimum() {
        let settings = PgPoolSettings::system_pool_settings(4);
        assert_eq!(settings.data_pool_min_connections(), 0);
        assert_eq!(
            settings
                .with_min_pool_size_percent(100)
                .data_pool_min_connections(),
            4
        );
        assert_eq!(
            settings
                .with_min_pool_size_percent(100)
                .without_min_pool_size()
                .data_pool_min_connections(),
            0
        );
    }

    #[test]
    fn data_pool_min_connections_scales_without_overflow() {
        assert_eq!(
            settings(20, 0)
                .with_min_pool_size_percent(10)
                .data_pool_min_connections(),
            2
        );
        assert_eq!(
            settings(4, 0)
                .with_min_pool_size_percent(10)
                .data_pool_min_connections(),
            1
        );
        assert_eq!(
            settings(usize::MAX, 0)
                .with_min_pool_size_percent(50)
                .data_pool_min_connections(),
            usize::MAX / 2
        );
        assert_eq!(
            settings(usize::MAX, 0)
                .with_min_pool_size_percent(usize::MAX)
                .data_pool_min_connections(),
            usize::MAX
        );
    }

    #[test]
    fn default_reservation_and_data_capacity_by_cpu_count() {
        let config = TestDynamicConfiguration::default();
        let backend_budget = config.be_connection_budget();
        assert_eq!(backend_budget, 7);

        for (cpu_count, expected_reservation, expected_data_capacity) in [
            (0, 10, 10),
            (1, 10, 10),
            (2, 13, 7),
            (3, 14, 6),
            (32, 14, 6),
        ] {
            let reservation = backend_budget + fe_system_connection_budget_for_cpu_count(cpu_count);
            assert_eq!(reservation, expected_reservation, "CPU count: {cpu_count}");
            assert_eq!(
                settings(20, reservation).data_pool_max_connections(),
                expected_data_capacity,
                "CPU count: {cpu_count}"
            );
            assert_eq!(
                settings(expected_reservation + 1, reservation).data_pool_max_connections(),
                1
            );
            assert_eq!(
                settings(expected_reservation, reservation).data_pool_max_connections(),
                2
            );
            assert_eq!(
                settings(expected_reservation - 1, reservation).data_pool_max_connections(),
                2
            );
        }
    }

    #[test]
    fn data_pool_max_connections_does_not_underflow_when_budget_exceeds_max() {
        // Regression: when the client-connection limit is below the system
        // budget, the unsigned subtraction must not wrap to a near-`usize::MAX`
        // value (which previously caused a capacity-overflow panic when the
        // result was used as a connection-pool capacity).
        assert_eq!(
            settings(5, 10).data_pool_max_connections(),
            DEFAULT_UNCHECKED_DATA_POOL_SIZE
        );
        assert_eq!(
            settings(0, 10).data_pool_max_connections(),
            DEFAULT_UNCHECKED_DATA_POOL_SIZE
        );
        assert_eq!(
            settings(0, usize::MAX).data_pool_max_connections(),
            DEFAULT_UNCHECKED_DATA_POOL_SIZE
        );
    }

    #[test]
    fn data_pool_max_connections_uses_fallback_when_budget_exhausts_max() {
        assert_eq!(
            settings(10, 10).data_pool_max_connections(),
            DEFAULT_UNCHECKED_DATA_POOL_SIZE
        );
        assert_eq!(
            settings(0, 0).data_pool_max_connections(),
            DEFAULT_UNCHECKED_DATA_POOL_SIZE
        );
        assert_eq!(
            settings(usize::MAX, usize::MAX).data_pool_max_connections(),
            DEFAULT_UNCHECKED_DATA_POOL_SIZE
        );
    }
}
