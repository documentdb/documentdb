/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/registry.rs
 *
 * AuthProviderRegistry — central registry for provider lookup.
 * Read-only after initialization; uses a plain HashMap (no locks
 * needed for concurrent reads).
 *
 *-------------------------------------------------------------------------
 */

use std::collections::HashMap;
use std::sync::Arc;

use tokio::time::{timeout, Duration};

use crate::error::{DocumentDBError, Result};

use super::provider::{AuthProvider, ProviderConfig};

/// Timeout applied to each provider's `shutdown()` call.
const SHUTDOWN_TIMEOUT_SECS: u64 = 30;

/// Central registry mapping SASL mechanism names to provider implementations.
/// Read-only after initialization — no locks needed for concurrent reads.
pub struct AuthProviderRegistry {
    providers: HashMap<String, Arc<dyn AuthProvider>>,
}

impl AuthProviderRegistry {
    /// Create an empty registry.
    pub fn new() -> Self {
        AuthProviderRegistry {
            providers: HashMap::new(),
        }
    }

    /// Register a provider. If the provider's config has `enabled: false`,
    /// registration is silently skipped. Otherwise the provider is
    /// initialized, and on success inserted into the map.
    ///
    /// Returns an error if a provider with the same mechanism name is
    /// already registered. If `initialize()` fails the provider is
    /// skipped (logged, not inserted) and Ok is returned so that
    /// remaining providers can still be registered.
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

    /// O(1) lookup by SASL mechanism name. Returns an authentication
    /// error listing supported mechanisms when the name is unknown.
    pub fn get_provider(&self, mechanism: &str) -> Result<Arc<dyn AuthProvider>> {
        self.providers.get(mechanism).cloned().ok_or_else(|| {
            let supported: Vec<&str> = self.providers.keys().map(|s| s.as_str()).collect();
            DocumentDBError::authentication_failed(format!(
                "Mechanism '{mechanism}' is not supported. Supported mechanisms: {supported:?}"
            ))
        })
    }

    /// Returns the names of all registered (enabled) mechanisms.
    pub fn list_enabled_mechanisms(&self) -> Vec<&str> {
        self.providers.keys().map(|s| s.as_str()).collect()
    }

    /// Gracefully shut down every registered provider with a 30-second
    /// timeout per provider. Errors and timeouts are logged but do not
    /// prevent remaining providers from being shut down.
    pub async fn shutdown_all(&mut self) {
        // We need mutable access to each provider for shutdown().
        // Take ownership of the map so we can get Arc::get_mut.
        let providers = std::mem::take(&mut self.providers);

        for (mechanism, mut arc_provider) in providers {
            // Arc::get_mut succeeds only when there are no other clones.
            // During shutdown the registry should be the sole owner.
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
                            "Auth provider '{mechanism}' shutdown timed out after {SHUTDOWN_TIMEOUT_SECS}s — force-terminating"
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
#[path = "registry_tests.rs"]
mod tests;
