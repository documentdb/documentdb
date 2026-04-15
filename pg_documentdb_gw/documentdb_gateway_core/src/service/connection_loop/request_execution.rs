/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/connection_loop/request_execution.rs
 *
 *-------------------------------------------------------------------------
 */

use either::Either::Left;
use tokio::{io::AsyncWrite, time::Instant};

use crate::{
    auth,
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, Result},
    postgres::PgDataClient,
    processor,
    protocol::header::Header,
    requests::{Request, RequestIntervalKind},
    responses::{self, Response},
    telemetry::{self, client_info},
};

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum RequestExecutionPath {
    AuthCommand,
    UnauthorizedRequest,
    ReauthenticationRequired,
    AuthorizedRequest,
}

fn determine_request_execution_path(
    request: &Request<'_>,
    auth_state: &auth::AuthState,
) -> RequestExecutionPath {
    if request.request_type().handle_with_auth() {
        return RequestExecutionPath::AuthCommand;
    }

    if !auth_state.is_authorized() {
        if auth_state.auth_kind() == Some(&auth::AuthKind::ExternalIdentity) {
            return RequestExecutionPath::ReauthenticationRequired;
        }

        return RequestExecutionPath::UnauthorizedRequest;
    }

    RequestExecutionPath::AuthorizedRequest
}

async fn get_response<T>(
    request_context: &RequestContext<'_>,
    connection_context: &mut ConnectionContext,
) -> Result<Response>
where
    T: PgDataClient,
{
    match determine_request_execution_path(request_context.payload, &connection_context.auth_state)
    {
        RequestExecutionPath::AuthCommand | RequestExecutionPath::UnauthorizedRequest => {
            let response = auth::process::<T>(connection_context, request_context).await?;
            return Ok(response);
        }
        RequestExecutionPath::ReauthenticationRequired => {
            return Err(DocumentDBError::reauthentication_required(
                "External identity token has expired.".to_owned(),
            ));
        }
        RequestExecutionPath::AuthorizedRequest => {}
    }

    let data_client = T::new_authorized(
        &connection_context.service_context,
        &connection_context.auth_state,
    )?;

    processor::process_request(request_context, connection_context, &data_client).await
}

pub(super) async fn handle_request<T, W>(
    connection_context: &mut ConnectionContext,
    header: &Header,
    request_context: &RequestContext<'_>,
    writer: &mut W,
    handle_message_start: Instant,
) -> Result<()>
where
    T: PgDataClient,
    W: AsyncWrite + Unpin,
{
    let handle_request_start = Instant::now();
    let response_result = get_response::<T>(request_context, connection_context).await;
    request_context
        .tracker
        .record_duration(RequestIntervalKind::HandleRequest, handle_request_start);

    let response = match response_result {
        Ok(response) => response,
        Err(error) => {
            return Err(error);
        }
    };

    request_context
        .tracker
        .record_duration(RequestIntervalKind::HandleMessage, handle_message_start);

    if connection_context.requires_response {
        let write_response_start = Instant::now();
        responses::writer::write(header, &response, writer).await?;
        request_context
            .tracker
            .record_duration(RequestIntervalKind::WriteResponse, write_response_start);
    }

    if connection_context.request_metrics_enabled() {
        telemetry::record_gateway_metrics(
            header,
            Some(request_context.payload),
            Left(&response),
            request_context.info.collection().unwrap_or(""),
            request_context.tracker,
        );
    }

    if let Some(telemetry) = connection_context.telemetry_provider.as_ref() {
        let collection = request_context.info.collection().unwrap_or("").to_owned();
        telemetry.emit_request_event(
            connection_context,
            header,
            Some(request_context.payload),
            Left(&response),
            collection,
            request_context.tracker,
            request_context.activity_id,
            &client_info::parse_client_info(connection_context.client_information.as_ref()),
        );
    }

    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::Arc;

    use tokio::io::AsyncReadExt;

    use crate::{
        auth::{AuthKind, AuthState},
        error::ErrorCode,
        postgres::DocumentDBDataClient,
        protocol::opcode::OpCode,
        requests::{request_tracker::RequestTracker, RequestType},
        testing::{
            assert_header_matches, assert_success_response, build_op_msg_parts, build_raw_document,
            decode_op_msg_response, logout_document, ping_document, test_connection_context,
            RecordingTelemetryProvider, TestDynamicConfiguration,
        },
    };

    async fn execute_handle_request<T>(
        connection_context: &mut ConnectionContext,
        header: &Header,
        request_context: &RequestContext<'_>,
        handle_message_start: Instant,
    ) -> (Result<()>, Vec<u8>)
    where
        T: PgDataClient,
    {
        let (mut response_writer, mut response_reader) = tokio::io::duplex(4096);
        let result = handle_request::<T, _>(
            connection_context,
            header,
            request_context,
            &mut response_writer,
            handle_message_start,
        )
        .await;
        drop(response_writer);

        let mut response_bytes = Vec::new();
        response_reader
            .read_to_end(&mut response_bytes)
            .await
            .expect("response reader should drain bytes");

        (result, response_bytes)
    }

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
        authorized.set_authorized(true);

        assert_eq!(
            determine_request_execution_path(&logout_request, &native_unauthorized),
            RequestExecutionPath::AuthCommand
        );
        assert_eq!(
            determine_request_execution_path(&ping_request, &native_unauthorized),
            RequestExecutionPath::UnauthorizedRequest
        );
        assert_eq!(
            determine_request_execution_path(&ping_request, &external_identity),
            RequestExecutionPath::ReauthenticationRequired
        );
        assert_eq!(
            determine_request_execution_path(&ping_request, &authorized),
            RequestExecutionPath::AuthorizedRequest
        );
    }

    #[tokio::test]
    async fn get_response_handles_auth_commands_without_pg_client_calls() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let logout_document = logout_document();
        let request = Request::RawBuf(RequestType::Logout, build_raw_document(&logout_document));
        let request_info = request
            .extract_common()
            .expect("logout request should have valid common fields");
        let request_tracker = RequestTracker::new();
        let request_context = RequestContext {
            activity_id: "activity-auth-command",
            payload: &request,
            info: &request_info,
            tracker: &request_tracker,
        };

        let response =
            get_response::<DocumentDBDataClient>(&request_context, &mut connection_context)
                .await
                .expect("logout should be handled in auth flow");

        assert_success_response(&response.as_json().expect("response should convert to JSON"));
    }

    #[tokio::test]
    async fn get_response_requires_reauthentication_for_expired_external_identity() {
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
        let request_tracker = RequestTracker::new();
        let request_context = RequestContext {
            activity_id: "activity-reauth",
            payload: &request,
            info: &request_info,
            tracker: &request_tracker,
        };

        let error = get_response::<DocumentDBDataClient>(&request_context, &mut connection_context)
            .await
            .expect_err("expired external identity should require reauthentication");

        assert_eq!(
            error.error_code_enum(),
            Some(ErrorCode::ReauthenticationRequired)
        );
    }

    #[tokio::test]
    async fn handle_request_writes_response_and_emits_success_event() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let telemetry_provider = RecordingTelemetryProvider::default();
        let mut connection_context = test_connection_context(
            true,
            dynamic_configuration,
            Some(Box::new(telemetry_provider.clone())),
        )
        .await;
        let logout_document = logout_document();
        let request = Request::RawBuf(RequestType::Logout, build_raw_document(&logout_document));
        let request_info = request
            .extract_common()
            .expect("logout request should have valid common fields");
        let request_tracker = RequestTracker::new();
        let request_context = RequestContext {
            activity_id: "activity-handle-request-success",
            payload: &request,
            info: &request_info,
            tracker: &request_tracker,
        };
        let (header, _) = build_op_msg_parts(&logout_document, 71);

        let (result, response_bytes) = execute_handle_request::<DocumentDBDataClient>(
            &mut connection_context,
            &header,
            &request_context,
            Instant::now(),
        )
        .await;

        assert!(result.is_ok(), "logout request should succeed");
        let (response_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(
            &response_header,
            response_header.length,
            71,
            71,
            OpCode::Msg,
        );
        assert_success_response(&response_document);

        let events = telemetry_provider.events();
        assert_eq!(
            events.len(),
            1,
            "success path should emit one telemetry event"
        );
        assert_eq!(events[0].activity_id(), "activity-handle-request-success");
        assert_eq!(events[0].collection(), "");
        assert_eq!(events[0].request_type(), Some(RequestType::Logout));
        assert!(
            !events[0].is_error(),
            "success event should not be marked as an error"
        );
        assert_eq!(events[0].user_agent(), "");
    }

    #[tokio::test]
    async fn handle_request_skips_response_write_when_not_required() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let telemetry_provider = RecordingTelemetryProvider::default();
        let mut connection_context = test_connection_context(
            true,
            dynamic_configuration,
            Some(Box::new(telemetry_provider.clone())),
        )
        .await;
        connection_context.requires_response = false;

        let logout_document = logout_document();
        let request = Request::RawBuf(RequestType::Logout, build_raw_document(&logout_document));
        let request_info = request
            .extract_common()
            .expect("logout request should have valid common fields");
        let request_tracker = RequestTracker::new();
        let request_context = RequestContext {
            activity_id: "activity-handle-request-no-response",
            payload: &request,
            info: &request_info,
            tracker: &request_tracker,
        };
        let (header, _) = build_op_msg_parts(&logout_document, 72);

        let (result, response_bytes) = execute_handle_request::<DocumentDBDataClient>(
            &mut connection_context,
            &header,
            &request_context,
            Instant::now(),
        )
        .await;

        assert!(
            result.is_ok(),
            "logout request should still succeed when no response is required"
        );
        assert!(
            response_bytes.is_empty(),
            "no wire response should be produced when requires_response is false"
        );

        let events = telemetry_provider.events();
        assert_eq!(events.len(), 1, "telemetry should still be emitted");
        assert_eq!(
            events[0].activity_id(),
            "activity-handle-request-no-response"
        );
        assert!(!events[0].is_error());
    }
}
