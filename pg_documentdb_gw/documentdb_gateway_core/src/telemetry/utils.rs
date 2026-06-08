/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/utils.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::{error::DocumentDBError, requests::Request};

pub const NANOS_PER_MILLISECOND: u64 = 1_000_000;

/// Converts nanoseconds to milliseconds.
#[must_use]
#[inline]
pub const fn ns_to_ms(ns: u64) -> u64 {
    ns / NANOS_PER_MILLISECOND
}

/// Returns the [`DocumentDBError`] error code as an `i32`, or `0` on success.
#[must_use]
pub const fn get_error_code_i32(error: Option<&DocumentDBError>) -> i32 {
    match error {
        None => 0,
        Some(e) => e.error_code() as i32,
    }
}

/// Returns the HTTP status code for telemetry: `200` on success, or the
/// error's [`DocumentDBError::http_status_code`] on failure.
#[must_use]
pub const fn get_status_code_u16(error: Option<&DocumentDBError>) -> u16 {
    match error {
        None => 200,
        Some(e) => e.http_status_code(),
    }
}

/// Returns a safe operation name for telemetry dimensions.
///
/// If request context is missing, this returns `"unknown"`.
/// If the operation name resolves to an empty string, this returns `"<empty>"`.
#[must_use]
pub fn get_safe_operation_name(request: Option<&Request<'_>>) -> String {
    let operation_name =
        request.map_or_else(|| "unknown".to_owned(), |r| r.request_type().to_string());

    if operation_name.is_empty() {
        "<empty>".to_owned()
    } else {
        operation_name
    }
}
