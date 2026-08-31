/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/tests/protocol.rs
 *
 *-------------------------------------------------------------------------
 */

//! Tests gateway request decoding and response wire framing.

use bytes::BytesMut;
use nacelle::{
    codec::MessageDecoder,
    core::{pipeline::ConnectionInfo, NacelleConnectionMeta, NacelleError},
    tcp::{DecodedMessage, FrameBuffer, Protocol},
};
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    error::DocumentDBError,
    protocol::{header::Header, opcode::OpCode, MAX_MESSAGE_SIZE_BYTES},
    responses::error_to_raw_document_buf,
    runtime::v2::{
        protocol::{self, GatewayDecodeError, GatewayRequestDecoder, GatewayWireProtocol},
        tests::support::{
            build_op_msg_request, decode_header, test_service_context, TestDynamicConfiguration,
        },
        wire,
    },
};

#[tokio::test]
async fn connection_protocol_preserves_gateway_connection_id() {
    let connection_id = Uuid::new_v4();
    let protocol = GatewayWireProtocol::new(
        test_service_context(TestDynamicConfiguration::default()).await,
        None,
        CancellationToken::new(),
        1024,
    )
    .for_connection(connection_id);
    let connection = NacelleConnectionMeta::tcp(None, None);

    assert_eq!(
        protocol
            .connection_state(&ConnectionInfo::from(&connection))
            .connection_id(),
        connection_id
    );
}

#[test]
fn protocol_decodes_wire_header_and_leaves_body() {
    let bytes = build_op_msg_request(42, 0);
    let mut buffer = BytesMut::from(bytes.as_slice());
    let mut decoder =
        GatewayRequestDecoder::new(usize::try_from(MAX_MESSAGE_SIZE_BYTES).unwrap_or(48_000_000));

    let decoded_message = decoder
        .decode(&mut buffer)
        .expect("decode should succeed")
        .expect("complete header should decode");
    let request_head = match decoded_message {
        DecodedMessage::Request(request_head) => request_head,
        DecodedMessage::OneWay(_) => panic!("normal logout should require a response"),
    };

    assert_eq!(request_head.request.header().request_id(), 42);
    assert_eq!(request_head.request.header().op_code(), OpCode::Msg);
    assert_eq!(request_head.body_len, buffer.len());
}

#[test]
fn protocol_decoder_preserves_incomplete_header() {
    let bytes = build_op_msg_request(42, 0);
    let mut buffer = BytesMut::from(&bytes[..Header::LENGTH - 1]);
    let original = buffer.clone();
    let mut decoder =
        GatewayRequestDecoder::new(usize::try_from(MAX_MESSAGE_SIZE_BYTES).unwrap_or(48_000_000));

    assert!(decoder
        .decode(&mut buffer)
        .expect("partial decode should succeed")
        .is_none());
    assert_eq!(buffer, original);
}

#[test]
fn protocol_decoder_preserves_incomplete_op_msg_flags() {
    let bytes = build_op_msg_request(42, 0);
    let mut buffer = BytesMut::from(&bytes[..Header::LENGTH + 3]);
    let original = buffer.clone();
    let mut decoder =
        GatewayRequestDecoder::new(usize::try_from(MAX_MESSAGE_SIZE_BYTES).unwrap_or(48_000_000));

    assert!(decoder
        .decode(&mut buffer)
        .expect("partial decode should succeed")
        .is_none());
    assert_eq!(buffer, original);
}

#[test]
fn protocol_decoder_routes_short_op_msg_without_consuming_following_bytes() {
    let more_to_come_flag = protocol::more_to_come_flag();
    let mut bytes = Vec::with_capacity(Header::LENGTH + std::mem::size_of::<u32>());
    bytes.extend_from_slice(&Header::LENGTH_I32.to_le_bytes());
    bytes.extend_from_slice(&42_i32.to_le_bytes());
    bytes.extend_from_slice(&0_i32.to_le_bytes());
    bytes.extend_from_slice(&(OpCode::Msg as i32).to_le_bytes());
    bytes.extend_from_slice(&more_to_come_flag.to_le_bytes());
    let mut buffer = BytesMut::from(bytes.as_slice());
    let mut decoder =
        GatewayRequestDecoder::new(usize::try_from(MAX_MESSAGE_SIZE_BYTES).unwrap_or(48_000_000));

    let decoded_message = decoder
        .decode(&mut buffer)
        .expect("malformed head should route through a request error")
        .expect("malformed head should produce an error request");
    let DecodedMessage::Request(request) = decoded_message else {
        panic!("malformed head must require an error response");
    };

    assert!(matches!(
        request.request.decode_error(),
        Some(GatewayDecodeError::BadValue(_))
    ));
    assert_eq!(request.body_len, 0);
    assert_eq!(buffer.as_ref(), more_to_come_flag.to_le_bytes());
}

#[test]
fn protocol_decoder_classifies_more_to_come_as_one_way() {
    let bytes = build_op_msg_request(42, protocol::more_to_come_flag());
    let mut buffer = BytesMut::from(bytes.as_slice());
    let mut decoder =
        GatewayRequestDecoder::new(usize::try_from(MAX_MESSAGE_SIZE_BYTES).unwrap_or(48_000_000));

    let decoded_message = decoder
        .decode(&mut buffer)
        .expect("decode should succeed")
        .expect("complete message head should decode");

    assert!(matches!(decoded_message, DecodedMessage::OneWay(_)));
}

#[test]
fn protocol_round_trips_response_bytes() {
    let response = error_to_raw_document_buf(
        &DocumentDBError::internal_error("test error".to_owned()),
        "",
    );
    let mut bytes = BytesMut::new();

    wire::append_op_msg_response(
        7,
        response.as_bytes(),
        &mut FrameBuffer::new(&mut bytes, usize::MAX),
    )
    .expect("response should encode");

    let header = decode_header(&bytes).expect("response header should decode");
    assert_eq!(header.response_to(), 7);
    assert_eq!(&bytes[wire::op_msg_prefix_length()..], response.as_bytes());
}

#[test]
fn response_message_length_allows_exact_gateway_limit() {
    let max = usize::try_from(MAX_MESSAGE_SIZE_BYTES).expect("gateway limit should fit");
    let prefix_length = wire::op_msg_prefix_length();

    assert_eq!(
        wire::response_message_length(max - prefix_length, prefix_length)
            .expect("exact gateway limit should encode"),
        MAX_MESSAGE_SIZE_BYTES
    );
}

#[test]
fn response_message_length_rejects_over_gateway_limit() {
    let max = usize::try_from(MAX_MESSAGE_SIZE_BYTES).expect("gateway limit should fit");
    let prefix_length = wire::op_msg_prefix_length();

    assert!(matches!(
        wire::response_message_length(max - prefix_length + 1, prefix_length),
        Err(NacelleError::FrameTooLarge { .. })
    ));
}
