/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/runtime/v2/benchmarks.rs
 *
 *-------------------------------------------------------------------------
 */

//! Exposes runtime operations to Criterion benchmarks.

#![expect(
    clippy::expect_used,
    reason = "Benchmarks should fail fast when fixture setup or production calls fail"
)]

use std::{
    io::{self, Cursor},
    pin::Pin,
    task::{Context, Poll},
    time::Duration,
};

use bson::RawDocument;
use bytes::{Bytes, BytesMut};
use nacelle::{
    codec::{MessageDecoder, MessageReader},
    core::NacelleBody,
    tcp::{DecodedMessage, FrameBuffer},
};
use tokio::io::{AsyncWrite, AsyncWriteExt};

use crate::{
    protocol::header::Header,
    responses::writer as response_writer,
    runtime::v2::{
        body::{collect_body, BoundedResponseWriter},
        protocol::GatewayRequestDecoder,
    },
};

const MAX_RESPONSE_BYTES: usize = 48 * 1024 * 1024;

struct DirectFrameBufferWriter<'buffer> {
    frame: FrameBuffer<'buffer>,
}

impl<'buffer> DirectFrameBufferWriter<'buffer> {
    const fn new(delivery: &'buffer mut BytesMut) -> Self {
        Self {
            frame: FrameBuffer::new(delivery, MAX_RESPONSE_BYTES),
        }
    }
}

impl AsyncWrite for DirectFrameBufferWriter<'_> {
    fn poll_write(
        mut self: Pin<&mut Self>,
        _context: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<io::Result<usize>> {
        match self.frame.extend_from_slice(buf) {
            Ok(()) => Poll::Ready(Ok(buf.len())),
            Err(error) => Poll::Ready(Err(io::Error::other(error))),
        }
    }

    fn poll_flush(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _context: &mut Context<'_>) -> Poll<io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

/// Allocates and drops an adapter response writer with the requested initial
/// capacity, isolating its per-request reservation cost.
///
/// # Panics
///
/// Panics if the benchmark-provided capacity cannot be allocated.
pub fn reserve_response_buffer(response_buffer_capacity: usize) {
    let writer = BoundedResponseWriter::new(MAX_RESPONSE_BYTES, response_buffer_capacity)
        .expect("benchmark response writer should allocate");
    std::hint::black_box(writer);
}

/// Builds a wire response in the adapter-owned buffer and copies it into the
/// transport delivery buffer, matching the current single-chunk response path.
///
/// # Panics
///
/// Panics if the benchmark-provided capacities cannot hold the response.
pub async fn stage_response_current(response: &Bytes, response_buffer_capacity: usize) -> BytesMut {
    let mut writer = BoundedResponseWriter::new(MAX_RESPONSE_BYTES, response_buffer_capacity)
        .expect("benchmark response writer should allocate");
    writer
        .write_all(response)
        .await
        .expect("benchmark response should fit");
    let response = writer
        .into_response()
        .expect("benchmark response should finalize");

    let mut delivery = BytesMut::with_capacity(response_buffer_capacity);
    delivery.extend_from_slice(&response);
    delivery
}

/// Copies a complete wire response directly into the transport delivery
/// buffer as a single-stage control.
#[must_use]
pub fn stage_response_control(response: &Bytes, response_buffer_capacity: usize) -> BytesMut {
    let mut delivery = BytesMut::with_capacity(response_buffer_capacity);
    delivery.extend_from_slice(response);
    delivery
}

/// Collects a request body using the adapter's production body collector.
///
/// # Panics
///
/// Panics if the benchmark body violates its declared limit.
pub async fn collect_request_body(body: NacelleBody, max_len: usize) -> Bytes {
    collect_body(body, max_len)
        .await
        .expect("benchmark body should collect")
}

/// Connection-owned reader state for one request benchmark fixture.
#[derive(Debug)]
pub struct BufferedRequestReader {
    message_reader: MessageReader<Cursor<Bytes>, GatewayRequestDecoder>,
    max_frame_len: usize,
}

impl BufferedRequestReader {
    /// Creates connection-owned state for one buffered request fixture.
    #[must_use]
    pub fn new(frame: Bytes, max_frame_len: usize, read_buffer_capacity: usize) -> Self {
        let request_decoder = GatewayRequestDecoder::new(max_frame_len);
        Self {
            message_reader: MessageReader::with_capacity(
                Cursor::new(frame),
                request_decoder,
                read_buffer_capacity,
            ),
            max_frame_len,
        }
    }

    /// Reads the buffered request and returns its body bytes.
    ///
    /// # Panics
    ///
    /// Panics if the frame cannot be read and decoded, or if its body does not
    /// fit in the connection-owned read buffer.
    pub async fn acquire(&mut self, read_timeout: Duration) -> Bytes {
        let decoded_message =
            tokio::time::timeout(read_timeout, self.message_reader.read_message())
                .await
                .expect("benchmark request should not time out")
                .expect("benchmark frame should read")
                .expect("benchmark frame should be complete");
        let body_len = match decoded_message {
            DecodedMessage::Request(request) | DecodedMessage::OneWay(request) => request.body_len,
        };
        assert!(
            self.message_reader.buffer().len() >= body_len,
            "benchmark frame body must fit in the configured read buffer"
        );
        let body = self.message_reader.buffer_mut().split_to(body_len).freeze();
        collect_body(NacelleBody::bytes(body), self.max_frame_len)
            .await
            .expect("benchmark body should collect")
    }
}

/// Encodes one adapter-owned response and writes it to the supplied transport.
///
/// # Panics
///
/// Panics if response serialization, bounded buffer allocation, or transport
/// delivery fails.
pub async fn deliver_owned_response_frame<W>(
    header: &Header,
    response: &RawDocument,
    response_buffer_capacity: usize,
    transport: &mut W,
) where
    W: AsyncWrite + Unpin,
{
    let mut writer = BoundedResponseWriter::new(MAX_RESPONSE_BYTES, response_buffer_capacity)
        .expect("benchmark response writer should allocate");
    response_writer::write_and_flush(header, response, &mut writer)
        .await
        .expect("benchmark response should encode");
    let response = writer
        .into_response()
        .expect("benchmark response should finalize");
    transport
        .write_all(&response)
        .await
        .expect("benchmark response should write");
    transport
        .flush()
        .await
        .expect("benchmark response should flush");
}

/// Encodes an owned response and copies it into reusable delivery storage.
///
/// # Panics
///
/// Panics if response serialization or bounded buffer allocation fails.
pub async fn stage_owned_response_frame(
    header: &Header,
    response: &RawDocument,
    response_buffer_capacity: usize,
    delivery: &mut BytesMut,
) {
    delivery.clear();
    let mut writer = BoundedResponseWriter::new(MAX_RESPONSE_BYTES, response_buffer_capacity)
        .expect("benchmark response writer should allocate");
    response_writer::write_and_flush(header, response, &mut writer)
        .await
        .expect("benchmark response should encode");
    let response = writer
        .into_response()
        .expect("benchmark response should finalize");
    delivery.extend_from_slice(&response);
}

/// Models direct response encoding into reusable runtime frame storage.
///
/// This benchmark-only candidate bypasses the current handler-owned response;
/// production use requires delivery storage to be writable during handling.
///
/// # Panics
///
/// Panics if response serialization or frame-buffer growth fails.
pub async fn stage_direct_response_frame(
    header: &Header,
    response: &RawDocument,
    delivery: &mut BytesMut,
) {
    delivery.clear();
    let mut writer = DirectFrameBufferWriter::new(delivery);
    response_writer::write_and_flush(header, response, &mut writer)
        .await
        .expect("benchmark response should encode directly");
}

/// Decodes one complete request frame and returns its body length.
///
/// # Panics
///
/// Panics if the benchmark frame is incomplete or malformed.
pub fn decode_request_frame(input: &mut BytesMut, max_frame_len: usize) -> usize {
    let mut request_decoder = GatewayRequestDecoder::new(max_frame_len);
    let decoded_message = request_decoder
        .decode(input)
        .expect("benchmark frame should decode")
        .expect("benchmark frame should be complete");
    match decoded_message {
        DecodedMessage::Request(request) | DecodedMessage::OneWay(request) => request.body_len,
    }
}
