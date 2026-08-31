/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/tests/support.rs
 *
 *-------------------------------------------------------------------------
 */

//! Provides shared runtime test fixtures and wire helpers.

use std::sync::Arc;

use nacelle::{
    core::{NacelleError, NacelleLimits, NacelleRuntimeState, NacelleTelemetry},
    tcp::{
        connection::serve_serial_stream_without_connection_limit, NacelleTcpConfig,
        NacelleTcpLimits, TcpRequestBodyMode,
    },
};
use tokio::{
    io::{AsyncReadExt, DuplexStream},
    net::TcpStream,
};
use tokio_util::sync::CancellationToken;

pub(super) use crate::testing::TestDynamicConfiguration;
use crate::{
    context::ServiceContext,
    error::Result,
    postgres::DocumentDBDataClient,
    protocol::{header::Header, opcode::OpCode},
    runtime::v2::{handler::GatewayRuntimeHandler, protocol::GatewayWireProtocol, wire},
    testing::test_connection_context,
};

const TEST_MAX_FRAME_LEN: usize = 1024 * 1024;

/// Builds a service context suitable for isolated runtime transport tests.
pub(super) async fn test_service_context(
    dynamic_configuration: TestDynamicConfiguration,
) -> ServiceContext {
    test_connection_context(false, Arc::new(dynamic_configuration), None)
        .await
        .service_context
        .as_ref()
        .clone()
}

/// Starts one serial runtime connection over an in-memory duplex stream.
pub(super) fn start_serial_test_connection(
    service_context: ServiceContext,
    shutdown_token: CancellationToken,
) -> (
    DuplexStream,
    tokio::task::JoinHandle<std::result::Result<(), NacelleError>>,
) {
    let runtime_state = NacelleRuntimeState::new(
        NacelleLimits::default()
            .with_max_connections(8)
            .with_max_in_flight_requests(8)
            .with_max_request_body_bytes(TEST_MAX_FRAME_LEN)
            .with_max_response_body_bytes(TEST_MAX_FRAME_LEN),
    );
    let config = NacelleTcpConfig::default()
        .with_max_frame_len(TEST_MAX_FRAME_LEN)
        .with_request_body_mode(TcpRequestBodyMode::Streaming);
    let protocol = Arc::new(GatewayWireProtocol::new(
        service_context,
        None,
        shutdown_token,
        config.response_buffer_capacity,
    ));
    let (client, mut server) = tokio::io::duplex(64 * 1024);
    let handler = Arc::new(GatewayRuntimeHandler::<DocumentDBDataClient>::new());
    let server_task = tokio::spawn(async move {
        Box::pin(serve_serial_stream_without_connection_limit(
            &mut server,
            protocol,
            Arc::clone(&handler),
            handler,
            config,
            NacelleTelemetry::default(),
            runtime_state,
            NacelleTcpLimits::default(),
            nacelle::core::NacelleConnectionMeta::tcp(None, None),
        ))
        .await
    });
    (client, server_task)
}

/// Reads one complete wire response from the test connection.
pub(super) async fn read_wire_response(client: &mut DuplexStream) -> Vec<u8> {
    let mut response_length = [0_u8; std::mem::size_of::<i32>()];
    client
        .read_exact(&mut response_length)
        .await
        .expect("response length should read");
    let response_length = usize::try_from(i32::from_le_bytes(response_length))
        .expect("response length should be positive");
    let mut response = vec![0_u8; response_length];
    response[..std::mem::size_of::<i32>()].copy_from_slice(
        &i32::try_from(response_length)
            .expect("length should fit")
            .to_le_bytes(),
    );
    client
        .read_exact(&mut response[std::mem::size_of::<i32>()..])
        .await
        .expect("response body should read");
    response
}

/// Builds an `OP_MSG` request containing the test logout command.
pub(super) fn build_op_msg_request(request_id: i32, flags: u32) -> Vec<u8> {
    build_op_msg_request_with_document(&bson::doc! { "logout": 1 }, request_id, flags)
}

/// Builds an `OP_MSG` request containing the supplied command document.
pub(super) fn build_op_msg_request_with_document(
    document: &bson::Document,
    request_id: i32,
    flags: u32,
) -> Vec<u8> {
    let document = bson::to_vec(document).expect("test document should serialize");
    let message_length = wire::op_msg_prefix_length() + document.len();
    let wire_message_length =
        i32::try_from(message_length).expect("test message length should fit");
    let mut bytes = Vec::with_capacity(message_length);
    bytes.extend_from_slice(&wire_message_length.to_le_bytes());
    bytes.extend_from_slice(&request_id.to_le_bytes());
    bytes.extend_from_slice(&0_i32.to_le_bytes());
    bytes.extend_from_slice(&(OpCode::Msg as i32).to_le_bytes());
    bytes.extend_from_slice(&flags.to_le_bytes());
    bytes.push(0);
    bytes.extend_from_slice(&document);
    bytes
}

/// Decodes a wire header from the supplied bytes.
///
/// # Errors
///
/// Returns an error if the header fields do not form a valid wire header.
pub(super) fn decode_header(input: &[u8]) -> Result<Header> {
    let message_length = i32::from_le_bytes([input[0], input[1], input[2], input[3]]);
    let request_id = i32::from_le_bytes([input[4], input[5], input[6], input[7]]);
    let response_to = i32::from_le_bytes([input[8], input[9], input[10], input[11]]);
    let op_code = OpCode::from_value(i32::from_le_bytes([
        input[12], input[13], input[14], input[15],
    ]));

    Header::new(message_length, request_id, response_to, op_code)
}

/// Creates a connected loopback TCP pair for listener tests.
pub(super) async fn connected_tcp_pair() -> (TcpStream, TcpStream) {
    let listener = tokio::net::TcpListener::bind("127.0.0.1:0")
        .await
        .expect("test listener should bind");
    let address = listener.local_addr().expect("test address should exist");
    let client = TcpStream::connect(address)
        .await
        .expect("test client should connect");
    let (server, _) = listener.accept().await.expect("test server should accept");
    (client, server)
}
