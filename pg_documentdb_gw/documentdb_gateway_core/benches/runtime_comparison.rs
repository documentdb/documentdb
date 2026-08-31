/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Paired Criterion benchmarks for legacy and default runtime boundaries.
 *
 * Run: cargo bench --features runtime-benchmarks --bench runtime_comparison
 *
 *-------------------------------------------------------------------------
 */
#![expect(
    clippy::expect_used,
    reason = "Benchmarks should fail fast when fixture setup or production calls fail"
)]

//! Compares equivalent legacy and default request and response boundaries.
//!
//! Request timings exclude connection-owned reader construction. The
//! response-to-`AsyncWrite` timings end after byte-identical complete wire
//! frames are flushed to the same preallocated in-memory transport; socket,
//! telemetry, dependency body and frame buffers, response accounting, and timed-write
//! driver costs are excluded. The direct-buffer strategy separately measures
//! `FrameBuffer` serialization under a benchmark-only ownership model, not a
//! currently selectable runtime path.

use std::{
    hint::black_box,
    io::Cursor,
    time::{Duration, Instant},
};

use bson::{rawdoc, RawDocument, RawDocumentBuf};
use bytes::{Bytes, BytesMut};
use criterion::{criterion_group, criterion_main, BatchSize, BenchmarkId, Criterion, Throughput};
use documentdb_gateway_core::{
    protocol::{header::Header, opcode::OpCode, reader},
    responses::writer as response_writer,
    runtime_benchmarks::{
        deliver_owned_response_frame, stage_direct_response_frame, stage_owned_response_frame,
        BufferedRequestReader,
    },
};
use tokio::{io::AsyncWrite, runtime::Runtime};

const MAX_FRAME_LEN: usize = 48 * 1024 * 1024;
const READ_BUFFER_CAPACITY: usize = 8 * 1024;
const RESPONSE_BUFFER_CAPACITY: usize = 8 * 1024;
const BENCHMARK_TIMEOUT: Duration = Duration::from_secs(30);

fn request_frame(body_len: usize) -> Bytes {
    const OP_MSG: i32 = 2013;

    let message_len = Header::LENGTH + body_len;
    let mut frame = Vec::with_capacity(message_len);
    frame.extend_from_slice(
        &i32::try_from(message_len)
            .expect("benchmark frame length should fit")
            .to_le_bytes(),
    );
    frame.extend_from_slice(&42_i32.to_le_bytes());
    frame.extend_from_slice(&0_i32.to_le_bytes());
    frame.extend_from_slice(&OP_MSG.to_le_bytes());
    frame.extend_from_slice(&0_u32.to_le_bytes());
    frame.resize(message_len, 0xAB);
    Bytes::from(frame)
}

#[derive(Debug)]
struct LegacyRequestReader {
    reader: Cursor<Bytes>,
}

impl LegacyRequestReader {
    const fn new(frame: Bytes) -> Self {
        Self {
            reader: Cursor::new(frame),
        }
    }

    async fn acquire(&mut self) -> Bytes {
        let header = reader::read_header_with_timeout(&mut self.reader, BENCHMARK_TIMEOUT)
            .await
            .expect("benchmark header should read")
            .expect("benchmark frame should contain a header");
        black_box(tokio::time::Instant::now());
        reader::read_request_with_timeout(true, &header, &mut self.reader, BENCHMARK_TIMEOUT)
            .await
            .expect("benchmark request should read")
            .request()
            .clone()
    }
}

async fn deliver_legacy_response_frame<W>(
    header: &Header,
    response: &RawDocument,
    transport: &mut W,
) where
    W: AsyncWrite + Unpin,
{
    response_writer::write_and_flush(header, response, transport)
        .await
        .expect("benchmark response should encode");
}

fn response_document(payload_len: usize) -> RawDocumentBuf {
    rawdoc! {
        "ok": 1.0,
        "payload": "x".repeat(payload_len),
    }
}

fn op_msg_header() -> Header {
    Header::new(Header::LENGTH_I32, 42, 0, OpCode::Msg)
        .expect("benchmark response header should construct")
}

fn reset_delivery_buffer(delivery: &mut BytesMut) {
    // Match ResponseDelivery: retain the base buffer, but discard oversized growth.
    if delivery.capacity() > RESPONSE_BUFFER_CAPACITY {
        *delivery = BytesMut::with_capacity(RESPONSE_BUFFER_CAPACITY);
    } else {
        delivery.clear();
    }
}

fn bench_request_acquisition(c: &mut Criterion) {
    let runtime = Runtime::new().expect("benchmark runtime should construct");
    let mut group = c.benchmark_group("runtime_request_acquisition");

    for body_len in [128, 1024, 4096] {
        let frame = request_frame(body_len);
        assert!(frame.len() <= READ_BUFFER_CAPACITY);
        let (legacy_body, runtime_body) = runtime.block_on(async {
            let mut legacy_reader = LegacyRequestReader::new(frame.clone());
            let mut runtime_reader =
                BufferedRequestReader::new(frame.clone(), MAX_FRAME_LEN, READ_BUFFER_CAPACITY);
            let legacy_body = legacy_reader.acquire().await;
            let runtime_body = runtime_reader.acquire(BENCHMARK_TIMEOUT).await;
            (legacy_body, runtime_body)
        });
        assert_eq!(legacy_body, runtime_body);

        group.throughput(Throughput::Bytes(
            u64::try_from(frame.len()).expect("benchmark frame length should fit"),
        ));
        group.bench_with_input(BenchmarkId::new("legacy", body_len), &frame, |b, frame| {
            b.to_async(&runtime).iter_batched(
                || LegacyRequestReader::new(frame.clone()),
                |mut reader| async move {
                    let body = black_box(reader.acquire().await);
                    (reader, body)
                },
                BatchSize::PerIteration,
            );
        });
        group.bench_with_input(BenchmarkId::new("runtime", body_len), &frame, |b, frame| {
            b.to_async(&runtime).iter_batched(
                || BufferedRequestReader::new(frame.clone(), MAX_FRAME_LEN, READ_BUFFER_CAPACITY),
                |mut reader| async move {
                    let body = black_box(reader.acquire(BENCHMARK_TIMEOUT).await);
                    (reader, body)
                },
                BatchSize::PerIteration,
            );
        });
    }

    group.finish();
}

fn bench_response_delivery(c: &mut Criterion) {
    let runtime = Runtime::new().expect("benchmark runtime should construct");
    let header = op_msg_header();
    let mut group = c.benchmark_group("response_to_async_write");

    for payload_len in [128, 1024, 8 * 1024, 64 * 1024] {
        let response = response_document(payload_len);
        let (legacy_frame, runtime_frame) = runtime.block_on(async {
            let mut legacy_frame = Vec::new();
            deliver_legacy_response_frame(&header, &response, &mut legacy_frame).await;
            let mut runtime_frame = Vec::new();
            deliver_owned_response_frame(
                &header,
                &response,
                RESPONSE_BUFFER_CAPACITY,
                &mut runtime_frame,
            )
            .await;
            (legacy_frame, runtime_frame)
        });
        assert_eq!(legacy_frame, runtime_frame);
        let frame_capacity = legacy_frame.len();

        group.throughput(Throughput::Bytes(
            u64::try_from(frame_capacity).expect("benchmark response frame length should fit"),
        ));
        group.bench_with_input(
            BenchmarkId::new("legacy", payload_len),
            &response,
            |b, response| {
                b.to_async(&runtime).iter_batched(
                    || Vec::with_capacity(frame_capacity),
                    |mut transport| async {
                        deliver_legacy_response_frame(&header, black_box(response), &mut transport)
                            .await;
                        black_box(transport)
                    },
                    BatchSize::PerIteration,
                );
            },
        );
        group.bench_with_input(
            BenchmarkId::new("runtime", payload_len),
            &response,
            |b, response| {
                b.to_async(&runtime).iter_batched(
                    || Vec::with_capacity(frame_capacity),
                    |mut transport| async {
                        deliver_owned_response_frame(
                            &header,
                            black_box(response),
                            RESPONSE_BUFFER_CAPACITY,
                            &mut transport,
                        )
                        .await;
                        black_box(transport)
                    },
                    BatchSize::PerIteration,
                );
            },
        );
    }

    group.finish();
}

fn bench_response_buffering_strategy(c: &mut Criterion) {
    let runtime = Runtime::new().expect("benchmark runtime should construct");
    let header = op_msg_header();
    let mut group = c.benchmark_group("runtime_response_buffering_strategy");

    for payload_len in [128, 1024, 8 * 1024, 64 * 1024] {
        let response = response_document(payload_len);
        let expected_frame = runtime.block_on(async {
            let mut frame = Vec::new();
            deliver_legacy_response_frame(&header, &response, &mut frame).await;
            frame
        });
        let (owned_frame, direct_frame) = runtime.block_on(async {
            let mut owned_frame = BytesMut::with_capacity(RESPONSE_BUFFER_CAPACITY);
            stage_owned_response_frame(
                &header,
                &response,
                RESPONSE_BUFFER_CAPACITY,
                &mut owned_frame,
            )
            .await;
            let mut direct_frame = BytesMut::with_capacity(RESPONSE_BUFFER_CAPACITY);
            stage_direct_response_frame(&header, &response, &mut direct_frame).await;
            (owned_frame, direct_frame)
        });
        assert_eq!(expected_frame.as_slice(), owned_frame.as_ref());
        assert_eq!(expected_frame.as_slice(), direct_frame.as_ref());

        group.throughput(Throughput::Bytes(
            u64::try_from(expected_frame.len())
                .expect("benchmark response frame length should fit"),
        ));
        group.bench_with_input(
            BenchmarkId::new("owned_then_copy", payload_len),
            &response,
            |b, response| {
                b.to_async(&runtime).iter_custom(|iterations| async move {
                    let mut delivery = BytesMut::with_capacity(RESPONSE_BUFFER_CAPACITY);
                    let start = Instant::now();
                    for _ in 0..iterations {
                        stage_owned_response_frame(
                            &header,
                            black_box(response),
                            RESPONSE_BUFFER_CAPACITY,
                            &mut delivery,
                        )
                        .await;
                        black_box(delivery.as_ref());
                        reset_delivery_buffer(&mut delivery);
                    }
                    start.elapsed()
                });
            },
        );
        group.bench_with_input(
            BenchmarkId::new("direct_frame_buffer", payload_len),
            &response,
            |b, response| {
                b.to_async(&runtime).iter_custom(|iterations| async move {
                    let mut delivery = BytesMut::with_capacity(RESPONSE_BUFFER_CAPACITY);
                    let start = Instant::now();
                    for _ in 0..iterations {
                        stage_direct_response_frame(&header, black_box(response), &mut delivery)
                            .await;
                        black_box(delivery.as_ref());
                        reset_delivery_buffer(&mut delivery);
                    }
                    start.elapsed()
                });
            },
        );
    }

    group.finish();
}

criterion_group!(
    benches,
    bench_request_acquisition,
    bench_response_delivery,
    bench_response_buffering_strategy,
);
criterion_main!(benches);
