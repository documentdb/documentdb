/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/service/connection_loop/routing.rs
 *
 *-------------------------------------------------------------------------
 */

use async_trait::async_trait;

use crate::{
    auth,
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, Result},
    postgres::PgDataClient,
    processor,
    requests::RequestType,
    responses::Response,
};

#[async_trait]
pub trait RequestRouter<D>: Sync {
    async fn handle_request(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &mut ConnectionContext,
    ) -> Result<Response>;
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RequestExecutionPath {
    AuthCommand,
    UnauthorizedRequest,
    ReauthenticationRequired,
    AuthorizedRequest,
}

fn determine_request_execution_path(
    request_type: RequestType,
    auth_state: &auth::AuthState,
) -> RequestExecutionPath {
    if request_type.handle_with_auth() {
        return RequestExecutionPath::AuthCommand;
    }

    if !auth_state.is_authenticated() {
        if auth_state.auth_kind() == Some(&auth::AuthKind::ExternalIdentity) {
            return RequestExecutionPath::ReauthenticationRequired;
        }

        return RequestExecutionPath::UnauthorizedRequest;
    }

    RequestExecutionPath::AuthorizedRequest
}

#[expect(
    missing_debug_implementations,
    reason = "Request router contract does not require Debug"
)]
#[expect(
    clippy::empty_structs_with_brackets,
    reason = "Preserve the existing DefaultRequestRouter contract"
)]
pub struct DefaultRequestRouter {}

#[async_trait]
impl<D> RequestRouter<D> for DefaultRequestRouter
where
    D: PgDataClient,
{
    async fn handle_request(
        &self,
        request_context: &RequestContext<'_>,
        connection_context: &mut ConnectionContext,
    ) -> Result<Response> {
        match determine_request_execution_path(
            request_context.request_type(),
            &connection_context.auth_state,
        ) {
            RequestExecutionPath::AuthCommand | RequestExecutionPath::UnauthorizedRequest => {
                let response = auth::process::<D>(connection_context, request_context).await?;
                return Ok(response);
            }
            RequestExecutionPath::ReauthenticationRequired => {
                return Err(DocumentDBError::reauthentication_required(
                    "External identity token has expired.".to_owned(),
                ));
            }
            RequestExecutionPath::AuthorizedRequest => {}
        }

        let data_client = D::new_authorized(
            &connection_context.service_context,
            &connection_context.auth_state,
        )?;

        processor::process_request(request_context, connection_context, &data_client).await
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::{
        auth::{AuthKind, AuthState},
        error::ErrorCode,
        postgres::DocumentDBDataClient,
        requests::{request_tracker::RequestTracker, Request, WireRequest},
        testing::{
            assert_success_response, build_raw_document, logout_document, ping_document,
            test_connection_context, TestDynamicConfiguration,
        },
    };

    #[test]
    fn determine_request_execution_path_covers_auth_states() {
        let logout_document = logout_document();
        let logout_request =
            Request::RawBuf(RequestType::Logout, build_raw_document(&logout_document));
        let ping_document = ping_document();
        let ping_request = Request::RawBuf(RequestType::Ping, build_raw_document(&ping_document));

        let native_unauthorized = AuthState::new();

        let mut external_identity = AuthState::new();
        external_identity
            .set_auth_kind(AuthKind::ExternalIdentity)
            .expect("auth kind should be set once in tests");

        let authorized = AuthState::new();
        authorized.set_authenticated(true);

        assert_eq!(
            determine_request_execution_path(logout_request.request_type(), &native_unauthorized),
            RequestExecutionPath::AuthCommand
        );
        assert_eq!(
            determine_request_execution_path(ping_request.request_type(), &native_unauthorized),
            RequestExecutionPath::UnauthorizedRequest
        );
        assert_eq!(
            determine_request_execution_path(ping_request.request_type(), &external_identity),
            RequestExecutionPath::ReauthenticationRequired
        );
        assert_eq!(
            determine_request_execution_path(ping_request.request_type(), &authorized),
            RequestExecutionPath::AuthorizedRequest
        );
    }

    #[tokio::test]
    async fn handle_request_handles_auth_commands_without_pg_client_calls() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let logout_document = logout_document();
        let request = Request::RawBuf(RequestType::Logout, build_raw_document(&logout_document));
        let request_info = request
            .extract_common()
            .expect("logout request should have valid common fields");
        let wire_request = WireRequest::from_request_and_info(&request, request_info);
        let request_tracker = RequestTracker::new();
        let request_context =
            RequestContext::new("activity-auth-command", &wire_request, &request_tracker);

        let response =
            <DefaultRequestRouter as RequestRouter<DocumentDBDataClient>>::handle_request(
                &DefaultRequestRouter {},
                &request_context,
                &mut connection_context,
            )
            .await
            .expect("logout should be handled in auth flow");

        assert_success_response(&response.as_json().expect("response should convert to JSON"));
    }

    #[tokio::test]
    async fn handle_request_requires_reauthentication_for_expired_external_identity() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        connection_context
            .auth_state
            .set_auth_kind(AuthKind::ExternalIdentity)
            .expect("auth kind should be set once in tests");

        let ping_document = ping_document();
        let request = Request::RawBuf(RequestType::Ping, build_raw_document(&ping_document));
        let request_info = request
            .extract_common()
            .expect("ping request should have valid common fields");
        let wire_request = WireRequest::from_request_and_info(&request, request_info);
        let request_tracker = RequestTracker::new();
        let request_context =
            RequestContext::new("activity-reauth", &wire_request, &request_tracker);

        let error = <DefaultRequestRouter as RequestRouter<DocumentDBDataClient>>::handle_request(
            &DefaultRequestRouter {},
            &request_context,
            &mut connection_context,
        )
        .await
        .expect_err("expired external identity should require reauthentication");

        assert_eq!(error.error_code(), ErrorCode::ReauthenticationRequired);
    }
}
