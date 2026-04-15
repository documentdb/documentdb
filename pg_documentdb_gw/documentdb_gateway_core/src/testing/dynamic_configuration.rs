/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/testing/dynamic_configuration.rs
 *
 * Shared dynamic-configuration helpers for unit tests.
 *
 *-------------------------------------------------------------------------
 */

use std::sync::atomic::{AtomicBool, Ordering};

use bson::{rawbson, RawBson};

use crate::configuration::DynamicConfiguration;

#[derive(Debug, Default)]
pub struct TestDynamicConfiguration {
    send_shutdown_responses: AtomicBool,
    allow_transaction_snapshot: AtomicBool,
}

impl TestDynamicConfiguration {
    pub fn set_send_shutdown_responses(&self, value: bool) {
        self.send_shutdown_responses.store(value, Ordering::Relaxed);
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

    fn get_u64(&self, _: &str, default: u64) -> u64 {
        default
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
