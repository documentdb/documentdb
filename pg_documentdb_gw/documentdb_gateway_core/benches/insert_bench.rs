/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * Criterion benchmark comparing OP_INSERT command construction:
 *   - "old" path:  per-document RawDocumentBuf::from_bytes + rawdoc! macro
 *   - "new" path:  BufMut direct byte assembly (no per-document validation)
 *
 *-------------------------------------------------------------------------
 */
#![allow(clippy::expect_used, reason = "benchmarking code")]
#![allow(clippy::unwrap_used, reason = "benchmarking code")]

use bson::{rawdoc, RawArrayBuf, RawDocumentBuf};
use criterion::{criterion_group, criterion_main, BenchmarkId, Criterion, Throughput};

use documentdb_gateway_core::protocol::{opcode::OpCode, reader};
use documentdb_gateway_core::requests::RequestMessage;

/// Build a small BSON document as raw bytes.
fn make_test_document(id: i32) -> Vec<u8> {
    rawdoc! {
        "_id": id,
        "name": "test document with some payload data",
        "value": 42_i64,
        "nested": { "a": 1, "b": "hello" },
    }
    .into_bytes()
}

/// Construct a complete `OP_INSERT` wire-format message.
#[expect(
    deprecated,
    reason = "OP_INSERT is still supported for legacy clients and testing"
)]
fn make_op_insert_message(doc_count: usize) -> RequestMessage {
    let collection = b"testdb.mycoll\0";
    let flags: i32 = 0; // ordered

    let mut request = Vec::new();
    request.extend_from_slice(&flags.to_le_bytes());
    request.extend_from_slice(collection);
    for i in 0..doc_count {
        request.extend_from_slice(&make_test_document(i32::try_from(i).unwrap_or(i32::MAX)));
    }

    RequestMessage {
        request,
        op_code: OpCode::Insert,
        request_id: 1,
        response_to: 0,
    }
}

/// Concatenate `count` BSON documents into raw bytes (for the old-path baseline).
fn make_docs_bytes(count: usize) -> Vec<u8> {
    let mut bytes = Vec::new();
    for i in 0..count {
        bytes.extend_from_slice(&make_test_document(i32::try_from(i).unwrap_or(i32::MAX)));
    }
    bytes
}

/// Baseline: the original approach using per-document `RawDocumentBuf` + rawdoc!
fn old_build_insert(
    collection: &str,
    ordered: bool,
    docs_bytes: &[u8],
    db: &str,
) -> RawDocumentBuf {
    fn read_documents_old(bytes: &[u8]) -> RawArrayBuf {
        let mut result = RawArrayBuf::new();
        let mut pos = 0;
        while pos < bytes.len() {
            let doc_size = i32::from_le_bytes(
                bytes[pos..pos + 4]
                    .try_into()
                    .expect("Slice of wrong length"),
            );
            let end = pos + usize::try_from(doc_size).expect("negative doc size");
            result
                .push(RawDocumentBuf::from_bytes(bytes[pos..end].to_vec()).expect("invalid BSON"));
            pos = end;
        }
        result
    }

    rawdoc! {
        "insert": collection,
        "ordered": ordered,
        "documents": read_documents_old(docs_bytes),
        "$db": db,
    }
}

fn bench_insert(c: &mut Criterion) {
    let mut group = c.benchmark_group("op_insert_construction");

    for count in [10, 100, 1_000] {
        group.throughput(Throughput::Elements(
            u64::try_from(count).unwrap_or(u64::MAX),
        ));

        // --- New path: full parse_request pipeline ---
        let message = make_op_insert_message(count);
        group.bench_with_input(BenchmarkId::new("bufmut", count), &message, |b, msg| {
            b.iter(|| {
                let mut requires_response = true;
                reader::parse_request(msg, &mut requires_response).unwrap()
            });
        });

        // --- Old path: RawDocumentBuf per doc + rawdoc! ---
        let docs = make_docs_bytes(count);
        group.bench_with_input(
            BenchmarkId::new("rawdocumentbuf", count),
            &docs,
            |b, docs_bytes| {
                b.iter(|| old_build_insert("mycoll", true, docs_bytes, "testdb"));
            },
        );
    }

    group.finish();
}

criterion_group!(benches, bench_insert);
criterion_main!(benches);
