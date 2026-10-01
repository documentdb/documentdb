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
        connection_context.update_user_expiration_status();
        let request_type = request_context.request_type();

        if request_type.handle_with_auth() {
            if let Some(response) =
                auth::handle_authentication(connection_context, request_context).await?
            {
                return Ok(response);
            }

            return Err(unauthorized_command_error(request_type));
        }

        if !connection_context.user().is_authenticated() {
            if connection_context.user().is_expired() {
                return Err(DocumentDBError::reauthentication_required(
                    "External identity token has expired.".to_owned(),
                ));
            }

            if !request_type.allowed_unauthorized() {
                return Err(unauthorized_command_error(request_type));
            }

            let data_client = D::new_unauthorized(&connection_context.service_context)?;
            return processor::process_request(request_context, connection_context, &data_client)
                .await;
        }

        let data_client = D::new_authorized(
            &connection_context.service_context,
            connection_context.user(),
        )?;

        processor::process_request(request_context, connection_context, &data_client).await
    }
}

fn unauthorized_command_error(request_type: RequestType) -> DocumentDBError {
    DocumentDBError::unauthorized(format!(
        "Command {} is not allowed as the connection is not authenticated yet.",
        request_type.to_string().to_lowercase()
    ))
}

#[cfg(test)]
mod tests {
    use std::sync::Arc;

    use super::*;
    use crate::{
        auth::UserAuthState,
        error::ErrorCode,
        postgres::DocumentDBDataClient,
        requests::{request_tracker::RequestTracker, Request, WireRequest},
        security::principal::Principal,
        testing::{
            assert_success_response, build_raw_document, logout_document, ping_document,
            test_connection_context, TestDynamicConfiguration,
        },
    };

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
    async fn handle_request_requires_reauthentication_after_failed_expired_user_reauthentication() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let authentication_scheme = "MONGODB-OIDC";
        connection_context.set_user(UserAuthState::authenticated(
            authentication_scheme,
            Principal::new("external-user", 1),
            None,
            Some(0),
        ));
        connection_context.update_user_expiration_status();
        connection_context.begin_authentication(authentication_scheme);
        connection_context.clear_failed_authentication();

        assert!(connection_context.user().is_expired());

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
