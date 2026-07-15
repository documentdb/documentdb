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
    io::Cursor,
    pin::Pin,
    sync::OnceLock,
    task::{Context, Poll},
};

use bson::{rawdoc, RawDocument, RawDocumentBuf};
use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};
use tokio::{
    io::{AsyncWrite, AsyncWriteExt, BufReader},
    runtime::Runtime,
};
use uuid::{Builder, Uuid};

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

    RequestMessage::new(body.into(), OpCode::Msg, request_id, 0)
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

    RequestMessage::new(body.into(), OpCode::Query, request_id, 0)
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

// ---------------------------------------------------------------------------
// Activity ID — String vs stack-allocated Hyphenated
// ---------------------------------------------------------------------------

fn bench_activity_id(c: &mut Criterion) {
    let connection_id = Uuid::new_v4();

    let mut group = c.benchmark_group("activity_id");
    group.throughput(Throughput::Elements(1));

    // Current: returns String (heap allocation)
    group.bench_function("string_alloc", |b| {
        b.iter(|| {
            let mut bytes = *connection_id.as_bytes();
            bytes[12..].copy_from_slice(&42_i32.to_be_bytes());
            let _id: String = Builder::from_bytes(bytes).into_uuid().to_string();
        });
    });

    // Proposed: stack-allocated via encode_lower
    group.bench_function("stack_encode_lower", |b| {
        b.iter(|| {
            let mut bytes = *connection_id.as_bytes();
            bytes[12..].copy_from_slice(&42_i32.to_be_bytes());
            let uuid = Builder::from_bytes(bytes).into_uuid();
            let mut buf = [0u8; uuid::fmt::Hyphenated::LENGTH];
            let _id: &str = uuid.hyphenated().encode_lower(&mut buf);
        });
    });

    group.finish();
}

// ---------------------------------------------------------------------------
// Message Buffer — Vec<u8> (zero-init + alloc) vs BytesMut
// ---------------------------------------------------------------------------

fn bench_message_buffer(c: &mut Criterion) {
    let mut group = c.benchmark_group("message_buffer");

    for size in [256, 4096, 65536] {
        group.throughput(Throughput::Bytes(size as u64));

        // Current: vec![0; N] per request
        group.bench_with_input(
            BenchmarkId::new("vec_zero_init", size),
            &size,
            |b, &size| {
                b.iter(|| {
                    let buf: Vec<u8> = vec![0; size];
                    std::hint::black_box(buf);
                });
            },
        );

        // Proposed: BytesMut::zeroed per request (matches actual code in reader.rs)
        group.bench_with_input(
            BenchmarkId::new("bytes_mut_zeroed", size),
            &size,
            |b, &size| {
                use bytes::BytesMut;
                b.iter(|| {
                    let buf = BytesMut::zeroed(size);
                    let frozen = buf.freeze();
                    std::hint::black_box(frozen);
                });
            },
        );
    }

    group.finish();
}

// ---------------------------------------------------------------------------
// BufStream buffer size — read throughput at different buffer sizes
// ---------------------------------------------------------------------------

fn bench_bufstream_sizes(c: &mut Criterion) {
    let rt = tokio::runtime::Builder::new_current_thread()
        .enable_all()
        .build()
        .unwrap();

    // Simulate reading 64 KiB of data through BufReader with different buffer sizes
    let data = vec![0xABu8; 65536];

    let mut group = c.benchmark_group("bufstream_read_size");
    group.throughput(Throughput::Bytes(65536));

    for buf_size in [8 * 1024, 16 * 1024, 32 * 1024, 64 * 1024] {
        group.bench_with_input(
            BenchmarkId::new("buf_reader", buf_size),
            &buf_size,
            |b, &buf_size| {
                b.iter(|| {
                    rt.block_on(async {
                        let cursor = Cursor::new(&*data);
                        let mut reader = BufReader::with_capacity(buf_size, cursor);
                        let mut sink = Vec::with_capacity(65536);
                        tokio::io::copy(&mut reader, &mut sink).await.unwrap();
                    });
                });
            },
        );
    }

    group.finish();
}

// ---------------------------------------------------------------------------
// BSON Document Scanning — bson crate iterator vs zero-copy scanner
// ---------------------------------------------------------------------------

fn bench_bson_scan(c: &mut Criterion) {
    use bson::rawdoc;
    use documentdb_gateway_core::protocol::bson_scanner;

    // Realistic command document with common fields
    let doc = rawdoc! {
        "find": "users",
        "$db": "myapp",
        "maxTimeMS": 5000_i32,
        "lsid": { "id": bson::Binary { subtype: bson::spec::BinarySubtype::Uuid, bytes: vec![0u8; 16] } },
        "txnNumber": 42_i64,
        "autocommit": false,
        "readConcern": { "level": "majority" },
        "filter": { "age": { "$gt": 21 } },
        "projection": { "name": 1, "email": 1 },
        "sort": { "created": -1 }
    };
    let bytes = doc.as_bytes();

    let mut group = c.benchmark_group("bson_document_scan");
    group.throughput(Throughput::Elements(1));

    // Current: bson crate RawDocument iterator
    group.bench_function("bson_crate_iter", |b| {
        b.iter(|| {
            let doc = bson::RawDocument::from_bytes(bytes).unwrap();
            let mut field_count = 0u32;
            for entry in doc {
                let (k, v) = entry.unwrap();
                match k {
                    "$db" => {
                        let _ = v.as_str();
                    }
                    "maxTimeMS" => {
                        let _ = v.as_i32();
                    }
                    "autocommit" | "explain" => {
                        let _ = v.as_bool();
                    }
                    "txnNumber" => {
                        let _ = v.as_i64();
                    }
                    _ => {}
                }
                field_count += 1;
            }
            std::hint::black_box(field_count);
        });
    });

    // New: zero-copy scanner
    group.bench_function("zero_copy_scanner", |b| {
        b.iter(|| {
            let mut field_count = 0u32;
            bson_scanner::scan_document(bytes, |field| {
                match field.name() {
                    b"$db" => {
                        let _ = field.as_str();
                    }
                    b"maxTimeMS" => {
                        let _ = field.as_i32();
                    }
                    b"autocommit" | b"explain" => {
                        let _ = field.as_bool();
                    }
                    b"txnNumber" => {
                        let _ = field.as_i64();
                    }
                    _ => {}
                }
                field_count += 1;
                Ok(())
            })
            .unwrap();
            std::hint::black_box(field_count);
        });
    });

    // First field extraction — command name only
    group.bench_function("bson_first_element", |b| {
        b.iter(|| {
            let doc = bson::RawDocument::from_bytes(bytes).unwrap();
            let first = doc.into_iter().next().unwrap().unwrap();
            std::hint::black_box(first.0);
        });
    });

    group.bench_function("scanner_first_field", |b| {
        b.iter(|| {
            let (name, _et) = bson_scanner::first_field_name(bytes).unwrap();
            std::hint::black_box(name);
        });
    });

    group.finish();
}

fn bench_request_extract_common(c: &mut Criterion) {
    use bson::{rawdoc, spec::ElementType};

    let request = rawdoc! {
        "find": "users",
        "$db": "myapp",
        "maxTimeMS": 5000_i32,
        "lsid": { "id": bson::Binary { subtype: bson::spec::BinarySubtype::Uuid, bytes: vec![0u8; 16] } },
        "txnNumber": 42_i64,
        "autocommit": false,
        "readConcern": { "level": "majority" },
        "filter": { "age": { "$gt": 21 } },
        "projection": { "name": 1, "email": 1 },
        "sort": { "created": -1 }
    };

    let mut group = c.benchmark_group("request_extract_common");
    group.throughput(Throughput::Elements(1));

    group.bench_function("no_callback_hot_path", |b| {
        b.iter(|| {
            let wire_request = reader::parse_cmd(request.as_ref(), None).unwrap();
            std::hint::black_box(wire_request.max_time_ms());
            std::hint::black_box(wire_request.transaction_info());
            std::hint::black_box(wire_request.db());
            std::hint::black_box(wire_request.collection().unwrap());
            std::hint::black_box(wire_request.read_concern());
        });
    });

    group.bench_function("wire_request_parse_build", |b| {
        b.iter(|| {
            let wire_request = reader::parse_cmd(request.as_ref(), None).unwrap();
            std::hint::black_box(wire_request.request_type());
            std::hint::black_box(wire_request.execution_mode());
            std::hint::black_box(wire_request.max_time_ms());
            std::hint::black_box(wire_request.transaction_info());
            std::hint::black_box(wire_request.db());
            std::hint::black_box(wire_request.collection().unwrap());
            std::hint::black_box(wire_request.read_concern());
        });
    });

    group.bench_function("raw_document_iter_baseline", |b| {
        b.iter(|| {
            let mut max_time_ms = None;
            let mut db = None;
            let mut collection = None;
            let mut lsid_len = None;
            let mut transaction_number = None;
            let mut auto_commit = None;
            let mut read_concern_level = None;

            for entry in request.as_ref() {
                let (key, value) = entry.unwrap();
                match key {
                    "$db" => db = value.as_str(),
                    "maxTimeMS" => {
                        max_time_ms = match value.element_type() {
                            ElementType::Int32 => value.as_i32().map(i64::from),
                            ElementType::Int64 => value.as_i64(),
                            _ => None,
                        };
                    }
                    "find" => collection = value.as_str(),
                    "lsid" => {
                        lsid_len = value
                            .as_document()
                            .and_then(|document| document.get_binary("id").ok())
                            .map(|binary| binary.bytes.len());
                    }
                    "txnNumber" => transaction_number = value.as_i64(),
                    "autocommit" => auto_commit = value.as_bool(),
                    "readConcern" => {
                        read_concern_level = value
                            .as_document()
                            .and_then(|document| document.get_str("level").ok());
                    }
                    _ => {}
                }
            }

            std::hint::black_box(max_time_ms);
            std::hint::black_box(db);
            std::hint::black_box(collection);
            std::hint::black_box(lsid_len);
            std::hint::black_box(transaction_number);
            std::hint::black_box(auto_commit);
            std::hint::black_box(read_concern_level);
        });
    });

    group.finish();
}

criterion_group!(
    benches,
    bench_request_parse,
    bench_response_writer,
    bench_activity_id,
    bench_message_buffer,
    bench_bufstream_sizes,
    bench_bson_scan,
    bench_request_extract_common,
);
criterion_main!(benches);
