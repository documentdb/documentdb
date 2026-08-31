/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/tests/transport.rs
 *
 *-------------------------------------------------------------------------
 */

//! Tests serial transport request processing and error framing.

use nacelle::core::NacelleError;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio_util::sync::CancellationToken;

use crate::{
    error::ErrorCode,
    protocol::{header::Header, opcode::OpCode, MAX_MESSAGE_SIZE_BYTES},
    runtime::v2::{
        protocol as runtime_protocol,
        tests::support::{
            build_op_msg_request, build_op_msg_request_with_document, decode_header,
            read_wire_response, start_serial_test_connection, test_service_context,
            TestDynamicConfiguration,
        },
        wire,
    },
    testing::{assert_error_response, malformed_sasl_start_document},
};

#[tokio::test]
async fn serial_transport_processes_and_frames_request() {
    let service_context = test_service_context(TestDynamicConfiguration::default()).await;
    let (mut client, server_task) =
        start_serial_test_connection(service_context, CancellationToken::new());

    client
        .write_all(&build_op_msg_request(91, 0))
        .await
        .expect("test request should write");
    let response = read_wire_response(&mut client).await;

    let header = decode_header(&response).expect("response header should decode");
    assert_eq!(header.response_to(), 91);
    assert_eq!(header.op_code(), OpCode::Msg);

    drop(client);
    server_task
        .await
        .expect("server task should join")
        .expect("server connection should close cleanly");
}

#[tokio::test]
async fn serial_transport_skips_one_way_response_and_processes_next_request() {
    let service_context = test_service_context(TestDynamicConfiguration::default()).await;
    let (mut client, server_task) =
        start_serial_test_connection(service_context, CancellationToken::new());

    client
        .write_all(&build_op_msg_request(
            98,
            runtime_protocol::more_to_come_flag(),
        ))
        .await
        .expect("one-way test request should write");
    client
        .write_all(&build_op_msg_request(99, 0))
        .await
        .expect("required-response test request should write");

    let response = read_wire_response(&mut client).await;
    let header = decode_header(&response).expect("response header should decode");
    assert_eq!(header.response_to(), 99);
    assert_eq!(header.op_code(), OpCode::Msg);

    drop(client);
    server_task
        .await
        .expect("server task should join")
        .expect("server connection should close cleanly");
}

#[tokio::test]
async fn serial_transport_keeps_connection_open_after_request_processing_error() {
    let service_context = test_service_context(TestDynamicConfiguration::default()).await;
    let (mut client, server_task) =
        start_serial_test_connection(service_context, CancellationToken::new());

    let invalid_request =
        build_op_msg_request_with_document(&malformed_sasl_start_document(), 100, 0);
    client
        .write_all(&invalid_request)
        .await
        .expect("invalid test request should write");
    let error_response = read_wire_response(&mut client).await;
    let error_header = decode_header(&error_response).expect("error response header should decode");
    assert_eq!(error_header.response_to(), 100);
    let error_document =
        bson::Document::from_reader(&error_response[wire::op_msg_prefix_length()..])
            .expect("error response document should decode");
    assert_error_response(&error_document, ErrorCode::BadValue);

    client
        .write_all(&build_op_msg_request(101, 0))
        .await
        .expect("follow-up test request should write");
    let follow_up_response = read_wire_response(&mut client).await;
    let follow_up_header =
        decode_header(&follow_up_response).expect("follow-up response header should decode");
    assert_eq!(follow_up_header.response_to(), 101);
    assert_eq!(follow_up_header.op_code(), OpCode::Msg);

    drop(client);
    server_task
        .await
        .expect("server task should join")
        .expect("server connection should close cleanly");
}

#[tokio::test]
async fn serial_transport_frames_truncated_body_error_before_close() {
    let service_context = test_service_context(TestDynamicConfiguration::default()).await;
    let (mut client, server_task) =
        start_serial_test_connection(service_context, CancellationToken::new());
    let request = build_op_msg_request(97, 0);

    client
        .write_all(&request[..request.len() - 2])
        .await
        .expect("truncated test request should write");
    client
        .shutdown()
        .await
        .expect("truncated test request should half-close");

    let response = read_wire_response(&mut client).await;
    let header = decode_header(&response).expect("error response header should decode");
    assert_eq!(header.response_to(), 97);
    assert_eq!(header.op_code(), OpCode::Msg);
    let error_document = bson::Document::from_reader(&response[wire::op_msg_prefix_length()..])
        .expect("error response document should decode");
    assert_eq!(error_document.get_i32("code"), Ok(1));

    assert!(matches!(
        server_task.await.expect("server task should join"),
        Err(NacelleError::UnexpectedEof)
    ));
}

#[tokio::test]
async fn serial_transport_returns_configured_shutdown_response() {
    let dynamic_configuration = TestDynamicConfiguration::default();
    dynamic_configuration.set_send_shutdown_responses(true);
    let service_context = test_service_context(dynamic_configuration).await;
    let shutdown_token = CancellationToken::new();
    shutdown_token.cancel();
    let (mut client, server_task) = start_serial_test_connection(service_context, shutdown_token);

    client
        .write_all(&build_op_msg_request(95, 0))
        .await
        .expect("shutdown test request should write");
    let response = read_wire_response(&mut client).await;
    let error_document = bson::Document::from_reader(&response[wire::op_msg_prefix_length()..])
        .expect("shutdown response document should decode");
    assert_eq!(
        error_document.get_str("errmsg"),
        Ok("Graceful shutdown requested")
    );

    drop(client);
    server_task
        .await
        .expect("server task should join")
        .expect("server connection should close cleanly");
}

#[tokio::test]
async fn serial_transport_closes_silently_when_shutdown_response_is_disabled() {
    let service_context = test_service_context(TestDynamicConfiguration::default()).await;
    let shutdown_token = CancellationToken::new();
    shutdown_token.cancel();
    let (mut client, server_task) = start_serial_test_connection(service_context, shutdown_token);

    client
        .write_all(&build_op_msg_request(96, 0))
        .await
        .expect("shutdown test request should write");
    assert!(matches!(
        server_task.await.expect("server task should join"),
        Err(NacelleError::ConnectionClosed)
    ));
    let mut response = Vec::new();
    client
        .read_to_end(&mut response)
        .await
        .expect("closed connection should reach EOF");
    assert!(response.is_empty());
}

#[tokio::test]
async fn serial_transport_frames_malformed_head_errors_before_close() {
    let service_context = test_service_context(TestDynamicConfiguration::default()).await;
    let cases = [
        (-1_i32, 92_i32),
        (Header::LENGTH_I32, 93_i32),
        (MAX_MESSAGE_SIZE_BYTES + 1, 94_i32),
    ];

    for (message_length, request_id) in cases {
        let (mut client, server_task) =
            start_serial_test_connection(service_context.clone(), CancellationToken::new());
        let mut request = Vec::with_capacity(Header::LENGTH);
        request.extend_from_slice(&message_length.to_le_bytes());
        request.extend_from_slice(&request_id.to_le_bytes());
        request.extend_from_slice(&0_i32.to_le_bytes());
        request.extend_from_slice(&(OpCode::Msg as i32).to_le_bytes());
        client
            .write_all(&request)
            .await
            .expect("malformed test head should write");

        let response = read_wire_response(&mut client).await;
        let header = decode_header(&response).expect("error response header should decode");
        assert_eq!(header.response_to(), request_id);
        assert_eq!(header.op_code(), OpCode::Msg);
        let error_document = bson::Document::from_reader(&response[wire::op_msg_prefix_length()..])
            .expect("error response document should decode");
        assert_eq!(error_document.get_i32("code"), Ok(2));

        drop(client);
        assert!(matches!(
            server_task.await.expect("server task should join"),
            Err(NacelleError::Protocol(_))
        ));
    }
}
