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
            handle_logout(connection_context);
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

fn handle_logout(connection_context: &mut ConnectionContext) {
    connection_context.auth_state = AuthState::new();
}

fn log_auth_event(
    connection_context: &ConnectionContext,
    mechanism: &str,
    result: &Result<Response>,
) {
    let outcome = if result.is_ok() { "success" } else { "failure" };
    let username = connection_context
        .auth_state
        .username()
        .unwrap_or("unknown");

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
#[path = "handler_tests.rs"]
mod tests;
