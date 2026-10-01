/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/auth/manager.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{collections::HashMap, fmt::Debug};

use async_trait::async_trait;
use serde_json::Value;

use crate::{
    auth::{scram, scram::SCRAM_SHA256_SCHEME},
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, Result},
    requests::RequestType,
    security::principal::Principal,
};

/// Handles a single authentication scheme.
#[async_trait]
pub trait AuthenticationHandler: Debug + Send + Sync {
    /// Returns whether this handler is currently available.
    fn enabled(&self) -> bool {
        true
    }

    /// Performs one authentication round for this scheme, mutating the
    /// connection's auth state as the conversation progresses.
    async fn handle_authenticate(
        &self,
        connection_context: &mut ConnectionContext,
        request_context: &RequestContext<'_>,
    ) -> Result<AuthenticationResult>;
}

/// Contributes one or more authentication schemes to an [`AuthenticationManager`].
pub trait AuthenticationProvider: Debug + Send + Sync {
    /// Registers this provider's scheme handlers with the manager.
    ///
    /// # Errors
    ///
    /// Returns an error when the provider attempts to register a scheme that
    /// already has a handler.
    fn register(&self, authentication_manager: &mut AuthenticationManager) -> Result<()>;
}

/// The details of a completed authentication.
pub struct AuthenticationSuccess {
    principal: Principal,
    payload: Vec<u8>,
    scheme: &'static str,
    pool_secret: String,
    expires_at: Option<u64>,
    metadata: Option<Value>,
}

impl Debug for AuthenticationSuccess {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("AuthenticationSuccess")
            .field("principal", &self.principal)
            .field("payload", &self.payload)
            .field("scheme", &self.scheme)
            .field("pool_secret", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .field("metadata", &self.metadata)
            .finish()
    }
}

impl AuthenticationSuccess {
    /// Creates a completed authentication result.
    #[must_use]
    pub const fn new(
        principal: Principal,
        payload: Vec<u8>,
        scheme: &'static str,
        pool_secret: String,
        expires_at: Option<u64>,
        metadata: Option<Value>,
    ) -> Self {
        Self {
            principal,
            payload,
            scheme,
            pool_secret,
            expires_at,
            metadata,
        }
    }

    #[must_use]
    pub(crate) const fn principal(&self) -> &Principal {
        &self.principal
    }

    pub(crate) fn into_parts(
        self,
    ) -> (
        Principal,
        Vec<u8>,
        &'static str,
        String,
        Option<u64>,
        Option<Value>,
    ) {
        (
            self.principal,
            self.payload,
            self.scheme,
            self.pool_secret,
            self.expires_at,
            self.metadata,
        )
    }
}

/// The details of a terminal authentication failure response.
#[derive(Debug)]
pub struct AuthenticationFailed {
    payload: Vec<u8>,
}

impl AuthenticationFailed {
    /// Creates a terminal authentication failure response.
    #[must_use]
    pub const fn new(payload: Vec<u8>) -> Self {
        Self { payload }
    }

    pub(crate) fn into_payload(self) -> Vec<u8> {
        self.payload
    }
}

/// The outcome of a single authentication round.
#[derive(Debug)]
pub enum AuthenticationResult {
    /// More rounds are required; carry the server's challenge payload back to the client.
    Challenge(Vec<u8>),
    /// Authentication completed; carry the details needed to finalize the connection.
    Success(AuthenticationSuccess),
    /// Authentication completed with a mechanism-defined failure payload.
    Failed(AuthenticationFailed),
}

/// Routes authentication requests to the handler registered for a scheme.
#[derive(Debug, Default)]
pub struct AuthenticationManager {
    handlers: HashMap<String, Box<dyn AuthenticationHandler>>,
}

impl AuthenticationManager {
    #[must_use]
    pub fn new() -> Self {
        let mut authentication_manager = Self::default();
        authentication_manager
            .handlers
            .insert(SCRAM_SHA256_SCHEME.to_owned(), scram::create_handler());

        authentication_manager
    }

    /// Registers a handler for the given authentication scheme.
    ///
    /// # Errors
    ///
    /// Returns an error when `scheme` already has a registered handler.
    pub fn register_scheme(
        &mut self,
        scheme: &str,
        handler: Box<dyn AuthenticationHandler>,
    ) -> Result<()> {
        if self.handlers.contains_key(scheme) {
            return Err(DocumentDBError::internal_error(format!(
                "Authentication scheme '{scheme}' is already registered"
            )));
        }

        self.handlers.insert(scheme.to_owned(), handler);
        Ok(())
    }

    /// Registers all of a provider's schemes with this manager.
    ///
    /// # Errors
    ///
    /// Returns an error when any scheme contributed by the provider conflicts
    /// with an existing handler.
    pub fn register_provider(&mut self, provider: &dyn AuthenticationProvider) -> Result<()> {
        provider.register(self)
    }

    /// Returns the registered authentication schemes in stable lexical order.
    #[must_use]
    pub fn supported_schemes(&self) -> Vec<&str> {
        let mut schemes: Vec<_> = self
            .handlers
            .iter()
            .filter_map(|(scheme, handler)| handler.enabled().then_some(scheme.as_str()))
            .collect();
        schemes.sort_unstable();
        schemes
    }

    /// Authenticates the request using the handler registered for its scheme.
    ///
    /// # Errors
    ///
    /// Returns an error if the scheme cannot be resolved, if no handler is
    /// registered for it, or if the handler itself fails to authenticate.
    pub async fn authenticate(
        &self,
        connection_context: &mut ConnectionContext,
        request_context: &RequestContext<'_>,
    ) -> Result<AuthenticationResult> {
        let (scheme, starts_conversation) = match request_context.request_type() {
            RequestType::SaslStart => {
                let scheme = request_context
                    .request()
                    .document()
                    .get_str("mechanism")
                    .map_err(DocumentDBError::parse_failure())?
                    .to_owned();
                (scheme, true)
            }
            RequestType::SaslContinue => (
                connection_context
                    .user()
                    .scheme()
                    .ok_or_else(|| {
                        DocumentDBError::authentication_failed("Authentication Failed".to_owned())
                    })?
                    .to_owned(),
                false,
            ),
            request_type => {
                let internal_message = format!(
                    "AuthenticationManager::authenticate was called with a request type of `{request_type}`"
                );
                return Err(DocumentDBError::authentication_failed_internal_error(
                    "Authentication Failed".to_owned(),
                    &internal_message,
                ));
            }
        };

        let handler = self.handlers.get(&scheme).ok_or_else(|| {
            DocumentDBError::authentication_failed(format!(
                "'{scheme}' is not a supported authentication scheme."
            ))
        })?;
        if !handler.enabled() {
            return Err(DocumentDBError::authentication_failed(
                "The authentication mechanism provided is not supported in the service.".to_owned(),
            ));
        }
        if starts_conversation {
            connection_context.begin_authentication(&scheme);
        }

        let result = handler
            .handle_authenticate(connection_context, request_context)
            .await?;

        if let AuthenticationResult::Success(success) = &result {
            connection_context
                .user()
                .validate_reauthentication_principal(success.principal())?;
        }

        Ok(result)
    }

    pub(crate) fn telemetry_scheme<'a>(&self, scheme: Option<&'a str>) -> &'a str {
        scheme
            .filter(|scheme| {
                self.handlers
                    .get(*scheme)
                    .is_some_and(|handler| handler.enabled())
            })
            .unwrap_or("unsupported")
    }
}
