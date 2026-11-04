/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/testing/dynamic_configuration.rs
 *
 * Shared dynamic-configuration helpers for unit tests.
 *
 *-------------------------------------------------------------------------
 */

use std::{
    collections::HashMap,
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        RwLock,
    },
};

use bson::{rawbson, RawBson};

use crate::configuration::{
    DynamicConfiguration, CONNECTION_GRACEFUL_CLOSURE_INTERVAL_SEC_KEY,
    ENABLE_GRACEFUL_CLOSURE_ON_CERT_ROTATION_KEY, ENABLE_WRITE_CONCERN_VALIDATION_KEY,
    MAX_REQUEST_TIMEOUT_DEFAULT_SEC, MAX_REQUEST_TIMEOUT_SEC_KEY,
    SOCKET_CONNECTION_IDLE_TIMEOUT_DEFAULT_SECS, SOCKET_CONNECTION_IDLE_TIMEOUT_KEY,
    TRANSACTION_TIMEOUT_DEFAULT_SEC, TRANSACTION_TIMEOUT_SEC_KEY,
};

const UNSET_U64: u64 = u64::MAX;

#[derive(Debug)]
pub struct TestDynamicConfiguration {
    bool_overrides: RwLock<HashMap<&'static str, bool>>,
    i32_overrides: RwLock<HashMap<&'static str, i32>>,
    u64_overrides: RwLock<HashMap<&'static str, u64>>,
    send_shutdown_responses: AtomicBool,
    allow_transaction_snapshot: AtomicBool,
    enable_role_crud: AtomicBool,
    enable_write_concern_validation: AtomicBool,
    socket_connection_idle_timeout_sec: AtomicU64,
    enable_graceful_closure_on_cert_rotation: AtomicBool,
    connection_graceful_closure_interval_sec: AtomicU64,
    endpoint_routable: AtomicBool,
    report_endpoint_name: AtomicBool,
    enable_change_streams: AtomicBool,
}

impl Default for TestDynamicConfiguration {
    fn default() -> Self {
        Self {
            bool_overrides: RwLock::new(HashMap::new()),
            i32_overrides: RwLock::new(HashMap::new()),
            u64_overrides: RwLock::new(HashMap::new()),
            send_shutdown_responses: AtomicBool::new(false),
            allow_transaction_snapshot: AtomicBool::new(false),
            enable_role_crud: AtomicBool::new(false),
            enable_write_concern_validation: AtomicBool::new(true),
            socket_connection_idle_timeout_sec: AtomicU64::new(UNSET_U64),
            enable_graceful_closure_on_cert_rotation: AtomicBool::new(false),
            connection_graceful_closure_interval_sec: AtomicU64::new(UNSET_U64),
            endpoint_routable: AtomicBool::new(true),
            report_endpoint_name: AtomicBool::new(false),
            enable_change_streams: AtomicBool::new(false),
        }
    }
}

impl TestDynamicConfiguration {
    pub fn set_bool(&self, key: &'static str, value: bool) {
        self.bool_overrides
            .write()
            .expect("test configuration lock")
            .insert(key, value);
    }

    pub fn set_i32(&self, key: &'static str, value: i32) {
        self.i32_overrides
            .write()
            .expect("test configuration lock")
            .insert(key, value);
    }

    pub fn set_u64(&self, key: &'static str, value: u64) {
        self.u64_overrides
            .write()
            .expect("test configuration lock")
            .insert(key, value);
    }

    pub fn set_send_shutdown_responses(&self, value: bool) {
        self.send_shutdown_responses.store(value, Ordering::Relaxed);
    }

    pub fn set_enable_role_crud(&self, value: bool) {
        self.enable_role_crud.store(value, Ordering::Relaxed);
    }

    pub fn set_enable_write_concern_validation(&self, value: bool) {
        self.enable_write_concern_validation
            .store(value, Ordering::Relaxed);
    }

    pub fn set_socket_connection_idle_timeout_sec(&self, value: u64) {
        self.socket_connection_idle_timeout_sec
            .store(value, Ordering::Relaxed);
    }

    pub fn set_enable_graceful_closure_on_cert_rotation(&self, value: bool) {
        self.enable_graceful_closure_on_cert_rotation
            .store(value, Ordering::Relaxed);
    }

    pub fn set_connection_graceful_closure_interval_sec(&self, value: u64) {
        self.connection_graceful_closure_interval_sec
            .store(value, Ordering::Relaxed);
    }

    pub fn set_endpoint_routable(&self, value: bool) {
        self.endpoint_routable.store(value, Ordering::Relaxed);
    }

    pub fn set_report_endpoint_name(&self, value: bool) {
        self.report_endpoint_name.store(value, Ordering::Relaxed);
    }

    pub fn set_enable_change_streams(&self, value: bool) {
        self.enable_change_streams.store(value, Ordering::Relaxed);
    }
}

impl DynamicConfiguration for TestDynamicConfiguration {
    fn get_str(&self, _: &str) -> Option<String> {
        None
    }

    fn get_bool(&self, key: &str, default: bool) -> bool {
        if let Some(value) = self
            .bool_overrides
            .read()
            .expect("test configuration lock")
            .get(key)
        {
            return *value;
        }
        match key {
            "enableRoleCrud" => self.enable_role_crud.load(Ordering::Relaxed),
            ENABLE_WRITE_CONCERN_VALIDATION_KEY => {
                self.enable_write_concern_validation.load(Ordering::Relaxed)
            }
            "SendShutdownResponses" => self.send_shutdown_responses.load(Ordering::Relaxed),
            ENABLE_GRACEFUL_CLOSURE_ON_CERT_ROTATION_KEY => self
                .enable_graceful_closure_on_cert_rotation
                .load(Ordering::Relaxed),
            _ => default,
        }
    }

    fn get_i32(&self, key: &str, default: i32) -> i32 {
        self.i32_overrides
            .read()
            .expect("test configuration lock")
            .get(key)
            .copied()
            .unwrap_or(default)
    }

    fn get_u64(&self, key: &str, default: u64) -> u64 {
        if let Some(value) = self
            .u64_overrides
            .read()
            .expect("test configuration lock")
            .get(key)
        {
            return *value;
        }
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
            CONNECTION_GRACEFUL_CLOSURE_INTERVAL_SEC_KEY => {
                let value = self
                    .connection_graceful_closure_interval_sec
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

    fn get_usize(&self, key: &str, default: usize) -> usize {
        usize::try_from(self.get_u64(key, default as u64)).unwrap_or(default)
    }

    fn equals_value(&self, _: &str, _: &str) -> bool {
        false
    }

    fn topology(&self) -> RawBson {
        rawbson!({})
    }

    fn max_connections(&self) -> usize {
        16
    }

    fn allow_transaction_snapshot(&self) -> bool {
        self.allow_transaction_snapshot.load(Ordering::Relaxed)
    }

    fn max_request_timeout_sec(&self) -> u64 {
        self.get_u64(MAX_REQUEST_TIMEOUT_SEC_KEY, MAX_REQUEST_TIMEOUT_DEFAULT_SEC)
    }

    fn transaction_timeout_sec(&self) -> u64 {
        self.get_u64(TRANSACTION_TIMEOUT_SEC_KEY, TRANSACTION_TIMEOUT_DEFAULT_SEC)
    }

    fn as_any(&self) -> &dyn std::any::Any {
        self
    }

    fn enable_request_metrics(&self) -> bool {
        false
    }

    fn is_endpoint_routable(&self, _server_name: Option<&str>) -> bool {
        self.endpoint_routable.load(Ordering::Relaxed)
    }

    fn report_endpoint_name(&self) -> bool {
        self.report_endpoint_name.load(Ordering::Relaxed)
    }

    fn enable_change_streams(&self) -> bool {
        self.enable_change_streams.load(Ordering::Relaxed)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn unsigned_configuration_uses_defaults() {
        let config = TestDynamicConfiguration::default();

        assert_eq!(config.get_u64("systemConnectionBudget", u64::MAX), u64::MAX);
        assert_eq!(
            config.get_usize("systemConnectionBudget", usize::MAX),
            usize::MAX
        );
    }

    #[test]
    fn unsigned_configuration_uses_overrides() {
        let config = TestDynamicConfiguration::default();

        for value in [0, 42, usize::MAX] {
            config.set_u64("systemConnectionBudget", value as u64);

            assert_eq!(config.get_u64("systemConnectionBudget", 10), value as u64);
            assert_eq!(config.get_usize("systemConnectionBudget", 10), value);
        }
    }

    #[test]
    fn unsigned_configuration_does_not_read_signed_overrides() {
        let config = TestDynamicConfiguration::default();
        config.set_i32("systemConnectionBudget", -1);

        assert_eq!(config.get_i32("systemConnectionBudget", 10), -1);
        assert_eq!(config.get_u64("systemConnectionBudget", 10), 10);
        assert_eq!(config.get_usize("systemConnectionBudget", 10), 10);
    }

    #[cfg(target_pointer_width = "32")]
    #[test]
    fn usize_configuration_uses_default_when_override_is_too_large() {
        let config = TestDynamicConfiguration::default();
        config.set_u64("systemConnectionBudget", u64::from(u32::MAX) + 1);

        assert_eq!(config.get_usize("systemConnectionBudget", 10), 10);
    }

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

    #[test]
    fn enable_write_concern_validation_defaults_to_true() {
        let config = TestDynamicConfiguration::default();

        assert!(config.enable_write_concern_validation());
    }

    #[test]
    fn enable_write_concern_validation_honors_override() {
        let config = TestDynamicConfiguration::default();
        config.set_enable_write_concern_validation(false);

        assert!(!config.enable_write_concern_validation());
    }
}
