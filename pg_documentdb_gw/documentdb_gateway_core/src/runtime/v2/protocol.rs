/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/protocol.rs
 *
 *-------------------------------------------------------------------------
 */

//! Decodes gateway requests and adapts them to the serial runtime protocol.

use std::{
    fmt::{Display, Formatter},
    net::IpAddr,
};

use bytes::{Buf, Bytes, BytesMut};
use nacelle::{
    codec::MessageDecoder,
    core::{pipeline::ConnectionInfo, NacelleBody, NacelleError, NacelleResourceLimitReason},
    tcp::{DecodedMessage, DecodedRequest, FrameBuffer, Protocol},
};
use tokio::time::Instant;
use tokio_util::sync::CancellationToken;
use uuid::Uuid;

use crate::{
    context::{ConnectionContext, ServiceContext},
    error::DocumentDBError,
    protocol::{
        header::Header, opcode::OpCode, MAX_MESSAGE_USIZE_BYTES, MAX_PRE_AUTH_MESSAGE_USIZE_BYTES,
        MESSAGE_SIZE_EXCEEDED_ERROR,
    },
    responses::error_to_raw_document_buf,
    runtime::v2::{
        handler::GatewayConnectionState,
        wire::{append_op_msg_response, append_wire_response},
    },
    telemetry::TelemetryProvider,
};

const MORE_TO_COME_FLAG: u32 = 1 << 1;

#[derive(Debug, Clone)]
pub(super) enum GatewayDecodeError {
    BadValue(String),
    MessageSizeExceeded,
}

impl GatewayDecodeError {
    fn documentdb_error(&self) -> DocumentDBError {
        match self {
            Self::BadValue(message) => DocumentDBError::bad_value(message.clone()),
            Self::MessageSizeExceeded => {
                DocumentDBError::internal_error(MESSAGE_SIZE_EXCEEDED_ERROR.to_owned())
            }
        }
    }
}

impl Display for GatewayDecodeError {
    fn fmt(&self, f: &mut Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::BadValue(message) => f.write_str(message),
            Self::MessageSizeExceeded => f.write_str(MESSAGE_SIZE_EXCEEDED_ERROR),
        }
    }
}

impl std::error::Error for GatewayDecodeError {}

#[derive(Debug, Clone)]
pub(super) struct GatewayWireRequest {
    header: Header,
    decode_error: Option<GatewayDecodeError>,
    read_request_start: Instant,
}

impl GatewayWireRequest {
    /// Returns the decoded wire header.
    #[must_use]
    pub(super) const fn header(&self) -> Header {
        self.header
    }

    /// Returns a deferred decoding error, if the request head was malformed.
    #[must_use]
    pub(super) fn decode_error(&self) -> Option<GatewayDecodeError> {
        self.decode_error.clone()
    }

    /// Returns when reading this request began.
    #[must_use]
    pub(super) const fn read_request_start(&self) -> Instant {
        self.read_request_start
    }
}

#[derive(Debug, Clone, Copy)]
pub(super) struct GatewayErrorContext(Option<Header>);

#[derive(Debug, Clone)]
pub(super) struct GatewayRequestDecoder {
    max_frame_len: usize,
    read_request_start: Option<Instant>,
}

impl GatewayRequestDecoder {
    /// Creates a request decoder bounded by the maximum wire frame length.
    #[must_use]
    pub(super) const fn new(max_frame_len: usize) -> Self {
        Self {
            max_frame_len,
            read_request_start: None,
        }
    }
}

impl MessageDecoder for GatewayRequestDecoder {
    type Message = DecodedMessage<GatewayWireRequest, GatewayWireRequest>;
    type Error = NacelleError;

    fn decode(
        &mut self,
        input: &mut BytesMut,
    ) -> std::result::Result<Option<Self::Message>, Self::Error> {
        if input.len() < Header::LENGTH {
            return Ok(None);
        }
        let read_request_start = *self.read_request_start.get_or_insert_with(Instant::now);

        let message_length = i32::from_le_bytes([input[0], input[1], input[2], input[3]]);
        let request_id = i32::from_le_bytes([input[4], input[5], input[6], input[7]]);
        let response_to = i32::from_le_bytes([input[8], input[9], input[10], input[11]]);
        let op_code = OpCode::from_value(i32::from_le_bytes([
            input[12], input[13], input[14], input[15],
        ]));
        let error_header = Header::new(Header::LENGTH_I32, request_id, response_to, op_code)
            .map_err(NacelleError::protocol)?;
        let header = match Header::new(message_length, request_id, response_to, op_code) {
            Ok(header) => header,
            Err(error) => {
                self.read_request_start = None;
                return Ok(Some(decode_error_request(
                    input,
                    error_header,
                    GatewayDecodeError::BadValue(error.error_message_user().to_owned()),
                    read_request_start,
                )));
            }
        };
        let message_len =
            usize::try_from(header.message_length()).map_err(NacelleError::protocol)?;

        if message_len > self.max_frame_len {
            self.read_request_start = None;
            return Ok(Some(decode_error_request(
                input,
                error_header,
                GatewayDecodeError::MessageSizeExceeded,
                read_request_start,
            )));
        }

        if header.op_code() == OpCode::Msg
            && message_len < Header::LENGTH + std::mem::size_of::<u32>()
        {
            self.read_request_start = None;
            return Ok(Some(decode_error_request(
                input,
                error_header,
                GatewayDecodeError::BadValue(
                    "OP_MSG frame is too short to contain message flags".to_owned(),
                ),
                read_request_start,
            )));
        }

        if header.op_code() == OpCode::Msg
            && input.len() < Header::LENGTH + std::mem::size_of::<u32>()
        {
            return Ok(None);
        }

        let is_one_way = match header.op_code() {
            OpCode::Msg => {
                let flags = u32::from_le_bytes([
                    input[Header::LENGTH],
                    input[Header::LENGTH + 1],
                    input[Header::LENGTH + 2],
                    input[Header::LENGTH + 3],
                ]);
                flags & MORE_TO_COME_FLAG != 0
            }
            #[expect(deprecated, reason = "OP_INSERT is a one-way legacy operation")]
            OpCode::Insert => true,
            _ => false,
        };

        self.read_request_start = None;
        input.advance(Header::LENGTH);
        let decoded = DecodedRequest {
            request: GatewayWireRequest {
                header,
                decode_error: None,
                read_request_start,
            },
            body_len: message_len - Header::LENGTH,
        };
        if is_one_way {
            Ok(Some(DecodedMessage::OneWay(decoded)))
        } else {
            Ok(Some(DecodedMessage::Request(decoded)))
        }
    }
}

fn decode_error_request(
    input: &mut BytesMut,
    header: Header,
    decode_error: GatewayDecodeError,
    read_request_start: Instant,
) -> DecodedMessage<GatewayWireRequest, GatewayWireRequest> {
    input.advance(Header::LENGTH);
    DecodedMessage::Request(DecodedRequest {
        request: GatewayWireRequest {
            header,
            decode_error: Some(decode_error),
            read_request_start,
        },
        body_len: 0,
    })
}

#[derive(Clone)]
pub(super) struct GatewayWireProtocol {
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    shutdown_token: CancellationToken,
    response_chunk_size: usize,
    connection_id: Option<Uuid>,
}

impl GatewayWireProtocol {
    /// Creates the protocol adapter for a gateway runtime.
    #[must_use]
    pub(super) fn new(
        service_context: ServiceContext,
        telemetry: Option<Box<dyn TelemetryProvider>>,
        shutdown_token: CancellationToken,
        response_chunk_size: usize,
    ) -> Self {
        Self {
            service_context,
            telemetry,
            shutdown_token,
            response_chunk_size,
            connection_id: None,
        }
    }

    /// Creates a protocol instance scoped to one gateway connection.
    #[must_use]
    pub(super) fn for_connection(&self, connection_id: Uuid) -> Self {
        let mut protocol = self.clone();
        protocol.connection_id = Some(connection_id);
        protocol
    }
}

impl Protocol for GatewayWireProtocol {
    type Request = GatewayWireRequest;
    type OneWayRequest = GatewayWireRequest;
    type Response = Bytes;
    type ConnectionState = GatewayConnectionState;
    type Decoder = GatewayRequestDecoder;
    type ErrorContext = GatewayErrorContext;
    type ResponseContext = Header;

    fn decoder(&self, max_frame_len: usize) -> Self::Decoder {
        GatewayRequestDecoder::new(max_frame_len)
    }

    fn connection_state(&self, connection: &ConnectionInfo) -> Self::ConnectionState {
        GatewayConnectionState::new(
            connection_context_from_info(
                self.service_context.clone(),
                self.telemetry.clone(),
                connection,
                self.connection_id.unwrap_or_else(Uuid::new_v4),
            ),
            self.shutdown_token.clone(),
            self.response_chunk_size,
        )
    }

    fn request_wire_bytes(&self, _request: &Self::Request, body_len: usize) -> usize {
        Header::LENGTH + body_len
    }

    fn one_way_wire_bytes(&self, _request: &Self::OneWayRequest, body_len: usize) -> usize {
        Header::LENGTH + body_len
    }

    fn max_request_body_bytes(
        &self,
        _request: &Self::Request,
        _connection: &ConnectionInfo,
        state: &Self::ConnectionState,
        default_limit: usize,
    ) -> usize {
        if state.is_authenticated() {
            default_limit
        } else {
            gateway_pre_auth_max_body_bytes().min(default_limit)
        }
    }

    fn max_one_way_body_bytes(
        &self,
        request: &Self::OneWayRequest,
        connection: &ConnectionInfo,
        state: &Self::ConnectionState,
        default_limit: usize,
    ) -> usize {
        self.max_request_body_bytes(request, connection, state, default_limit)
    }

    fn response_context(&self, req: &GatewayWireRequest) -> Self::ResponseContext {
        req.header()
    }

    fn error_context(&self, req: &GatewayWireRequest) -> Self::ErrorContext {
        let header = match req.header().op_code() {
            #[expect(
                deprecated,
                reason = "OP_QUERY remains supported for legacy handshake clients"
            )]
            OpCode::Msg | OpCode::Query => Some(req.header()),
            _ => None,
        };
        GatewayErrorContext(header)
    }

    fn apply_response(&self, _context: &mut Self::ResponseContext, _response: &Self::Response) {}

    fn max_response_frame_overhead(&self) -> usize {
        0
    }

    fn response_body(&self, response: Self::Response) -> NacelleBody {
        NacelleBody::bytes(response)
    }

    fn encode_response_chunk(
        &self,
        _context: &mut Self::ResponseContext,
        chunk: Bytes,
        dst: &mut FrameBuffer<'_>,
    ) -> std::result::Result<(), NacelleError> {
        dst.extend_from_slice(&chunk)
    }

    fn encode_response_terminal_chunk(
        &self,
        _context: &mut Self::ResponseContext,
        chunk: Bytes,
        dst: &mut FrameBuffer<'_>,
    ) -> std::result::Result<(), NacelleError> {
        dst.extend_from_slice(&chunk)
    }

    fn encode_response_end(
        &self,
        _context: &mut Self::ResponseContext,
        _dst: &mut FrameBuffer<'_>,
    ) -> std::result::Result<(), NacelleError> {
        Ok(())
    }

    fn encode_error(
        &self,
        context: Option<&Self::ErrorContext>,
        error: &NacelleError,
        dst: &mut FrameBuffer<'_>,
    ) -> std::result::Result<(), NacelleError> {
        if matches!(error, NacelleError::ConnectionClosed) {
            return Ok(());
        }
        let error = documentdb_error_from_runtime_error(error);
        let response = error_to_raw_document_buf(&error, "");
        match context.and_then(|context| context.0.as_ref()) {
            Some(header) => append_wire_response(header, response.as_bytes(), dst),
            None => append_op_msg_response(0, response.as_bytes(), dst),
        }
    }
}

fn documentdb_error_from_runtime_error(error: &NacelleError) -> DocumentDBError {
    if let NacelleError::Protocol(source) = error {
        if let Some(decode_error) = source.downcast_ref::<GatewayDecodeError>() {
            return decode_error.documentdb_error();
        }
    }
    if matches!(
        error,
        NacelleError::ResourceLimit(NacelleResourceLimitReason::RequestBodyBytes)
    ) {
        return DocumentDBError::internal_error(MESSAGE_SIZE_EXCEEDED_ERROR.to_owned());
    }

    DocumentDBError::internal_error(format!("Gateway request failed: {error}."))
}

fn connection_context_from_info(
    service_context: ServiceContext,
    telemetry: Option<Box<dyn TelemetryProvider>>,
    connection: &ConnectionInfo,
    connection_id: Uuid,
) -> ConnectionContext {
    let ip_address = connection_peer_ip(connection);
    let transport_protocol = if connection.local_path.is_some() {
        "UnixSocket"
    } else {
        "TCP"
    }
    .to_owned();
    let mut connection_context = ConnectionContext::new(
        service_context,
        telemetry,
        ip_address,
        None,
        connection_id,
        transport_protocol,
    );

    if let Some(tls) = connection.tls.as_ref() {
        connection_context.ssl_protocol = tls.protocol.clone().unwrap_or_default();
        connection_context.cipher_type = connection_context
            .service_context
            .tls_provider()
            .ciphersuite_name_to_i32(tls.cipher_suite.as_deref());
    }

    connection_context
}

fn connection_peer_ip(connection: &ConnectionInfo) -> String {
    match connection.peer_ip {
        Some(IpAddr::V6(ipv6)) => ipv6
            .to_ipv4_mapped()
            .map_or(IpAddr::V6(ipv6), IpAddr::V4)
            .to_string(),
        Some(ip_address) => ip_address.to_string(),
        None => "localhost".to_owned(),
    }
}

#[must_use]
const fn gateway_pre_auth_max_body_bytes() -> usize {
    MAX_PRE_AUTH_MESSAGE_USIZE_BYTES
}

#[must_use]
/// Returns the maximum complete wire frame length accepted by the gateway.
pub(super) const fn gateway_max_frame_len() -> usize {
    MAX_MESSAGE_USIZE_BYTES
}

#[must_use]
/// Returns the maximum request body length after excluding the wire header.
pub(super) const fn gateway_max_request_body_len() -> usize {
    gateway_max_frame_len().saturating_sub(Header::LENGTH)
}

#[cfg(test)]
/// Returns the one-way `OP_MSG` flag used by decoder tests.
pub(super) const fn more_to_come_flag() -> u32 {
    MORE_TO_COME_FLAG
}
