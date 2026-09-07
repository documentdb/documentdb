/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/connection_loop/request_execution.rs
 *
 *-------------------------------------------------------------------------
 */

use either::Either::Left;
use tokio::{io::AsyncWrite, time::Instant};
use tracing::Instrument;

use crate::{
    context::{ConnectionContext, RequestContext},
    error::Result,
    postgres::PgDataClient,
    protocol::header::Header,
    requests::{RequestIntervalKind, RequestObservation},
    responses,
    service::connection_loop::routing::RequestRouter,
    telemetry::{self, client_info},
};

pub(super) async fn handle_request<T, R, W>(
    connection_context: &mut ConnectionContext,
    header: &Header,
    request_context: &RequestContext<'_>,
    request_router: &R,
    writer: &mut W,
    handle_message_start: Instant,
) -> Result<()>
where
    T: PgDataClient,
    R: RequestRouter<T>,
    W: AsyncWrite + Unpin,
{
    let handle_request_start = Instant::now();
    let response_result = request_router
        .handle_request(request_context, connection_context)
        .await;
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
        responses::writer::write(header, &response, writer)
            .instrument(tracing::info_span!("gateway.write_response"))
            .await?;
        request_context
            .tracker
            .record_duration(RequestIntervalKind::WriteResponse, write_response_start);
    }

    if connection_context.request_metrics_enabled() {
        telemetry::record_gateway_metrics(
            header,
            Some(RequestObservation::Strict(request_context.request())),
            Left(&response),
            request_context.request().collection().unwrap_or(""),
            request_context.tracker,
        );
    }

    if let Some(telemetry) = connection_context.telemetry_provider.as_ref() {
        let collection = request_context.request().collection().unwrap_or("");

        telemetry.emit_request_event(
            connection_context,
            header,
            Some(RequestObservation::Strict(request_context.request())),
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
    use std::sync::Arc;

    use tokio::io::AsyncReadExt;

    use super::*;
    use crate::{
        postgres::DocumentDBDataClient,
        protocol::opcode::OpCode,
        requests::{request_tracker::RequestTracker, Request, RequestType, WireRequest},
        service::connection_loop::routing::DefaultRequestRouter,
        testing::{
            assert_header_matches, assert_success_response, build_op_msg_parts, build_raw_document,
            decode_op_msg_response, logout_document, test_connection_context,
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
        let result = handle_request::<T, _, _>(
            connection_context,
            header,
            request_context,
            &DefaultRequestRouter {},
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
        let wire_request = WireRequest::from_request_and_info(&request, request_info);
        let request_tracker = RequestTracker::new();
        let request_context = RequestContext::new(
            "activity-handle-request-success",
            &wire_request,
            &request_tracker,
        );
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
            response_header.message_length(),
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
        let wire_request = WireRequest::from_request_and_info(&request, request_info);
        let request_tracker = RequestTracker::new();
        let request_context = RequestContext::new(
            "activity-handle-request-no-response",
            &wire_request,
            &request_tracker,
        );
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
