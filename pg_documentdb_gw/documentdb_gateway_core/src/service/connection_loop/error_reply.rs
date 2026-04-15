/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/connection_loop/error_reply.rs
 *
 *-------------------------------------------------------------------------
 */

use either::Either::Right;
use tokio::{io::AsyncWrite, time::Instant};

use crate::{
    context::ConnectionContext,
    error::{DocumentDBError, ErrorCode, Result},
    protocol::header::Header,
    requests::{request_tracker::RequestTracker, Request, RequestIntervalKind},
    responses::{self, CommandError},
    telemetry::{self, client_info},
};

#[expect(
    clippy::too_many_arguments,
    reason = "Error handling function needs all these parameters"
)]
pub(super) async fn log_and_write_error<W>(
    connection_context: &ConnectionContext,
    header: &Header,
    error: &DocumentDBError,
    request: Option<&Request<'_>>,
    writer: &mut W,
    collection: Option<String>,
    request_tracker: &RequestTracker,
    activity_id: &str,
    handle_message_start: Option<Instant>,
) -> Result<()>
where
    W: AsyncWrite + Unpin,
{
    let command_error = CommandError::from_error(connection_context, error, activity_id);
    let response = command_error.to_raw_document_buf();

    if let Some(start) = handle_message_start {
        request_tracker.record_duration(RequestIntervalKind::HandleMessage, start);
    }

    let write_response_start = Instant::now();
    responses::writer::write_and_flush(header, &response, writer).await?;
    request_tracker.record_duration(RequestIntervalKind::WriteResponse, write_response_start);

    // telemetry can block so do it after write and flush.
    telemetry::log_request_failure(error, connection_context, activity_id, request);

    let collection = collection.unwrap_or_default();

    if connection_context.request_metrics_enabled() {
        telemetry::record_gateway_metrics(
            header,
            request,
            Right((&command_error, response.as_bytes().len())),
            &collection,
            request_tracker,
        );
    }

    if let Some(telemetry) = connection_context.telemetry_provider.as_ref() {
        telemetry.emit_request_event(
            connection_context,
            header,
            request,
            Right((&command_error, response.as_bytes().len())),
            collection,
            request_tracker,
            activity_id,
            &client_info::parse_client_info(connection_context.client_information.as_ref()),
        );
    }

    Ok(())
}

#[expect(
    clippy::too_many_arguments,
    reason = "Request error reply needs request, tracker, and telemetry context"
)]
pub(super) async fn reply_with_request_error<W>(
    connection_context: &ConnectionContext,
    header: &Header,
    error: &DocumentDBError,
    request: Option<&Request<'_>>,
    writer: &mut W,
    collection: Option<String>,
    request_tracker: &RequestTracker,
    activity_id: &str,
    handle_message_start: Option<Instant>,
) where
    W: AsyncWrite + Unpin,
{
    if let Err(write_error) = log_and_write_error(
        connection_context,
        header,
        error,
        request,
        writer,
        collection,
        request_tracker,
        activity_id,
        handle_message_start,
    )
    .await
    {
        tracing::error!(
            activity_id = activity_id,
            "Couldn't reply with error {write_error:?}."
        );
    }
}

pub(super) async fn maybe_reply_shutdown<W>(
    connection_context: &ConnectionContext,
    header: &Header,
    writer: &mut W,
    request_tracker: &RequestTracker,
    activity_id: &str,
    handle_message_start: Instant,
) -> bool
where
    W: AsyncWrite + Unpin,
{
    if !connection_context
        .dynamic_configuration()
        .send_shutdown_responses()
    {
        return false;
    }

    let error = DocumentDBError::documentdb_error(
        ErrorCode::ShutdownInProgress,
        "Graceful shutdown requested".to_owned(),
    );
    reply_with_request_error(
        connection_context,
        header,
        &error,
        None,
        writer,
        None,
        request_tracker,
        activity_id,
        Some(handle_message_start),
    )
    .await;
    true
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::Arc;

    use tokio::io::AsyncReadExt;

    use crate::{
        protocol::opcode::OpCode,
        requests::RequestType,
        testing::{
            assert_error_response, assert_header_matches, build_op_msg_parts, build_raw_document,
            decode_op_msg_response, logout_document, test_connection_context,
            RecordingTelemetryProvider, TestDynamicConfiguration,
        },
    };

    async fn execute_maybe_reply_shutdown(
        connection_context: &ConnectionContext,
        header: &Header,
        request_tracker: &RequestTracker,
        activity_id: &str,
        handle_message_start: Instant,
    ) -> (bool, Vec<u8>) {
        let (mut response_writer, mut response_reader) = tokio::io::duplex(4096);
        let should_stop = maybe_reply_shutdown(
            connection_context,
            header,
            &mut response_writer,
            request_tracker,
            activity_id,
            handle_message_start,
        )
        .await;
        drop(response_writer);

        let mut response_bytes = Vec::new();
        response_reader
            .read_to_end(&mut response_bytes)
            .await
            .expect("response reader should drain bytes");

        (should_stop, response_bytes)
    }

    #[tokio::test]
    async fn maybe_reply_shutdown_returns_false_when_disabled() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let connection_context = test_connection_context(false, dynamic_configuration, None).await;
        let logout_document = logout_document();
        let (header, _) = build_op_msg_parts(&logout_document, 51);
        let request_tracker = RequestTracker::new();

        let (should_stop, response_bytes) = execute_maybe_reply_shutdown(
            &connection_context,
            &header,
            &request_tracker,
            "activity-shutdown-disabled",
            Instant::now(),
        )
        .await;

        assert!(
            !should_stop,
            "shutdown reply should be skipped when disabled"
        );
        assert!(
            response_bytes.is_empty(),
            "no response bytes should be written when shutdown replies are disabled"
        );
    }

    #[tokio::test]
    async fn maybe_reply_shutdown_writes_shutdown_error_when_enabled() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        dynamic_configuration.set_send_shutdown_responses(true);
        let connection_context = test_connection_context(false, dynamic_configuration, None).await;
        let logout_document = logout_document();
        let (header, _) = build_op_msg_parts(&logout_document, 52);
        let request_tracker = RequestTracker::new();

        let (should_stop, response_bytes) = execute_maybe_reply_shutdown(
            &connection_context,
            &header,
            &request_tracker,
            "activity-shutdown-enabled",
            Instant::now(),
        )
        .await;

        assert!(should_stop, "shutdown reply should stop request processing");
        let (response_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(
            &response_header,
            response_header.length,
            52,
            52,
            OpCode::Msg,
        );
        assert_error_response(&response_document, ErrorCode::ShutdownInProgress);
    }

    #[tokio::test]
    async fn log_and_write_error_writes_error_response_and_emits_failure_event() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let telemetry_provider = RecordingTelemetryProvider::default();
        let connection_context = test_connection_context(
            true,
            dynamic_configuration,
            Some(Box::new(telemetry_provider.clone())),
        )
        .await;
        let logout_document = logout_document();
        let request = Request::RawBuf(RequestType::Logout, build_raw_document(&logout_document));
        let request_tracker = RequestTracker::new();
        let (header, _) = build_op_msg_parts(&logout_document, 73);
        let error = DocumentDBError::documentdb_error(
            ErrorCode::BadValue,
            "bad request payload".to_owned(),
        );
        let (mut response_writer, mut response_reader) = tokio::io::duplex(4096);

        log_and_write_error(
            &connection_context,
            &header,
            &error,
            Some(&request),
            &mut response_writer,
            Some("admin".to_owned()),
            &request_tracker,
            "activity-log-and-write-error",
            Some(Instant::now()),
        )
        .await
        .expect("error path should serialize and write the response");
        drop(response_writer);

        let mut response_bytes = Vec::new();
        response_reader
            .read_to_end(&mut response_bytes)
            .await
            .expect("response reader should drain bytes");
        let (reply_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(&reply_header, reply_header.length, 73, 73, OpCode::Msg);
        assert_error_response(&response_document, ErrorCode::BadValue);

        let events = telemetry_provider.events();
        assert_eq!(
            events.len(),
            1,
            "error path should emit one telemetry event"
        );
        assert_eq!(events[0].activity_id(), "activity-log-and-write-error");
        assert_eq!(events[0].collection(), "admin");
        assert_eq!(events[0].request_type(), Some(RequestType::Logout));
        assert!(
            events[0].is_error(),
            "error event should be marked as an error"
        );
        assert_eq!(
            events[0].error_code_name(),
            Some(ErrorCode::BadValue.to_string().as_str())
        );
    }
}
