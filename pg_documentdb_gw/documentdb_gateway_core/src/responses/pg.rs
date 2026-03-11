/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/responses/pg.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{Bson, Document, RawDocument, RawDocumentBuf};

use documentdb_macros::documentdb_int_error_mapping;
use tokio_postgres::{error::SqlState, Row};

use crate::{
    context::{ConnectionContext, Cursor},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::PgDocument,
    responses::constant::{
        duplicate_key_violation_message, generic_internal_error_message,
        pg_returned_invalid_response_message,
    },
};

use super::{raw::RawResponse, Response};

/// Response from PG. This holds ownership of the response from the backend
#[derive(Debug)]
pub struct PgResponse {
    rows: Vec<Row>,
}

impl PgResponse {
    pub fn new(rows: Vec<Row>) -> Self {
        PgResponse { rows }
    }

    pub fn first(&self) -> Result<&Row> {
        self.rows
            .first()
            .ok_or(DocumentDBError::pg_response_empty())
    }

    pub fn as_raw_document(&self) -> Result<&RawDocument> {
        match self.rows.first() {
            Some(row) => {
                let content: PgDocument = row.try_get(0)?;
                Ok(content.0)
            }
            None => Err(DocumentDBError::pg_response_empty()),
        }
    }

    pub fn get_cursor(&self) -> Result<Option<(bool, Cursor)>> {
        match self.rows.first() {
            Some(row) => {
                let cols = row.columns();
                if cols.len() != 4 {
                    Ok(None)
                } else {
                    let continuation: Option<PgDocument> = row.try_get(1)?;
                    match continuation {
                        Some(continuation) => {
                            let persist: bool = row.try_get(2)?;
                            let cursor_id: i64 = row.try_get(3)?;
                            Ok(Some((
                                persist,
                                Cursor {
                                    continuation: continuation.0.to_raw_document_buf(),
                                    cursor_id,
                                },
                            )))
                        }
                        None => Ok(None),
                    }
                }
            }
            None => Err(DocumentDBError::pg_response_empty()),
        }
    }

    /// If 'writeErrors' is present, it transforms each error by potentially mapping them to the known DocumentDB error codes.
    pub fn transform_write_errors(
        self,
        connection_context: &ConnectionContext,
        activity_id: &str,
    ) -> Result<Response> {
        if let Ok(Some(_)) = self.as_raw_document()?.get("writeErrors") {
            // TODO: Conceivably faster without conversion to document
            let mut response = Document::try_from(self.as_raw_document()?)?;
            let write_errors = response.get_array_mut("writeErrors").map_err(|e| {
                DocumentDBError::internal_error(pg_returned_invalid_response_message(e))
            })?;

            for value in write_errors {
                self.transform_error(connection_context, value, activity_id)?;
            }
            let raw = RawDocumentBuf::from_document(&response)?;
            return Ok(Response::Raw(RawResponse(raw)));
        }
        Ok(Response::Pg(self))
    }

    fn transform_error(
        &self,
        context: &ConnectionContext,
        error_bson: &mut Bson,
        activity_id: &str,
    ) -> Result<()> {
        let doc = error_bson
            .as_document_mut()
            .ok_or(DocumentDBError::internal_error(
                "Failed to convert BSON write error into BSON document.".to_string(),
            ))?;
        let msg = doc.get_str("errmsg").unwrap_or("").to_owned();
        let code = doc.get_i32_mut("code").map_err(|e| {
            DocumentDBError::internal_error(pg_returned_invalid_response_message(e))
        })?;

        let pg_code = PgResponse::i32_to_postgres_sqlstate(code)?;

        let mapped_response = PgResponse::known_pg_error(context, &pg_code, &msg, activity_id);

        if mapped_response.error_code() == ErrorCode::WriteConflict as i32
            || mapped_response.error_code() == ErrorCode::InternalError as i32
            || mapped_response.error_code() == ErrorCode::LockTimeout as i32
            || mapped_response.error_code() == ErrorCode::Unauthorized as i32
        {
            // unwrap will never run here.
            let error_code = ErrorCode::from_i32(mapped_response.error_code())
                .unwrap_or(ErrorCode::InternalError);
            return Err(DocumentDBError::error_with_loggable_message(
                error_code,
                mapped_response.error_message(),
                mapped_response.internal_note().unwrap_or_default(),
            ));
        }

        let internal_note = mapped_response.internal_note();
        let error_code_i32 = mapped_response.error_code();
        tracing::warn!(
            activity_id = activity_id,
            sub_status_code = ?pg_code,
            error_message_loggable = internal_note,
            external_code = error_code_i32,
            "WriteError info: sub_status_code = {{sub_status_code}}, error_message_loggable = {{error_message_loggable}}, external_code = {{external_code}}.",
        );

        *code = mapped_response.error_code();
        doc.insert("errmsg", mapped_response.error_message());

        Ok(())
    }

    pub fn i32_to_postgres_sqlstate(code: &i32) -> Result<SqlState> {
        let mut code = *code;
        let mut chars = [0_u8; 5];
        for char in &mut chars {
            *char = (code & 0x3F) as u8 + b'0';
            code >>= 6;
        }

        Ok(SqlState::from_code(str::from_utf8(&chars).map_err(
            |_| {
                DocumentDBError::internal_error(format!(
                    "Failed to map command error code '{chars:?}' to SQL state."
                ))
            },
        )?))
    }

    pub fn postgres_sqlstate_to_i32(sql_state: &SqlState) -> i32 {
        let mut i = 0;
        let mut res = 0;
        for byte in sql_state.code().as_bytes() {
            res += (((byte - b'0') & 0x3F) as i32) << i;
            i += 6;
        }
        res
    }

    documentdb_int_error_mapping!();

    pub fn known_pg_error<'a>(
        connection_context: &'a ConnectionContext,
        state: &'a SqlState,
        msg: &'a str,
        activity_id: &str,
    ) -> PostgresErrorMappedResult<'a> {
        if let Some((known, code_name)) = PgResponse::from_known_external_error_code(state) {
            let message = "This may be due to the database disk being full";
            if known == ErrorCode::NotWritablePrimary as i32 {
                return PostgresErrorMappedResult {
                    error_code: ErrorCode::NotWritablePrimary as i32,
                    code_name: Some(code_name),
                    error_message: message,
                    internal_note: Some(message),
                };
            }

            return PostgresErrorMappedResult {
                error_code: known,
                code_name: Some(code_name),
                error_message: msg,
                ..Default::default()
            };
        }

        let code = PgResponse::postgres_sqlstate_to_i32(state);
        if (PgResponse::API_ERROR_CODE_MIN..PgResponse::API_ERROR_CODE_MAX).contains(&code) {
            return PostgresErrorMappedResult {
                error_code: code - PgResponse::API_ERROR_CODE_MIN,
                error_message: msg,
                internal_note: Some(msg),
                ..Default::default()
            };
        }

        // Handle specific pg states and map them to DocumentDB error codes
        match *state {
            SqlState::UNIQUE_VIOLATION | SqlState::EXCLUSION_VIOLATION => {
                if connection_context.transaction.is_some() {
                    tracing::error!(
                        activity_id = activity_id,
                        "Duplicate key error during transaction."
                    );

                    PostgresErrorMappedResult {
                        error_code: ErrorCode::WriteConflict as i32,
                        code_name: Some("UNIQUE_VIOLATION"),
                        error_message: duplicate_key_violation_message(),
                        internal_note: Some(msg),
                    }
                } else {
                    tracing::error!(activity_id = activity_id, "Duplicate key error.");

                    PostgresErrorMappedResult {
                        error_code: ErrorCode::DuplicateKey as i32,
                        code_name: Some("UNIQUE_VIOLATION"),
                        error_message: duplicate_key_violation_message(),
                        internal_note: Some(msg),
                    }
                }
            }
            SqlState::DISK_FULL => PostgresErrorMappedResult {
                error_code: ErrorCode::OutOfDiskSpace as i32,
                code_name: Some("DISK_FULL"),
                error_message: "The database disk is full",
                internal_note: Some(msg),
            },
            SqlState::UNDEFINED_TABLE => PostgresErrorMappedResult {
                error_code: ErrorCode::NamespaceNotFound as i32,
                code_name: Some("UNDEFINED_TABLE"),
                error_message: msg,
                internal_note: Some("undefined table error."),
            },
            SqlState::QUERY_CANCELED => {
                if connection_context.transaction.is_some() {
                    tracing::error!(
                        activity_id = activity_id,
                        "Query canceled during transaction."
                    );
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::ExceededTimeLimit as i32,
                        code_name: Some("QUERY_CANCELED"),
                        error_message: "The command being executed was terminated due to a command timeout. This may be due to concurrent transactions.",
                        internal_note: Some(msg),
                    }
                } else {
                    tracing::error!(activity_id = activity_id, "Query canceled.");
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::ExceededTimeLimit as i32,
                        code_name: Some("QUERY_CANCELED"),
                        error_message: "The command being executed was terminated due to a command timeout. This may be due to concurrent transactions. Consider increasing the maxTimeMS on the command.",
                        internal_note: Some(msg),
                    }
                }
            }
            SqlState::LOCK_NOT_AVAILABLE => {
                if connection_context.transaction.is_some() {
                    tracing::error!(
                        activity_id = activity_id,
                        "Lock not available error during transaction."
                    );
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::WriteConflict as i32,
                        code_name: Some("LOCK_NOT_AVAILABLE"),
                        error_message: msg,
                        internal_note: Some(msg),
                    }
                } else {
                    tracing::error!(activity_id = activity_id, "Lock not available error.");
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::LockTimeout as i32,
                        code_name: Some("LOCK_NOT_AVAILABLE"),
                        error_message: msg,
                        internal_note: Some(msg),
                    }
                }
            }
            SqlState::FEATURE_NOT_SUPPORTED => PostgresErrorMappedResult {
                error_code: ErrorCode::CommandNotSupported as i32,
                code_name: Some("FEATURE_NOT_SUPPORTED"),
                error_message: msg,
                ..Default::default()
            },
            SqlState::DATA_EXCEPTION => {
                if msg.contains("dimensions, not") || msg.contains("not allowed in vector") {
                    let error_message_loggable = "Dimensions are not allowed in vector error.";
                    tracing::error!(activity_id = activity_id, error_message_loggable);
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::BadValue as i32,
                        code_name: Some("DATA_EXCEPTION"),
                        error_message: msg,
                        internal_note: Some(error_message_loggable),
                    }
                } else {
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::InternalError as i32,
                        code_name: Some("DATA_EXCEPTION"),
                        error_message: generic_internal_error_message(),
                        internal_note: Some("generic data exception error"),
                    }
                }
            }
            SqlState::PROGRAM_LIMIT_EXCEEDED => {
                if msg.contains("MB, maintenance_work_mem is") {
                    tracing::error!(activity_id = activity_id, "Index creation requires resources too large to fit in the resource memory limit.");
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::ExceededMemoryLimit as i32,
                        code_name: Some("PROGRAM_LIMIT_EXCEEDED"),
                        error_message: "index creation requires resources too large to fit in the resource memory limit, please try creating index with less number of documents or creating index before inserting documents into collection",
                        internal_note: Some(msg),
                    }
                } else if msg.contains("index row size") && msg.contains("exceeds maximum") {
                    let error_message = "Index key is too large.";
                    tracing::error!(activity_id = activity_id, "{error_message}");
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::CannotBuildIndexKeys as i32,
                        code_name: Some("PROGRAM_LIMIT_EXCEEDED"),
                        error_message,
                        internal_note: Some(msg),
                    }
                } else {
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::InternalError as i32,
                        code_name: Some("PROGRAM_LIMIT_EXCEEDED"),
                        error_message: msg,
                        internal_note: Some(msg),
                    }
                }
            }
            SqlState::NUMERIC_VALUE_OUT_OF_RANGE => {
                if msg.contains("is out of range for type halfvec") {
                    let error_message =
                        "Some values in the vector are out of range for half vector index";
                    tracing::error!(activity_id = activity_id, "{error_message}");
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::BadValue as i32,
                        code_name: Some("NUMERIC_VALUE_OUT_OF_RANGE"),
                        error_message,
                        internal_note: Some(error_message),
                    }
                } else {
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::InternalError as i32,
                        code_name: Some("InternalError"),
                        error_message: generic_internal_error_message(),
                        internal_note: Some("generic numeric value out of range error"),
                    }
                }
            }
            SqlState::OBJECT_NOT_IN_PREREQUISITE_STATE
                if msg.contains("diskann index needs to be upgraded to version") =>
            {
                let error_message = "The diskann index needs to be upgraded to the latest version, please drop and recreate the index";
                tracing::error!(activity_id = activity_id, "{error_message}");
                PostgresErrorMappedResult {
                    error_code: ErrorCode::InvalidOptions as i32,
                    code_name: Some("OBJECT_NOT_IN_PREREQUISITE_STATE"),
                    error_message,
                    internal_note: Some(msg),
                }
            }
            SqlState::INTERNAL_ERROR => {
                if msg.contains("tsquery stack too small") {
                    // When the search terms have more than 32 nested levels, tsquery raises the PG internal error with message "tsquery stack too small".
                    // This can happen in find commands or $match aggregation stages with $text filter.
                    let error_message = "$text query is exceeding the maximum allowed depth(32), please simplify the query";
                    tracing::error!(activity_id = activity_id, "{error_message}");
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::BadValue as i32,
                        code_name: Some("INTERNAL_ERROR"),
                        error_message,
                        internal_note: Some(error_message),
                    }
                } else {
                    PostgresErrorMappedResult {
                        error_code: ErrorCode::InternalError as i32,
                        code_name: Some("InternalError"),
                        error_message: generic_internal_error_message(),
                        internal_note: Some(msg),
                    }
                }
            }
            SqlState::INVALID_TEXT_REPRESENTATION => PostgresErrorMappedResult {
                error_code: ErrorCode::FailedToParse as i32,
                code_name: Some("INVALID_TEXT_REPRESENTATION"),
                error_message: msg,
                internal_note: Some("invalid text representation error."),
            },
            SqlState::INVALID_PARAMETER_VALUE => PostgresErrorMappedResult {
                error_code: ErrorCode::BadValue as i32,
                code_name: Some("INVALID_PARAMETER_VALUE"),
                error_message: msg,
                internal_note: Some("invalid parameter value error."),
            },
            SqlState::INVALID_ARGUMENT_FOR_NTH_VALUE => PostgresErrorMappedResult {
                error_code: ErrorCode::BadValue as i32,
                code_name: Some("INVALID_ARGUMENT_FOR_NTH_VALUE"),
                error_message: msg,
                internal_note: Some("invalid argument for nth value error."),
            },
            SqlState::READ_ONLY_SQL_TRANSACTION
                if connection_context
                    .dynamic_configuration()
                    .is_replica_cluster() =>
            {
                let error_message = "Cannot execute the operation on this replica cluster";
                tracing::error!(activity_id = activity_id, "{error_message}");
                PostgresErrorMappedResult {
                    error_code: ErrorCode::IllegalOperation as i32,
                    code_name: Some("IllegalOperation"),
                    error_message,
                    internal_note: Some(msg),
                }
            }
            SqlState::READ_ONLY_SQL_TRANSACTION => PostgresErrorMappedResult {
                error_code: ErrorCode::ExceededTimeLimit as i32,
                code_name: Some("ExceededTimeLimit"),
                error_message: "Exceeded time limit while waiting for a new primary to be elected",
                internal_note: Some(msg),
            },
            SqlState::INSUFFICIENT_PRIVILEGE => PostgresErrorMappedResult {
                error_code: ErrorCode::Unauthorized as i32,
                code_name: Some("Unauthorized"),
                error_message: "User is not authorized to perform this action",
                internal_note: Some(msg),
            },
            SqlState::T_R_DEADLOCK_DETECTED => PostgresErrorMappedResult {
                error_code: ErrorCode::WriteConflict as i32,
                code_name: Some("WriteConflict"),
                error_message: "Could not acquire lock for operation due to deadlock",
                internal_note: Some(msg),
            },
            SqlState::UNDEFINED_OBJECT => PostgresErrorMappedResult {
                error_code: ErrorCode::UserNotFound as i32,
                code_name: Some("UserNotFound"),
                error_message: msg,
                internal_note: Some("undefined object error."),
            },
            SqlState::DUPLICATE_OBJECT => PostgresErrorMappedResult {
                error_code: ErrorCode::Location51003 as i32,
                code_name: Some("User already exists"),
                error_message: msg,
                internal_note: Some("duplicate object error."),
            },
            _ => PostgresErrorMappedResult {
                error_code: ErrorCode::InternalError as i32,
                code_name: Some("InternalError"),
                error_message: generic_internal_error_message(),
                internal_note: Some(msg),
            },
        }
    }

    /// Corresponds to the PG ErrorCode 0000Y.
    /// Smallest value of the documentdb backend error.
    pub const API_ERROR_CODE_MIN: i32 = 687865856;

    /// Corresponds to the PG ErrorCode 000PY.
    /// Largest value of the documentdb backend error.
    pub const API_ERROR_CODE_MAX: i32 = 696254464;
}

#[derive(Default)]
pub struct PostgresErrorMappedResult<'a> {
    error_code: i32,
    code_name: Option<&'a str>,
    error_message: &'a str,
    internal_note: Option<&'a str>,
}

impl<'a> PostgresErrorMappedResult<'a> {
    pub fn error_code(&self) -> i32 {
        self.error_code
    }

    pub fn code_name(&self) -> Option<&'a str> {
        self.code_name
    }

    pub fn error_message(&self) -> &'a str {
        self.error_message
    }

    pub fn internal_note(&self) -> Option<&'a str> {
        self.internal_note
    }
}
