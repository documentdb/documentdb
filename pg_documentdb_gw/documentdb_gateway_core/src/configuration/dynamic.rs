/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/configuration/dynamic.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt::Debug;

use bson::RawBson;

use crate::{configuration::Version, postgres::conn_mgmt};

pub const POSTGRES_RECOVERY_KEY: &str = "IsPostgresInRecovery";

/// Used for configurations which can change during runtime.
pub trait DynamicConfiguration: Send + Sync + Debug {
    fn get_str(&self, key: &str) -> Option<String>;
    fn get_bool(&self, key: &str, default: bool) -> bool;
    fn get_i32(&self, key: &str, default: i32) -> i32;
    fn get_u64(&self, key: &str, default: u64) -> u64;
    fn equals_value(&self, key: &str, value: &str) -> bool;
    fn topology(&self) -> RawBson;
    fn enable_developer_explain(&self) -> bool;
    fn max_connections(&self) -> usize;
    fn allow_transaction_snapshot(&self) -> bool;

    // Needed to downcast to concrete type
    fn as_any(&self) -> &dyn std::any::Any;

    fn enable_change_streams(&self) -> bool {
        self.get_bool("enableChangeStreams", false)
    }

    fn enable_backend_timeout(&self) -> bool {
        self.get_bool("enableStatementTimeout", false)
    }

    fn enable_write_procedures(&self) -> bool {
        self.get_bool("enableWriteProcedures", false)
    }

    fn enable_write_procedures_with_batch_commit(&self) -> bool {
        self.get_bool("enableWriteProceduresWithBatchCommit", false)
    }

    fn enable_connection_status(&self) -> bool {
        self.get_bool("enableConnectionStatus", true)
    }

    fn enable_verbose_logging_in_gateway(&self) -> bool {
        self.get_bool("enableVerboseLoggingInGateway", false)
    }

    fn index_build_sleep_milli_secs(&self) -> i32 {
        self.get_i32("indexBuildWaitSleepTimeInMilliSec", 1000)
    }

    fn is_postgres_writable(&self) -> bool {
        !self.get_bool(POSTGRES_RECOVERY_KEY, false)
    }

    fn is_read_only_for_disk_full(&self) -> bool {
        self.get_bool("default_transaction_read_only", false)
    }

    fn is_replica_cluster(&self) -> bool {
        (self.get_bool(POSTGRES_RECOVERY_KEY, false)
            && self.equals_value("citus.use_secondary_nodes", "always"))
            || self.get_bool("simulateReadReplica", false)
    }

    fn max_write_batch_size(&self) -> i32 {
        self.get_i32("maxWriteBatchSize", 100000)
    }

    fn read_only(&self) -> bool {
        self.get_bool("readOnly", false)
    }

    fn send_shutdown_responses(&self) -> bool {
        self.get_bool("SendShutdownResponses", false)
    }

    fn server_version(&self) -> Version {
        self.get_str("serverVersion")
            .as_deref()
            .and_then(Version::parse)
            .unwrap_or(Version::Seven)
    }

    fn enable_stateless_cursor_timeout(&self) -> bool {
        self.get_bool("enableStatelessCursorTimeout", false)
    }

    fn default_cursor_idle_timeout_sec(&self) -> u64 {
        self.get_u64("mongoCursorIdleTimeoutInSeconds", 60)
    }

    fn stateless_cursor_idle_timeout_sec(&self) -> u64 {
        self.get_u64("mongoCursorStatelessIdleTimeoutInSeconds", 600)
    }

    fn cursor_resolution_interval(&self) -> u64 {
        self.get_u64("mongoCursorIdleResolutionIntervalSeconds", 5)
    }

    fn system_connection_budget(&self) -> usize {
        let min_system_connections = (conn_mgmt::SYSTEM_REQUESTS_MAX_CONNECTIONS
            + conn_mgmt::AUTHENTICATION_MAX_CONNECTIONS)
            as i32;
        let system_connection_budget =
            self.get_i32("systemConnectionBudget", min_system_connections);

        system_connection_budget as usize
    }

    fn gateway_connection_idle_lifetime_sec(&self) -> u64 {
        self.get_u64(
            "gatewayConnectionIdleLifetimeSec",
            conn_mgmt::CONN_IDLE_LIFETIME_SECS,
        )
    }

    fn gateway_connection_pruning_interval_sec(&self) -> u64 {
        self.get_u64(
            "gatewayConnectionPruningIntervalSec",
            conn_mgmt::CONN_PRUNE_INTERVAL_SECS,
        )
    }

    fn gateway_connection_lifetime_sec(&self) -> u64 {
        self.get_u64(
            "gatewayConnectionLifetimeSec",
            conn_mgmt::CONN_LIFETIME_SECS,
        )
    }

    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "")
    }
}
