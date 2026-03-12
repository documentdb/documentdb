/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/protocol/bson_writer.rs
 *
 * Low-level helpers for writing BSON elements directly into a byte buffer
 * using `BufMut`, bypassing the `bson` crate's validation. Use these when
 * the gateway needs to construct BSON from raw, already-validated bytes.
 *
 *-------------------------------------------------------------------------
 */

use bytes::{Buf, BufMut};

use crate::error::{DocumentDBError, Result};

// BSON element type tags
const BSON_TYPE_STRING: u8 = 0x02;
const BSON_TYPE_DOCUMENT: u8 = 0x03;
const BSON_TYPE_ARRAY: u8 = 0x04;
const BSON_TYPE_BOOLEAN: u8 = 0x08;

/// Peek at the first 4 bytes of a buffer to read a BSON document's declared size.
///
/// # Errors
///
/// Returns an error if `buf` is shorter than 4 bytes or the size is negative.
#[inline]
pub fn bson_doc_size(buf: &[u8]) -> Result<usize> {
    if buf.len() < 4 {
        return Err(DocumentDBError::internal_error(
            "Buffer too short to read BSON document size".to_owned(),
        ));
    }
    let size = i32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
    usize::try_from(size)
        .map_err(|_| DocumentDBError::internal_error("BSON document size is negative".to_owned()))
}

/// Append a BSON string element (type 0x02) to `buf`.
#[inline]
pub fn append_bson_string(buf: &mut Vec<u8>, key: &str, value: &str) {
    buf.put_u8(BSON_TYPE_STRING);
    buf.put_slice(key.as_bytes());
    buf.put_u8(0);

    // BSON string length includes the trailing null byte.
    // See <https://bsonspec.org/spec.html>
    let str_len = i32::try_from(value.len() + 1).unwrap_or(i32::MAX);
    buf.put_i32_le(str_len);
    buf.put_slice(value.as_bytes());
    buf.put_u8(0);
}

/// Append a BSON boolean element (type 0x08) to `buf`.
#[inline]
pub fn append_bson_bool(buf: &mut Vec<u8>, key: &str, value: bool) {
    buf.put_u8(BSON_TYPE_BOOLEAN);
    buf.put_slice(key.as_bytes());
    buf.put_u8(0);
    buf.put_u8(u8::from(value));
}

/// Append a BSON array element (type 0x04) containing raw BSON documents
/// copied directly from `docs_bytes` without per-document validation.
///
/// # Errors
///
/// Returns an error if any document in `docs_bytes` is truncated, has a
/// negative size, or is smaller than the 5-byte BSON minimum.
pub fn append_bson_raw_doc_array(buf: &mut Vec<u8>, key: &str, docs_bytes: &[u8]) -> Result<()> {
    buf.put_u8(BSON_TYPE_ARRAY);
    buf.put_slice(key.as_bytes());
    buf.put_u8(0);

    let doc_start = begin_document(buf);

    let mut src = docs_bytes;
    let mut index = 0u32;
    while src.has_remaining() {
        if src.remaining() < 5 {
            return Err(DocumentDBError::internal_error(
                "Truncated document in insert batch".to_owned(),
            ));
        }

        let doc_size = bson_doc_size(src)?;

        // A valid BSON document is at least 5 bytes (4-byte length + null terminator).
        // Reject smaller sizes to prevent infinite loops on malformed input.
        if doc_size < 5 {
            return Err(DocumentDBError::internal_error(
                "BSON document size too small (minimum 5 bytes)".to_owned(),
            ));
        }

        if src.remaining() < doc_size {
            return Err(DocumentDBError::internal_error(
                "Document extends beyond insert message boundary".to_owned(),
            ));
        }

        // Write array element: type (embedded doc), key (index as string), value (raw bytes)
        buf.put_u8(BSON_TYPE_DOCUMENT);
        let key_str = index.to_string();
        buf.put_slice(key_str.as_bytes());

        buf.put_u8(0);
        buf.put_slice(&src[..doc_size]);

        src.advance(doc_size);
        index += 1;
    }

    end_document(buf, doc_start)
}

/// Begins a new BSON document by writing a 4-byte length placeholder.
///
/// Returns the byte offset of the placeholder so [`end_document`] can
/// back-fill the correct position even when prefix bytes (e.g. a BSON
/// element type tag and key) were written before this call.
/// Every call to `begin_document` must be paired with a corresponding
/// call to [`end_document`].
#[must_use]
#[inline]
pub fn begin_document(buf: &mut Vec<u8>) -> usize {
    let offset = buf.len();
    buf.put_i32_le(0); // placeholder for document length, back-filled by end_document
    offset
}

/// Finalizes a BSON document started by [`begin_document`].
///
/// Appends the null terminator byte, then back-fills the 4-byte length
/// placeholder at `doc_start` (the offset returned by [`begin_document`])
/// with the actual document length in little-endian byte order.
///
/// # Errors
///
/// Returns [`DocumentDBError::bad_value`] if the document length exceeds
/// [`i32::MAX`].
#[inline]
pub fn end_document(buf: &mut Vec<u8>, doc_start: usize) -> Result<()> {
    buf.put_u8(0); // document null terminator

    let doc_len = i32::try_from(buf.len() - doc_start)
        .map_err(|_| DocumentDBError::bad_value("Document too large".to_owned()))?;

    buf[doc_start..doc_start + 4].copy_from_slice(&doc_len.to_le_bytes());

    Ok(())
}

#[cfg(test)]
mod tests {
    use bson::{rawdoc, RawDocument};

    use super::*;

    #[test]
    fn bson_doc_size_valid() {
        let buf = 42_i32.to_le_bytes();
        assert_eq!(bson_doc_size(&buf).unwrap(), 42);
    }

    #[test]
    fn bson_doc_size_negative_returns_error() {
        let buf = (-1_i32).to_le_bytes();
        assert!(bson_doc_size(&buf).is_err());
    }

    #[test]
    fn bson_doc_size_too_short_returns_error() {
        assert!(bson_doc_size(&[0u8; 3]).is_err());
    }

    #[test]
    fn append_bson_string_round_trips() {
        let mut buf = Vec::new();
        buf.put_i32_le(0); // placeholder for doc length
        append_bson_string(&mut buf, "key", "hello");
        buf.put_u8(0); // doc null terminator
        let len = i32::try_from(buf.len()).unwrap();
        buf[..4].copy_from_slice(&len.to_le_bytes());

        let doc = RawDocument::from_bytes(&buf).unwrap();
        assert_eq!(doc.get_str("key").unwrap(), "hello");
    }

    #[test]
    fn append_bson_bool_round_trips() {
        let mut buf = Vec::new();
        buf.put_i32_le(0);
        append_bson_bool(&mut buf, "flag", true);
        buf.put_u8(0);
        let len = i32::try_from(buf.len()).unwrap();
        buf[..4].copy_from_slice(&len.to_le_bytes());

        let doc = RawDocument::from_bytes(&buf).unwrap();
        assert!(doc.get_bool("flag").unwrap());
    }

    #[test]
    fn append_bson_raw_doc_array_round_trips() {
        // Build two small BSON documents as raw bytes
        let d1 = rawdoc! { "a": 1 };
        let d2 = rawdoc! { "b": 2 };
        let mut docs_bytes = Vec::new();
        docs_bytes.extend_from_slice(d1.as_bytes());
        docs_bytes.extend_from_slice(d2.as_bytes());

        let mut buf = Vec::new();
        buf.put_i32_le(0);
        append_bson_raw_doc_array(&mut buf, "arr", &docs_bytes).unwrap();
        buf.put_u8(0);
        let len = i32::try_from(buf.len()).unwrap();
        buf[..4].copy_from_slice(&len.to_le_bytes());

        let doc = RawDocument::from_bytes(&buf).unwrap();
        let arr = doc.get_array("arr").unwrap();
        assert_eq!(arr.into_iter().count(), 2);
    }

    #[test]
    fn append_bson_raw_doc_array_empty() {
        let mut buf = Vec::new();
        buf.put_i32_le(0);
        append_bson_raw_doc_array(&mut buf, "arr", &[]).unwrap();
        buf.put_u8(0);
        let len = i32::try_from(buf.len()).unwrap();
        buf[..4].copy_from_slice(&len.to_le_bytes());

        let doc = RawDocument::from_bytes(&buf).unwrap();
        let arr = doc.get_array("arr").unwrap();
        assert_eq!(arr.into_iter().count(), 0);
    }

    #[test]
    fn append_bson_raw_doc_array_rejects_undersized_doc() {
        // doc_size = 3 (below minimum of 5)
        let bad = 3_i32.to_le_bytes();
        let mut buf = Vec::new();
        assert!(append_bson_raw_doc_array(&mut buf, "arr", &bad).is_err());
    }
}
