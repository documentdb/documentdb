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
    requests::{RequestPreview, WireRequest},
};

struct QueryCommand<'a> {
    document: &'a RawDocument,
    database_name: &'a str,
    collection_name: &'a str,
}

/// Parse an `OP_QUERY` message using `Buf` for efficient in-memory reads.
///
/// # Errors
/// Returns an error if the message is malformed or cannot be parsed.
pub fn parse_query(message: &[u8]) -> Result<WireRequest<'_>> {
    let command = parse_query_document(message)?;

    if command.collection_name == "$cmd" {
        if has_database_name(command.document) {
            return reader::parse_cmd(command.document, None);
        }

        return parse_cmd_with_db(command.document, command.database_name);
    }

    Err(DocumentDBError::internal_error(
        "Unable to parse OP_QUERY request".to_owned(),
    ))
}

/// Parse an `OP_QUERY` message into a payload-only request.
///
/// # Errors
/// Returns an error if the message is malformed or cannot be parsed.
pub(crate) fn parse_query_payload(message: &[u8]) -> Result<RequestPreview<'_>> {
    let command = parse_query_document(message)?;

    if command.collection_name == "$cmd" {
        if has_database_name(command.document) {
            let database_name = command
                .document
                .get_str("$db")
                .unwrap_or(command.database_name);
            return reader::parse_cmd_payload_with_db(command.document, None, database_name);
        }

        return parse_cmd_payload_with_db(command.document, command.database_name);
    }

    Err(DocumentDBError::internal_error(
        "Unable to parse OP_QUERY request".to_owned(),
    ))
}

fn parse_query_document(message: &[u8]) -> Result<QueryCommand<'_>> {
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

    // Parse the command document — this one IS inspected by the gateway
    let query = RawDocument::from_bytes(&buf[..query_size])?;
    let (db, collection_name) = protocol::extract_database_and_collection_names(collection_path)?;

    Ok(QueryCommand {
        document: query,
        database_name: db,
        collection_name,
    })
}

fn has_database_name(query: &RawDocument) -> bool {
    matches!(query.get("$db"), Ok(Some(_)))
}

fn parse_cmd_with_db(query: &RawDocument, db: &str) -> Result<WireRequest<'static>> {
    reader::parse_cmd_buf(build_command_with_db(query, db)?)
}

fn parse_cmd_payload_with_db(query: &RawDocument, db: &str) -> Result<RequestPreview<'static>> {
    reader::parse_cmd_buf_payload(build_command_with_db(query, db)?)
}

fn build_command_with_db(query: &RawDocument, db: &str) -> Result<RawDocumentBuf> {
    let query_bytes = query.as_bytes();

    if query_bytes.len() < 5 {
        return Err(DocumentDBError::internal_error(
            "OP_QUERY command document is too short".to_owned(),
        ));
    }

    let elements = &query_bytes[4..query_bytes.len() - 1];

    let mut body = Vec::with_capacity(query_bytes.len() + db.len() + 16);
    let doc_start = bson_writer::begin_document(&mut body);
    body.extend_from_slice(elements);
    bson_writer::append_bson_string(&mut body, "$db", db);
    bson_writer::end_document(&mut body, doc_start)?;

    RawDocumentBuf::from_bytes(body).map_err(|e| {
        DocumentDBError::internal_error(format!(
            "Failed to construct command with $db for OP_QUERY: {e}"
        ))
    })
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
        assert_eq!(request.db(), "testdb");
        assert_eq!(request.document().get_str("$db").unwrap(), "testdb");
        assert_eq!(request.request_type(), RequestType::Find);
    }

    #[test]
    fn op_query_preserves_existing_db() {
        let command = rawdoc! { "find": "myCollection", "$db": "fromBody" };
        let msg = build_op_query_message("wiredb.$cmd", command.as_bytes());

        let request = parse_query(&msg).expect("should parse OP_QUERY");
        assert_eq!(request.db(), "fromBody");
    }

    #[test]
    fn op_query_non_cmd_collection_returns_error() {
        let command = rawdoc! { "find": "myCollection" };
        let msg = build_op_query_message("testdb.regularCollection", command.as_bytes());

        let result = parse_query(&msg);
        assert!(result.is_err(), "non-$cmd OP_QUERY should fail");
    }

    #[test]
    fn op_query_invalid_db_type_is_rejected() {
        let command = rawdoc! { "find": "myCollection", "$db": 42 };
        let msg = build_op_query_message("testdb.$cmd", command.as_bytes());

        parse_query(&msg).expect_err("non-string $db should be rejected");
    }

    #[test]
    fn op_query_payload_invalid_db_type_does_not_inject_duplicate() {
        let command = rawdoc! { "ping": 1, "$db": true };
        let msg = build_op_query_message("wiredb.$cmd", command.as_bytes());

        let request = parse_query_payload(&msg).expect("should parse OP_QUERY payload");

        assert_eq!(
            request.db_hint(),
            Some("wiredb"),
            "payload metadata should still carry the namespace database"
        );

        let db_count = request
            .document()
            .iter()
            .filter_map(std::result::Result::ok)
            .filter(|(k, _)| *k == "$db")
            .count();
        assert_eq!(
            db_count, 1,
            "payload parser should not append a duplicate database field"
        );
    }

    #[test]
    fn op_query_payload_injects_db_when_missing() {
        let command = rawdoc! { "ping": 1 };
        let msg = build_op_query_message("payloadDb.$cmd", command.as_bytes());

        let request = parse_query_payload(&msg).expect("should parse OP_QUERY payload");

        assert_eq!(request.db_hint(), Some("payloadDb"));
        assert_eq!(request.document().get_str("$db").unwrap(), "payloadDb");
        assert_eq!(request.request_type(), RequestType::Ping);
    }
}
