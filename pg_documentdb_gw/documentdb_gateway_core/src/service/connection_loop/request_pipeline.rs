/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/service/connection_loop/request_pipeline.rs
 *
 *-------------------------------------------------------------------------
 */

use tokio::{
    io::{AsyncRead, AsyncWrite},
    time::Instant,
};

use crate::{
    context::{ConnectionContext, RequestContext},
    postgres::PgDataClient,
    protocol::{self, header::Header},
    requests::{request_tracker::RequestTracker, validation, RequestIntervalKind},
    service::connection_loop::{
        error_reply,
        read_ahead::{self, PendingHeaderRead},
        request_execution,
    },
};

#[expect(
    clippy::too_many_lines,
    reason = "Request hot path coordinates read-ahead, parsing, validation, response writing, and telemetry"
)]
pub(super) async fn handle_message<'a, T, R, W>(
    connection_context: &mut ConnectionContext,
    header: &Header,
    reader: &'a mut R,
    writer: &mut W,
    activity_id: &str,
) -> PendingHeaderRead<'a>
where
    T: PgDataClient,
    R: AsyncRead + Unpin + Send + 'a,
    W: AsyncWrite + Unpin,
{
    let request_tracker = RequestTracker::new();

    let read_request_start = Instant::now();
    let message = match protocol::reader::read_request(header, reader).await {
        Ok(message) => message,
        Err(error) => {
            error_reply::reply_with_request_error::<W>(
                connection_context,
                header,
                &error,
                None,
                writer,
                None,
                &request_tracker,
                activity_id,
                None,
            )
            .await;
            return read_ahead::start_next_header_read(reader).await;
        }
    };
    request_tracker.record_duration(RequestIntervalKind::ReadRequest, read_request_start);

    // Start receiving the next request as soon as the current request bytes are fully consumed,
    // mirroring the managed gateway's read-ahead overlap before deeper parsing/handling work.
    let next_header = read_ahead::start_next_header_read(reader).await;

    // HandleMessage captures the overall duration needed by the server to handle/process
    // a user operation message/request. Client-to-Gateway networking latency should be
    // excluded from HandleMessage; therefore, ReadRequest is closed before this starts,
    // and WriteResponse starts measuring only after HandleMessage is closed.
    let handle_message_start = Instant::now();
    if error_reply::maybe_reply_shutdown(
        connection_context,
        header,
        writer,
        &request_tracker,
        activity_id,
        handle_message_start,
    )
    .await
    {
        return next_header;
    }

    let format_request_start = Instant::now();
    let request = match protocol::reader::parse_request(
        &message,
        &mut connection_context.requires_response,
    ) {
        Ok(request) => request,
        Err(error) => {
            error_reply::reply_with_request_error::<W>(
                connection_context,
                header,
                &error,
                None,
                writer,
                None,
                &request_tracker,
                activity_id,
                Some(handle_message_start),
            )
            .await;

            return next_header;
        }
    };
    request_tracker.record_duration(RequestIntervalKind::FormatRequest, format_request_start);

    let request_info = match request.extract_common() {
        Ok(request_info) => request_info,
        Err(error) => {
            error_reply::reply_with_request_error::<W>(
                connection_context,
                header,
                &error,
                Some(&request),
                writer,
                None,
                &request_tracker,
                activity_id,
                Some(handle_message_start),
            )
            .await;

            return next_header;
        }
    };

    if let Err(error) = validation::validate_request(connection_context, &request_info, &request) {
        let collection = request_info.collection().unwrap_or("").to_owned();
        error_reply::reply_with_request_error::<W>(
            connection_context,
            header,
            &error,
            Some(&request),
            writer,
            Some(collection),
            &request_tracker,
            activity_id,
            Some(handle_message_start),
        )
        .await;

        return next_header;
    }

    let request_context = RequestContext {
        activity_id,
        payload: &request,
        info: &request_info,
        tracker: &request_tracker,
    };

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
        let collection = request_context.info.collection().unwrap_or("").to_owned();
        error_reply::reply_with_request_error::<W>(
            connection_context,
            header,
            &error,
            Some(&request),
            writer,
            Some(collection),
            request_context.tracker,
            activity_id,
            Some(handle_message_start),
        )
        .await;
    }

    next_header
}

#[cfg(test)]
mod tests {
    use super::*;

    use std::sync::Arc;

    use bson::doc;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    use crate::{
        error::{ErrorCode, Result},
        postgres::DocumentDBDataClient,
        protocol::opcode::OpCode,
        testing::{
            assert_error_response, assert_header_matches, build_op_msg_parts,
            decode_op_msg_response, invalid_transaction_find_document, logout_document,
            malformed_sasl_start_document, test_connection_context, TestDynamicConfiguration,
        },
    };

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
    async fn handle_message_replies_when_request_body_is_truncated() {
        let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let mut connection_context =
            test_connection_context(false, dynamic_configuration, None).await;
        let logout_document = logout_document();
        let (_, full_body) = build_op_msg_parts(&logout_document, 61);
        let truncated_body = full_body[..full_body.len() - 2].to_vec();
        let header = Header {
            length: i32::try_from(Header::LENGTH + full_body.len())
                .expect("message size should fit into i32"),
            request_id: 61,
            response_to: 0,
            op_code: OpCode::Msg,
        };

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
            response_header.length,
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
            response_header.length,
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
            response_header.length,
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
            response_header.length,
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
            response_header.length,
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
