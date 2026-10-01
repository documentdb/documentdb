/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/auth/command.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::Arc;

use bson::{rawdoc, spec::BinarySubtype};

use crate::{
    auth::{AuthenticationResult, UserAuthState},
    context::{ConnectionContext, RequestContext},
    error::Result,
    protocol::OK_SUCCEEDED,
    requests::RequestType,
    responses::{RawResponse, Response},
    telemetry::{event_id::EventId, record_authentication_attempt, AuthenticationOutcome},
};

/// Handles an authentication command (`saslStart`, `saslContinue`, or `logout`).
///
/// Returns `Some(response)` for authentication commands and `None` for any
/// other request type.
///
/// # Errors
///
/// Returns an error if the authentication conversation fails or an underlying
/// auth query cannot be completed.
#[cfg_attr(
    feature = "request-tracing",
    tracing::instrument(
        name = "gateway.auth",
        skip_all,
        fields(db.auth.scheme = tracing::field::Empty)
    )
)]
pub async fn handle_authentication(
    connection_context: &mut ConnectionContext,
    request_context: &RequestContext<'_>,
) -> Result<Option<Response>> {
    connection_context.update_user_expiration_status();

    match request_context.request_type() {
        RequestType::Logout => {
            connection_context.clear_user();
            Ok(Some(Response::Raw(RawResponse::new(rawdoc! {
                "ok": OK_SUCCEEDED,
            }))))
        }
        RequestType::SaslStart | RequestType::SaslContinue => {
            handle_sasl_authentication(connection_context, request_context).await
        }
        _ => Ok(None),
    }
}

async fn handle_sasl_authentication(
    connection_context: &mut ConnectionContext,
    request_context: &RequestContext<'_>,
) -> Result<Option<Response>> {
    let service_context = Arc::clone(&connection_context.service_context);
    let authentication_manager = service_context.authentication_manager();
    let requested_scheme = match request_context.request_type() {
        RequestType::SaslStart => request_context
            .request()
            .document()
            .get_str("mechanism")
            .ok(),
        RequestType::SaslContinue => connection_context.user().scheme(),
        _ => None,
    };
    let telemetry_scheme = authentication_manager
        .telemetry_scheme(requested_scheme)
        .to_owned();
    tracing::Span::current().record("db.auth.scheme", tracing::field::display(&telemetry_scheme));

    let result = authentication_manager
        .authenticate(connection_context, request_context)
        .await;

    let result = match result {
        Ok(result) => result,
        Err(error) => {
            clear_failed_authentication(connection_context, request_context, &telemetry_scheme);
            return Err(error);
        }
    };

    let response = match result {
        AuthenticationResult::Challenge(payload) => build_sasl_response(&payload, false),
        AuthenticationResult::Success(success) => {
            let (principal, payload, scheme, pool_secret, expires_at, metadata) =
                success.into_parts();
            let authenticated_user =
                UserAuthState::authenticated(scheme, principal, metadata, expires_at);
            if let Err(error) =
                connection_context.set_authenticated_user(authenticated_user, &pool_secret)
            {
                clear_failed_authentication(connection_context, request_context, &telemetry_scheme);
                return Err(error);
            }
            connection_context.update_user_expiration_status();
            emit_authentication_audit_event(
                request_context,
                &telemetry_scheme,
                AuthenticationOutcome::Success,
            );

            build_sasl_response(&payload, true)
        }
        AuthenticationResult::Failed(failed) => {
            clear_failed_authentication(connection_context, request_context, &telemetry_scheme);
            build_sasl_response(&failed.into_payload(), true)
        }
    };

    Ok(Some(response))
}

fn clear_failed_authentication(
    connection_context: &mut ConnectionContext,
    request_context: &RequestContext<'_>,
    telemetry_scheme: &str,
) {
    connection_context.clear_failed_authentication();
    emit_authentication_audit_event(
        request_context,
        telemetry_scheme,
        AuthenticationOutcome::Failure,
    );
}

fn build_sasl_response(payload: &[u8], done: bool) -> Response {
    let binary = bson::Binary {
        subtype: BinarySubtype::Generic,
        bytes: payload.to_vec(),
    };

    Response::Raw(RawResponse::new(rawdoc! {
        "payload": binary,
        "ok": OK_SUCCEEDED,
        "conversationId": 1,
        "done": done,
    }))
}

fn emit_authentication_audit_event(
    request_context: &RequestContext<'_>,
    mechanism: &str,
    outcome: AuthenticationOutcome,
) {
    record_authentication_attempt(mechanism, outcome);

    match outcome {
        AuthenticationOutcome::Success => tracing::info!(
            target: "documentdb_gateway_core::auth::audit",
            activity_id = request_context.activity_id,
            event_id = EventId::Authentication.code(),
            authentication_mechanism = mechanism,
            authentication_outcome = "success",
            "Authentication attempt completed"
        ),
        AuthenticationOutcome::Failure => tracing::warn!(
            target: "documentdb_gateway_core::auth::audit",
            activity_id = request_context.activity_id,
            event_id = EventId::Authentication.code(),
            authentication_mechanism = mechanism,
            authentication_outcome = "failure",
            "Authentication attempt completed"
        ),
    }
}
