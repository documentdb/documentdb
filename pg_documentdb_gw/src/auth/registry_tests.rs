/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/registry_tests.rs
 *
 * Property-based tests for AuthProviderRegistry.
 *
 *-------------------------------------------------------------------------
 */

use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::Arc;

use async_trait::async_trait;
use proptest::prelude::*;

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
// Helper: build a tokio runtime for proptest (which runs sync closures)
// ---------------------------------------------------------------------------

fn rt() -> tokio::runtime::Runtime {
    tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .expect("failed to build tokio runtime")
}

// ---------------------------------------------------------------------------
// Property tests
// ---------------------------------------------------------------------------

proptest! {
    #![proptest_config(ProptestConfig::with_cases(100))]

    // Feature: pluggable-auth-phase1, Property 1: Registry initialization calls initialize on all enabled providers
    // **Validates: Requirements 2.2, 3.1**
    #[test]
    fn prop_registry_init_calls_initialize_on_enabled(
        names in prop::collection::hash_set("[A-Z][A-Z0-9-]{2,15}", 1..6),
    ) {
        let rt = rt();
        rt.block_on(async {
            let mut registry = AuthProviderRegistry::new();
            let config = ProviderConfig::default(); // enabled: true

            let mut trackers: Vec<(String, Arc<AtomicBool>)> = Vec::new();

            for name in &names {
                let init_flag = Arc::new(AtomicBool::new(false));
                let provider = TestProvider::new_tracked(
                    name,
                    false,
                    init_flag.clone(),
                    Arc::new(AtomicBool::new(false)),
                );
                trackers.push((name.clone(), init_flag));
                registry.register(Box::new(provider), &config).await.unwrap();
            }

            for (name, init_flag) in &trackers {
                prop_assert!(
                    init_flag.load(Ordering::SeqCst),
                    "initialize() was not called for provider '{name}'"
                );
            }

            Ok(())
        })?;
    }

    // Feature: pluggable-auth-phase1, Property 2: Failed initialization skips provider without affecting others
    // **Validates: Requirements 2.3, 3.2**
    #[test]
    fn prop_failed_init_skips_without_affecting_others(
        good_names in prop::collection::hash_set("[A-Z][A-Z0-9-]{2,15}", 1..4),
        bad_names in prop::collection::hash_set("[a-z][a-z0-9-]{2,15}", 1..4),
    ) {
        let rt = rt();
        rt.block_on(async {
            let mut registry = AuthProviderRegistry::new();
            let config = ProviderConfig::default();

            // Register good providers
            for name in &good_names {
                let provider = TestProvider::new(name, false);
                registry.register(Box::new(provider), &config).await.unwrap();
            }

            // Register bad providers (init fails)
            for name in &bad_names {
                let provider = TestProvider::new(name, true);
                // register should still return Ok — failure is logged, not propagated
                registry.register(Box::new(provider), &config).await.unwrap();
            }

            // Good providers should be accessible
            for name in &good_names {
                prop_assert!(
                    registry.get_provider(name).is_ok(),
                    "Good provider '{name}' should be registered"
                );
            }

            // Bad providers should NOT be accessible
            for name in &bad_names {
                prop_assert!(
                    registry.get_provider(name).is_err(),
                    "Bad provider '{name}' should NOT be registered"
                );
            }

            Ok(())
        })?;
    }

    // Feature: pluggable-auth-phase1, Property 3: Duplicate mechanism registration is rejected
    // **Validates: Requirements 2.4**
    #[test]
    fn prop_duplicate_mechanism_rejected(
        name in "[A-Z][A-Z0-9-]{2,15}",
    ) {
        let rt = rt();
        rt.block_on(async {
            let mut registry = AuthProviderRegistry::new();
            let config = ProviderConfig::default();

            let p1 = TestProvider::new(&name, false);
            registry.register(Box::new(p1), &config).await.unwrap();

            let p2 = TestProvider::new(&name, false);
            let result = registry.register(Box::new(p2), &config).await;
            prop_assert!(result.is_err(), "Second registration of '{name}' should fail");

            // First provider should still be accessible
            prop_assert!(
                registry.get_provider(&name).is_ok(),
                "First provider '{name}' should still be accessible after duplicate rejection"
            );

            Ok(())
        })?;
    }

    // Feature: pluggable-auth-phase1, Property 4: Registry lookup correctness
    // **Validates: Requirements 2.5, 2.6**
    #[test]
    fn prop_registry_lookup_correctness(
        registered in prop::collection::hash_set("[A-Z][A-Z0-9-]{2,15}", 1..6),
        query in "[A-Z][A-Z0-9-]{2,15}",
    ) {
        let rt = rt();
        rt.block_on(async {
            let mut registry = AuthProviderRegistry::new();
            let config = ProviderConfig::default();

            for name in &registered {
                let provider = TestProvider::new(name, false);
                registry.register(Box::new(provider), &config).await.unwrap();
            }

            let result = registry.get_provider(&query);
            if registered.contains(&query) {
                prop_assert!(result.is_ok(), "Registered mechanism '{query}' should be found");
                let provider = result.unwrap();
                prop_assert_eq!(provider.mechanism_name(), query.as_str());
            } else {
                prop_assert!(result.is_err(), "Unregistered mechanism '{query}' should return error");
            }

            Ok(())
        })?;
    }

    // Feature: pluggable-auth-phase1, Property 5: list_enabled_mechanisms returns exactly registered names
    // **Validates: Requirements 2.7**
    #[test]
    fn prop_list_enabled_mechanisms_exact(
        names in prop::collection::hash_set("[A-Z][A-Z0-9-]{2,15}", 0..6),
    ) {
        let rt = rt();
        rt.block_on(async {
            let mut registry = AuthProviderRegistry::new();
            let config = ProviderConfig::default();

            for name in &names {
                let provider = TestProvider::new(name, false);
                registry.register(Box::new(provider), &config).await.unwrap();
            }

            let mut listed: Vec<&str> = registry.list_enabled_mechanisms();
            listed.sort();
            let mut expected: Vec<&str> = names.iter().map(|s| s.as_str()).collect();
            expected.sort();

            prop_assert_eq!(listed, expected);

            Ok(())
        })?;
    }

    // Feature: pluggable-auth-phase1, Property 14: Disabled providers are not registered
    // **Validates: Requirements 8.3**
    #[test]
    fn prop_disabled_providers_not_registered(
        enabled_names in prop::collection::hash_set("[A-Z][A-Z0-9-]{2,15}", 0..4),
        disabled_names in prop::collection::hash_set("[a-z][a-z0-9-]{2,15}", 1..4),
    ) {
        let rt = rt();
        rt.block_on(async {
            let mut registry = AuthProviderRegistry::new();
            let enabled_config = ProviderConfig { enabled: true, ..Default::default() };
            let disabled_config = ProviderConfig { enabled: false, ..Default::default() };

            for name in &enabled_names {
                let provider = TestProvider::new(name, false);
                registry.register(Box::new(provider), &enabled_config).await.unwrap();
            }

            let mut disabled_init_flags: Vec<(String, Arc<AtomicBool>)> = Vec::new();
            for name in &disabled_names {
                let init_flag = Arc::new(AtomicBool::new(false));
                let provider = TestProvider::new_tracked(
                    name,
                    false,
                    init_flag.clone(),
                    Arc::new(AtomicBool::new(false)),
                );
                disabled_init_flags.push((name.clone(), init_flag));
                registry.register(Box::new(provider), &disabled_config).await.unwrap();
            }

            // Disabled providers should not be findable
            for name in &disabled_names {
                prop_assert!(
                    registry.get_provider(name).is_err(),
                    "Disabled provider '{name}' should not be registered"
                );
            }

            // Disabled providers should not have had initialize() called
            for (name, init_flag) in &disabled_init_flags {
                prop_assert!(
                    !init_flag.load(Ordering::SeqCst),
                    "initialize() should NOT be called for disabled provider '{name}'"
                );
            }

            // Enabled providers should still be accessible
            for name in &enabled_names {
                prop_assert!(
                    registry.get_provider(name).is_ok(),
                    "Enabled provider '{name}' should be registered"
                );
            }

            // list_enabled_mechanisms should only contain enabled names
            let listed: std::collections::HashSet<&str> =
                registry.list_enabled_mechanisms().into_iter().collect();
            for name in &disabled_names {
                prop_assert!(
                    !listed.contains(name.as_str()),
                    "Disabled provider '{name}' should not appear in list_enabled_mechanisms"
                );
            }

            Ok(())
        })?;
    }
}
