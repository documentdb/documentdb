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
    let start = usize::try_from(cursor.position()).map_err(|error| {
        DocumentDBError::bad_value(format!("BSON document offset is invalid: {error}"))
    })?;
    let data = &cursor.clone().into_inner()[start..];
    let length = cursor.read_i32_sync()?;
    let length = usize::try_from(length).map_err(|error| {
        DocumentDBError::bad_value(format!("BSON document length is negative: {error}"))
    })?;
    let document_bytes = data.get(..length).ok_or_else(|| {
        DocumentDBError::bad_value(format!(
            "BSON document length {length} exceeds available bytes {}",
            data.len()
        ))
    })?;
    let doc = RawDocument::from_bytes(document_bytes)?;
    cursor.set_position(u64::try_from(start + length).map_err(|error| {
        DocumentDBError::bad_value(format!("BSON document end offset is invalid: {error}"))
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
