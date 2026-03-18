/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/constant.rs
 *
 *-------------------------------------------------------------------------
 */

use std::fmt::Display;

#[must_use]
pub fn value_access_error_message() -> String {
    "Value Access Error.".to_owned()
}

#[must_use]
pub fn documentdb_error_message() -> String {
    "DocumentDB error.".to_owned()
}

pub fn pg_returned_invalid_response_message<E: Display>(error: E) -> String {
    format!("PG returned invalid response: {error}.")
}

#[must_use]
pub const fn duplicate_key_violation_message() -> &'static str {
    "Duplicate key violation on the requested collection."
}

#[must_use]
pub const fn generic_internal_error_message() -> &'static str {
    "An unexpected internal error has occurred."
}
