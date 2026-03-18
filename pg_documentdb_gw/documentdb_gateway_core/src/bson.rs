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
#[expect(
    clippy::cast_possible_truncation,
    reason = "BSON document sizes fit in usize on supported platforms"
)]
#[expect(
    clippy::cast_sign_loss,
    reason = "length is validated positive by BSON spec"
)]
pub fn read_document_bytes<'a>(
    cursor: &mut Cursor<&'a [u8]>,
) -> Result<(&'a RawDocument, usize), DocumentDBError> {
    let data = &cursor.clone().into_inner()[cursor.position() as usize..];
    let length = cursor.read_i32_sync()?;
    let doc = RawDocument::from_bytes(&data[0..length as usize])?;
    cursor.set_position(cursor.position() + length as u64 - 4);
    Ok((doc, length as usize))
}

/// Converts a BSON value to `f64` if it is a numeric type.
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
#[expect(
    clippy::cast_precision_loss,
    reason = "i64-to-f64 loss is acceptable for numeric coercion"
)]
pub fn convert_to_f64(bson: RawBsonRef) -> Option<f64> {
    match bson.element_type() {
        ElementType::Double => Some(bson.as_f64().expect("checked")),
        ElementType::Int32 => Some(f64::from(bson.as_i32().expect("checked"))),
        ElementType::Int64 => Some(bson.as_i64().expect("checked") as f64),
        _ => None,
    }
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
