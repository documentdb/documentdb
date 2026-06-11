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
    protocol::{header::Header, opcode::OpCode, reader},
    requests::RequestMessage,
    responses::writer as response_writer,
};

const MORE_TO_COME_FLAG: u32 = 0b10;

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

fn document_section(document: &RawDocumentBuf) -> Vec<u8> {
    let mut bytes = Vec::with_capacity(1 + document.as_bytes().len());
    bytes.push(0);
    bytes.extend_from_slice(document.as_bytes());
    bytes
}

fn document_sequence_section(identifier: &str, documents: &[RawDocumentBuf]) -> Vec<u8> {
    let document_bytes_len = documents
        .iter()
        .map(|document| document.as_bytes().len())
        .sum::<usize>();
    let section_size =
        i32::try_from(std::mem::size_of::<i32>() + identifier.len() + 1 + document_bytes_len)
            .unwrap();
    let mut bytes = Vec::with_capacity(1 + usize::try_from(section_size).unwrap());
    bytes.push(1);
    bytes.extend_from_slice(&section_size.to_le_bytes());
    bytes.extend_from_slice(identifier.as_bytes());
    bytes.push(0);
    for document in documents {
        bytes.extend_from_slice(document.as_bytes());
    }
    bytes
}

fn op_msg_message(request_id: i32, flags: u32, sections: &[Vec<u8>]) -> RequestMessage {
    let sections_len = sections.iter().map(Vec::len).sum::<usize>();
    let mut body = Vec::with_capacity(std::mem::size_of::<u32>() + sections_len);
    body.extend_from_slice(&flags.to_le_bytes());
    for section in sections {
        body.extend_from_slice(section);
    }

    RequestMessage {
        request: body,
        op_code: OpCode::Msg,
        request_id,
        response_to: 0,
    }
}

#[expect(
    deprecated,
    reason = "OP_QUERY is still supported for legacy clients and testing"
)]
fn op_query_message(request_id: i32, namespace: &str, command: &RawDocumentBuf) -> RequestMessage {
    let mut body = Vec::with_capacity(
        std::mem::size_of::<u32>()
            + namespace.len()
            + 1
            + (2 * std::mem::size_of::<u32>())
            + command.as_bytes().len(),
    );
    body.extend_from_slice(&0_u32.to_le_bytes());
    body.extend_from_slice(namespace.as_bytes());
    body.push(0);
    body.extend_from_slice(&0_u32.to_le_bytes());
    body.extend_from_slice(&1_u32.to_le_bytes());
    body.extend_from_slice(command.as_bytes());

    RequestMessage {
        request: body,
        op_code: OpCode::Query,
        request_id,
        response_to: 0,
    }
}

fn bench_request_parse(c: &mut Criterion) {
    let find_command = rawdoc! {
        "find": "users",
        "$db": "myapp",
        "filter": { "age": { "$gt": 21 } },
    };
    let extra_document = rawdoc! {
        "cursor": { "batchSize": 10_i32 },
    };
    let insert_command = rawdoc! {
        "insert": "users",
        "$db": "myapp",
    };
    let insert_documents = [
        rawdoc! { "_id": 1_i32, "name": "one" },
        rawdoc! { "_id": 2_i32, "name": "two" },
    ];

    let find_section = document_section(&find_command);
    let extra_section = document_section(&extra_document);
    let insert_section = document_section(&insert_command);
    let sequence_section = document_sequence_section("documents", &insert_documents);

    let op_msg_find = op_msg_message(100, 0, std::slice::from_ref(&find_section));
    let op_msg_find_with_extra = op_msg_message(101, 0, &[find_section.clone(), extra_section]);
    let op_msg_insert_sequence =
        op_msg_message(102, 0, &[insert_section.clone(), sequence_section.clone()]);
    let op_msg_sequence_before_command =
        op_msg_message(103, 0, &[sequence_section, insert_section]);
    let op_msg_more_to_come = op_msg_message(104, MORE_TO_COME_FLAG, &[find_section]);
    let op_query_existing_db = op_query_message(
        200,
        "wiredb.$cmd",
        &rawdoc! { "find": "users", "$db": "bodydb" },
    );
    let op_query_missing_db = op_query_message(201, "wiredb.$cmd", &rawdoc! { "find": "users" });

    let mut group = c.benchmark_group("request_parse");
    group.throughput(Throughput::Elements(1));

    for (name, message) in [
        ("op_msg_find_strict", &op_msg_find),
        ("op_msg_find_with_extra", &op_msg_find_with_extra),
        ("op_msg_insert_sequence", &op_msg_insert_sequence),
        (
            "op_msg_sequence_before_command",
            &op_msg_sequence_before_command,
        ),
        ("op_msg_more_to_come", &op_msg_more_to_come),
        ("op_query_existing_db", &op_query_existing_db),
        ("op_query_missing_db", &op_query_missing_db),
    ] {
        group.bench_with_input(BenchmarkId::new("strict", name), message, |b, message| {
            b.iter(|| {
                let mut requires_response = true;
                let request =
                    reader::parse_request(black_box(message), &mut requires_response).unwrap();
                black_box(request.request_type());
                black_box(requires_response);
            });
        });
    }

    group.finish();
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

criterion_group!(benches, bench_request_parse, bench_response_writer);
criterion_main!(benches);
