/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/configuration/dynamic.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt::Debug;

use bson::RawBson;

use crate::{
    configuration::{
        Version, SOCKET_CONNECTION_IDLE_TIMEOUT_DEFAULT_SECS, SOCKET_CONNECTION_IDLE_TIMEOUT_KEY,
    },
    postgres::conn_mgmt,
};

pub const POSTGRES_RECOVERY_KEY: &str = "IsPostgresInRecovery";

/// The deployed `documentdb` extension version parsed from the cluster topology,
/// expressed as `major.minor-build` (for example, `1.114-0`).
///
/// Ordering is lexicographic by `major`, then `minor`, then `build`, so two
/// `ClusterVersion` values can be compared directly to test version thresholds.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord)]
pub struct ClusterVersion {
    major: u32,
    minor: u32,
    build: u32,
}

impl ClusterVersion {
    /// Creates a `ClusterVersion` from its `major`, `minor`, and `build` components.
    #[must_use]
    pub const fn new(major: u32, minor: u32, build: u32) -> Self {
        Self {
            major,
            minor,
            build,
        }
    }
}

/// Parses the cluster version from the topology BSON.
/// The topology has `documentdb_versions: ["major.minor-build", ...]`.
/// Returns the parsed `ClusterVersion` or `None` if parsing fails.
pub fn parse_cluster_version(topology: &RawBson) -> Option<ClusterVersion> {
    let doc = topology.as_document()?;
    let versions = doc.get("documentdb_versions").ok()??;
    let arr = versions.as_array()?;
    let version_str = arr.into_iter().next()?.ok()?.as_str()?;

    // Format: "major.minor-build" e.g. "1.111-0"
    let (major_minor, build_str) = version_str.split_once('-')?;
    let (major_str, minor_str) = major_minor.split_once('.')?;

    let major = major_str.parse::<u32>().ok()?;
    let minor = minor_str.parse::<u32>().ok()?;
    let build = build_str.parse::<u32>().ok()?;

    Some(ClusterVersion::new(major, minor, build))
}

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
        self.get_i32("maxWriteBatchSize", 100_000)
    }

    fn read_only(&self) -> bool {
        self.get_bool("readOnly", false)
    }

    fn send_shutdown_responses(&self) -> bool {
        self.get_bool("SendShutdownResponses", false)
    }

    fn socket_connection_idle_timeout_sec(&self) -> u64 {
        self.get_u64(
            SOCKET_CONNECTION_IDLE_TIMEOUT_KEY,
            SOCKET_CONNECTION_IDLE_TIMEOUT_DEFAULT_SECS,
        )
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

    #[expect(clippy::cast_possible_truncation, reason = "value fits in i32")]
    #[expect(clippy::cast_possible_wrap, reason = "value is small positive")]
    #[expect(clippy::cast_sign_loss, reason = "value is always positive")]
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

    fn gateway_connection_buffer_size(&self) -> usize {
        usize::try_from(self.get_u64("gatewayConnectionBufferSize", conn_mgmt::CONN_BUFFER_SIZE))
            .unwrap_or(usize::MAX)
    }

    fn slow_query_log_interval_ms(&self) -> u64 {
        self.get_u64("slowQueryLogIntervalInMilliseconds", 0)
    }

    fn tailable_cursor_await_time_slice_interval_ms(&self) -> i32 {
        self.get_i32("tailableCursorAwaitTimeSliceIntervalMs", 100)
    }

    fn enable_tailable_cursor_max_await_time(&self) -> bool {
        self.get_bool("enableTailableCursorMaxAwaitTime", true)
    }

    /// Returns the parsed `ClusterVersion` of the deployed `documentdb` extension
    /// as reported in the topology, or `None` if the topology has no version entry
    /// or it fails to parse.
    ///
    /// Implementations that already hold a topology snapshot should override
    /// this to return a cached value and avoid re-parsing the BSON on every
    /// call.
    fn cluster_version(&self) -> Option<ClusterVersion> {
        parse_cluster_version(&self.topology())
    }

    /// Returns `true` when the deployed `documentdb` extension version reported in
    /// the topology is greater than or equal to `(major, minor, build)`.
    /// Returns `false` if the topology has no version entry or it fails to parse.
    fn is_cluster_version_at_least(&self, major: u32, minor: u32, build: u32) -> bool {
        self.cluster_version()
            .is_some_and(|version| version >= ClusterVersion::new(major, minor, build))
    }

    /// # Errors
    ///
    /// Returns an error if the operation fails.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "")
    }
}

#[cfg(test)]
mod tests {
    use bson::{rawdoc, RawArrayBuf};

    use super::*;

    fn topology_with_versions(versions: &[&str]) -> RawBson {
        let mut arr = RawArrayBuf::new();
        for v in versions {
            arr.push(*v);
        }
        RawBson::Document(rawdoc! {
            "documentdb_versions": arr,
        })
    }

    #[test]
    fn parse_cluster_version_valid() {
        let topology = topology_with_versions(&["1.111-0"]);
        assert_eq!(
            parse_cluster_version(&topology),
            Some(ClusterVersion::new(1, 111, 0))
        );
    }

    #[test]
    fn parse_cluster_version_uses_first_entry() {
        let topology = topology_with_versions(&["2.5-3", "9.9-9"]);
        assert_eq!(
            parse_cluster_version(&topology),
            Some(ClusterVersion::new(2, 5, 3))
        );
    }

    #[test]
    fn parse_cluster_version_large_values() {
        let topology = topology_with_versions(&["10.250-15"]);
        assert_eq!(
            parse_cluster_version(&topology),
            Some(ClusterVersion::new(10, 250, 15))
        );
    }

    #[test]
    fn parse_cluster_version_missing_field() {
        let topology = RawBson::Document(rawdoc! { "other": "value" });
        assert_eq!(parse_cluster_version(&topology), None);
    }

    #[test]
    fn parse_cluster_version_empty_array() {
        let topology = topology_with_versions(&[]);
        assert_eq!(parse_cluster_version(&topology), None);
    }

    #[test]
    fn parse_cluster_version_missing_dash() {
        let topology = topology_with_versions(&["1.111"]);
        assert_eq!(parse_cluster_version(&topology), None);
    }

    #[test]
    fn parse_cluster_version_missing_dot() {
        let topology = topology_with_versions(&["1-0"]);
        assert_eq!(parse_cluster_version(&topology), None);
    }

    #[test]
    fn parse_cluster_version_non_numeric_major() {
        let topology = topology_with_versions(&["x.111-0"]);
        assert_eq!(parse_cluster_version(&topology), None);
    }

    #[test]
    fn parse_cluster_version_non_numeric_minor() {
        let topology = topology_with_versions(&["1.y-0"]);
        assert_eq!(parse_cluster_version(&topology), None);
    }

    #[test]
    fn parse_cluster_version_non_numeric_build() {
        let topology = topology_with_versions(&["1.111-z"]);
        assert_eq!(parse_cluster_version(&topology), None);
    }

    #[test]
    fn parse_cluster_version_negative_component_rejected() {
        // `u32::from_str` rejects the leading '-', so the build is unparsable.
        let topology = topology_with_versions(&["1.111--1"]);
        assert_eq!(parse_cluster_version(&topology), None);
    }

    #[test]
    fn parse_cluster_version_not_a_document() {
        let topology = RawBson::String("not a doc".to_owned());
        assert_eq!(parse_cluster_version(&topology), None);
    }
}
