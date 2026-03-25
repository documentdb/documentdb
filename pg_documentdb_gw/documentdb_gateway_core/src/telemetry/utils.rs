/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/utils.rs
 *
 *-------------------------------------------------------------------------
 */

use crate::{error::ErrorCode, responses::CommandError};

// In case of no error (success), error_code passed here should be None and status code returned is 200
#[must_use]
const fn error_code_to_status_code(error_code: Option<&ErrorCode>) -> u16 {
    match error_code {
        None => 200,
        Some(code) => match code {
            ErrorCode::AuthenticationFailed | ErrorCode::Unauthorized => 401,
            ErrorCode::InternalError => 500,
            ErrorCode::ExceededTimeLimit => 408,
            ErrorCode::DuplicateKey => 409,
            _ => 400,
        },
    }
}

/// Converts an optional `CommandError` reference to its corresponding error code as an i32.
/// If the `CommandError` is None, returns 0 to indicate no error.
#[must_use]
pub const fn get_error_code_i32(error: Option<&CommandError>) -> i32 {
    match error {
        None => 0,
        Some(e) => *e.code() as i32,
    }
}

/// Converts an optional `CommandError` reference to its corresponding HTTP status code as a u16.
/// If the `CommandError` is None, returns 200 to indicate success.
#[must_use]
pub const fn get_status_code_u16(error: Option<&CommandError>) -> u16 {
    match error {
        None => 200,
        Some(command_error) => error_code_to_status_code(Some(command_error.code())),
    }
}
