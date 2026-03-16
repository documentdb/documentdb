/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/auth/registry.rs
 *
 * AuthProviderRegistry — central registry for provider lookup.
 * Read-only after initialization; uses a plain HashMap (no locks
 * needed for concurrent reads).
 *
 *-------------------------------------------------------------------------
 */

use std::collections::HashMap;
use std::sync::Arc;

use bson::RawArrayBuf;
use tokio::time::{timeout, Duration};

use crate::error::{DocumentDBError, Result};

use super::provider::{AuthProvider, ProviderConfig};

/// Timeout applied to each provider's `shutdown()` call.
const SHUTDOWN_TIMEOUT_SECS: u64 = 30;

/// Central registry mapping SASL mechanism names to provider implementations.
/// Read-only after initialization — no locks needed for concurrent reads.
pub struct AuthProviderRegistry {
    providers: HashMap<String, Arc<dyn AuthProvider>>,
    /// Cached list of mechanism names, built during registration.
    enabled_mechanisms: Vec<String>,
    /// Pre-built BSON array for the Hello/isMaster response.
    mechanisms_bson: RawArrayBuf,
}

impl Default for AuthProviderRegistry {
    fn default() -> Self {
        Self::new()
    }
}

impl AuthProviderRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        AuthProviderRegistry {
            providers: HashMap::new(),
            enabled_mechanisms: Vec::new(),
            mechanisms_bson: RawArrayBuf::new(),
        }
    }

    /// Register a provider. If the provider's config has `enabled: false`,
    /// registration is silently skipped. Otherwise the provider is
    /// initialized, and on success inserted into the map.
    pub async fn register(
        &mut self,
        mut provider: Box<dyn AuthProvider>,
        config: &ProviderConfig,
    ) -> Result<()> {
        if !config.enabled {
            tracing::info!(
                "Provider '{}' is disabled — skipping registration",
                provider.mechanism_name()
            );
            return Ok(());
        }

        let mechanism = provider.mechanism_name().to_string();

        if self.providers.contains_key(&mechanism) {
            return Err(DocumentDBError::internal_error(format!(
                "Duplicate auth provider registration for mechanism '{mechanism}'"
            )));
        }

        match provider.initialize(config).await {
            Ok(()) => {
                tracing::info!("Auth provider '{mechanism}' initialized successfully");
                self.enabled_mechanisms.push(mechanism.clone());
                self.mechanisms_bson.push(mechanism.as_str());
                self.providers.insert(mechanism, Arc::from(provider));
                Ok(())
            }
            Err(e) => {
                tracing::error!(
                    "Auth provider '{mechanism}' failed to initialize: {e} — skipping"
                );
                Ok(())
            }
        }
    }

    /// O(1) lookup by SASL mechanism name.
    pub fn get_provider(&self, mechanism: &str) -> Result<Arc<dyn AuthProvider>> {
        self.providers.get(mechanism).cloned().ok_or_else(|| {
            let supported: Vec<&str> = self.providers.keys().map(|s| s.as_str()).collect();
            DocumentDBError::authentication_failed(format!(
                "Mechanism '{mechanism}' is not supported. Supported mechanisms: {supported:?}"
            ))
        })
    }

    /// Returns the names of all registered (enabled) mechanisms.
    pub fn list_enabled_mechanisms(&self) -> &[String] {
        &self.enabled_mechanisms
    }

    /// Returns a pre-built BSON array of mechanism names for the Hello response.
    pub fn mechanisms_bson(&self) -> &RawArrayBuf {
        &self.mechanisms_bson
    }

    /// Gracefully shut down every registered provider with a 30-second
    /// timeout per provider.
    pub async fn shutdown_all(&mut self) {
        let providers = std::mem::take(&mut self.providers);
        self.enabled_mechanisms.clear();
        self.mechanisms_bson = RawArrayBuf::new();

        for (mechanism, mut arc_provider) in providers {
            if let Some(provider) = Arc::get_mut(&mut arc_provider) {
                match timeout(
                    Duration::from_secs(SHUTDOWN_TIMEOUT_SECS),
                    provider.shutdown(),
                )
                .await
                {
                    Ok(Ok(())) => {
                        tracing::info!("Auth provider '{mechanism}' shut down successfully");
                    }
                    Ok(Err(e)) => {
                        tracing::warn!(
                            "Auth provider '{mechanism}' shutdown returned error: {e}"
                        );
                    }
                    Err(_) => {
                        tracing::warn!(
                            "Auth provider '{mechanism}' shutdown timed out after {SHUTDOWN_TIMEOUT_SECS}s"
                        );
                    }
                }
            } else {
                tracing::warn!(
                    "Auth provider '{mechanism}' has outstanding references — cannot call shutdown"
                );
            }
        }
    }
}


#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::atomic::{AtomicBool, Ordering};
    use async_trait::async_trait;

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
            _ctx: &mut crate::context::ConnectionContext,
            _req: &crate::requests::Request<'_>,
        ) -> Result<crate::responses::Response> {
            unimplemented!("not used in registry tests")
        }

        async fn handle_sasl_continue(
            &self,
            _ctx: &mut crate::context::ConnectionContext,
            _req: &crate::requests::Request<'_>,
        ) -> Result<crate::responses::Response> {
            unimplemented!("not used in registry tests")
        }

        async fn initialize(&mut self, _config: &ProviderConfig) -> Result<()> {
            self.init_called.store(true, Ordering::SeqCst);
            if self.should_fail_init {
                Err(DocumentDBError::internal_error(format!(
                    "Simulated init failure for '{}'", self.name
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

    // -----------------------------------------------------------------------
    // Tests — Registry initialization
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn register_calls_initialize_on_enabled_providers() {
        let mut registry = AuthProviderRegistry::new();
        let config = ProviderConfig::default();
        let init_a = Arc::new(AtomicBool::new(false));
        let init_b = Arc::new(AtomicBool::new(false));
        let pa = TestProvider::new_tracked("MECH-A", false, init_a.clone(), Arc::new(AtomicBool::new(false)));
        let pb = TestProvider::new_tracked("MECH-B", false, init_b.clone(), Arc::new(AtomicBool::new(false)));
        registry.register(Box::new(pa), &config).await.unwrap();
        registry.register(Box::new(pb), &config).await.unwrap();
        assert!(init_a.load(Ordering::SeqCst));
        assert!(init_b.load(Ordering::SeqCst));
    }

    // -----------------------------------------------------------------------
    // Tests — Failed initialization
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn failed_init_skips_provider_without_affecting_others() {
        let mut registry = AuthProviderRegistry::new();
        let config = ProviderConfig::default();
        registry.register(Box::new(TestProvider::new("GOOD", false)), &config).await.unwrap();
        registry.register(Box::new(TestProvider::new("BAD", true)), &config).await.unwrap();
        assert!(registry.get_provider("GOOD").is_ok());
        assert!(registry.get_provider("BAD").is_err());
    }

    #[tokio::test]
    async fn failed_init_does_not_block_subsequent_registrations() {
        let mut registry = AuthProviderRegistry::new();
        let config = ProviderConfig::default();
        registry.register(Box::new(TestProvider::new("FAILS", true)), &config).await.unwrap();
        registry.register(Box::new(TestProvider::new("WORKS", false)), &config).await.unwrap();
        assert!(registry.get_provider("WORKS").is_ok());
        assert!(registry.get_provider("FAILS").is_err());
    }

    // -----------------------------------------------------------------------
    // Tests — Duplicate registration
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn duplicate_mechanism_registration_is_rejected() {
        let mut registry = AuthProviderRegistry::new();
        let config = ProviderConfig::default();
        registry.register(Box::new(TestProvider::new("SCRAM-SHA-256", false)), &config).await.unwrap();
        let result = registry.register(Box::new(TestProvider::new("SCRAM-SHA-256", false)), &config).await;
        assert!(result.is_err());
        assert!(registry.get_provider("SCRAM-SHA-256").is_ok());
    }

    // -----------------------------------------------------------------------
    // Tests — Lookup correctness
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn get_provider_returns_correct_provider() {
        let mut registry = AuthProviderRegistry::new();
        let config = ProviderConfig::default();
        registry.register(Box::new(TestProvider::new("SCRAM-SHA-256", false)), &config).await.unwrap();
        registry.register(Box::new(TestProvider::new("MONGODB-OIDC", false)), &config).await.unwrap();
        assert_eq!(registry.get_provider("SCRAM-SHA-256").unwrap().mechanism_name(), "SCRAM-SHA-256");
        assert_eq!(registry.get_provider("MONGODB-OIDC").unwrap().mechanism_name(), "MONGODB-OIDC");
    }

    #[tokio::test]
    async fn get_provider_returns_error_for_unknown_mechanism() {
        let mut registry = AuthProviderRegistry::new();
        let config = ProviderConfig::default();
        registry.register(Box::new(TestProvider::new("SCRAM-SHA-256", false)), &config).await.unwrap();
        assert!(registry.get_provider("UNKNOWN").is_err());
    }

    #[tokio::test]
    async fn get_provider_on_empty_registry_returns_error() {
        let registry = AuthProviderRegistry::new();
        assert!(registry.get_provider("ANYTHING").is_err());
    }

    // -----------------------------------------------------------------------
    // Tests — list_enabled_mechanisms
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn list_enabled_mechanisms_returns_all_registered() {
        let mut registry = AuthProviderRegistry::new();
        let config = ProviderConfig::default();
        registry.register(Box::new(TestProvider::new("SCRAM-SHA-256", false)), &config).await.unwrap();
        registry.register(Box::new(TestProvider::new("MONGODB-OIDC", false)), &config).await.unwrap();
        let mut mechs: Vec<&str> = registry.list_enabled_mechanisms().iter().map(|s| s.as_str()).collect();
        mechs.sort();
        assert_eq!(mechs, vec!["MONGODB-OIDC", "SCRAM-SHA-256"]);
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
        assert_eq!(registry.list_enabled_mechanisms(), vec!["GOOD"]);
    }

    // -----------------------------------------------------------------------
    // Tests — Disabled providers
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn disabled_provider_is_not_registered() {
        let mut registry = AuthProviderRegistry::new();
        let disabled = ProviderConfig { enabled: false, ..Default::default() };
        let init_flag = Arc::new(AtomicBool::new(false));
        let p = TestProvider::new_tracked("DISABLED", false, init_flag.clone(), Arc::new(AtomicBool::new(false)));
        registry.register(Box::new(p), &disabled).await.unwrap();
        assert!(registry.get_provider("DISABLED").is_err());
        assert!(!init_flag.load(Ordering::SeqCst));
        assert!(registry.list_enabled_mechanisms().is_empty());
    }

    #[tokio::test]
    async fn disabled_provider_does_not_affect_enabled_ones() {
        let mut registry = AuthProviderRegistry::new();
        let enabled = ProviderConfig::default();
        let disabled = ProviderConfig { enabled: false, ..Default::default() };
        registry.register(Box::new(TestProvider::new("ENABLED", false)), &enabled).await.unwrap();
        registry.register(Box::new(TestProvider::new("DISABLED", false)), &disabled).await.unwrap();
        assert!(registry.get_provider("ENABLED").is_ok());
        assert!(registry.get_provider("DISABLED").is_err());
        assert_eq!(registry.list_enabled_mechanisms(), vec!["ENABLED"]);
    }

    // -----------------------------------------------------------------------
    // Tests — Shutdown
    // -----------------------------------------------------------------------

    #[tokio::test]
    async fn shutdown_all_calls_shutdown_on_all_providers() {
        let mut registry = AuthProviderRegistry::new();
        let config = ProviderConfig::default();
        let sa = Arc::new(AtomicBool::new(false));
        let sb = Arc::new(AtomicBool::new(false));
        let pa = TestProvider::new_tracked("A", false, Arc::new(AtomicBool::new(false)), sa.clone());
        let pb = TestProvider::new_tracked("B", false, Arc::new(AtomicBool::new(false)), sb.clone());
        registry.register(Box::new(pa), &config).await.unwrap();
        registry.register(Box::new(pb), &config).await.unwrap();
        registry.shutdown_all().await;
        assert!(sa.load(Ordering::SeqCst));
        assert!(sb.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn shutdown_all_empties_the_registry() {
        let mut registry = AuthProviderRegistry::new();
        let config = ProviderConfig::default();
        registry.register(Box::new(TestProvider::new("A", false)), &config).await.unwrap();
        registry.shutdown_all().await;
        assert!(registry.list_enabled_mechanisms().is_empty());
        assert!(registry.get_provider("A").is_err());
    }
}
