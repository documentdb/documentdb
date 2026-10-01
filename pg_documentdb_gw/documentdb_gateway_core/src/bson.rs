/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/bson.rs
 *
 *-------------------------------------------------------------------------
 */

use std::io::Cursor;

use bson::{Decimal128, RawBsonRef, RawDocument};

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

/// Converts a BSON [`Decimal128`] to `f64` by parsing its decimal string
/// representation. Returns [`None`] only when the string form does not parse as
/// an `f64` at all.
///
/// Non-finite decimal values parse successfully: `Infinity` and `-Infinity`
/// yield the corresponding infinite `f64`, and `NaN` yields a NaN `f64`. This
/// mirrors how a `Double` value is forwarded unchanged, so the returned value
/// is not guaranteed to be finite and the caller is responsible for any
/// finiteness or range checks it requires.
#[must_use]
pub fn decimal128_to_f64(value: Decimal128) -> Option<f64> {
    value.to_string().parse::<f64>().ok()
}

/// Returns whether a BSON [`Decimal128`] represents a numeric zero.
///
/// This inspects the coefficient digits of the decimal string form rather than
/// converting through `f64`, so it neither misclassifies a tiny non-zero value
/// that underflows `f64` to `0.0` nor depends on the byte representation (a
/// `Decimal128` compares equal only byte-for-byte, so `0`, `0.0`, `-0`, and
/// `0E5` are distinct values despite all being numerically zero). Non-finite
/// values (`NaN`, `Infinity`) contain non-digit characters and are reported as
/// non-zero.
#[must_use]
pub fn decimal128_is_zero(value: Decimal128) -> bool {
    let text = value.to_string();
    let coefficient = text
        .trim_start_matches(['+', '-'])
        .split(['E', 'e'])
        .next()
        .unwrap_or_default();

    let mut saw_digit = false;
    for c in coefficient.chars() {
        if c == '.' {
            continue;
        }
        if !c.is_ascii_digit() {
            return false;
        }
        saw_digit = true;
        if c != '0' {
            return false;
        }
    }
    saw_digit
}

/// Converts a BSON value to `bool` if it is a boolean, numeric, decimal, or null
/// value. Returns [`None`] for any other type so the caller can reject it.
#[must_use]
pub fn convert_to_bool(bson: RawBsonRef) -> Option<bool> {
    match bson {
        RawBsonRef::Boolean(b) => Some(b),
        RawBsonRef::Double(d) => Some(d != 0.0),
        RawBsonRef::Int32(i) => Some(i != 0),
        RawBsonRef::Int64(i) => Some(i != 0),
        RawBsonRef::Decimal128(d) => Some(!decimal128_is_zero(d)),
        RawBsonRef::Null => Some(false),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use bson::rawdoc;

    use super::*;

    #[test]
    fn convert_to_bool_accepts_bool_numeric_decimal_and_null() {
        assert_eq!(convert_to_bool(RawBsonRef::Boolean(true)), Some(true));
        assert_eq!(convert_to_bool(RawBsonRef::Boolean(false)), Some(false));
        assert_eq!(convert_to_bool(RawBsonRef::Int32(1)), Some(true));
        assert_eq!(convert_to_bool(RawBsonRef::Int32(0)), Some(false));
        assert_eq!(convert_to_bool(RawBsonRef::Int64(5)), Some(true));
        assert_eq!(convert_to_bool(RawBsonRef::Double(2.5)), Some(true));
        assert_eq!(convert_to_bool(RawBsonRef::Double(0.0)), Some(false));

        let nonzero = "1024".parse::<Decimal128>().expect("valid decimal");
        let zero = "0".parse::<Decimal128>().expect("valid decimal");
        assert_eq!(convert_to_bool(RawBsonRef::Decimal128(nonzero)), Some(true));
        assert_eq!(convert_to_bool(RawBsonRef::Decimal128(zero)), Some(false));

        assert_eq!(convert_to_bool(RawBsonRef::Null), Some(false));
    }

    #[test]
    fn convert_to_bool_rejects_non_numeric_types() {
        assert_eq!(convert_to_bool(RawBsonRef::String("x")), None);
    }

    #[test]
    fn decimal128_zero_detection_is_numeric_not_byte_wise() {
        for form in ["0", "0.0", "-0", "0E5", "0.000", "+0"] {
            let value = form.parse::<Decimal128>().expect("valid decimal");
            assert!(
                decimal128_is_zero(value),
                "{form} should be detected as zero"
            );
            assert_eq!(convert_to_bool(RawBsonRef::Decimal128(value)), Some(false));
        }

        // A non-zero value smaller than the smallest positive f64 must not be
        // misclassified as zero through an f64 underflow.
        let subnormal = "1E-400".parse::<Decimal128>().expect("valid decimal");
        assert!(!decimal128_is_zero(subnormal));
        assert_eq!(
            convert_to_bool(RawBsonRef::Decimal128(subnormal)),
            Some(true)
        );

        for form in ["1024", "-2.5", "1E-400", "Infinity", "-Infinity", "NaN"] {
            let value = form.parse::<Decimal128>().expect("valid decimal");
            assert!(!decimal128_is_zero(value), "{form} should be non-zero");
        }
    }

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
