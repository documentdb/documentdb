/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/registry_tests.rs
 *
 * Unit tests for AuthProviderRegistry.
 *
 *-------------------------------------------------------------------------
 */

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use async_trait::async_trait;

use crate::auth::provider::{AuthProvider, ProviderConfig};
use crate::auth::registry::AuthProviderRegistry;
use crate::context::ConnectionContext;
use crate::error::{DocumentDBError, Result};
use crate::requests::Request;
use crate::responses::Response;

// ---------------------------------------------------------------------------
// Mock TestProvider
// ---------------------------------------------------------------------------

struct TestProvider {
    name: String,
    should_fail_init: bool,
    init_called: Arc<AtomicBool>,
    shutdown_called: Arc<AtomicBool>,
}

impl TestProvider {
    fn new(name: &str, should_fail_init: bool) -> Self {
        TestProvider {
            name: name.to_string(),
            should_fail_init,
            init_called: Arc::new(AtomicBool::new(false)),
            shutdown_called: Arc::new(AtomicBool::new(false)),
        }
    }

    fn new_tracked(
        name: &str,
        should_fail_init: bool,
        init_called: Arc<AtomicBool>,
        shutdown_called: Arc<AtomicBool>,
    ) -> Self {
        TestProvider {
            name: name.to_string(),
            should_fail_init,
            init_called,
            shutdown_called,
        }
    }
}

#[async_trait]
impl AuthProvider for TestProvider {
    fn mechanism_name(&self) -> &str {
        &self.name
    }

    async fn handle_sasl_start(
        &self,
        _connection_context: &mut ConnectionContext,
        _request: &Request<'_>,
    ) -> Result<Response> {
        unimplemented!("not used in registry tests")
    }

    async fn handle_sasl_continue(
        &self,
        _connection_context: &mut ConnectionContext,
        _request: &Request<'_>,
    ) -> Result<Response> {
        unimplemented!("not used in registry tests")
    }

    async fn initialize(&mut self, _config: &ProviderConfig) -> Result<()> {
        self.init_called.store(true, Ordering::SeqCst);
        if self.should_fail_init {
            Err(DocumentDBError::internal_error(format!(
                "Simulated init failure for '{}'",
                self.name
            )))
        } else {
            Ok(())
        }
    }

    async fn shutdown(&mut self) -> Result<()> {
        self.shutdown_called.store(true, Ordering::SeqCst);
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Tests — Registry initialization (Requirements 2.2, 3.1)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn register_calls_initialize_on_enabled_providers() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    let init_a = Arc::new(AtomicBool::new(false));
    let init_b = Arc::new(AtomicBool::new(false));

    let provider_a = TestProvider::new_tracked("MECH-A", false, init_a.clone(), Arc::new(AtomicBool::new(false)));
    let provider_b = TestProvider::new_tracked("MECH-B", false, init_b.clone(), Arc::new(AtomicBool::new(false)));

    registry.register(Box::new(provider_a), &config).await.unwrap();
    registry.register(Box::new(provider_b), &config).await.unwrap();

    assert!(init_a.load(Ordering::SeqCst), "initialize() should be called for MECH-A");
    assert!(init_b.load(Ordering::SeqCst), "initialize() should be called for MECH-B");
}

// ---------------------------------------------------------------------------
// Tests — Failed initialization (Requirements 2.3, 3.2)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn failed_init_skips_provider_without_affecting_others() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    let good = TestProvider::new("GOOD-MECH", false);
    let bad = TestProvider::new("BAD-MECH", true);

    registry.register(Box::new(good), &config).await.unwrap();
    registry.register(Box::new(bad), &config).await.unwrap();

    assert!(registry.get_provider("GOOD-MECH").is_ok(), "Good provider should be registered");
    assert!(registry.get_provider("BAD-MECH").is_err(), "Bad provider should NOT be registered");
}

#[tokio::test]
async fn failed_init_does_not_block_subsequent_registrations() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    let bad = TestProvider::new("FAILS", true);
    let good = TestProvider::new("WORKS", false);

    registry.register(Box::new(bad), &config).await.unwrap();
    registry.register(Box::new(good), &config).await.unwrap();

    assert!(registry.get_provider("WORKS").is_ok());
    assert!(registry.get_provider("FAILS").is_err());
}

// ---------------------------------------------------------------------------
// Tests — Duplicate registration (Requirement 2.4)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn duplicate_mechanism_registration_is_rejected() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    let p1 = TestProvider::new("SCRAM-SHA-256", false);
    let p2 = TestProvider::new("SCRAM-SHA-256", false);

    registry.register(Box::new(p1), &config).await.unwrap();
    let result = registry.register(Box::new(p2), &config).await;

    assert!(result.is_err(), "Second registration of same mechanism should fail");
    assert!(registry.get_provider("SCRAM-SHA-256").is_ok(), "First provider should still be accessible");
}

// ---------------------------------------------------------------------------
// Tests — Lookup correctness (Requirements 2.5, 2.6)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn get_provider_returns_correct_provider() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    registry.register(Box::new(TestProvider::new("SCRAM-SHA-256", false)), &config).await.unwrap();
    registry.register(Box::new(TestProvider::new("MONGODB-OIDC", false)), &config).await.unwrap();

    let provider = registry.get_provider("SCRAM-SHA-256").unwrap();
    assert_eq!(provider.mechanism_name(), "SCRAM-SHA-256");

    let provider = registry.get_provider("MONGODB-OIDC").unwrap();
    assert_eq!(provider.mechanism_name(), "MONGODB-OIDC");
}

#[tokio::test]
async fn get_provider_returns_error_for_unknown_mechanism() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    registry.register(Box::new(TestProvider::new("SCRAM-SHA-256", false)), &config).await.unwrap();

    let result = registry.get_provider("UNKNOWN-MECH");
    assert!(result.is_err(), "Unknown mechanism should return error");
}

#[tokio::test]
async fn get_provider_on_empty_registry_returns_error() {
    let registry = AuthProviderRegistry::new();
    assert!(registry.get_provider("ANYTHING").is_err());
}

// ---------------------------------------------------------------------------
// Tests — list_enabled_mechanisms (Requirement 2.7)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn list_enabled_mechanisms_returns_all_registered() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    registry.register(Box::new(TestProvider::new("SCRAM-SHA-256", false)), &config).await.unwrap();
    registry.register(Box::new(TestProvider::new("MONGODB-OIDC", false)), &config).await.unwrap();

    let mut mechanisms = registry.list_enabled_mechanisms();
    mechanisms.sort();
    assert_eq!(mechanisms, vec!["MONGODB-OIDC", "SCRAM-SHA-256"]);
}

#[tokio::test]
async fn list_enabled_mechanisms_empty_registry() {
    let registry = AuthProviderRegistry::new();
    assert!(registry.list_enabled_mechanisms().is_empty());
}

#[tokio::test]
async fn list_enabled_mechanisms_excludes_failed_providers() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    registry.register(Box::new(TestProvider::new("GOOD", false)), &config).await.unwrap();
    registry.register(Box::new(TestProvider::new("BAD", true)), &config).await.unwrap();

    let mechanisms = registry.list_enabled_mechanisms();
    assert_eq!(mechanisms, vec!["GOOD"]);
}

// ---------------------------------------------------------------------------
// Tests — Disabled providers (Requirement 8.3)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn disabled_provider_is_not_registered() {
    let mut registry = AuthProviderRegistry::new();
    let disabled_config = ProviderConfig { enabled: false, ..Default::default() };

    let init_flag = Arc::new(AtomicBool::new(false));
    let provider = TestProvider::new_tracked("DISABLED", false, init_flag.clone(), Arc::new(AtomicBool::new(false)));

    registry.register(Box::new(provider), &disabled_config).await.unwrap();

    assert!(registry.get_provider("DISABLED").is_err(), "Disabled provider should not be registered");
    assert!(!init_flag.load(Ordering::SeqCst), "initialize() should NOT be called for disabled provider");
    assert!(registry.list_enabled_mechanisms().is_empty());
}

#[tokio::test]
async fn disabled_provider_does_not_affect_enabled_ones() {
    let mut registry = AuthProviderRegistry::new();
    let enabled_config = ProviderConfig::default();
    let disabled_config = ProviderConfig { enabled: false, ..Default::default() };

    registry.register(Box::new(TestProvider::new("ENABLED", false)), &enabled_config).await.unwrap();
    registry.register(Box::new(TestProvider::new("DISABLED", false)), &disabled_config).await.unwrap();

    assert!(registry.get_provider("ENABLED").is_ok());
    assert!(registry.get_provider("DISABLED").is_err());
    assert_eq!(registry.list_enabled_mechanisms(), vec!["ENABLED"]);
}

// ---------------------------------------------------------------------------
// Tests — Shutdown (Requirement 3.3)
// ---------------------------------------------------------------------------

#[tokio::test]
async fn shutdown_all_calls_shutdown_on_all_providers() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    let shutdown_a = Arc::new(AtomicBool::new(false));
    let shutdown_b = Arc::new(AtomicBool::new(false));

    let provider_a = TestProvider::new_tracked("MECH-A", false, Arc::new(AtomicBool::new(false)), shutdown_a.clone());
    let provider_b = TestProvider::new_tracked("MECH-B", false, Arc::new(AtomicBool::new(false)), shutdown_b.clone());

    registry.register(Box::new(provider_a), &config).await.unwrap();
    registry.register(Box::new(provider_b), &config).await.unwrap();

    registry.shutdown_all().await;

    assert!(shutdown_a.load(Ordering::SeqCst), "shutdown() should be called for MECH-A");
    assert!(shutdown_b.load(Ordering::SeqCst), "shutdown() should be called for MECH-B");
}

#[tokio::test]
async fn shutdown_all_empties_the_registry() {
    let mut registry = AuthProviderRegistry::new();
    let config = ProviderConfig::default();

    registry.register(Box::new(TestProvider::new("MECH-A", false)), &config).await.unwrap();
    registry.shutdown_all().await;

    assert!(registry.list_enabled_mechanisms().is_empty());
    assert!(registry.get_provider("MECH-A").is_err());
}
