/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/protocol/bson_scanner.rs
 *
 * Zero-copy BSON document field scanner for the request hot path.
 *
 * Operates directly on `&[u8]` raw BSON bytes, extracting field names
 * and values without constructing intermediate wrapper objects. Uses
 * length-discriminated field matching (compare field name length first,
 * then full bytes) for fast dispatch.
 *
 * DESIGN: "sync core" — this module is entirely synchronous, no async,
 * no tokio dependency. Pure functions on byte slices, testable with
 * standard `#[test]`.
 *
 * For nested document fields, the scanner returns the sub-document as a
 * `&[u8]` slice. Callers can re-scan the slice or fall back to
 * `bson::RawDocument::from_bytes()` for complex nested access.
 *-------------------------------------------------------------------------
 */

use crate::error::{DocumentDBError, Result};

/// BSON element type bytes (subset needed for command parsing).
mod element_type {
    pub const DOUBLE: u8 = 0x01;
    pub const STRING: u8 = 0x02;
    pub const DOCUMENT: u8 = 0x03;
    pub const ARRAY: u8 = 0x04;
    pub const BINARY: u8 = 0x05;
    pub const BOOLEAN: u8 = 0x08;
    pub const NULL: u8 = 0x0A;
    pub const INT32: u8 = 0x10;
    pub const TIMESTAMP: u8 = 0x11;
    pub const INT64: u8 = 0x12;
    pub const DECIMAL128: u8 = 0x13;
    pub const MIN_KEY: u8 = 0xFF;
    pub const MAX_KEY: u8 = 0x7F;
}

/// A raw BSON field extracted by the scanner — zero-copy references into
/// the original document bytes.
#[derive(Debug)]
pub struct RawField<'a> {
    /// Element type byte.
    element_type: u8,
    /// Field name as UTF-8 bytes (without null terminator).
    name: &'a [u8],
    /// Raw value bytes (type-dependent length).
    value: &'a [u8],
}

impl<'a> RawField<'a> {
    #[must_use]
    pub const fn element_type(&self) -> u8 {
        self.element_type
    }

    /// Returns the field name as a byte slice.
    #[must_use]
    pub const fn name(&self) -> &'a [u8] {
        self.name
    }

    /// Returns the raw value bytes.
    #[must_use]
    pub const fn value(&self) -> &'a [u8] {
        self.value
    }

    /// Returns the field name as a `&str`, or `None` if not valid UTF-8.
    #[must_use]
    pub fn name_str(&self) -> Option<&'a str> {
        std::str::from_utf8(self.name).ok()
    }

    /// Reads the value as a bool (element type 0x08).
    #[must_use]
    pub fn as_bool(&self) -> Option<bool> {
        if self.element_type != element_type::BOOLEAN || self.value.len() != 1 {
            return None;
        }

        match self.value[0] {
            0 => Some(false),
            1 => Some(true),
            _ => None,
        }
    }

    /// Reads the value as an i32 (element type 0x10).
    #[must_use]
    pub fn as_i32(&self) -> Option<i32> {
        (self.element_type == element_type::INT32 && self.value.len() >= 4).then(|| {
            i32::from_le_bytes([self.value[0], self.value[1], self.value[2], self.value[3]])
        })
    }

    /// Reads the value as an i64 (element type 0x12).
    #[must_use]
    pub fn as_i64(&self) -> Option<i64> {
        (self.element_type == element_type::INT64 && self.value.len() >= 8).then(|| {
            i64::from_le_bytes([
                self.value[0],
                self.value[1],
                self.value[2],
                self.value[3],
                self.value[4],
                self.value[5],
                self.value[6],
                self.value[7],
            ])
        })
    }

    /// Reads the value as a f64 (element type 0x01).
    #[must_use]
    pub fn as_f64(&self) -> Option<f64> {
        (self.element_type == element_type::DOUBLE && self.value.len() >= 8).then(|| {
            f64::from_le_bytes([
                self.value[0],
                self.value[1],
                self.value[2],
                self.value[3],
                self.value[4],
                self.value[5],
                self.value[6],
                self.value[7],
            ])
        })
    }

    /// Reads the value as a UTF-8 string (element type 0x02).
    /// BSON strings: `int32` (length including null) + bytes + 0x00
    #[must_use]
    pub fn as_str(&self) -> Option<&'a str> {
        if self.element_type != element_type::STRING || self.value.len() < 5 {
            return None;
        }

        let str_len =
            i32::from_le_bytes([self.value[0], self.value[1], self.value[2], self.value[3]]);
        let str_len = usize::try_from(str_len).ok()?;

        if str_len == 0 || self.value.len() < 4 + str_len {
            return None;
        }

        if self.value[4 + str_len - 1] != 0 {
            return None;
        }

        // str_len includes the null terminator
        std::str::from_utf8(&self.value[4..(4 + str_len - 1)]).ok()
    }

    /// Returns the raw bytes of a sub-document (element type 0x03) or array (0x04).
    /// The returned slice includes the document's leading `int32` size.
    #[must_use]
    pub fn as_document_bytes(&self) -> Option<&'a [u8]> {
        matches!(
            self.element_type,
            element_type::DOCUMENT | element_type::ARRAY
        )
        .then_some(self.value)
    }

    /// Returns the raw bytes of a sub-document (element type 0x03).
    /// The returned slice includes the document's leading `int32` size.
    #[must_use]
    pub fn as_embedded_document_bytes(&self) -> Option<&'a [u8]> {
        (self.element_type == element_type::DOCUMENT).then_some(self.value)
    }

    /// Returns true if this field is a numeric type (int32, int64, double).
    #[must_use]
    pub const fn is_numeric(&self) -> bool {
        matches!(
            self.element_type,
            element_type::INT32 | element_type::INT64 | element_type::DOUBLE
        )
    }

    /// Returns the raw binary data bytes (element type 0x05).
    /// BSON binary: `int32`(len) + `uint8`(subtype) + bytes.
    /// Returns `(subtype, data_bytes)`.
    #[must_use]
    pub fn as_binary_data(&self) -> Option<(u8, &'a [u8])> {
        if self.element_type != element_type::BINARY || self.value.len() < 5 {
            return None;
        }

        let len = i32::from_le_bytes([self.value[0], self.value[1], self.value[2], self.value[3]]);
        let len = usize::try_from(len).ok()?;

        if self.value.len() < 5 + len {
            return None;
        }

        let subtype = self.value[4];
        Some((subtype, &self.value[5..(5 + len)]))
    }

    /// Reads any numeric type as `i64`.
    #[must_use]
    pub fn to_i64(&self) -> Option<i64> {
        match self.element_type {
            element_type::INT32 => self.as_i32().map(i64::from),
            element_type::INT64 => self.as_i64(),
            #[expect(
                clippy::cast_possible_truncation,
                reason = "truncation acceptable for f64 to i64"
            )]
            element_type::DOUBLE => self.as_f64().map(|f| f as i64),
            _ => None,
        }
    }
}

/// Returns the byte length of a BSON value given its element type and
/// the bytes starting at the value position.
///
/// Returns `None` if the type is unknown or the bytes are insufficient.
fn value_length(element_type: u8, bytes: &[u8]) -> Option<usize> {
    match element_type {
        element_type::NULL | element_type::MIN_KEY | element_type::MAX_KEY | 0x06 => Some(0),
        element_type::BOOLEAN => Some(1),
        element_type::INT32 => Some(4),
        element_type::DOUBLE | element_type::INT64 | element_type::TIMESTAMP | 0x09 => Some(8),
        0x07 => Some(12), // ObjectId
        element_type::DECIMAL128 => Some(16),
        element_type::STRING | 0x0D | 0x0E => {
            if bytes.len() < 4 {
                return None;
            }

            let len = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            let len = usize::try_from(len).ok()?;

            if len == 0 || bytes.len() < 4 + len || bytes[4 + len - 1] != 0 {
                return None;
            }

            Some(4 + len)
        }
        element_type::DOCUMENT | element_type::ARRAY => {
            if bytes.len() < 4 {
                return None;
            }

            let size = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            let size = usize::try_from(size).ok()?;

            if size < 5 || bytes.len() < size || bytes[size - 1] != 0 {
                return None;
            }

            Some(size)
        }
        element_type::BINARY => {
            if bytes.len() < 5 {
                return None;
            }

            let len = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            let len = usize::try_from(len).ok()?;
            let value_len = 5usize.checked_add(len)?;

            (bytes.len() >= value_len).then_some(value_len) // size + subtype + data
        }
        0x0B => {
            // Regex: two cstrings
            let first_end = bytes.iter().position(|&b| b == 0)?;

            let second_start = first_end + 1;
            let second_end = bytes[second_start..].iter().position(|&b| b == 0)?;

            Some(second_start + second_end + 1)
        }
        0x0C => {
            // DBPointer: string namespace + ObjectId
            if bytes.len() < 4 {
                return None;
            }

            let len = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            let len = usize::try_from(len).ok()?;

            if len == 0 || bytes.len() < 4 + len + 12 || bytes[4 + len - 1] != 0 {
                return None;
            }

            Some(4 + len + 12)
        }
        0x0F => {
            // Code with scope (int32 total size)
            if bytes.len() < 4 {
                return None;
            }

            let size = i32::from_le_bytes([bytes[0], bytes[1], bytes[2], bytes[3]]);
            let size = usize::try_from(size).ok()?;
            if size < 14 || bytes.len() < size {
                return None;
            }

            let code_len = i32::from_le_bytes([bytes[4], bytes[5], bytes[6], bytes[7]]);
            let code_len = usize::try_from(code_len).ok()?;
            let scope_start = 8usize.checked_add(code_len)?;
            if code_len == 0 || scope_start >= size || bytes[scope_start - 1] != 0 {
                return None;
            }

            if scope_start + 4 > size {
                return None;
            }
            let scope_size = i32::from_le_bytes([
                bytes[scope_start],
                bytes[scope_start + 1],
                bytes[scope_start + 2],
                bytes[scope_start + 3],
            ]);
            let scope_size = usize::try_from(scope_size).ok()?;
            if scope_size < 5
                || scope_start.checked_add(scope_size)? != size
                || bytes[size - 1] != 0
            {
                return None;
            }

            Some(size)
        }
        _ => None, // Unknown type
    }
}

/// Scans a BSON document's raw bytes and calls the visitor for each field.
///
/// The visitor receives a [`RawField`] with zero-copy references into the
/// original bytes. Returning `Err` from the visitor stops iteration.
///
/// # Errors
///
/// Returns an error if the document bytes are malformed (too short, invalid
/// element type, truncated field name or value).
pub fn scan_document<'a, F>(doc_bytes: &'a [u8], mut visitor: F) -> Result<()>
where
    F: FnMut(RawField<'a>) -> Result<()>,
{
    if doc_bytes.len() < 5 {
        return Err(DocumentDBError::bad_value(
            "BSON document too short".to_owned(),
        ));
    }

    let doc_size = i32::from_le_bytes([doc_bytes[0], doc_bytes[1], doc_bytes[2], doc_bytes[3]]);
    let doc_size = usize::try_from(doc_size)
        .map_err(|e| DocumentDBError::bad_value(format!("BSON document size is negative: {e}")))?;

    if doc_size > doc_bytes.len() || doc_size < 5 {
        return Err(DocumentDBError::bad_value(format!(
            "BSON document size {doc_size} invalid for buffer of {} bytes",
            doc_bytes.len()
        )));
    }

    let mut pos = 4; // skip the document size
    let end = doc_size - 1; // last byte should be 0x00
    if doc_bytes[end] != 0 {
        return Err(DocumentDBError::bad_value(
            "BSON document missing null terminator".to_owned(),
        ));
    }

    while pos < end {
        // Read element type
        let et = doc_bytes[pos];
        if et == 0x00 {
            return Err(DocumentDBError::bad_value(
                "BSON document contains an early null terminator".to_owned(),
            ));
        }
        pos += 1;

        // Read field name (cstring: bytes until 0x00)
        let name_start = pos;
        let name_end = doc_bytes[pos..end]
            .iter()
            .position(|&b| b == 0)
            .ok_or_else(|| {
                DocumentDBError::bad_value("Unterminated field name in BSON document".to_owned())
            })?
            + pos;

        let name = &doc_bytes[name_start..name_end];
        pos = name_end + 1; // skip null terminator

        // Determine value length
        let val_len = value_length(et, &doc_bytes[pos..]).ok_or_else(|| {
            DocumentDBError::bad_value(format!("Unknown or truncated BSON element type 0x{et:02X}"))
        })?;

        let value_end = pos.checked_add(val_len).ok_or_else(|| {
            DocumentDBError::bad_value("BSON element value length overflow".to_owned())
        })?;
        if value_end > end {
            return Err(DocumentDBError::bad_value(
                "BSON element value extends beyond document".to_owned(),
            ));
        }

        let value = &doc_bytes[pos..value_end];
        pos = value_end;

        visitor(RawField {
            element_type: et,
            name,
            value,
        })?;
    }

    if pos != end {
        return Err(DocumentDBError::bad_value(format!(
            "BSON document scan ended at {pos}, expected {end}"
        )));
    }

    Ok(())
}

/// Extracts the first field name from a BSON document (the command name).
///
/// Returns the field name as `&str` and its element type, without scanning
/// the rest of the document.
///
/// # Errors
///
/// Returns an error if the document is malformed or empty.
pub fn first_field_name(doc_bytes: &[u8]) -> Result<(&str, u8)> {
    if doc_bytes.len() < 6 {
        return Err(DocumentDBError::bad_value(
            "BSON document too short for any element".to_owned(),
        ));
    }

    let et = doc_bytes[4];
    if et == 0x00 {
        return Err(DocumentDBError::bad_value("Empty BSON document".to_owned()));
    }

    let name_start = 5;
    let name_end = doc_bytes[name_start..]
        .iter()
        .position(|&b| b == 0)
        .ok_or_else(|| DocumentDBError::bad_value("Unterminated field name in BSON".to_owned()))?
        + name_start;

    let name = std::str::from_utf8(&doc_bytes[name_start..name_end]).map_err(|e| {
        DocumentDBError::bad_value(format!("BSON field name is not valid UTF-8: {e}"))
    })?;

    Ok((name, et))
}

#[cfg(test)]
mod tests {
    use super::*;

    use bson::rawdoc;

    fn cstring_field(element_type: u8, name: &str, value: &[u8]) -> Vec<u8> {
        let mut bytes = Vec::new();
        bytes.push(element_type);
        bytes.extend_from_slice(name.as_bytes());
        bytes.push(0);
        bytes.extend_from_slice(value);
        bytes
    }

    fn raw_document(elements: &[Vec<u8>]) -> Vec<u8> {
        let size = std::mem::size_of::<i32>() + elements.iter().map(Vec::len).sum::<usize>() + 1;
        let mut bytes = Vec::with_capacity(size);
        bytes.extend_from_slice(
            &i32::try_from(size)
                .expect("test document size should fit into i32")
                .to_le_bytes(),
        );
        for element in elements {
            bytes.extend_from_slice(element);
        }
        bytes.push(0);
        bytes
    }

    fn string_value(value: &str) -> Vec<u8> {
        let len = value.len() + 1;
        let mut bytes = Vec::with_capacity(std::mem::size_of::<i32>() + len);
        bytes.extend_from_slice(
            &i32::try_from(len)
                .expect("test string size should fit into i32")
                .to_le_bytes(),
        );
        bytes.extend_from_slice(value.as_bytes());
        bytes.push(0);
        bytes
    }

    fn db_pointer_value(namespace: &str) -> Vec<u8> {
        let mut bytes = string_value(namespace);
        bytes.extend_from_slice(&[7_u8; 12]);
        bytes
    }

    #[test]
    fn scan_simple_document() {
        let doc = rawdoc! {
            "find": "mycoll",
            "$db": "testdb",
            "maxTimeMS": 5000_i32
        };
        let bytes = doc.as_bytes();

        let mut fields = Vec::new();
        scan_document(bytes, |field| {
            fields.push((field.name_str().unwrap().to_owned(), field.element_type));
            Ok(())
        })
        .unwrap();

        assert_eq!(fields.len(), 3);
        assert_eq!(fields[0].0, "find");
        assert_eq!(fields[0].1, element_type::STRING);
        assert_eq!(fields[1].0, "$db");
        assert_eq!(fields[2].0, "maxTimeMS");
        assert_eq!(fields[2].1, element_type::INT32);
    }

    #[test]
    fn first_field_extracts_command_name() {
        let doc = rawdoc! { "aggregate": "users", "$db": "app" };
        let (name, et) = first_field_name(doc.as_bytes()).unwrap();
        assert_eq!(name, "aggregate");
        assert_eq!(et, element_type::STRING);
    }

    #[test]
    fn field_value_accessors() {
        let doc = rawdoc! {
            "cmd": "test",
            "flag": true,
            "count": 42_i32,
            "big": 123_456_789_i64,
            "ratio": 2.5_f64,
            "$db": "mydb"
        };

        let mut found_flag = false;
        let mut found_count = false;
        let mut found_big = false;
        let mut found_ratio = false;
        let mut found_db = false;

        scan_document(doc.as_bytes(), |field| {
            match field.name_str().unwrap() {
                "flag" => {
                    assert_eq!(field.as_bool(), Some(true));
                    found_flag = true;
                }
                "count" => {
                    assert_eq!(field.as_i32(), Some(42));
                    assert_eq!(field.to_i64(), Some(42));
                    found_count = true;
                }
                "big" => {
                    assert_eq!(field.as_i64(), Some(123_456_789));
                    found_big = true;
                }
                "ratio" => {
                    assert!(field.as_f64().is_some());
                    found_ratio = true;
                }
                "$db" => {
                    assert_eq!(field.as_str(), Some("mydb"));
                    found_db = true;
                }
                _ => {}
            }
            Ok(())
        })
        .unwrap();

        assert!(found_flag && found_count && found_big && found_ratio && found_db);
    }

    #[test]
    fn nested_document_extraction() {
        let doc = rawdoc! {
            "find": "coll",
            "readConcern": { "level": "majority" },
            "$db": "test"
        };

        let mut concern_bytes = None;
        scan_document(doc.as_bytes(), |field| {
            if field.name == b"readConcern" {
                concern_bytes = field.as_document_bytes().map(<[u8]>::to_vec);
            }
            Ok(())
        })
        .unwrap();

        // Re-scan the nested document
        let concern = concern_bytes.unwrap();
        let mut level = None;
        scan_document(&concern, |field| {
            if field.name == b"level" {
                level = field.as_str().map(ToOwned::to_owned);
            }
            Ok(())
        })
        .unwrap();

        assert_eq!(level.as_deref(), Some("majority"));
    }

    #[test]
    fn empty_document() {
        let doc = rawdoc! {};
        // Empty doc has no elements — first_field_name should error
        first_field_name(doc.as_bytes()).unwrap_err();
    }

    #[test]
    fn explain_flag_detected() {
        let doc = rawdoc! {
            "find": "mycoll",
            "explain": true,
            "$db": "test"
        };

        let mut is_explain = false;
        scan_document(doc.as_bytes(), |field| {
            if field.name == b"explain" {
                is_explain = field.as_bool().unwrap_or(false);
            }
            Ok(())
        })
        .unwrap();

        assert!(is_explain);
    }

    #[test]
    fn malformed_boolean_value_is_not_decoded() {
        let doc = raw_document(&[
            cstring_field(element_type::STRING, "find", &string_value("users")),
            cstring_field(element_type::BOOLEAN, "explain", &[2]),
        ]);
        let mut explain = Some(true);

        scan_document(&doc, |field| {
            if field.name == b"explain" {
                explain = field.as_bool();
            }
            Ok(())
        })
        .unwrap();

        assert_eq!(explain, None);
    }

    #[test]
    fn scanner_rejects_field_value_that_consumes_document_terminator_before_visit() {
        let mut doc = Vec::new();
        doc.extend_from_slice(&13_i32.to_le_bytes());
        doc.push(element_type::STRING);
        doc.extend_from_slice(b"x\0");
        doc.extend_from_slice(&2_i32.to_le_bytes());
        doc.push(b'a');
        doc.push(0);

        let mut visited_fields = 0;
        scan_document(&doc, |_| {
            visited_fields += 1;
            Ok(())
        })
        .unwrap_err();

        assert_eq!(visited_fields, 0);
    }

    #[test]
    fn to_i64_from_various_numeric_types() {
        let doc = rawdoc! {
            "a": 42_i32,
            "b": 123_i64,
            "c": 99.9_f64
        };

        let mut values = Vec::new();
        scan_document(doc.as_bytes(), |field| {
            if let Some(v) = field.to_i64() {
                values.push(v);
            }
            Ok(())
        })
        .unwrap();

        assert_eq!(values, vec![42, 123, 99]);
    }

    #[test]
    fn binary_field_skipped_correctly() {
        let doc = rawdoc! {
            "cmd": "test",
            "data": bson::Binary { subtype: bson::spec::BinarySubtype::Generic, bytes: vec![1, 2, 3] },
            "$db": "mydb"
        };

        let mut field_names = Vec::new();
        scan_document(doc.as_bytes(), |field| {
            field_names.push(field.name_str().unwrap().to_owned());
            Ok(())
        })
        .unwrap();

        assert_eq!(field_names, vec!["cmd", "data", "$db"]);
    }

    #[test]
    fn scanner_skips_symbol_and_db_pointer_fields() {
        let document = raw_document(&[
            cstring_field(element_type::STRING, "find", &string_value("users")),
            cstring_field(0x0E, "symbol", &string_value("ignored")),
            cstring_field(0x0C, "dbPointer", &db_pointer_value("legacy.ns")),
            cstring_field(element_type::STRING, "$db", &string_value("mydb")),
        ]);

        let mut field_names = Vec::new();
        scan_document(&document, |field| {
            field_names.push(field.name_str().unwrap().to_owned());
            Ok(())
        })
        .unwrap();

        assert_eq!(field_names, vec!["find", "symbol", "dbPointer", "$db"]);
    }

    #[test]
    fn value_length_rejects_truncated_binary() {
        let truncated_binary = [3, 0, 0, 0, 0, 1, 2];

        assert_eq!(value_length(element_type::BINARY, &truncated_binary), None);
    }

    #[test]
    fn value_length_rejects_truncated_code_with_scope() {
        let truncated_code_with_scope = [20, 0, 0, 0, 1, 0, 0, 0, 0];

        assert_eq!(value_length(0x0F, &truncated_code_with_scope), None);
    }

    #[test]
    fn scanner_rejects_string_without_null_terminator() {
        let mut invalid_string = Vec::new();
        invalid_string.extend_from_slice(&4_i32.to_le_bytes());
        invalid_string.extend_from_slice(b"abcx");
        let document =
            raw_document(&[cstring_field(element_type::STRING, "find", &invalid_string)]);

        scan_document(&document, |_| Ok(())).unwrap_err();
    }

    #[test]
    fn scanner_rejects_document_without_null_terminator() {
        let mut document = raw_document(&[cstring_field(
            element_type::STRING,
            "find",
            &string_value("users"),
        )]);
        let last = document.len() - 1;
        document[last] = 1;

        scan_document(&document, |_| Ok(())).unwrap_err();
    }

    #[test]
    fn scanner_rejects_nested_document_without_null_terminator() {
        let mut nested = raw_document(&[cstring_field(
            element_type::STRING,
            "level",
            &string_value("majority"),
        )]);
        let last = nested.len() - 1;
        nested[last] = 1;
        let document = raw_document(&[cstring_field(
            element_type::DOCUMENT,
            "readConcern",
            &nested,
        )]);

        scan_document(&document, |_| Ok(())).unwrap_err();
    }

    #[test]
    fn scanner_rejects_early_document_null_terminator() {
        let document = vec![7, 0, 0, 0, 0, 1, 0];

        scan_document(&document, |_| Ok(())).unwrap_err();
    }
}
