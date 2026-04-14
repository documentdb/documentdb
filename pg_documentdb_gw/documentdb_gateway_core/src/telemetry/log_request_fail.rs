/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/telemetry/log_request_fail.rs
 *
 *-------------------------------------------------------------------------
 */

use std::backtrace::Backtrace;

use tokio_postgres::error::SqlState;

use crate::{
    context::ConnectionContext,
    error::{should_log_on_postgres_error, DocumentDBError, ErrorKind},
    requests::Request,
    responses,
    telemetry::{event_id::EventId, utils},
};

#[derive(Default)]
struct RequestFailureLogFields<'a> {
    activity_id: &'a str,
    error_source: &'a str,
    operation_name: &'a str,
    backtrace: Option<&'a Backtrace>,
    error_message_loggable: Option<&'a str>,
    error_code: Option<&'a i32>,
    sub_status: Option<&'a str>,
    sub_status_code: Option<&'a i32>,
    error_hint: Option<&'a str>,
    error_file_name: Option<&'a str>,
    error_file_line_num: Option<&'a u32>,
}

// Function here helps in picking consistent field names for different error variants.
fn log_request_failure_inner(request_failure: &RequestFailureLogFields<'_>) {
    tracing::error!(
        activity_id = %request_failure.activity_id,
        event_id = %EventId::RequestFailure.code(),
        error_source = %request_failure.error_source,
        operation_name = %request_failure.operation_name,
        error_message_loggable = %request_failure.error_message_loggable.unwrap_or_default(),
        error_code = %request_failure.error_code.map_or(String::new(), ToString::to_string),
        sub_status = %request_failure.sub_status.unwrap_or_default(),
        sub_status_code = %request_failure.sub_status_code.map_or(String::new(), ToString::to_string),
        error_hint = %request_failure.error_hint.unwrap_or_default(),
        error_file_name = %request_failure.error_file_name.unwrap_or_default(),
        error_file_line_num = %request_failure
            .error_file_line_num
            .map_or(String::new(), ToString::to_string),
        backtrace = ?request_failure.backtrace,
        "User request failed.",
    );
}

// Logs error with common format for all `DocumentDBError`s on request failure.
// The logged output here must be PII free and is used for telemetry and logging.
#[expect(
    clippy::too_many_lines,
    reason = "complex logic that would lose clarity if split"
)]
pub fn log_request_failure(
    error: &DocumentDBError,
    connection_context: &ConnectionContext,
    activity_id: &str,
    request: Option<&Request<'_>>,
) {
    let operation_name = utils::get_safe_operation_name(request);
    match error.kind() {
        ErrorKind::IoError(error, backtrace) => {
            let error_message_loggable = error.to_string();
            log_request_failure_inner(&RequestFailureLogFields {
                activity_id,
                error_source: "IoError",
                operation_name: &operation_name,
                backtrace: Some(backtrace),
                error_message_loggable: Some(error_message_loggable.as_str()),
                ..Default::default()
            });
        }
        ErrorKind::DocumentDBError(code, _msg, error_message_loggable, backtrace) => {
            let error_code = *code as i32;
            log_request_failure_inner(&RequestFailureLogFields {
                activity_id,
                error_source: "DocumentDBError",
                operation_name: &operation_name,
                backtrace: Some(backtrace),
                error_message_loggable: error_message_loggable.as_deref(),
                error_code: Some(&error_code),
                ..Default::default()
            });
        }
        ErrorKind::PostgresError(error, backtrace) => {
            if let Some(dbe) = error.as_db_error() {
                if should_log_on_postgres_error(dbe.code()) {
                    tracing::error!(
                        activity_id = activity_id,
                        dbe = ?dbe,
                        "Postgres error with debug info: {{dbe}}."
                    );
                }

                let error_message_loggable = responses::map_pg_error(
                    connection_context,
                    dbe.code(),
                    dbe.message(),
                    activity_id,
                )
                .internal_note();

                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "PostgresError",
                    operation_name: &operation_name,
                    backtrace: Some(backtrace),
                    error_message_loggable,
                    sub_status: Some(dbe.code().code()),
                    sub_status_code: Some(&responses::postgres_sqlstate_to_i32(dbe.code())),
                    error_hint: dbe.hint(),
                    error_file_name: dbe.file(),
                    error_file_line_num: dbe.line().as_ref(),
                    ..Default::default()
                });
            } else {
                let error_message_loggable = error.to_string();
                log_request_failure_inner(&RequestFailureLogFields {
                    activity_id,
                    error_source: "PostgresError",
                    operation_name: &operation_name,
                    backtrace: Some(backtrace),
                    error_message_loggable: Some(error_message_loggable.as_str()),
                    ..Default::default()
                });
            }
        }
        ErrorKind::PostgresDocumentDBError(pg_code, msg, backtrace) => {
            let (sql_state, error_message_loggable): (Option<SqlState>, Option<String>) =
                match responses::i32_to_postgres_sqlstate(*pg_code) {
                    Ok(state) => {
                        let mapped_response = responses::map_pg_error(
                            connection_context,
                            &state,
                            msg.as_str(),
                            activity_id,
                        );
                        (
                            Some(state.clone()),
                            mapped_response
                                .internal_note()
                                .map(std::borrow::ToOwned::to_owned),
                        )
                    }
                    Err(_) => (
                        None,
                        Some(format!(
                            "Unable to convert to Postgres SQLState code: {pg_code}"
                        )),
                    ),
                };

            log_request_failure_inner(&RequestFailureLogFields {
                activity_id,
                error_source: "PostgresDocumentDBError",
                operation_name: &operation_name,
                backtrace: Some(backtrace),
                error_message_loggable: error_message_loggable.as_deref(),
                sub_status: sql_state
                    .as_ref()
                    .map(tokio_postgres::error::SqlState::code),
                sub_status_code: Some(pg_code),
                ..Default::default()
            });
        }
        ErrorKind::PoolError(error, backtrace) => {
            let error_message_loggable = match error {
                deadpool_postgres::PoolError::Backend(e) => {
                    if let Some(dbe) = e.as_db_error() {
                        format!(
                            "PoolError caused by Postgres error with code: {}, message: {}: hint: {}, file: {}, line: {}.",
                            dbe.code().code(),
                            dbe.message(),
                            dbe.hint().unwrap_or_default(),
                            dbe.file().unwrap_or_default(),
                            dbe.line().unwrap_or_default()
                        )
                    } else {
                        error.to_string()
                    }
                }
                _ => error.to_string(),
            };

            log_request_failure_inner(&RequestFailureLogFields {
                activity_id,
                error_source: "PoolError",
                operation_name: &operation_name,
                backtrace: Some(backtrace),
                error_message_loggable: Some(error_message_loggable.as_str()),
                ..Default::default()
            });
        }
        ErrorKind::CreatePoolError(error, backtrace) => {
            let error_message_loggable = error.to_string();
            log_request_failure_inner(&RequestFailureLogFields {
                activity_id,
                error_source: "CreatePoolError",
                operation_name: &operation_name,
                backtrace: Some(backtrace),
                error_message_loggable: Some(error_message_loggable.as_str()),
                ..Default::default()
            });
        }
        ErrorKind::BuildPoolError(error, backtrace) => {
            let error_message_loggable = error.to_string();
            log_request_failure_inner(&RequestFailureLogFields {
                activity_id,
                error_source: "BuildPoolError",
                operation_name: &operation_name,
                backtrace: Some(backtrace),
                error_message_loggable: Some(error_message_loggable.as_str()),
                ..Default::default()
            });
        }
        ErrorKind::RawBsonError(error, backtrace) => {
            log_request_failure_inner(&RequestFailureLogFields {
                activity_id,
                error_source: "RawBsonError",
                operation_name: &operation_name,
                backtrace: Some(backtrace),
                error_message_loggable: Some(error.to_string().as_str()),
                ..Default::default()
            });
        }
        ErrorKind::SSLError(error, backtrace) => {
            let error_message_loggable = error.to_string();
            log_request_failure_inner(&RequestFailureLogFields {
                activity_id,
                error_source: "SSLError",
                operation_name: &operation_name,
                backtrace: Some(backtrace),
                error_message_loggable: Some(error_message_loggable.as_str()),
                ..Default::default()
            });
        }
        ErrorKind::SSLErrorStack(error, backtrace) => {
            let error_message_loggable = error.to_string();
            log_request_failure_inner(&RequestFailureLogFields {
                activity_id,
                error_source: "SSLErrorStack",
                operation_name: &operation_name,
                backtrace: Some(backtrace),
                error_message_loggable: Some(error_message_loggable.as_str()),
                ..Default::default()
            });
        }
    }
}
