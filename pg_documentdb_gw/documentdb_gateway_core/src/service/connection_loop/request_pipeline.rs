/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/connection_loop/request_pipeline.rs
 *
 *-------------------------------------------------------------------------
 */

use bytes::Bytes;
use tokio::{
    io::{AsyncRead, AsyncWrite},
    time::{Duration, Instant},
};
#[cfg(feature = "request-tracing")]
use tracing::field::Empty;

use crate::{
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, Result},
    postgres::PgDataClient,
    protocol::{
        self, header::Header, MAX_PRE_AUTH_MESSAGE_SIZE_BYTES, MESSAGE_SIZE_EXCEEDED_ERROR,
    },
    requests::{
        request_tracker::RequestTracker, validation, RequestIntervalKind, RequestMessage,
        RequestObservation,
    },
    service::connection_loop::{
        error_reply,
        read_ahead::{self, PendingHeaderRead},
        request_execution,
        writer::FailureTrackingWriter,
    },
    telemetry::{consts::labels, context_propagation},
};

#[cfg_attr(
    feature = "request-tracing",
    tracing::instrument(
        name = "gateway.request",
        skip_all,
        fields(
            span.kind = "server",
            span.status_code = Empty,
            span.status_message = Empty,
            db.system.name = "documentdb",
            db.operation.name = Empty,
            db.collection.name = Empty,
            db.namespace = Empty,
            network.connection.id = %connection_context.connection_id,
            network.protocol.name = %connection_context.transport_protocol(),
            tls.established = !connection_context.ssl_protocol.is_empty(),
            request.id = header.request_id(),
            activity_id = %activity_id,
        )
    )
)]
pub(super) async fn handle_message<'a, T, R, W>(
    connection_context: &mut ConnectionContext,
    header: &Header,
    reader: &'a mut R,
    writer: &mut W,
    activity_id: &str,
    idle_timeout: Duration,
) -> PendingHeaderRead<'a>
where
    T: PgDataClient,
    R: AsyncRead + Unpin + Send + 'a,
    W: AsyncWrite + Unpin,
{
    let request_tracker = RequestTracker::new();

    let read_request_start = Instant::now();
    let authenticated = connection_context.auth_state.is_authenticated();
    let message = match protocol::reader::read_request_with_timeout(
        authenticated,
        header,
        reader,
        idle_timeout,
    )
    .await
    {
        Ok(message) => message,
        Err(error) => {
            if protocol::reader::is_idle_timeout_error(&error) {
                return read_ahead::closed_header_read();
            }

            context_propagation::mark_span_error(&tracing::Span::current());
            error_reply::reply_with_request_error::<W>(
                connection_context,
                header,
                &error,
                None,
                writer,
                true,
                None,
                &request_tracker,
                activity_id,
                None,
            )
            .await;
            return read_ahead::start_next_header_read(reader, idle_timeout).await;
        }
    };
    request_tracker.record_duration(RequestIntervalKind::ReadRequest, read_request_start);
    // Start receiving the next request as soon as the current request bytes are fully consumed so
    // socket read-ahead overlaps deeper parsing and handling work.
    let next_header = read_ahead::start_next_header_read(reader, idle_timeout).await;

    process_message::<T, W>(
        connection_context,
        header,
        &message,
        writer,
        activity_id,
        &request_tracker,
    )
    .await;

    next_header
}

/// Processes one decoded request and writes its complete wire response.
///
/// Writes nothing for a valid one-way request. A header/body length mismatch is
/// encoded as a request error when the request requires a response. The caller
/// supplies the instant at which body reading began after decoding the header.
///
/// # Errors
///
/// Returns an I/O error when the complete wire response cannot be written.
#[cfg_attr(
    feature = "request-tracing",
    tracing::instrument(
        name = "gateway.request",
        skip_all,
        fields(
            span.kind = "server",
            span.status_code = Empty,
            span.status_message = Empty,
            db.system.name = "documentdb",
            db.operation.name = Empty,
            db.collection.name = Empty,
            db.namespace = Empty,
            network.connection.id = %connection_context.connection_id,
            network.protocol.name = %connection_context.transport_protocol(),
            tls.established = !connection_context.ssl_protocol.is_empty(),
            request.id = header.request_id(),
            activity_id = %activity_id,
        )
    )
)]
pub async fn process_request_message<T, W>(
    connection_context: &mut ConnectionContext,
    header: Header,
    body: Bytes,
    read_request_start: Instant,
    activity_id: &str,
    writer: &mut W,
) -> Result<()>
where
    T: PgDataClient,
    W: AsyncWrite + Unpin,
{
    let mut writer = FailureTrackingWriter::new(writer);
    let request_tracker = RequestTracker::new();
    request_tracker.record_duration(RequestIntervalKind::ReadRequest, read_request_start);
    let message_length = Header::LENGTH.saturating_add(body.len());
    let message = RequestMessage::new(
        body,
        header.op_code(),
        header.request_id(),
        header.response_to(),
    );
    let requires_response =
        protocol::reader::requires_response_from_parsed_message(&message).unwrap_or(true);
    if usize::try_from(header.message_length()) != Ok(message_length) {
        let error = DocumentDBError::bad_value(
            "Message body length does not match the declared message length.".to_owned(),
        );
        error_reply::reply_with_request_error(
            connection_context,
            &header,
            &error,
            None,
            &mut writer,
            requires_response,
            None,
            &request_tracker,
            activity_id,
            None,
        )
        .await;
        return writer.into_result();
    }
    if !connection_context.auth_state.is_authenticated()
        && message_length > usize::try_from(MAX_PRE_AUTH_MESSAGE_SIZE_BYTES).unwrap_or(250_000)
    {
        let error = DocumentDBError::internal_error(MESSAGE_SIZE_EXCEEDED_ERROR.to_owned());
        error_reply::reply_with_request_error(
            connection_context,
            &header,
            &error,
            None,
            &mut writer,
            requires_response,
            None,
            &request_tracker,
            activity_id,
            None,
        )
        .await;
        return writer.into_result();
    }

    process_message::<T, _>(
        connection_context,
        &header,
        &message,
        &mut writer,
        activity_id,
        &request_tracker,
    )
    .await;

    writer.into_result()
}

#[expect(
    clippy::too_many_lines,
    reason = "Request hot path coordinates parsing, validation, response writing, and telemetry"
)]
async fn process_message<T, W>(
    connection_context: &mut ConnectionContext,
    header: &Header,
    message: &RequestMessage,
    writer: &mut W,
    activity_id: &str,
    request_tracker: &RequestTracker,
) where
    T: PgDataClient,
    W: AsyncWrite + Unpin,
{
    let mut requires_response =
        protocol::reader::requires_response_from_parsed_message(message).unwrap_or(true);
    let shutdown_requires_response = if connection_context
        .dynamic_configuration()
        .send_shutdown_responses()
    {
        requires_response
    } else {
        true
    };

    // HandleMessage captures the overall duration needed by the server to handle/process
    // a user operation message/request. Client-to-Gateway networking latency should be
    // excluded from HandleMessage; therefore, ReadRequest is closed before this starts,
    // and WriteResponse starts measuring only after HandleMessage is closed.
    let handle_message_start = Instant::now();
    if error_reply::maybe_reply_shutdown(
        connection_context,
        header,
        writer,
        shutdown_requires_response,
        request_tracker,
        activity_id,
        handle_message_start,
    )
    .await
    {
        return;
    }
    let format_request_start = Instant::now();
    let wire_request = match protocol::reader::parse_request(message, &mut requires_response) {
        Ok(request) => request,
        Err(error) => {
            let span = tracing::Span::current();
            context_propagation::mark_span_error(&span);
            let telemetry_wire_request =
                protocol::reader::parse_request_payload(message, &mut requires_response).ok();
            if let Some(preview) = telemetry_wire_request.as_ref() {
                span.record(
                    labels::DB_OPERATION_NAME,
                    tracing::field::display(preview.request_type()),
                );
                span.record(labels::DB_NAMESPACE, preview.db_hint().unwrap_or(""));
            }
            error_reply::reply_with_request_error::<W>(
                connection_context,
                header,
                &error,
                telemetry_wire_request
                    .as_ref()
                    .map(RequestObservation::Preview),
                writer,
                requires_response,
                None,
                request_tracker,
                activity_id,
                Some(handle_message_start),
            )
            .await;

            return;
        }
    };
    connection_context.requires_response = requires_response;
    request_tracker.record_duration(RequestIntervalKind::FormatRequest, format_request_start);

    let span = tracing::Span::current();
    span.record(
        labels::DB_OPERATION_NAME,
        tracing::field::display(wire_request.request_type()),
    );
    span.record(
        labels::DB_COLLECTION_NAME,
        wire_request.collection().unwrap_or(""),
    );
    span.record(labels::DB_NAMESPACE, wire_request.db());

    // If the client carried a W3C trace context in the request `comment`, re-parent
    // the gateway's root span onto it so this request (and its downstream
    // `postgres.execute` span) appear under the caller's distributed trace. Absent
    // or malformed context leaves the gateway starting its own trace.
    if let Some(comment) = wire_request.comment() {
        let _ = context_propagation::set_parent_from_comment(&span, comment);
    }

    if let Err(error) = validation::validate_request(connection_context, &wire_request) {
        context_propagation::mark_span_error(&span);
        let collection = wire_request.collection().unwrap_or("").to_owned();
        error_reply::reply_with_request_error::<W>(
            connection_context,
            header,
            &error,
            Some(RequestObservation::Strict(&wire_request)),
            writer,
            connection_context.requires_response,
            Some(collection),
            request_tracker,
            activity_id,
            Some(handle_message_start),
        )
        .await;
        return;
    }

    let request_context = RequestContext::new(activity_id, &wire_request, request_tracker);

    // Errors in request handling are handled explicitly so that telemetry can have access to the
    // request. The next header read is already pending, so the caller can await it on the next
    // iteration without paying request teardown time on the critical path.
    if let Err(error) = request_execution::handle_request::<T, W>(
        connection_context,
        header,
        &request_context,
        writer,
        handle_message_start,
    )
    .await
    {
        context_propagation::mark_span_error(&span);
        let collection = request_context
            .request()
            .collection()
            .unwrap_or("")
            .to_owned();
        error_reply::reply_with_request_error::<W>(
            connection_context,
            header,
            &error,
            Some(RequestObservation::Strict(request_context.request())),
            writer,
            connection_context.requires_response,
            Some(collection),
            request_context.tracker,
            activity_id,
            Some(handle_message_start),
        )
        .await;
    }
}

#[cfg(test)]
mod tests {
    use std::sync::{
        atomic::{AtomicU64, Ordering},
        Arc,
    };

    use bson::{doc, spec::BinarySubtype, Binary};
    use either::Either;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use super::*;
    use crate::{
        error::ErrorCode,
        postgres::DocumentDBDataClient,
        protocol::opcode::OpCode,
        responses::Response,
        telemetry::TelemetryProvider,
        testing::{
            assert_error_response, assert_header_matches, build_document_section,
            build_op_msg_parts, build_op_msg_parts_with_sections, decode_op_msg_response,
            invalid_transaction_find_document, logout_document, malformed_sasl_start_document,
            test_connection_context, TestDynamicConfiguration,
        },
    };

    const NON_EXPIRING_IDLE_TIMEOUT: Duration = Duration::from_mins(1);

    #[derive(Clone, Debug, Default)]
    struct ReadIntervalTelemetryProvider {
        read_request_ns: Arc<AtomicU64>,
    }

    impl ReadIntervalTelemetryProvider {
        fn read_request_ns(&self) -> u64 {
            self.read_request_ns.load(Ordering::Relaxed)
        }
    }

    impl TelemetryProvider for ReadIntervalTelemetryProvider {
        fn emit_request_event(
            &self,
            _: &ConnectionContext,
            _: &Header,
            _: Option<RequestObservation<'_, '_>>,
            _: Either<&Response, (&DocumentDBError, usize)>,
            _: &str,
            request_tracker: &RequestTracker,
            _: &str,
            _: &str,
        ) {
            self.read_request_ns.store(
                request_tracker.get_interval_elapsed_time(RequestIntervalKind::ReadRequest),
                Ordering::Relaxed,
            );
        }
    }

    async fn execute_handle_message<T>(
        connection_context: &mut ConnectionContext,
        header: Header,
        request_body: Vec<u8>,
        activity_id: &str,
    ) -> (Vec<u8>, Result<Option<Header>>)
    where
        T: PgDataClient,
    {
        let (mut request_reader, mut request_writer) = tokio::io::duplex(4096);
        request_writer
            .write_all(&request_body)
            .await
            .expect("request bytes should be written to the test reader");
        request_writer
            .shutdown()
            .await
            .expect("request writer should shut down cleanly");

        let (mut response_writer, mut response_reader) = tokio::io::duplex(4096);
        let next_header = handle_message::<T, _, _>(
            connection_context,
            &header,
            &mut request_reader,
            &mut response_writer,
            activity_id,
            NON_EXPIRING_IDLE_TIMEOUT,
        )
        .await;
        drop(response_writer);

        let mut response_bytes = Vec::new();
        response_reader
            .read_to_end(&mut response_bytes)
            .await
            .expect("response reader should drain bytes");

        (response_bytes, next_header.await)
    }

    #[tokio::test]
    async fn process_request_message_returns_framed_response() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = doc! {
            "ping": 1_i32,
            "$db": 7_i32,
        };
        let (header, body) = build_op_msg_parts(&invalid_document, 81);
        let mut writer = Vec::new();

        process_request_message::<DocumentDBDataClient, _>(
            &mut connection_context,
            header,
            Bytes::from(body),
            Instant::now(),
            "activity-process-request-message",
            &mut writer,
        )
        .await
        .expect("captured response should complete");
        let response = Bytes::from(writer);

        let (response_header, response_document) = decode_op_msg_response(&response);
        assert_header_matches(
            &response_header,
            response_header.message_length(),
            81,
            81,
            OpCode::Msg,
        );
        assert_error_response(&response_document, ErrorCode::BadValue);
    }

    #[tokio::test]
    async fn process_request_message_records_body_read_interval() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let telemetry_provider = ReadIntervalTelemetryProvider::default();
        let mut connection_context = test_connection_context(
            false,
            dynamic_configuration,
            Some(Box::new(telemetry_provider.clone())),
        )
        .await;
        let invalid_document = doc! {
            "ping": 1_i32,
            "$db": 7_i32,
        };
        let (header, body) = build_op_msg_parts(&invalid_document, 87);
        let mut writer = Vec::new();

        process_request_message::<DocumentDBDataClient, _>(
            &mut connection_context,
            header,
            Bytes::from(body),
            Instant::now() - Duration::from_millis(5),
            "activity-process-read-interval",
            &mut writer,
        )
        .await
        .expect("captured response should complete");

        assert!(telemetry_provider.read_request_ns() > 0);
    }

    #[tokio::test]
    async fn process_request_message_returns_empty_bytes_for_one_way_request() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = doc! {
            "ping": 1_i32,
            "$db": 7_i32,
        };
        let (header, mut body) = build_op_msg_parts(&invalid_document, 82);
        body[..std::mem::size_of::<u32>()].copy_from_slice(&2_u32.to_le_bytes());
        let mut writer = Vec::new();

        process_request_message::<DocumentDBDataClient, _>(
            &mut connection_context,
            header,
            Bytes::from(body),
            Instant::now(),
            "activity-process-one-way-message",
            &mut writer,
        )
        .await
        .expect("one-way processing should complete");

        assert!(writer.is_empty());
    }

    #[tokio::test]
    async fn process_request_message_rejects_header_body_length_mismatch() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let (header, body) = build_op_msg_parts(&logout_document(), 83);
        let mismatched_header = Header::new(
            header.message_length() - 1,
            header.request_id(),
            header.response_to(),
            header.op_code(),
        )
        .expect("mismatched test header should remain structurally valid");
        let mut writer = Vec::new();

        process_request_message::<DocumentDBDataClient, _>(
            &mut connection_context,
            mismatched_header,
            Bytes::from(body),
            Instant::now(),
            "activity-process-mismatched-message",
            &mut writer,
        )
        .await
        .expect("mismatch response should complete");
        let response = Bytes::from(writer);

        let (_, response_document) = decode_op_msg_response(&response);
        assert_error_response(&response_document, ErrorCode::BadValue);
    }

    #[tokio::test]
    async fn process_request_message_does_not_reply_to_mismatched_one_way_request() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let (header, mut body) = build_op_msg_parts(&logout_document(), 84);
        body[..std::mem::size_of::<u32>()].copy_from_slice(&2_u32.to_le_bytes());
        let mismatched_header = Header::new(
            header.message_length() - 1,
            header.request_id(),
            header.response_to(),
            header.op_code(),
        )
        .expect("mismatched test header should remain structurally valid");
        let mut writer = Vec::new();

        process_request_message::<DocumentDBDataClient, _>(
            &mut connection_context,
            mismatched_header,
            Bytes::from(body),
            Instant::now(),
            "activity-process-mismatched-one-way-message",
            &mut writer,
        )
        .await
        .expect("one-way mismatch processing should complete");

        assert!(writer.is_empty());
    }

    #[tokio::test]
    async fn handle_message_replies_when_request_body_is_truncated() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let logout_document = logout_document();
        let (_, full_body) = build_op_msg_parts(&logout_document, 61);
        let truncated_body = full_body[..full_body.len() - 2].to_vec();
        let length = i32::try_from(Header::LENGTH + full_body.len())
            .expect("message size should fit into i32");
        let header = Header::new(length, 61, 0, OpCode::Msg).expect("test header should be valid");

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            truncated_body,
            "activity-read-request-error",
        )
        .await;

        let (response_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(
            &response_header,
            response_header.message_length(),
            61,
            61,
            OpCode::Msg,
        );
        assert_error_response(&response_document, ErrorCode::InternalError);
        assert!(
            next_header_result
                .expect("next header future should resolve cleanly after truncated request")
                .is_none(),
            "connection should be at EOF after the truncated request body"
        );
    }

    #[tokio::test]
    async fn handle_message_closes_when_request_body_idle_times_out() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let logout_document = logout_document();
        let (_, full_body) = build_op_msg_parts(&logout_document, 71);
        let length = i32::try_from(Header::LENGTH + full_body.len())
            .expect("message size should fit into i32");
        let header = Header::new(length, 71, 0, OpCode::Msg).expect("test header should be valid");
        let (mut request_reader, mut request_writer) = tokio::io::duplex(4096);
        request_writer
            .write_all(&full_body[..1])
            .await
            .expect("partial request bytes should be written");

        let (mut response_writer, mut response_reader) = tokio::io::duplex(4096);
        let next_header = handle_message::<DocumentDBDataClient, _, _>(
            &mut connection_context,
            &header,
            &mut request_reader,
            &mut response_writer,
            "activity-read-request-timeout",
            Duration::ZERO,
        )
        .await;
        drop(response_writer);
        drop(request_writer);

        let mut response_bytes = Vec::new();
        response_reader
            .read_to_end(&mut response_bytes)
            .await
            .expect("response reader should drain bytes");

        assert!(
            response_bytes.is_empty(),
            "idle request body timeout should close without a response"
        );
        assert!(
            next_header
                .await
                .expect("idle request body timeout should resolve cleanly")
                .is_none(),
            "idle request body timeout should stop the connection loop"
        );
    }

    #[tokio::test]
    async fn handle_message_replies_when_command_parsing_fails() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = doc! {
            "unknownCommand": 1_i32,
            "$db": "admin",
        };
        let (header, body) = build_op_msg_parts(&invalid_document, 62);

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-parse-request-error",
        )
        .await;

        let (response_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(
            &response_header,
            response_header.message_length(),
            62,
            62,
            OpCode::Msg,
        );
        assert_error_response(&response_document, ErrorCode::CommandNotFound);
        assert!(
            next_header_result
                .expect("next header future should resolve after parse failure")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }

    #[tokio::test]
    async fn handle_message_replies_when_common_field_extraction_fails() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = doc! {
            "ping": 1_i32,
            "$db": 7_i32,
        };
        let (header, body) = build_op_msg_parts(&invalid_document, 63);

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-extract-common-error",
        )
        .await;

        let (response_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(
            &response_header,
            response_header.message_length(),
            63,
            63,
            OpCode::Msg,
        );
        assert_error_response(&response_document, ErrorCode::BadValue);
        assert!(
            next_header_result
                .expect("next header future should resolve after extraction failure")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }

    #[tokio::test]
    async fn handle_message_skips_error_response_when_more_to_come() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = doc! {
            "ping": 1_i32,
            "$db": 7_i32,
        };
        let (header, mut body) = build_op_msg_parts(&invalid_document, 68);
        body[..std::mem::size_of::<u32>()].copy_from_slice(&2_u32.to_le_bytes());

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-more-to-come-error",
        )
        .await;

        assert!(
            response_bytes.is_empty(),
            "moreToCome requests must not receive error responses"
        );
        assert!(
            next_header_result
                .expect("next header future should resolve after moreToCome error")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }

    #[tokio::test]
    async fn handle_message_skips_error_response_when_more_to_come_msg_is_malformed() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        connection_context.requires_response = false;
        let body = 2_u32.to_le_bytes().to_vec();
        let length =
            i32::try_from(Header::LENGTH + body.len()).expect("message size should fit into i32");
        let header = Header::new(length, 69, 0, OpCode::Msg).expect("test header should be valid");

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-malformed-more-to-come",
        )
        .await;

        assert!(
            response_bytes.is_empty(),
            "malformed moreToCome requests must not receive error responses"
        );
        assert!(
            next_header_result
                .expect("next header future should resolve after malformed moreToCome request")
                .is_none(),
            "connection should be at EOF after the single malformed request"
        );
    }

    #[tokio::test]
    async fn handle_message_skips_required_flag_error_response_when_more_to_come() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let command = doc! { "ping": 1_i32, "$db": "admin" };
        let (header, mut body) = build_op_msg_parts(&command, 74);
        let unknown_required_flag = 0x0004_u32;
        let flags = 2_u32 | unknown_required_flag;
        body[..std::mem::size_of::<u32>()].copy_from_slice(&flags.to_le_bytes());

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-more-to-come-unknown-required-flag",
        )
        .await;

        assert!(
            response_bytes.is_empty(),
            "unknown required flag errors must not reply to moreToCome requests"
        );
        assert!(
            next_header_result
                .expect("next header future should resolve after required flag failure")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }

    #[tokio::test]
    async fn handle_message_skips_too_many_sections_error_when_more_to_come() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let command = doc! { "ping": 1_i32, "$db": "admin" };
        let extra_a = doc! { "a": 1_i32 };
        let extra_b = doc! { "b": 1_i32 };
        let command_section = build_document_section(&command);
        let first_extra_section = build_document_section(&extra_a);
        let second_extra_section = build_document_section(&extra_b);
        let (header, mut body) = build_op_msg_parts_with_sections(
            &[command_section, first_extra_section, second_extra_section],
            70,
        );
        body[..std::mem::size_of::<u32>()].copy_from_slice(&2_u32.to_le_bytes());

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-more-to-come-too-many-sections",
        )
        .await;

        assert!(
            response_bytes.is_empty(),
            "parsed moreToCome envelopes must not receive shape-error responses"
        );
        assert!(
            next_header_result
                .expect("next header future should resolve after too-many-sections error")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }

    #[tokio::test]
    async fn handle_message_shutdown_skips_response_when_more_to_come() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        dynamic_configuration.set_send_shutdown_responses(true);
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let command = doc! { "ping": 1_i32, "$db": "admin" };
        let (header, mut body) = build_op_msg_parts(&command, 71);
        body[..std::mem::size_of::<u32>()].copy_from_slice(&2_u32.to_le_bytes());

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-shutdown-more-to-come",
        )
        .await;

        assert!(
            response_bytes.is_empty(),
            "shutdown handling must not reply when current request has moreToCome"
        );
        assert!(
            next_header_result
                .expect("next header future should resolve after shutdown moreToCome")
                .is_none(),
            "connection should be at EOF after the single shutdown request"
        );
    }

    #[tokio::test]
    async fn handle_message_shutdown_skips_response_when_more_to_come_msg_is_malformed() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        dynamic_configuration.set_send_shutdown_responses(true);
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        connection_context.requires_response = false;
        let body = 2_u32.to_le_bytes().to_vec();
        let length =
            i32::try_from(Header::LENGTH + body.len()).expect("message size should fit into i32");
        let header = Header::new(length, 72, 0, OpCode::Msg).expect("test header should be valid");

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-shutdown-malformed-more-to-come",
        )
        .await;

        assert!(
            response_bytes.is_empty(),
            "shutdown handling must not reply to malformed moreToCome requests"
        );
        assert!(
            next_header_result
                .expect("next header future should resolve after malformed shutdown request")
                .is_none(),
            "connection should be at EOF after the single malformed request"
        );
    }

    #[tokio::test]
    async fn handle_message_replies_when_transaction_validation_fails() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = invalid_transaction_find_document();
        let (header, body) = build_op_msg_parts(&invalid_document, 64);

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-validation-error",
        )
        .await;

        let (response_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(
            &response_header,
            response_header.message_length(),
            64,
            64,
            OpCode::Msg,
        );
        assert_error_response(
            &response_document,
            ErrorCode::OperationNotSupportedInTransaction,
        );
        assert!(
            next_header_result
                .expect("next header future should resolve after validation failure")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }

    #[tokio::test]
    async fn handle_message_skips_validation_error_response_when_more_to_come() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = invalid_transaction_find_document();
        let (header, mut body) = build_op_msg_parts(&invalid_document, 73);
        body[..std::mem::size_of::<u32>()].copy_from_slice(&2_u32.to_le_bytes());

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-more-to-come-validation-error",
        )
        .await;

        assert!(
            response_bytes.is_empty(),
            "post-parse validation errors must not reply to moreToCome requests"
        );
        assert!(
            next_header_result
                .expect("next header future should resolve after validation failure")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }

    #[tokio::test]
    async fn handle_message_replies_when_pre_auth_request_has_transaction_metadata() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = doc! {
            "ping": 1_i32,
            "$db": "admin",
            "lsid": { "id": Binary { subtype: BinarySubtype::Uuid, bytes: vec![0_u8; 16] } },
            "txnNumber": 1_i64,
            "autocommit": false,
        };
        let (header, body) = build_op_msg_parts(&invalid_document, 66);

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-pre-auth-transaction-metadata",
        )
        .await;

        let (response_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(
            &response_header,
            response_header.message_length(),
            66,
            66,
            OpCode::Msg,
        );
        assert_error_response(&response_document, ErrorCode::Unauthorized);
        assert!(
            next_header_result
                .expect("next header future should resolve after pre-auth metadata failure")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }

    #[tokio::test]
    async fn handle_message_replies_when_pre_auth_request_has_explain_flag() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = doc! {
            "ping": 1_i32,
            "$db": "admin",
            "explain": true,
        };
        let (header, body) = build_op_msg_parts(&invalid_document, 67);

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-pre-auth-explain",
        )
        .await;

        let (response_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(
            &response_header,
            response_header.message_length(),
            67,
            67,
            OpCode::Msg,
        );
        assert_error_response(&response_document, ErrorCode::BadValue);
        assert!(
            next_header_result
                .expect("next header future should resolve after pre-auth explain failure")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }

    #[tokio::test]
    async fn handle_message_replies_when_auth_processing_fails() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let invalid_document = malformed_sasl_start_document();
        let (header, body) = build_op_msg_parts(&invalid_document, 65);

        let (response_bytes, next_header_result) = execute_handle_message::<DocumentDBDataClient>(
            &mut connection_context,
            header,
            body,
            "activity-auth-processing-error",
        )
        .await;

        let (response_header, response_document) = decode_op_msg_response(&response_bytes);
        assert_header_matches(
            &response_header,
            response_header.message_length(),
            65,
            65,
            OpCode::Msg,
        );
        assert_error_response(&response_document, ErrorCode::BadValue);
        assert!(
            next_header_result
                .expect("next header future should resolve after auth failure")
                .is_none(),
            "connection should be at EOF after the single invalid request"
        );
    }
}
