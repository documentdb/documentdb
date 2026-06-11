/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/testing/dynamic_configuration.rs
 *
 * Shared dynamic-configuration helpers for unit tests.
 *
 *-------------------------------------------------------------------------
 */

use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};

use bson::{rawbson, RawBson};

use crate::configuration::{
    DynamicConfiguration, SOCKET_CONNECTION_IDLE_TIMEOUT_DEFAULT_SECS,
    SOCKET_CONNECTION_IDLE_TIMEOUT_KEY,
};

const UNSET_U64: u64 = u64::MAX;

#[derive(Debug)]
pub struct TestDynamicConfiguration {
    send_shutdown_responses: AtomicBool,
    allow_transaction_snapshot: AtomicBool,
    socket_connection_idle_timeout_sec: AtomicU64,
}

impl Default for TestDynamicConfiguration {
    fn default() -> Self {
        Self {
            send_shutdown_responses: AtomicBool::new(false),
            allow_transaction_snapshot: AtomicBool::new(false),
            socket_connection_idle_timeout_sec: AtomicU64::new(UNSET_U64),
        }
    }
}

impl TestDynamicConfiguration {
    pub fn set_send_shutdown_responses(&self, value: bool) {
        self.send_shutdown_responses.store(value, Ordering::Relaxed);
    }

    pub fn set_socket_connection_idle_timeout_sec(&self, value: u64) {
        self.socket_connection_idle_timeout_sec
            .store(value, Ordering::Relaxed);
    }
}

impl DynamicConfiguration for TestDynamicConfiguration {
    fn get_str(&self, _: &str) -> Option<String> {
        None
    }

    fn get_bool(&self, key: &str, default: bool) -> bool {
        match key {
            "SendShutdownResponses" => self.send_shutdown_responses.load(Ordering::Relaxed),
            _ => default,
        }
    }

    fn get_i32(&self, _: &str, default: i32) -> i32 {
        default
    }

    fn get_u64(&self, key: &str, default: u64) -> u64 {
        match key {
            SOCKET_CONNECTION_IDLE_TIMEOUT_KEY => {
                let value = self
                    .socket_connection_idle_timeout_sec
                    .load(Ordering::Relaxed);
                if value == UNSET_U64 {
                    default
                } else {
                    value
                }
            }
            _ => default,
        }
    }

    fn equals_value(&self, _: &str, _: &str) -> bool {
        false
    }

    fn topology(&self) -> RawBson {
        rawbson!({})
    }

    fn enable_developer_explain(&self) -> bool {
        false
    }

    fn max_connections(&self) -> usize {
        16
    }

    fn allow_transaction_snapshot(&self) -> bool {
        self.allow_transaction_snapshot.load(Ordering::Relaxed)
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn socket_connection_idle_timeout_uses_default() {
        let config = TestDynamicConfiguration::default();

        assert_eq!(
            config.socket_connection_idle_timeout_sec(),
            SOCKET_CONNECTION_IDLE_TIMEOUT_DEFAULT_SECS
        );
    }

    #[test]
    fn socket_connection_idle_timeout_uses_override() {
        let config = TestDynamicConfiguration::default();
        config.set_socket_connection_idle_timeout_sec(42);

        assert_eq!(config.socket_connection_idle_timeout_sec(), 42);
    }
}
