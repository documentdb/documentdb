/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/requests/read_concern.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::{
    error::{DocumentDBError, ErrorCode, Result},
    protocol::bson_scanner::{self, RawField},
};

/// BSON element type bytes needed for readConcern sub-field validation.
mod element_type {
    pub const NULL: u8 = 0x0A;
    pub const TIMESTAMP: u8 = 0x11;
}

/// Valid `provenance` values for the readConcern document.
const VALID_PROVENANCE: [&str; 4] = [
    "clientSupplied",
    "implicitDefault",
    "customDefault",
    "getLastErrorDefaults",
];

#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub enum ReadConcern {
    /// Read concern is not specified.
    #[default]
    Unspecified,

    /// Read data as defined on the node, account for Mongo chunk migration
    /// in Mongo sharded cluster. Same as Available for unsharded clusters.
    Local,

    /// Read data as defined on the node.
    Available,

    /// Read with majority quorum.  
    Majority,

    /// Read with majority quorum such that all writes before time T are
    /// readable before the start of the operation.
    Linearizable,

    /// Read snapshot of data.
    Snapshot,
}

impl ReadConcern {
    /// Strictly parses a readConcern `level` value. The match is case-sensitive
    /// and rejects unknown or empty values, matching the wire-protocol behavior
    /// asserted by the compatibility tests.
    fn from_level_str(s: &str) -> Option<Self> {
        match s {
            "local" => Some(Self::Local),
            "available" => Some(Self::Available),
            "majority" => Some(Self::Majority),
            "linearizable" => Some(Self::Linearizable),
            "snapshot" => Some(Self::Snapshot),
            _ => None,
        }
    }
}

/// Validates a readConcern document and extracts its `level`.
///
/// Enforces the wire-protocol semantics for the readConcern field and its
/// sub-fields (`level`, `afterClusterTime`, `atClusterTime`, `provenance`):
///
/// - `level`: non-string (non-null) → `TypeMismatch`; empty/unknown/wrong-case →
///   `BadValue`.
/// - `afterClusterTime`: non-Timestamp (incl. null) → `TypeMismatch`; the zero
///   timestamp → `InvalidOptions`; any valid non-zero timestamp →
///   `IllegalOperation` (not supported on a non-replica-set deployment).
/// - `atClusterTime`: non-Timestamp (incl. null) → `TypeMismatch`; any valid
///   timestamp → `InvalidOptions`.
/// - `provenance`: non-string (non-null) → `TypeMismatch`; unknown value →
///   `BadValue`.
/// - any other sub-field → `UnknownBsonField`.
///
/// A `null` value for `level` or `provenance` is accepted and treated as unset.
///
/// # Errors
/// Returns a [`DocumentDBError`] with the appropriate error code when any
/// sub-field violates the rules above.
pub fn validate_and_extract_level(doc_bytes: &[u8]) -> Result<ReadConcern> {
    let mut level = ReadConcern::Unspecified;

    bson_scanner::scan_document(doc_bytes, |field| {
        match field.name() {
            b"level" => {
                if field.element_type() == element_type::NULL {
                    return Ok(());
                }

                let level_str = field.as_str().ok_or_else(|| {
                    DocumentDBError::type_mismatch(format!(
                        "readConcern.level must be a string but got element type 0x{:02X}",
                        field.element_type()
                    ))
                })?;

                level = ReadConcern::from_level_str(level_str).ok_or_else(|| {
                    DocumentDBError::bad_value(format!("Invalid readConcern level: '{level_str}'"))
                })?;
            }
            b"afterClusterTime" => {
                validate_cluster_time(&field, false)?;
            }
            b"atClusterTime" => {
                validate_cluster_time(&field, true)?;
            }
            b"provenance" => {
                if field.element_type() == element_type::NULL {
                    return Ok(());
                }

                let provenance = field.as_str().ok_or_else(|| {
                    DocumentDBError::type_mismatch(format!(
                        "readConcern.provenance must be a string but got element type 0x{:02X}",
                        field.element_type()
                    ))
                })?;

                if !VALID_PROVENANCE.contains(&provenance) {
                    return Err(DocumentDBError::bad_value(format!(
                        "Invalid readConcern provenance: '{provenance}'"
                    )));
                }
            }
            other => {
                let name = String::from_utf8_lossy(other);
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::UnknownBsonField,
                    format!("BSON field 'readConcern.{name}' is an unknown field"),
                ));
            }
        }

        Ok(())
    })?;

    Ok(level)
}

/// Validates an `afterClusterTime` / `atClusterTime` sub-field of readConcern.
///
/// `is_at_cluster_time` selects the `atClusterTime` rules (any valid timestamp is
/// rejected with `InvalidOptions`) versus the `afterClusterTime` rules (the zero
/// timestamp yields `InvalidOptions`, any other valid timestamp yields
/// `IllegalOperation`).
fn validate_cluster_time(field: &RawField<'_>, is_at_cluster_time: bool) -> Result<()> {
    let field_name = if is_at_cluster_time {
        "atClusterTime"
    } else {
        "afterClusterTime"
    };

    if field.element_type() != element_type::TIMESTAMP {
        return Err(DocumentDBError::type_mismatch(format!(
            "readConcern.{field_name} must be a timestamp but got element type 0x{:02X}",
            field.element_type()
        )));
    }

    let is_zero = field.value().iter().all(|&b| b == 0);

    if is_at_cluster_time || is_zero {
        Err(DocumentDBError::documentdb_error(
            ErrorCode::InvalidOptions,
            format!("readConcern.{field_name} is not supported"),
        ))
    } else {
        Err(DocumentDBError::documentdb_error(
            ErrorCode::IllegalOperation,
            format!("readConcern.{field_name} is not supported on this deployment"),
        ))
    }
}

#[cfg(test)]
mod tests {
    use bson::{rawdoc, Timestamp};

    use super::*;

    fn validate(doc: &bson::RawDocumentBuf) -> Result<ReadConcern> {
        validate_and_extract_level(doc.as_bytes())
    }

    fn expect_code(doc: &bson::RawDocumentBuf, code: ErrorCode) {
        let err = validate(doc).expect_err("expected readConcern validation to fail");
        assert_eq!(err.error_code(), code);
    }

    #[test]
    fn accepts_empty_and_null_level() {
        assert_eq!(validate(&rawdoc! {}).unwrap(), ReadConcern::Unspecified);
        assert_eq!(
            validate(&rawdoc! { "level": null }).unwrap(),
            ReadConcern::Unspecified
        );
    }

    #[test]
    fn accepts_valid_levels() {
        assert_eq!(
            validate(&rawdoc! { "level": "local" }).unwrap(),
            ReadConcern::Local
        );
        assert_eq!(
            validate(&rawdoc! { "level": "available" }).unwrap(),
            ReadConcern::Available
        );
        assert_eq!(
            validate(&rawdoc! { "level": "majority" }).unwrap(),
            ReadConcern::Majority
        );
        assert_eq!(
            validate(&rawdoc! { "level": "snapshot" }).unwrap(),
            ReadConcern::Snapshot
        );
    }

    #[test]
    fn rejects_non_string_level_with_type_mismatch() {
        expect_code(&rawdoc! { "level": 123_i32 }, ErrorCode::TypeMismatch);
        expect_code(&rawdoc! { "level": 1.0_f64 }, ErrorCode::TypeMismatch);
        expect_code(&rawdoc! { "level": true }, ErrorCode::TypeMismatch);
        expect_code(&rawdoc! { "level": ["local"] }, ErrorCode::TypeMismatch);
    }

    #[test]
    fn rejects_invalid_level_value_with_bad_value() {
        expect_code(&rawdoc! { "level": "" }, ErrorCode::BadValue);
        expect_code(&rawdoc! { "level": "invalid" }, ErrorCode::BadValue);
        expect_code(&rawdoc! { "level": "Local" }, ErrorCode::BadValue);
    }

    #[test]
    fn validates_provenance() {
        assert_eq!(
            validate(&rawdoc! { "provenance": "clientSupplied" }).unwrap(),
            ReadConcern::Unspecified
        );
        assert_eq!(
            validate(&rawdoc! { "provenance": null }).unwrap(),
            ReadConcern::Unspecified
        );
        expect_code(&rawdoc! { "provenance": 1_i32 }, ErrorCode::TypeMismatch);
        expect_code(&rawdoc! { "provenance": "invalid" }, ErrorCode::BadValue);
    }

    #[test]
    fn validates_after_cluster_time() {
        expect_code(
            &rawdoc! { "afterClusterTime": 123_i32 },
            ErrorCode::TypeMismatch,
        );
        expect_code(
            &rawdoc! { "afterClusterTime": null },
            ErrorCode::TypeMismatch,
        );
        expect_code(
            &rawdoc! { "afterClusterTime": Timestamp { time: 0, increment: 0 } },
            ErrorCode::InvalidOptions,
        );
        expect_code(
            &rawdoc! { "afterClusterTime": Timestamp { time: 1, increment: 1 } },
            ErrorCode::IllegalOperation,
        );
    }

    #[test]
    fn validates_at_cluster_time() {
        expect_code(&rawdoc! { "atClusterTime": null }, ErrorCode::TypeMismatch);
        expect_code(
            &rawdoc! { "atClusterTime": Timestamp { time: 1, increment: 1 } },
            ErrorCode::InvalidOptions,
        );
        expect_code(
            &rawdoc! { "level": "snapshot", "atClusterTime": Timestamp { time: 0, increment: 0 } },
            ErrorCode::InvalidOptions,
        );
    }

    #[test]
    fn rejects_unknown_subfields() {
        expect_code(
            &rawdoc! { "unknownField": 1_i32 },
            ErrorCode::UnknownBsonField,
        );
        expect_code(&rawdoc! { "Level": "local" }, ErrorCode::UnknownBsonField);
    }
}
