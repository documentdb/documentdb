/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * Criterion benchmarks for response writer hot-path serialization.
 *
 *-------------------------------------------------------------------------
 */
#![allow(clippy::expect_used, reason = "benchmarking code")]
#![allow(clippy::unwrap_used, reason = "benchmarking code")]

use std::{
    hint::black_box,
    pin::Pin,
    sync::OnceLock,
    task::{Context, Poll},
};

use bson::{rawdoc, RawDocument, RawDocumentBuf};
use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use tokio::{
    io::{AsyncWrite, AsyncWriteExt},
    runtime::Runtime,
};

use documentdb_gateway_core::{
    protocol::{header::Header, opcode::OpCode},
    responses::writer as response_writer,
};

#[derive(Default)]
struct CountingWriter {
    bytes_written: u64,
    write_calls: u64,
    flush_calls: u64,
}

impl CountingWriter {
    const fn stats(&self) -> (u64, u64, u64) {
        (self.bytes_written, self.write_calls, self.flush_calls)
    }
}

impl AsyncWrite for CountingWriter {
    fn poll_write(
        mut self: Pin<&mut Self>,
        _cx: &mut Context<'_>,
        buf: &[u8],
    ) -> Poll<std::io::Result<usize>> {
        self.bytes_written += u64::try_from(buf.len()).unwrap_or(u64::MAX);
        self.write_calls += 1;

        Poll::Ready(Ok(buf.len()))
    }

    fn poll_flush(mut self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        self.flush_calls += 1;

        Poll::Ready(Ok(()))
    }

    fn poll_shutdown(self: Pin<&mut Self>, _cx: &mut Context<'_>) -> Poll<std::io::Result<()>> {
        Poll::Ready(Ok(()))
    }
}

struct ResponseCase {
    name: &'static str,
    response: RawDocumentBuf,
}

fn bench_runtime() -> &'static Runtime {
    static RUNTIME: OnceLock<Runtime> = OnceLock::new();

    RUNTIME.get_or_init(|| {
        let runtime = Runtime::new().unwrap();
        runtime.block_on(async {
            tokio::task::yield_now().await;
        });
        runtime
    })
}

fn response_cases() -> Vec<ResponseCase> {
    vec![
        ResponseCase {
            name: "small_ok",
            response: rawdoc! {
                "ok": 1.0,
            },
        },
        ResponseCase {
            name: "medium_payload",
            response: rawdoc! {
                "ok": 1.0,
                "payload": "x".repeat(4096),
            },
        },
    ]
}

fn op_msg_header() -> Header {
    Header::new(Header::LENGTH_I32, 42, 0, OpCode::Msg).unwrap()
}

#[expect(
    deprecated,
    reason = "OP_QUERY is still supported for legacy clients and testing"
)]
fn op_query_header() -> Header {
    Header::new(Header::LENGTH_I32, 42, 0, OpCode::Query).unwrap()
}

async fn write_fragmented_response<S>(
    request_header: &Header,
    response: &RawDocument,
    writer: &mut S,
) where
    S: AsyncWrite + Unpin,
{
    match request_header.op_code() {
        OpCode::Msg => write_fragmented_message(request_header, response, writer).await,
        #[expect(
            deprecated,
            reason = "OP_QUERY is still supported for legacy clients and testing"
        )]
        OpCode::Query => write_fragmented_reply(request_header, response, writer).await,
        _ => unreachable!("benchmark only uses request opcodes with responses"),
    }

    writer.flush().await.unwrap();
}

async fn write_fragmented_message<S>(
    request_header: &Header,
    response: &RawDocument,
    writer: &mut S,
) where
    S: AsyncWrite + Unpin,
{
    let message_length = i32::try_from(
        Header::LENGTH
            + std::mem::size_of::<u32>()
            + std::mem::size_of::<u8>()
            + response.as_bytes().len(),
    )
    .unwrap();
    let response_header = Header::new(
        message_length,
        request_header.request_id(),
        request_header.request_id(),
        OpCode::Msg,
    )
    .unwrap();

    response_header.write_to(writer).await.unwrap();
    writer.write_u32_le(0).await.unwrap();
    writer.write_u8(0).await.unwrap();
    writer.write_all(response.as_bytes()).await.unwrap();
}

#[expect(
    deprecated,
    reason = "OP_QUERY is still supported for legacy clients and testing"
)]
async fn write_fragmented_reply<S>(request_header: &Header, response: &RawDocument, writer: &mut S)
where
    S: AsyncWrite + Unpin,
{
    let message_length = i32::try_from(Header::LENGTH + 20 + response.as_bytes().len()).unwrap();
    let response_header = Header::new(
        message_length,
        request_header.request_id(),
        request_header.request_id(),
        OpCode::Reply,
    )
    .unwrap();

    response_header.write_to(writer).await.unwrap();
    writer.write_i32_le(0).await.unwrap();
    writer.write_i64_le(0).await.unwrap();
    writer.write_i32_le(0).await.unwrap();
    writer.write_i32_le(1).await.unwrap();
    writer.write_all(response.as_bytes()).await.unwrap();
}

async fn write_current_response(header: &Header, response: &RawDocument) -> CountingWriter {
    let mut writer = CountingWriter::default();
    response_writer::write_and_flush(header, response, &mut writer)
        .await
        .unwrap();

    writer
}

async fn write_fragmented_baseline(header: &Header, response: &RawDocument) -> CountingWriter {
    let mut writer = CountingWriter::default();
    write_fragmented_response(header, response, &mut writer).await;

    writer
}

fn validate_baseline(
    rt: &Runtime,
    op_msg_header: &Header,
    op_query_header: &Header,
    cases: &[ResponseCase],
) {
    for case in cases {
        for header in [op_msg_header, op_query_header] {
            rt.block_on(async {
                let mut current = Vec::with_capacity(response_wire_len(header, &case.response));
                response_writer::write_and_flush(header, &case.response, &mut current)
                    .await
                    .unwrap();

                let mut fragmented = Vec::with_capacity(response_wire_len(header, &case.response));
                write_fragmented_response(header, &case.response, &mut fragmented).await;

                assert_eq!(current, fragmented);
            });
        }
    }
}

fn response_wire_len(header: &Header, response: &RawDocument) -> usize {
    match header.op_code() {
        OpCode::Msg => {
            Header::LENGTH
                + std::mem::size_of::<u32>()
                + std::mem::size_of::<u8>()
                + response.as_bytes().len()
        }
        #[expect(
            deprecated,
            reason = "OP_QUERY is still supported for legacy clients and testing"
        )]
        OpCode::Query => Header::LENGTH + 20 + response.as_bytes().len(),
        _ => unreachable!("benchmark only uses request opcodes with responses"),
    }
}

fn bench_response_writer(c: &mut Criterion) {
    let rt = bench_runtime();
    let op_msg_header = op_msg_header();
    let op_query_header = op_query_header();
    let cases = response_cases();

    validate_baseline(rt, &op_msg_header, &op_query_header, &cases);

    let mut group = c.benchmark_group("response_writer");

    for case in &cases {
        group.throughput(Throughput::Bytes(
            u64::try_from(case.response.as_bytes().len()).unwrap_or(u64::MAX),
        ));

        group.bench_with_input(
            BenchmarkId::new("packed_op_msg", case.name),
            case,
            |b, case| {
                b.to_async(rt).iter(|| async {
                    let writer = write_current_response(&op_msg_header, &case.response).await;
                    black_box(writer.stats())
                });
            },
        );

        group.bench_with_input(
            BenchmarkId::new("fragmented_op_msg", case.name),
            case,
            |b, case| {
                b.to_async(rt).iter(|| async {
                    let writer = write_fragmented_baseline(&op_msg_header, &case.response).await;
                    black_box(writer.stats())
                });
            },
        );

        group.bench_with_input(
            BenchmarkId::new("packed_op_query", case.name),
            case,
            |b, case| {
                b.to_async(rt).iter(|| async {
                    let writer = write_current_response(&op_query_header, &case.response).await;
                    black_box(writer.stats())
                });
            },
        );

        group.bench_with_input(
            BenchmarkId::new("fragmented_op_query", case.name),
            case,
            |b, case| {
                b.to_async(rt).iter(|| async {
                    let writer = write_fragmented_baseline(&op_query_header, &case.response).await;
                    black_box(writer.stats())
                });
            },
        );
    }

    group.finish();
}

criterion_group!(benches, bench_response_writer);
criterion_main!(benches);
