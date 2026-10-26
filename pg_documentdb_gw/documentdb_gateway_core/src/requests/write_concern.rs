/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/write_concern.rs
 *
 *-------------------------------------------------------------------------
 */

//! Validation of the `writeConcern` command field and its sub-fields.
//!
//! Enforces the wire-protocol semantics asserted by the compatibility tests:
//! the field must be a document (or null), and the `w`, `wtimeout`, `j`, and
//! `provenance` sub-fields are type- and range-checked. Unknown sub-fields are
//! rejected. The value is validated but not retained: this deployment behaves as
//! a standalone node, so any acknowledgement stronger than `w: 1` is rejected at
//! validation time and there is nothing further to apply downstream.

use crate::{
    error::{DocumentDBError, ErrorCode, Result},
    protocol::bson_scanner::{self, RawField},
};

/// BSON element type bytes needed for writeConcern sub-field validation.
mod element_type {
    pub const DOUBLE: u8 = 0x01;
    pub const DOCUMENT: u8 = 0x03;
    pub const BOOLEAN: u8 = 0x08;
    pub const NULL: u8 = 0x0A;
    pub const INT32: u8 = 0x10;
    pub const INT64: u8 = 0x12;
    pub const DECIMAL128: u8 = 0x13;
}

/// The largest `w` value this deployment parses before returning `FailedToParse`.
const MAX_W: i64 = 50;

/// The largest `wtimeout` value this deployment parses before returning
/// `FailedToParse` (a signed 32-bit millisecond count).
const MAX_WTIMEOUT: i64 = i32::MAX as i64;

/// Valid `provenance` values for the writeConcern document.
const VALID_PROVENANCE: [&str; 4] = [
    "clientSupplied",
    "implicitDefault",
    "customDefault",
    "getLastErrorDefaults",
];

/// Validates a `writeConcern` document and its sub-fields.
///
/// The document is accepted when every sub-field is well-formed. A `w` value of
/// `0` or `1` is accepted; any stronger acknowledgement is rejected because this
/// deployment is a standalone node.
///
/// # Errors
/// Returns a [`DocumentDBError`] with the wire-protocol-compatible error code
/// when the document or any sub-field violates the rules:
/// - `w`: numeric outside `[0, 50]`, `NaN`, or `±Inf` -> `FailedToParse`; numeric
///   `2..=50`, an unknown string tag, or null -> `BadValue`; a bool or array, or
///   a malformed tag-set object -> `FailedToParse`.
/// - `wtimeout`: numeric greater than `i32::MAX` -> `FailedToParse`; non-numeric
///   values are ignored.
/// - `j`: non-boolean, non-numeric, non-null -> `TypeMismatch`.
/// - `provenance`: non-string -> `TypeMismatch`; unknown value -> `BadValue`.
/// - any other sub-field -> `UnknownBsonField`.
pub fn validate(field: &RawField<'_>) -> Result<()> {
    if field.element_type() == element_type::NULL {
        return Ok(());
    }

    let doc_bytes = field.as_embedded_document_bytes().ok_or_else(|| {
        DocumentDBError::type_mismatch(format!(
            "writeConcern must be a document but got element type 0x{:02X}",
            field.element_type()
        ))
    })?;

    bson_scanner::scan_document(doc_bytes, |sub_field| match sub_field.name() {
        b"w" => validate_w(&sub_field),
        b"wtimeout" => validate_wtimeout(&sub_field),
        b"j" | b"fsync" => validate_flag(&sub_field, sub_field.name()),
        b"provenance" => validate_provenance(&sub_field),
        // Legacy write-acknowledgement echo fields. A client may round-trip a
        // prior acknowledgement document back as writeConcern, so these are
        // tolerated without further inspection for wire-protocol compatibility.
        b"wElectionId" | b"wOpTime" | b"getLastError" => Ok(()),
        other => {
            let name = String::from_utf8_lossy(other);
            Err(DocumentDBError::documentdb_error(
                ErrorCode::UnknownBsonField,
                format!("BSON field 'writeConcern.{name}' is an unknown field"),
            ))
        }
    })
}

/// Validates the `w` sub-field (numeric acknowledgement count, string tag, or
/// tag-set document).
fn validate_w(field: &RawField<'_>) -> Result<()> {
    match field.element_type() {
        element_type::INT32 | element_type::INT64 | element_type::DOUBLE => {
            let value = numeric_to_integer(field).ok_or_else(w_out_of_range)?;
            check_w_range(value)
        }
        element_type::DECIMAL128 => {
            let value = decimal128_to_integer(field.value()).ok_or_else(w_out_of_range)?;
            check_w_range(value)
        }
        // A string is a replica-set tag name. This standalone deployment defines
        // no tags, so only the special "majority" tag is accepted.
        0x02 => {
            let tag = field.as_str().ok_or_else(w_out_of_range)?;
            if tag == "majority" {
                Ok(())
            } else {
                Err(DocumentDBError::bad_value(format!(
                    "Unknown writeConcern w tag: '{tag}'"
                )))
            }
        }
        // A document is a custom tag set: every value must be numeric and it must
        // not be empty. This standalone deployment cannot satisfy a tag set, but
        // the shape is still validated.
        element_type::DOCUMENT => {
            let tag_bytes = field
                .as_embedded_document_bytes()
                .ok_or_else(w_out_of_range)?;
            let mut count = 0_u32;
            bson_scanner::scan_document(tag_bytes, |tag_field| {
                count += 1;
                if tag_field.is_numeric() {
                    Ok(())
                } else {
                    Err(w_out_of_range())
                }
            })?;
            if count == 0 {
                return Err(w_out_of_range());
            }
            Ok(())
        }
        // Null coerces to an empty string tag, which is not a recognized tag.
        element_type::NULL => Err(DocumentDBError::bad_value(
            "writeConcern w cannot be an empty string".to_owned(),
        )),
        _ => Err(w_out_of_range()),
    }
}

/// Rejects a `w` acknowledgement count that this standalone deployment cannot
/// satisfy. `0` and `1` are accepted; `2..=50` parse but are unsatisfiable.
fn check_w_range(value: i64) -> Result<()> {
    if !(0..=MAX_W).contains(&value) {
        return Err(w_out_of_range());
    }
    if value > 1 {
        return Err(DocumentDBError::bad_value(format!(
            "w value {value} exceeds the number of data-bearing voting members"
        )));
    }
    Ok(())
}

/// Validates the `wtimeout` sub-field: numeric values must not exceed
/// `i32::MAX`; non-numeric values are ignored.
///
/// The comparison follows the documented numeric semantics: `NaN` and any
/// negative value (including negative infinity) are never greater than the
/// maximum and are accepted. Only a value strictly greater than `i32::MAX`,
/// including positive infinity, is rejected.
fn validate_wtimeout(field: &RawField<'_>) -> Result<()> {
    if wtimeout_exceeds_max(field) {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::FailedToParse,
            "writeConcern wtimeout must not exceed the maximum 32-bit integer".to_owned(),
        ));
    }
    Ok(())
}

/// Returns whether a numeric `wtimeout` value is strictly greater than
/// `i32::MAX`. `NaN` and negative values (including negative infinity) are not
/// greater and return `false`; non-numeric values are ignored and return
/// `false`.
fn wtimeout_exceeds_max(field: &RawField<'_>) -> bool {
    match field.element_type() {
        element_type::INT32 => field.as_i32().is_some_and(|v| i64::from(v) > MAX_WTIMEOUT),
        element_type::INT64 => field.as_i64().is_some_and(|v| v > MAX_WTIMEOUT),
        element_type::DOUBLE => field.as_f64().is_some_and(|v| v > f64::from(i32::MAX)),
        element_type::DECIMAL128 => decimal128_exceeds_max(field.value()),
        _ => false,
    }
}

/// Returns whether a Decimal128 `wtimeout` value is strictly greater than
/// `i32::MAX`. `NaN` and negative values (including negative infinity) return
/// `false`; positive infinity and any positive value strictly above the maximum
/// (including a fractional value just above it) return `true`.
fn decimal128_exceeds_max(bytes: &[u8]) -> bool {
    let Some(raw): Option<[u8; 16]> = bytes.get(0..16).and_then(|slice| slice.try_into().ok())
    else {
        return false;
    };
    let text = bson::Decimal128::from_bytes(raw).to_string();

    // "Infinity" contains an 'n', so the infinity check must precede the NaN
    // check. Only positive infinity exceeds the maximum.
    if text.contains(['I', 'i']) {
        return !text.starts_with('-');
    }
    if text.contains(['N', 'n']) {
        return false;
    }
    if text.starts_with('-') {
        return false;
    }

    // A positive finite value strictly greater than the maximum is rejected;
    // the comparison is exact, so a fractional value just above the maximum is
    // not rounded down into range.
    match parse_decimal_string(&text) {
        Some((coefficient, exponent, _sign)) => decimal_positive_exceeds_max(coefficient, exponent),
        None => true,
    }
}

/// Returns whether a non-negative decimal value `coefficient * 10^exponent` is
/// strictly greater than [`MAX_WTIMEOUT`]. The comparison is exact: no rounding
/// or truncation is applied, so a fractional value just above the maximum is
/// still rejected.
fn decimal_positive_exceeds_max(coefficient: i128, exponent: i32) -> bool {
    let max = i128::from(MAX_WTIMEOUT);

    if exponent >= 0 {
        let mut value = coefficient;
        for _ in 0..exponent {
            match value.checked_mul(10) {
                Some(scaled) => value = scaled,
                // Overflowing `i128` means the value dwarfs the maximum.
                None => return true,
            }
            if value > max {
                return true;
            }
        }
        value > max
    } else {
        // value = coefficient / 10^n, so value > max <=> coefficient > max * 10^n.
        let n = exponent.unsigned_abs();
        let mut threshold = max;
        for _ in 0..n {
            match threshold.checked_mul(10) {
                Some(scaled) => threshold = scaled,
                // The threshold exceeds every representable coefficient, so the
                // value cannot be greater than the maximum.
                None => return false,
            }
        }
        coefficient > threshold
    }
}

/// Validates a boolean-style flag sub-field (`j` or `fsync`): booleans, numbers,
/// and null are accepted; any other type is a type mismatch.
fn validate_flag(field: &RawField<'_>, name: &[u8]) -> Result<()> {
    match field.element_type() {
        element_type::BOOLEAN
        | element_type::INT32
        | element_type::INT64
        | element_type::DOUBLE
        | element_type::DECIMAL128
        | element_type::NULL => Ok(()),
        other => {
            let name = String::from_utf8_lossy(name);
            Err(DocumentDBError::type_mismatch(format!(
                "writeConcern.{name} must be a boolean or number but got element type 0x{other:02X}"
            )))
        }
    }
}

/// Validates the `provenance` sub-field: it must be a string drawn from the
/// recognized set.
fn validate_provenance(field: &RawField<'_>) -> Result<()> {
    if field.element_type() == element_type::NULL {
        return Ok(());
    }

    let provenance = field.as_str().ok_or_else(|| {
        DocumentDBError::type_mismatch(format!(
            "writeConcern.provenance must be a string but got element type 0x{:02X}",
            field.element_type()
        ))
    })?;

    if VALID_PROVENANCE.contains(&provenance) {
        Ok(())
    } else {
        Err(DocumentDBError::bad_value(format!(
            "Invalid writeConcern provenance: '{provenance}'"
        )))
    }
}

/// Builds the `FailedToParse` error used when `w` is out of range or malformed.
fn w_out_of_range() -> DocumentDBError {
    DocumentDBError::documentdb_error(
        ErrorCode::FailedToParse,
        "writeConcern w must be a non-negative integer, 'majority', or a tag set".to_owned(),
    )
}

/// Converts an int32/int64/double numeric field to an integer, truncating a
/// double toward zero. Returns `None` for `NaN`, `±Inf`, or a value outside the
/// `i64` range so the caller can reject it.
fn numeric_to_integer(field: &RawField<'_>) -> Option<i64> {
    match field.element_type() {
        element_type::INT32 => field.as_i32().map(i64::from),
        element_type::INT64 => field.as_i64(),
        element_type::DOUBLE => {
            let value = field.as_f64()?;
            #[expect(
                clippy::cast_possible_truncation,
                reason = "value is finite and within i64 range; truncation toward zero is intended"
            )]
            (value.is_finite() && value.abs() < 9_223_372_036_854_775_808.0)
                .then(|| value.trunc() as i64)
        }
        _ => None,
    }
}

/// Converts a BSON Decimal128 value (16 little-endian bytes) to an integer.
///
/// Returns `None` for `NaN`, `±Inf`, or a magnitude outside the `i64` range, so
/// the caller rejects it. A fractional value is rounded to the nearest integer
/// using the decimal round-half-to-even rule used by the wire protocol.
fn decimal128_to_integer(bytes: &[u8]) -> Option<i64> {
    let raw: [u8; 16] = bytes.get(0..16)?.try_into().ok()?;
    let text = bson::Decimal128::from_bytes(raw).to_string();
    let (coefficient, exponent, sign) = parse_decimal_string(&text)?;
    round_decimal_to_integer(coefficient, exponent, sign)
}

/// Parses the canonical Decimal128 string produced by [`bson::Decimal128`] into a
/// `(coefficient, exponent, sign)` triple such that the value equals
/// `(-1)^sign * coefficient * 10^exponent`.
///
/// Returns `None` for the non-finite forms (`NaN`, `Infinity`).
fn parse_decimal_string(text: &str) -> Option<(i128, i32, bool)> {
    if text.contains(['N', 'n']) || text.contains(['I', 'i']) {
        // Rejects NaN and Infinity in either sign/case.
        return None;
    }

    let sign = text.starts_with('-');
    let unsigned = text.trim_start_matches(['+', '-']);

    let (mantissa, exp10) = match unsigned.split_once(['E', 'e']) {
        Some((mantissa, exp)) => (mantissa, exp.parse::<i32>().ok()?),
        None => (unsigned, 0),
    };

    let (digits, fraction_len) = match mantissa.split_once('.') {
        Some((int_part, frac_part)) => {
            let combined = format!("{int_part}{frac_part}");
            (combined, i32::try_from(frac_part.len()).ok()?)
        }
        None => (mantissa.to_owned(), 0),
    };

    let coefficient = digits.parse::<i128>().ok()?;
    Some((coefficient, exp10 - fraction_len, sign))
}

/// Applies the decimal exponent to a coefficient and rounds half-to-even to the
/// nearest integer. Returns `None` on `i64` overflow.
fn round_decimal_to_integer(coefficient: i128, exponent: i32, sign: bool) -> Option<i64> {
    let mut magnitude = coefficient;

    // A zero coefficient is zero at any exponent. Returning early avoids
    // iterating over the exponent magnitude, which a valid Decimal128 allows to
    // be as extreme as +6111 or -6176.
    if magnitude == 0 {
        return Some(0);
    }

    if exponent >= 0 {
        for _ in 0..exponent {
            magnitude = magnitude.checked_mul(10)?;
        }
    } else {
        // Dropping `n` fractional digits with repeated `% 10` yields the digits
        // from least to most significant, so the rounding digit (the most
        // significant dropped digit) is the one dropped on the final step; every
        // earlier dropped digit is less significant and only affects the
        // half-way tie-break.
        let n = -exponent;
        let mut round_digit = 0_i128;
        let mut rest_nonzero = false;
        for step in 0..n {
            let digit = magnitude % 10;
            magnitude /= 10;
            if step == n - 1 {
                round_digit = digit;
            } else if digit != 0 {
                rest_nonzero = true;
            }
            // Once the magnitude reaches zero every remaining dropped digit is
            // zero, so the rounding digit at step `n - 1` is zero and the result
            // is zero. Stopping here bounds the loop to the coefficient's digit
            // count (at most 39) instead of the exponent magnitude, which can be
            // as large as 6176 and, across duplicate fields, amplify into an
            // unbounded amount of work on an untrusted command.
            if magnitude == 0 {
                break;
            }
        }

        let round_up =
            round_digit > 5 || (round_digit == 5 && (rest_nonzero || magnitude % 2 == 1));
        if round_up {
            magnitude = magnitude.checked_add(1)?;
        }
    }

    let signed = if sign { -magnitude } else { magnitude };
    i64::try_from(signed).ok()
}

#[cfg(test)]
mod tests {
    use bson::{rawdoc, Decimal128, RawDocumentBuf};

    use super::*;

    /// Runs [`validate`] against the `writeConcern` field of a command document.
    fn validate_wc(doc: &RawDocumentBuf) -> Result<()> {
        let mut result = Ok(());
        bson_scanner::scan_document(doc.as_bytes(), |field| {
            if field.name() == b"writeConcern" {
                result = validate(&field);
            }
            Ok(())
        })?;
        result
    }

    fn dec(value: &str) -> Decimal128 {
        value.parse().expect("valid decimal128")
    }

    fn expect_ok(doc: &RawDocumentBuf) {
        validate_wc(doc).expect("writeConcern should be accepted");
    }

    fn expect_code(doc: &RawDocumentBuf, code: ErrorCode) {
        assert_eq!(validate_wc(doc).unwrap_err().error_code(), code);
    }

    #[test]
    fn accepts_null_empty_and_basic_values() {
        expect_ok(&rawdoc! { "writeConcern": null });
        expect_ok(&rawdoc! { "writeConcern": {} });
        expect_ok(&rawdoc! { "writeConcern": { "w": 0_i32 } });
        expect_ok(&rawdoc! { "writeConcern": { "w": 1_i32 } });
        expect_ok(&rawdoc! { "writeConcern": { "w": 1_i64 } });
        expect_ok(&rawdoc! { "writeConcern": { "w": 1.0_f64 } });
        expect_ok(&rawdoc! { "writeConcern": { "w": "majority" } });
        expect_ok(&rawdoc! { "writeConcern": { "w": { "dc1": 1_i32 } } });
    }

    #[test]
    fn rejects_non_document_with_type_mismatch() {
        expect_code(
            &rawdoc! { "writeConcern": "majority" },
            ErrorCode::TypeMismatch,
        );
        expect_code(&rawdoc! { "writeConcern": 42_i32 }, ErrorCode::TypeMismatch);
        expect_code(
            &rawdoc! { "writeConcern": [1_i32, 2_i32] },
            ErrorCode::TypeMismatch,
        );
        expect_code(&rawdoc! { "writeConcern": true }, ErrorCode::TypeMismatch);
        expect_code(
            &rawdoc! { "writeConcern": 2.5_f64 },
            ErrorCode::TypeMismatch,
        );
    }

    #[test]
    fn w_numeric_range_rules() {
        // 0 and 1 accepted; 2..=50 parse but are unsatisfiable on a standalone.
        expect_code(
            &rawdoc! { "writeConcern": { "w": 2_i32 } },
            ErrorCode::BadValue,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": 50_i32 } },
            ErrorCode::BadValue,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": 50.99_f64 } },
            ErrorCode::BadValue,
        );
        // Out of the parse range or non-integral special values.
        expect_code(
            &rawdoc! { "writeConcern": { "w": -1_i32 } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": 51_i32 } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": i64::MAX } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": f64::NAN } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": f64::INFINITY } },
            ErrorCode::FailedToParse,
        );
    }

    #[test]
    fn w_non_numeric_rules() {
        expect_code(
            &rawdoc! { "writeConcern": { "w": "Majority" } },
            ErrorCode::BadValue,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": "" } },
            ErrorCode::BadValue,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": null } },
            ErrorCode::BadValue,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": true } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": [1_i32] } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": {} } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": { "dc1": "hello" } } },
            ErrorCode::FailedToParse,
        );
    }

    #[test]
    fn w_decimal128_rounding() {
        expect_ok(&rawdoc! { "writeConcern": { "w": dec("0") } });
        expect_ok(&rawdoc! { "writeConcern": { "w": dec("1") } });
        // 0.5 rounds half-to-even to 0 (accepted); 1.5 rounds to 2, 50.5 to 50.
        expect_ok(&rawdoc! { "writeConcern": { "w": dec("0.5") } });
        expect_code(
            &rawdoc! { "writeConcern": { "w": dec("1.5") } },
            ErrorCode::BadValue,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": dec("50.5") } },
            ErrorCode::BadValue,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": dec("NaN") } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": dec("Infinity") } },
            ErrorCode::FailedToParse,
        );
    }

    #[test]
    fn w_decimal128_extreme_exponent_is_bounded() {
        // A minimum-exponent nonzero coefficient underflows to zero after a
        // single division, so the rounding loop must stop early instead of
        // iterating over the full 6176-step exponent magnitude.
        expect_ok(&rawdoc! { "writeConcern": { "w": dec("1E-6176") } });
        // A zero coefficient at the maximum positive exponent is zero without
        // scaling 6111 times.
        expect_ok(&rawdoc! { "writeConcern": { "w": dec("0E+6111") } });
        // A nonzero coefficient at a large positive exponent exceeds the integer
        // range and is rejected without looping over the full exponent.
        expect_code(
            &rawdoc! { "writeConcern": { "w": dec("1E6111") } },
            ErrorCode::FailedToParse,
        );
    }

    #[test]
    fn w_repeated_decimal128_fields_are_bounded() {
        // Duplicate `w` keys are each validated independently; extreme exponents
        // on every occurrence must not amplify into unbounded work.
        let mut inner = RawDocumentBuf::new();
        inner.append("w", dec("1E-6176"));
        inner.append("w", dec("1E-6176"));
        let mut doc = RawDocumentBuf::new();
        doc.append("writeConcern", inner);
        expect_ok(&doc);
    }

    #[test]
    fn wtimeout_rules() {
        expect_ok(&rawdoc! { "writeConcern": { "w": 1_i32, "wtimeout": 0_i32 } });
        expect_ok(&rawdoc! { "writeConcern": { "wtimeout": -1_i32 } });
        expect_ok(&rawdoc! { "writeConcern": { "wtimeout": i32::MAX } });
        // NaN and negative values (including negative infinity) are accepted
        // because they are never greater than the maximum.
        expect_ok(&rawdoc! { "writeConcern": { "wtimeout": f64::NAN } });
        expect_ok(&rawdoc! { "writeConcern": { "wtimeout": f64::NEG_INFINITY } });
        expect_ok(&rawdoc! { "writeConcern": { "wtimeout": -5.0e30_f64 } });
        expect_ok(
            &rawdoc! { "writeConcern": { "wtimeout": "NaN".parse::<Decimal128>().unwrap() } },
        );
        expect_ok(
            &rawdoc! { "writeConcern": { "wtimeout": "-Infinity".parse::<Decimal128>().unwrap() } },
        );
        expect_ok(
            &rawdoc! { "writeConcern": { "wtimeout": "-1E40".parse::<Decimal128>().unwrap() } },
        );
        // A positive value at or below the maximum is accepted, including a
        // fractional value just under it.
        expect_ok(
            &rawdoc! { "writeConcern": { "wtimeout": "2147483646.9".parse::<Decimal128>().unwrap() } },
        );
        // Non-numeric wtimeout is silently accepted.
        expect_ok(&rawdoc! { "writeConcern": { "wtimeout": "hello" } });
        expect_ok(&rawdoc! { "writeConcern": { "wtimeout": true } });
        // Numeric wtimeout above i32::MAX is rejected.
        expect_code(
            &rawdoc! { "writeConcern": { "wtimeout": i64::from(i32::MAX) + 1 } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "wtimeout": f64::INFINITY } },
            ErrorCode::FailedToParse,
        );
        // Positive infinity and a positive magnitude beyond the maximum are
        // rejected for Decimal128 as well.
        expect_code(
            &rawdoc! { "writeConcern": { "wtimeout": "Infinity".parse::<Decimal128>().unwrap() } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "wtimeout": "1E40".parse::<Decimal128>().unwrap() } },
            ErrorCode::FailedToParse,
        );
        // A fractional value just above the maximum is rejected: the comparison
        // is exact and is not rounded down into range.
        expect_code(
            &rawdoc! { "writeConcern": { "wtimeout": "2147483647.4".parse::<Decimal128>().unwrap() } },
            ErrorCode::FailedToParse,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "wtimeout": 2_147_483_647.4_f64 } },
            ErrorCode::FailedToParse,
        );
    }

    #[test]
    fn j_type_rules() {
        expect_ok(&rawdoc! { "writeConcern": { "j": true } });
        expect_ok(&rawdoc! { "writeConcern": { "j": false } });
        expect_ok(&rawdoc! { "writeConcern": { "j": 1_i32 } });
        expect_ok(&rawdoc! { "writeConcern": { "j": 1_i64 } });
        expect_ok(&rawdoc! { "writeConcern": { "j": 1.0_f64 } });
        expect_ok(&rawdoc! { "writeConcern": { "j": null } });
        expect_code(
            &rawdoc! { "writeConcern": { "j": "true" } },
            ErrorCode::TypeMismatch,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "j": [1_i32] } },
            ErrorCode::TypeMismatch,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "j": { "a": 1_i32 } } },
            ErrorCode::TypeMismatch,
        );
    }

    #[test]
    fn provenance_rules() {
        expect_ok(&rawdoc! { "writeConcern": { "w": 1_i32, "provenance": "clientSupplied" } });
        expect_code(
            &rawdoc! { "writeConcern": { "w": 1_i32, "provenance": "invalid" } },
            ErrorCode::BadValue,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "w": 1_i32, "provenance": 42_i32 } },
            ErrorCode::TypeMismatch,
        );
    }

    #[test]
    fn unknown_sub_fields_are_rejected() {
        expect_code(
            &rawdoc! { "writeConcern": { "unknownField": 1_i32 } },
            ErrorCode::UnknownBsonField,
        );
        // Case-sensitive: uppercase variants are unknown.
        expect_code(
            &rawdoc! { "writeConcern": { "W": 1_i32 } },
            ErrorCode::UnknownBsonField,
        );
        expect_code(
            &rawdoc! { "writeConcern": { "Wtimeout": 1000_i32 } },
            ErrorCode::UnknownBsonField,
        );
    }
}
