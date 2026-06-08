/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/log_request_fail.rs
 *
 *-------------------------------------------------------------------------
 */

use std::backtrace::Backtrace;

use crate::{
    error::DocumentDBError,
    requests::Request,
    telemetry::{event_id::EventId, utils},
};

// Logs error with common format for all `DocumentDBError`s on request failure.
// The logged output here must be PII free and is used for telemetry and logging.
pub fn log_request_failure(
    error: &DocumentDBError,
    activity_id: &str,
    request: Option<&Request<'_>>,
) {
    let operation_name = utils::get_safe_operation_name(request);

    let error_source = error.kind();

    let db_error = error.as_db_error();
    let (error_sub_status, error_hint, error_file_name, error_file_line_num) = match db_error {
        Some(dbe) => (Some(dbe.code().code()), dbe.hint(), dbe.file(), dbe.line()),
        None => (None, None, None, None),
    };
    let error_code = error.error_code() as i32;
    let sub_status_code = error.sub_status_code();
    let backtrace: Option<&Backtrace> = Some(error.backtrace());

    tracing::error!(
        activity_id = %activity_id,
        event_id = %EventId::RequestFailure.code(),
        error_source = %error_source,
        operation_name = %operation_name,
        error_message_internal = %error.error_message_internal().unwrap_or_default(),
        error_code = %error_code,
        sub_status = %error_sub_status.unwrap_or_default(),
        sub_status_code = %sub_status_code.map_or(String::new(), |v| v.to_string()),
        error_hint = %error_hint.unwrap_or_default(),
        error_file_name = %error_file_name.unwrap_or("not_found"),
        error_file_line_num = %error_file_line_num.unwrap_or_default(),
        backtrace = ?backtrace,
        "User request failed.",
    );
}
