/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/protocol/op_query.rs
 *
 * Parser for the legacy OP_QUERY wire protocol message.
 *
 *-------------------------------------------------------------------------
 */

use bson::{RawDocument, RawDocumentBuf};
use bytes::Buf;

use crate::{
    error::{DocumentDBError, Result},
    protocol::{self, bson_writer, reader},
    requests::Request,
};

/// Parse an `OP_QUERY` message using `Buf` for efficient in-memory reads.
///
/// # Errors
/// Returns an error if the message is malformed or cannot be parsed.
pub fn parse_query(message: &[u8]) -> Result<Request<'_>> {
    let mut buf = message;

    if buf.remaining() < 4 {
        return Err(DocumentDBError::internal_error(
            "OP_QUERY message too short for flags".to_owned(),
        ));
    }
    let _flags = buf.get_u32_le();

    // Parse the collection (null-terminated string starting after flags)
    let (collection_path, endpos) = reader::str_from_u8_nul_utf8(buf)?;
    buf.advance(endpos + 1); // skip past string + null terminator

    if buf.remaining() < 8 {
        return Err(DocumentDBError::internal_error(
            "OP_QUERY message too short for skip/return counts".to_owned(),
        ));
    }
    let _number_to_skip = buf.get_u32_le();
    let _number_to_return = buf.get_u32_le();

    // The remaining buffer starts at the BSON query document (including its length prefix)
    if buf.remaining() < 4 {
        return Err(DocumentDBError::internal_error(
            "OP_QUERY message too short for query document".to_owned(),
        ));
    }

    // Peek at the BSON document size without consuming (it's part of the document bytes)
    let query_size = bson_writer::bson_doc_size(buf)?;

    if buf.remaining() < query_size {
        return Err(DocumentDBError::internal_error(
            "OP_QUERY query document extends beyond message".to_owned(),
        ));
    }

    // Parse the command document - this one IS inspected by the gateway
    let query = RawDocument::from_bytes(&buf[..query_size])?;
    let (db, collection_name) = protocol::extract_database_and_collection_names(collection_path)?;

    // OP_QUERY is only supported for commands currently
    if collection_name == "$cmd" {
        // If `$db` is present in the document body (regardless of type), use the zero-copy path.
        // Otherwise, rebuild the document with `$db` injected from the namespace —
        // legacy drivers rely on the wire-level fullCollectionName and may omit `$db`.
        //
        // Note: leaving an invalid `$db` value in-place ensures it is rejected by the
        // common command validation path, rather than appending a second `$db` field.
        if matches!(query.get("$db"), Ok(Some(_))) {
            return reader::parse_cmd(query, None);
        }
        return parse_cmd_with_db(query, db);
    }

    Err(DocumentDBError::internal_error(
        "Unable to parse OP_QUERY request".to_owned(),
    ))
}

/// Rebuild a command document with `$db` appended, then parse it as a command.
fn parse_cmd_with_db(query: &RawDocument, db: &str) -> Result<Request<'static>> {
    let query_bytes = query.as_bytes();

    // The original doc is: [4-byte len][elements...][0x00 terminator]
    // We insert a `$db` string element before the terminator.
    let elements = &query_bytes[4..query_bytes.len() - 1]; // strip length prefix and terminator

    let mut body = Vec::with_capacity(query_bytes.len() + db.len() + 16);
    let doc_start = bson_writer::begin_document(&mut body);
    body.extend_from_slice(elements);
    bson_writer::append_bson_string(&mut body, "$db", db);
    bson_writer::end_document(&mut body, doc_start)?;

    let doc = RawDocumentBuf::from_bytes(body).map_err(|e| {
        DocumentDBError::internal_error(format!(
            "Failed to construct command with $db for OP_QUERY: {e}"
        ))
    })?;

    reader::parse_cmd_buf(doc)
}

#[cfg(test)]
mod tests {
    use bson::rawdoc;
    use bytes::BufMut;

    use super::*;
    use crate::requests::RequestType;

    /// Build a minimal `OP_QUERY` message from a namespace and BSON command body.
    fn build_op_query_message(namespace: &str, command: &[u8]) -> Vec<u8> {
        let mut msg = Vec::new();
        msg.put_u32_le(0); // flags
        msg.extend_from_slice(namespace.as_bytes());
        msg.put_u8(0); // null terminator for namespace
        msg.put_u32_le(0); // numberToSkip
        msg.put_u32_le(1); // numberToReturn
        msg.extend_from_slice(command);
        msg
    }

    #[test]
    fn op_query_injects_db_when_missing() {
        let command = rawdoc! { "find": "myCollection", "filter": {} };
        let msg = build_op_query_message("testdb.$cmd", command.as_bytes());

        let request = parse_query(&msg).expect("should parse OP_QUERY");
        let info = request
            .extract_common()
            .expect("extract_common should succeed");

        assert_eq!(info.db().expect("db should be present"), "testdb");
        assert_eq!(request.request_type(), RequestType::Find);
    }

    #[test]
    fn op_query_preserves_existing_db() {
        let command = rawdoc! { "find": "myCollection", "$db": "fromBody" };
        let msg = build_op_query_message("wiredb.$cmd", command.as_bytes());

        let request = parse_query(&msg).expect("should parse OP_QUERY");
        let info = request
            .extract_common()
            .expect("extract_common should succeed");

        // Should use the $db from the document body, not the namespace
        assert_eq!(info.db().expect("db should be present"), "fromBody");
    }

    #[test]
    fn op_query_non_cmd_collection_returns_error() {
        let command = rawdoc! { "find": "myCollection" };
        let msg = build_op_query_message("testdb.regularCollection", command.as_bytes());

        let result = parse_query(&msg);
        assert!(result.is_err(), "non-$cmd OP_QUERY should fail");
    }

    #[test]
    fn op_query_invalid_db_type_rejected_without_duplicate() {
        // $db is present but with an integer type instead of a string.
        // The parser should NOT inject a second $db; instead it should pass
        // the document as-is so common validation rejects the invalid type.
        let command = rawdoc! { "find": "myCollection", "$db": 42 };
        let msg = build_op_query_message("testdb.$cmd", command.as_bytes());

        let request = parse_query(&msg).expect("should parse OP_QUERY");
        let result = request.extract_common();

        // Common validation rejects $db because it's not a string
        assert!(
            result.is_err(),
            "non-string $db should be rejected by common validation"
        );
    }

    #[test]
    fn op_query_invalid_db_type_does_not_inject_duplicate() {
        // $db is a boolean — verify that the document passed to parse_cmd
        // still contains exactly one $db field (the invalid one from the body),
        // not an additional string $db injected from the namespace.
        let command = rawdoc! { "ping": 1, "$db": true };
        let msg = build_op_query_message("wiredb.$cmd", command.as_bytes());

        let request = parse_query(&msg).expect("should parse OP_QUERY");

        // Count $db fields in the underlying document
        let db_count = request
            .document()
            .iter()
            .filter_map(std::result::Result::ok)
            .filter(|(k, _)| *k == "$db")
            .count();
        assert_eq!(
            db_count, 1,
            "should have exactly one $db field, not a duplicate"
        );
    }
}
