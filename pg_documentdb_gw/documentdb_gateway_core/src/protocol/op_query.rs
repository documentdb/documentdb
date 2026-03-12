/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/protocol/op_query.rs
 *
 * Parser for the legacy OP_QUERY wire protocol message.
 *
 *-------------------------------------------------------------------------
 */

use bson::RawDocument;
use bytes::Buf;

use crate::{
    error::{DocumentDBError, Result},
    protocol::{self, bson_writer, reader},
    requests::Request,
};

/// Parse an OP_QUERY message using `Buf` for efficient in-memory reads.
pub fn parse_query<'a>(message: &'a [u8]) -> Result<Request<'a>> {
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
    let (_db, collection_name) = protocol::extract_database_and_collection_names(collection_path)?;

    // OP_QUERY is only supported for commands currently
    if collection_name == "$cmd" {
        return reader::parse_cmd(query, None);
    }

    Err(DocumentDBError::internal_error(
        "Unable to parse OpQuery request".to_owned(),
    ))
}
