/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * Criterion benchmarks for the gateway runtime hot path.
 *
 * Run: cargo bench --features runtime-benchmarks --bench runtime_hot_path
 *
 *-------------------------------------------------------------------------
 */
#![allow(clippy::expect_used, reason = "benchmarking code")]

use std::hint::black_box;

use bytes::{Bytes, BytesMut};
use criterion::{criterion_group, criterion_main, BatchSize, BenchmarkId, Criterion, Throughput};
use documentdb_gateway_core::runtime_benchmarks::{
    collect_request_body, decode_request_frame, reserve_response_buffer, stage_response_control,
    stage_response_current,
};
use nacelle::core::NacelleBody;
use tokio::runtime::Runtime;

const RESPONSE_BUFFER_CAPACITY: usize = 8 * 1024;
const MAX_FRAME_LEN: usize = 48 * 1024 * 1024;

fn bench_response_buffer_reservation(c: &mut Criterion) {
    let mut group = c.benchmark_group("runtime_response_buffer_reservation");

    for capacity in [256, 1024, 8 * 1024, 64 * 1024] {
        group.throughput(Throughput::Bytes(
            u64::try_from(capacity).expect("benchmark capacity should fit"),
        ));
        group.bench_with_input(
            BenchmarkId::from_parameter(capacity),
            &capacity,
            |b, capacity| b.iter(|| reserve_response_buffer(black_box(*capacity))),
        );
    }

    group.finish();
}

fn bench_response_staging(c: &mut Criterion) {
    let runtime = Runtime::new().expect("benchmark runtime should construct");
    let mut group = c.benchmark_group("runtime_response_staging");

    for response_len in [128, 1024, 8 * 1024, 64 * 1024] {
        let response = Bytes::from(vec![0xAB; response_len]);
        group.throughput(Throughput::Bytes(
            u64::try_from(response_len).expect("benchmark response length should fit"),
        ));

        group.bench_with_input(
            BenchmarkId::new("current_double_stage", response_len),
            &response,
            |b, response| {
                b.to_async(&runtime).iter(|| async {
                    black_box(stage_response_current(response, RESPONSE_BUFFER_CAPACITY).await)
                });
            },
        );

        group.bench_with_input(
            BenchmarkId::new("single_stage_control", response_len),
            &response,
            |b, response| {
                b.to_async(&runtime).iter(|| async {
                    black_box(stage_response_control(
                        black_box(response),
                        RESPONSE_BUFFER_CAPACITY,
                    ))
                });
            },
        );
    }

    group.finish();
}

fn bench_request_body_collection(c: &mut Criterion) {
    let runtime = Runtime::new().expect("benchmark runtime should construct");
    let mut group = c.benchmark_group("runtime_request_body_collection");

    for body_len in [128, 1024, 8 * 1024, 64 * 1024] {
        let body = Bytes::from(vec![0xAB; body_len]);
        group.throughput(Throughput::Bytes(
            u64::try_from(body_len).expect("benchmark body length should fit"),
        ));

        group.bench_with_input(
            BenchmarkId::new("single_chunk", body_len),
            &body,
            |b, body| {
                b.to_async(&runtime).iter_batched(
                    || NacelleBody::bytes(body.clone()),
                    |body| async move { black_box(collect_request_body(body, MAX_FRAME_LEN).await) },
                    BatchSize::SmallInput,
                );
            },
        );

        group.bench_with_input(
            BenchmarkId::new("eight_chunks", body_len),
            &body,
            |b, body| {
                b.to_async(&runtime).iter_batched(
                    || {
                        let chunk_len = body.len() / 8;
                        let chunks = (0..8)
                            .map(|index| {
                                let start = index * chunk_len;
                                let end = if index == 7 {
                                    body.len()
                                } else {
                                    start + chunk_len
                                };
                                body.slice(start..end)
                            })
                            .collect();
                        NacelleBody::from_buffered(chunks, body.len())
                    },
                    |body| async move { black_box(collect_request_body(body, MAX_FRAME_LEN).await) },
                    BatchSize::SmallInput,
                );
            },
        );
    }

    group.finish();
}

fn request_frame(body_len: usize) -> Vec<u8> {
    const HEADER_LEN: usize = 16;
    const OP_MSG: i32 = 2013;

    let message_len = HEADER_LEN + body_len;
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
    frame
}

fn bench_request_frame_decode(c: &mut Criterion) {
    let mut group = c.benchmark_group("runtime_request_frame_decode");

    for body_len in [128, 1024, 8 * 1024, 64 * 1024] {
        let frame = request_frame(body_len);
        group.throughput(Throughput::Bytes(
            u64::try_from(frame.len()).expect("benchmark frame length should fit"),
        ));
        group.bench_with_input(
            BenchmarkId::new("complete_frame", body_len),
            &frame,
            |b, frame| {
                b.iter_batched(
                    || BytesMut::from(frame.as_slice()),
                    |mut input| black_box(decode_request_frame(&mut input, MAX_FRAME_LEN)),
                    BatchSize::SmallInput,
                );
            },
        );
    }

    group.finish();
}

criterion_group!(
    benches,
    bench_response_buffer_reservation,
    bench_response_staging,
    bench_request_body_collection,
    bench_request_frame_decode,
);
criterion_main!(benches);
