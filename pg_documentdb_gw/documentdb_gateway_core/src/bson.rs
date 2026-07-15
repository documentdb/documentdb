/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/bson.rs
 *
 *-------------------------------------------------------------------------
 */

use std::io::Cursor;

use bson::{spec::ElementType, RawBsonRef, RawDocument};

use crate::{error::DocumentDBError, protocol::util::SyncLittleEndianRead};

/// Read a document's raw BSON bytes from the provided reader.
///
/// # Errors
/// Returns error if the operation fails.
pub fn read_document_bytes<'a>(
    cursor: &mut Cursor<&'a [u8]>,
) -> Result<(&'a RawDocument, usize), DocumentDBError> {
    let position = usize::try_from(cursor.position()).map_err(|error| {
        DocumentDBError::bad_value(format!("BSON document cursor position is invalid: {error}"))
    })?;

    let buffer = *cursor.get_ref();
    if position > buffer.len() {
        return Err(DocumentDBError::bad_value(format!(
            "BSON document cursor position {position} exceeds buffer length {}",
            buffer.len()
        )));
    }

    let length = cursor.read_i32_sync()?;
    let length = usize::try_from(length).map_err(|error| {
        DocumentDBError::bad_value(format!("BSON document size is negative: {error}"))
    })?;

    if length < 5 {
        return Err(DocumentDBError::bad_value(format!(
            "BSON document size {length} is smaller than the minimum document size"
        )));
    }

    let data = &buffer[position..];
    if length > data.len() {
        return Err(DocumentDBError::bad_value(format!(
            "BSON document size {length} exceeds remaining buffer {}",
            data.len()
        )));
    }

    let doc = RawDocument::from_bytes(&data[..length])?;
    cursor.set_position(u64::try_from(position + length).map_err(|error| {
        DocumentDBError::bad_value(format!("BSON document cursor position is invalid: {error}"))
    })?);

    Ok((doc, length))
}

/// Converts a BSON value to `bool` if it is a boolean or numeric type.
///
/// # Panics
/// Panics if the BSON element type does not match its value accessor.
#[must_use]
#[expect(
    clippy::expect_used,
    reason = "element type is checked before accessor call"
)]
#[expect(
    clippy::unwrap_in_result,
    reason = "expect is used on type-checked BSON values"
)]
pub fn convert_to_bool(bson: RawBsonRef) -> Option<bool> {
    match bson.element_type() {
        ElementType::Boolean => Some(bson.as_bool().expect("checked")),
        ElementType::Double => Some(bson.as_f64().expect("checked") != 0.0),
        ElementType::Int32 => Some(bson.as_i32().expect("checked") != 0),
        ElementType::Int64 => Some(bson.as_i64().expect("checked") != 0),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    use bson::rawdoc;

    #[test]
    fn read_document_bytes_rejects_negative_length() {
        let bytes = (-1_i32).to_le_bytes();
        let mut cursor = Cursor::new(bytes.as_slice());

        read_document_bytes(&mut cursor).expect_err("negative length should be rejected");
    }

    #[test]
    fn read_document_bytes_rejects_length_beyond_buffer() {
        let mut bytes = 100_i32.to_le_bytes().to_vec();
        bytes.push(0);
        let mut cursor = Cursor::new(bytes.as_slice());

        read_document_bytes(&mut cursor).expect_err("oversized document should be rejected");
    }

    #[test]
    fn read_document_bytes_rejects_cursor_position_beyond_buffer() {
        let bytes = 5_i32.to_le_bytes();
        let mut cursor = Cursor::new(bytes.as_slice());
        cursor.set_position(u64::try_from(usize::MAX).expect("usize max should fit in u64"));

        read_document_bytes(&mut cursor).expect_err("cursor past buffer should be rejected");
    }

    #[test]
    fn read_document_bytes_reads_valid_document() {
        let document = rawdoc! { "ok": 1_i32 };
        let bytes = document.as_bytes();
        let mut cursor = Cursor::new(bytes);

        let (raw, length) = read_document_bytes(&mut cursor).expect("document should parse");

        assert_eq!(raw.get_i32("ok").unwrap(), 1);
        assert_eq!(length, bytes.len());
        assert_eq!(
            cursor.position(),
            u64::try_from(bytes.len()).expect("test length should fit")
        );
    }
}
