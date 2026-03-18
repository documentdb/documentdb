/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/protocol/op_insert.rs
 *
 * Parser for the legacy OP_INSERT wire protocol message. Builds the
 * equivalent insert command document using `BufMut`, copying raw document
 * bytes without per-document BSON validation.
 *
 *-------------------------------------------------------------------------
 */

use bson::RawDocumentBuf;
use bytes::Buf;

use crate::{
    error::{DocumentDBError, Result},
    protocol::{bson_writer, extract_database_and_collection_names, reader},
    requests::{Request, RequestMessage, RequestType},
};

/// Parse an `OP_INSERT` message into a `Request`.
///
/// # Errors
/// Returns an error if the message is malformed or cannot be parsed.
pub fn parse_insert(message: &RequestMessage) -> Result<Request<'_>> {
    let mut buf = message.request.as_slice();

    if buf.remaining() < 4 {
        return Err(DocumentDBError::bad_value(
            "OP_INSERT message too short for flags".to_owned(),
        ));
    }
    let flags = buf.get_i32_le();

    let (collection_path, endpos) = reader::str_from_u8_nul_utf8(buf)?;

    // Everything after the collection string + null terminator is document data
    let docs_slice = &buf[endpos + 1..];

    let (db, coll) = extract_database_and_collection_names(collection_path)?;
    let ordered = (flags & 1) == 0;

    // Build the insert command BSON document directly with BufMut,
    // copying raw document bytes without per-document validation.
    let doc = build_insert_command(coll, ordered, docs_slice, db)?;

    Ok(Request::RawBuf(RequestType::Insert, doc))
}

/// Build an `OP_INSERT` command document using `BufMut`, avoiding per-document
/// `RawDocumentBuf` parsing. The embedded documents are copied as raw bytes.
fn build_insert_command(
    collection: &str,
    ordered: bool,
    docs_bytes: &[u8],
    db: &str,
) -> Result<RawDocumentBuf> {
    // 64 is a conservative upper bound for the fixed BSON envelope overhead
    // The extra headroom avoids a reallocation in the common case.
    let initial_capacity = docs_bytes.len() + collection.len() + db.len() + 64;
    let mut body = Vec::with_capacity(initial_capacity);

    let doc_start = bson_writer::begin_document(&mut body);
    bson_writer::append_bson_string(&mut body, "insert", collection);
    bson_writer::append_bson_bool(&mut body, "ordered", ordered);
    bson_writer::append_bson_raw_doc_array(&mut body, "documents", docs_bytes)?;
    bson_writer::append_bson_string(&mut body, "$db", db);
    bson_writer::end_document(&mut body, doc_start)?;

    RawDocumentBuf::from_bytes(body).map_err(|e| {
        DocumentDBError::internal_error(format!("Failed to construct insert command: {e}"))
    })
}

#[cfg(test)]
mod tests {
    use bson::{rawdoc, RawArrayBuf};

    use super::*;

    /// Build a small but realistic BSON document as raw bytes.
    fn make_test_document(id: i32) -> Vec<u8> {
        rawdoc! {
            "_id": id,
            "name": "test document with some payload data",
            "value": 42_i64,
            "nested": { "a": 1, "b": "hello" },
        }
        .into_bytes()
    }

    /// Concatenate `count` BSON documents into a contiguous byte buffer,
    /// simulating the document section of an `OP_INSERT` message.
    fn make_docs_bytes(count: usize) -> Vec<u8> {
        let mut bytes = Vec::new();
        for i in 0..count {
            bytes.extend_from_slice(&make_test_document(i32::try_from(i).unwrap_or(i32::MAX)));
        }
        bytes
    }

    /// Original approach: per-document `RawDocumentBuf::from_bytes` + `rawdoc!`
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
                result.push(
                    RawDocumentBuf::from_bytes(bytes[pos..end].to_vec()).expect("invalid BSON"),
                );
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

    #[test]
    fn build_insert_command_produces_valid_bson() {
        let docs = make_docs_bytes(5);
        let result = build_insert_command("mycoll", true, &docs, "mydb").unwrap();

        let doc = result.as_ref();
        assert_eq!(doc.get_str("insert").unwrap(), "mycoll");
        assert!(doc.get_bool("ordered").unwrap());
        assert_eq!(doc.get_str("$db").unwrap(), "mydb");

        let arr = doc.get_array("documents").unwrap();
        assert_eq!(arr.into_iter().count(), 5);
    }

    #[test]
    fn build_insert_command_matches_old_output() {
        for count in [1, 5, 20] {
            let docs = make_docs_bytes(count);
            let new_doc = build_insert_command("coll", false, &docs, "testdb").unwrap();
            let old_doc = old_build_insert("coll", false, &docs, "testdb");

            // Both must produce byte-identical BSON
            assert_eq!(
                new_doc.as_bytes(),
                old_doc.as_bytes(),
                "Mismatch for {count} documents"
            );
        }
    }

    #[test]
    fn build_insert_command_empty_batch() {
        let result = build_insert_command("coll", true, &[], "db").unwrap();
        let arr = result.as_ref().get_array("documents").unwrap();
        assert_eq!(arr.into_iter().count(), 0);
    }

    #[test]
    fn build_insert_command_rejects_truncated_doc() {
        // 4-byte size header claiming 100 bytes, but only 10 bytes present
        let mut bad = Vec::new();
        bad.extend_from_slice(&100_i32.to_le_bytes());
        bad.extend_from_slice(&[0u8; 6]);
        build_insert_command("c", true, &bad, "d").unwrap_err();
    }

    #[test]
    fn build_insert_command_rejects_zero_size_doc() {
        let mut bad = Vec::new();
        bad.extend_from_slice(&0_i32.to_le_bytes());
        bad.push(0);
        build_insert_command("c", true, &bad, "d").unwrap_err();
    }
}
