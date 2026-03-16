/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/auth/provider.rs
 *
 * Defines the AuthProvider trait and ProviderConfig struct.
 *
 *-------------------------------------------------------------------------
 */

use async_trait::async_trait;
use serde_json::Value;

use crate::{
    context::ConnectionContext,
    error::Result,
    requests::Request,
    responses::Response,
};

/// Configuration for an individual authentication provider.
#[derive(Debug, Clone)]
pub struct ProviderConfig {
    /// Whether this provider should be registered.
    pub enabled: bool,
    /// Provider-specific configuration (opaque JSON value).
    pub custom: Value,
}

impl Default for ProviderConfig {
    fn default() -> Self {
        ProviderConfig {
            enabled: true,
            custom: Value::Null,
        }
    }
}

/// Core trait that all authentication providers must implement.
#[async_trait]
pub trait AuthProvider: Send + Sync {
    /// Returns the SASL mechanism name (e.g., "SCRAM-SHA-256").
    fn mechanism_name(&self) -> &str;

    /// Returns true if this provider supports multi-step auth (saslContinue).
    fn supports_continue(&self) -> bool {
        false
    }

    /// Handle the initial saslStart command.
    async fn handle_sasl_start(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response>;

    /// Handle subsequent saslContinue commands.
    async fn handle_sasl_continue(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response>;

    /// Called once during registration. Validate config and initialize resources.
    async fn initialize(&mut self, config: &ProviderConfig) -> Result<()>;

    /// Called once during graceful gateway shutdown. 30s timeout enforced by registry.
    async fn shutdown(&mut self) -> Result<()> {
        Ok(())
    }

    /// Called when a connection closes. Clean up per-connection state.
    async fn on_connection_close(&self, _connection_context: &ConnectionContext) -> Result<()> {
        Ok(())
    }
}
