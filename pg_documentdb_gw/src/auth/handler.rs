/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/handler.rs
 *
 * Registry-based auth handler. Routes SASL requests to the correct
 * provider via the AuthProviderRegistry.
 *
 *-------------------------------------------------------------------------
 */

use bson::rawdoc;

use crate::{
    auth_legacy::AuthState,
    context::ConnectionContext,
    error::{DocumentDBError, Result},
    protocol::OK_SUCCEEDED,
    requests::{Request, RequestType},
    responses::{RawResponse, Response},
};

/// Top-level entry point for registry-based authentication.
/// Routes SaslStart, SaslContinue, and Logout requests.
pub async fn handle_auth_request(
    connection_context: &mut ConnectionContext,
    request: &Request<'_>,
) -> Result<Option<Response>> {
    match request.request_type() {
        RequestType::SaslStart => {
            Ok(Some(handle_sasl_start(connection_context, request).await?))
        }
        RequestType::SaslContinue => {
            Ok(Some(handle_sasl_continue(connection_context, request).await?))
        }
        RequestType::Logout => {
            handle_logout(connection_context).await;
            Ok(Some(Response::Raw(RawResponse(rawdoc! {
                "ok": OK_SUCCEEDED,
            }))))
        }
        _ => Ok(None),
    }
}

async fn handle_sasl_start(
    connection_context: &mut ConnectionContext,
    request: &Request<'_>,
) -> Result<Response> {
    let mechanism = request
        .document()
        .get_str("mechanism")
        .map_err(DocumentDBError::parse_failure())?;

    let registry = connection_context
        .service_context
        .auth_provider_registry()
        .ok_or_else(|| {
            DocumentDBError::internal_error(
                "Auth provider registry is not initialized".to_string(),
            )
        })?;

    let provider = registry.get_provider(mechanism)?;

    // Store which provider is handling this connection for saslContinue routing
    connection_context
        .auth_state
        .set_active_mechanism(mechanism);

    let result = provider
        .handle_sasl_start(connection_context, request)
        .await;

    log_auth_event(connection_context, mechanism, &result);

    result
}

async fn handle_sasl_continue(
    connection_context: &mut ConnectionContext,
    request: &Request<'_>,
) -> Result<Response> {
    let mechanism = connection_context
        .auth_state
        .active_mechanism()
        .ok_or_else(|| {
            DocumentDBError::authentication_failed(
                "SaslContinue called without a prior SaslStart".to_string(),
            )
        })?
        .to_string();

    let registry = connection_context
        .service_context
        .auth_provider_registry()
        .ok_or_else(|| {
            DocumentDBError::internal_error(
                "Auth provider registry is not initialized".to_string(),
            )
        })?;

    let provider = registry.get_provider(&mechanism)?;

    let result = provider
        .handle_sasl_continue(connection_context, request)
        .await;

    log_auth_event(connection_context, &mechanism, &result);

    result
}

async fn handle_logout(connection_context: &mut ConnectionContext) {
    // Notify the active provider so it can clean up per-connection resources.
    if let Some(mechanism) = connection_context.auth_state.active_mechanism() {
        if let Some(registry) = connection_context.service_context.auth_provider_registry() {
            if let Ok(provider) = registry.get_provider(mechanism) {
                if let Err(e) = provider.on_connection_close(connection_context).await {
                    tracing::warn!(
                        activity_id = connection_context.connection_id.to_string().as_str(),
                        "on_connection_close failed during logout for provider '{mechanism}': {e}"
                    );
                }
            }
        }
    }

    connection_context.auth_state = AuthState::new();
}

fn log_auth_event(
    connection_context: &ConnectionContext,
    mechanism: &str,
    result: &Result<Response>,
) {
    let outcome = if result.is_ok() { "success" } else { "failure" };
    let username = connection_context.auth_state.username().ok();

    tracing::info!(
        activity_id = connection_context.connection_id.to_string().as_str(),
        user = username,
        mechanism = mechanism,
        outcome = outcome,
        ip = connection_context.ip_address.as_str(),
        "Authentication event"
    );
}


#[cfg(test)]
mod tests {
    use crate::auth_legacy::AuthState;

    // -----------------------------------------------------------------------
    // AuthState active_mechanism tests
    // -----------------------------------------------------------------------

    #[test]
    fn active_mechanism_initially_none() {
        let state = AuthState::new();
        assert!(state.active_mechanism().is_none());
    }

    #[test]
    fn set_active_mechanism_stores_value() {
        let mut state = AuthState::new();
        state.set_active_mechanism("SCRAM-SHA-256");
        assert_eq!(state.active_mechanism(), Some("SCRAM-SHA-256"));
    }

    #[test]
    fn set_active_mechanism_can_be_overwritten() {
        let mut state = AuthState::new();
        state.set_active_mechanism("SCRAM-SHA-256");
        state.set_active_mechanism("MONGODB-OIDC");
        assert_eq!(state.active_mechanism(), Some("MONGODB-OIDC"));
    }

    #[test]
    fn logout_resets_active_mechanism() {
        let mut state = AuthState::new();
        state.set_active_mechanism("SCRAM-SHA-256");
        state = AuthState::new();
        assert!(state.active_mechanism().is_none());
    }

    #[test]
    fn new_auth_state_has_no_username() {
        let state = AuthState::new();
        assert!(state.username().is_err());
    }

    #[test]
    fn connection_close_resets_all_auth_state() {
        let mut state = AuthState::new();
        state.set_active_mechanism("SCRAM-SHA-256");
        state.set_username("testuser");
        state.password = Some("pass".to_string());
        state.user_oid = Some(42);

        state = AuthState::new();

        assert!(state.active_mechanism().is_none());
        assert!(state.username().is_err());
        assert!(state.password.is_none());
        assert!(state.user_oid.is_none());
    }
}
