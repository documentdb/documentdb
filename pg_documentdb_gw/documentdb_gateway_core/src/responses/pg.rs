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
    context::{ConnectionContext, Cursor, CursorId},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{document::ColumnByteLen, PgDocument},
    responses::{
        constant::{
            duplicate_key_violation_message, generic_internal_error_message,
            pg_returned_invalid_response_message,
        },
        global_custom_error_mapper,
    },
};

use super::{raw::RawResponse, Response};

/// Converts an i32 to a Postgres `SqlState`
///
/// # Errors
///
/// Returns an error if the operation fails.
pub fn i32_to_postgres_sqlstate(code: i32) -> Result<SqlState> {
    let mut code = code;
    let mut chars = [0_u8; 5];
    for char in &mut chars {
        *char = u8::try_from(code & 0x3F).map_err(|error| {
            tracing::error!("Failed to convert code '{code}' to u8: {error}");
            DocumentDBError::internal_error(format!("Failed to convert code '{code}' to u8."))
        })? + b'0';
        code >>= 6;
    }

    Ok(SqlState::from_code(str::from_utf8(&chars).map_err(
        |error| {
            tracing::error!("Failed to map command error code '{chars:?}' to SQL state: {error}");
            DocumentDBError::internal_error(format!(
                "Failed to map command error code '{chars:?}' to SQL state."
            ))
        },
    )?))
}

#[must_use]
pub fn postgres_sqlstate_to_i32(sql_state: &SqlState) -> i32 {
    let mut i = 0;
    let mut res = 0;
    for byte in sql_state.code().as_bytes() {
        res += i32::from((byte - b'0') & 0x3F) << i;
        i += 6;
    }
    res
}

documentdb_int_error_mapping!();

/// Converts a raw [`tokio_postgres::Error`] into a [`DocumentDBError`].
///
/// If the error carries a [`SqlState`] code, the code and message are extracted
/// and forwarded to [`map_pg_db_error`] for semantic mapping, with the original
/// error preserved as the error source. Errors without a SQL state (e.g. I/O or
/// connection errors) are returned as [`ErrorCode::InternalError`].
#[must_use]
pub fn map_pg_error(
    pg_error: tokio_postgres::Error,
    in_transaction: bool,
    is_replica_cluster: bool,
    activity_id: &str,
) -> DocumentDBError {
    let Some(sql_state) = pg_error.code().cloned() else {
        return DocumentDBError::internal_error(format!("Non db postgres error: {pg_error}"));
    };

    let db_error_message = pg_error
        .as_db_error()
        .map_or(String::new(), |e| e.message().to_owned());

    let mapped_result = map_pg_db_error(
        in_transaction,
        is_replica_cluster,
        &sql_state,
        &db_error_message,
        activity_id,
    );

    DocumentDBError::from_mapped_postgres_error(
        mapped_result.error_code(),
        mapped_result.error_message(),
        mapped_result.internal_note(),
        pg_error,
    )
}

/// First applies any registered custom error mapping logic,
/// then falls back to the generic error mapping logic in `map_pg_error_generic`
/// if the custom mapper returns `None`.
///
/// Errors which are related to open sourced documentdb extension functionality
/// should be mapped in `map_pg_error_generic`.
#[must_use]
pub fn map_pg_db_error<'a>(
    is_in_transaction: bool,
    is_replica_cluster: bool,
    sql_state: &'a SqlState,
    msg: &'a str,
    activity_id: &str,
) -> PostgresErrorMappedResult<'a> {
    if let Some(mapper) = global_custom_error_mapper() {
        // Check `CustomPostgresErrorMapper` trait definition for more details.
        if let Some(mapped_error) = mapper.map_postgres_error(sql_state, msg, activity_id) {
            return mapped_error;
        }
    }

    map_pg_error_generic(
        is_in_transaction,
        is_replica_cluster,
        sql_state,
        msg,
        activity_id,
    )
}

/// Errors which are related to open sourced documentdb extension functionality should be mapped in this function.
#[expect(clippy::too_many_lines, reason = "complex error mapping logic")]
fn map_pg_error_generic<'a>(
    is_in_transaction: bool,
    is_replica_cluster: bool,
    sql_state: &'a SqlState,
    msg: &'a str,
    activity_id: &str,
) -> PostgresErrorMappedResult<'a> {
    if let Some(known) = from_known_external_error_code(sql_state) {
        let message = "This may be due to the database disk being full";
        if known == ErrorCode::NotWritablePrimary as i32 {
            return PostgresErrorMappedResult {
                error_code: ErrorCode::NotWritablePrimary,
                error_message: message,
                internal_note: Some(message),
            };
        }

        let Some(known_error_code) = ErrorCode::from_i32(known) else {
            tracing::error!(
                activity_id = activity_id,
                "Known external error code {known} does not map to any ErrorCode enum variant."
            );

            return PostgresErrorMappedResult {
                error_code: ErrorCode::InternalError,
                error_message: generic_internal_error_message(),
                internal_note: Some("Failed to map known error code int to ErrorCode enum."),
            };
        };

        return PostgresErrorMappedResult {
            error_code: known_error_code,
            error_message: msg,
            internal_note: None,
        };
    }

    // Handle specific pg states and map them to DocumentDB error codes
    match *sql_state {
        SqlState::UNIQUE_VIOLATION | SqlState::EXCLUSION_VIOLATION => {
            if is_in_transaction {
                tracing::error!(
                    activity_id = activity_id,
                    "Duplicate key error during transaction."
                );

                PostgresErrorMappedResult {
                    error_code: ErrorCode::WriteConflict,
                    error_message: duplicate_key_violation_message(),
                    internal_note: Some(msg),
                }
            } else {
                tracing::error!(activity_id = activity_id, "Duplicate key error.");

                PostgresErrorMappedResult {
                    error_code: ErrorCode::DuplicateKey,
                    error_message: duplicate_key_violation_message(),
                    internal_note: Some(msg),
                }
            }
        }
        SqlState::DISK_FULL => PostgresErrorMappedResult {
            error_code: ErrorCode::OutOfDiskSpace,
            error_message: "The database disk is full",
            internal_note: Some(msg),
        },
        SqlState::UNDEFINED_TABLE => PostgresErrorMappedResult {
            error_code: ErrorCode::NamespaceNotFound,
            error_message: msg,
            internal_note: Some("undefined table error."),
        },
        SqlState::QUERY_CANCELED => {
            if is_in_transaction {
                tracing::error!(
                    activity_id = activity_id,
                    "Query canceled during transaction."
                );
                PostgresErrorMappedResult {
                        error_code: ErrorCode::ExceededTimeLimit,
                        error_message: "The command being executed was terminated due to a command timeout. This may be due to concurrent transactions.",
                        internal_note: Some(msg),
                    }
            } else {
                tracing::error!(activity_id = activity_id, "Query canceled.");
                PostgresErrorMappedResult {
                        error_code: ErrorCode::ExceededTimeLimit,
                        error_message: "The command being executed was terminated due to a command timeout. This may be due to concurrent transactions. Consider increasing the maxTimeMS on the command.",
                        internal_note: Some(msg),
                    }
            }
        }
        SqlState::LOCK_NOT_AVAILABLE => {
            if is_in_transaction {
                tracing::error!(
                    activity_id = activity_id,
                    "Lock not available error during transaction."
                );
                PostgresErrorMappedResult {
                    error_code: ErrorCode::WriteConflict,
                    error_message: msg,
                    internal_note: Some(msg),
                }
            } else {
                tracing::error!(activity_id = activity_id, "Lock not available error.");
                PostgresErrorMappedResult {
                    error_code: ErrorCode::LockTimeout,
                    error_message: msg,
                    internal_note: Some(msg),
                }
            }
        }
        SqlState::FEATURE_NOT_SUPPORTED => PostgresErrorMappedResult {
            error_code: ErrorCode::CommandNotSupported,
            error_message: msg,
            internal_note: None,
        },
        SqlState::DATA_EXCEPTION => {
            if msg.contains("dimensions, not") || msg.contains("not allowed in vector") {
                let error_message_loggable = "Dimensions are not allowed in vector error.";
                tracing::error!(activity_id = activity_id, error_message_loggable);
                PostgresErrorMappedResult {
                    error_code: ErrorCode::BadValue,
                    error_message: msg,
                    internal_note: Some(error_message_loggable),
                }
            } else {
                PostgresErrorMappedResult {
                    error_code: ErrorCode::InternalError,
                    error_message: generic_internal_error_message(),
                    internal_note: Some("generic data exception error"),
                }
            }
        }
        SqlState::PROGRAM_LIMIT_EXCEEDED => {
            if msg.contains("index row requires") {
                let error_message = "Index key is too large.";
                tracing::error!(activity_id = activity_id, "{error_message}");
                PostgresErrorMappedResult {
                    error_code: ErrorCode::CannotBuildIndexKeys,
                    error_message,
                    internal_note: Some(msg),
                }
            } else if msg.contains("index row size") && msg.contains("exceeds btree version") {
                let error_message = "Index key is too large for _id.";
                tracing::error!(activity_id = activity_id, "{error_message}");
                PostgresErrorMappedResult {
                    error_code: ErrorCode::CannotBuildIndexKeys,
                    error_message,
                    internal_note: Some(msg),
                }
            } else if msg.contains("index row size") && msg.contains("exceeds maximum") {
                let error_message = "Index key is too large.";
                tracing::error!(activity_id = activity_id, "{error_message}");
                PostgresErrorMappedResult {
                    error_code: ErrorCode::CannotBuildIndexKeys,
                    error_message,
                    internal_note: Some(msg),
                }
            } else if msg.contains("MB, maintenance_work_mem is") {
                // PG Vector hardcodes this as an exceeded memory limit error, replace the original message with a more comprehensive error message.
                tracing::error!(activity_id = activity_id, "Index creation requires resources too large to fit in the resource memory limit.");
                PostgresErrorMappedResult {
                        error_code: ErrorCode::ExceededMemoryLimit,
                        error_message: "index creation requires resources too large to fit in the resource memory limit, please try creating index with less number of documents or creating index before inserting documents into collection",
                        internal_note: Some(msg),
                    }
            } else {
                PostgresErrorMappedResult {
                    error_code: ErrorCode::InternalError,
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
                    error_code: ErrorCode::BadValue,
                    error_message,
                    internal_note: Some(error_message),
                }
            } else {
                PostgresErrorMappedResult {
                    error_code: ErrorCode::InternalError,
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
                error_code: ErrorCode::InvalidOptions,
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
                    error_code: ErrorCode::BadValue,
                    error_message,
                    internal_note: Some(error_message),
                }
            } else if msg.contains("EXPLAIN ANALYZE is currently not supported for MERGE INTO") {
                PostgresErrorMappedResult::new(
                    ErrorCode::IllegalOperation,
                    "Explain is not supported with certain Merge commands.",
                    Some(msg),
                )
            } else if msg.contains("out of dynamic memory in yy_create_buffer() at file") {
                PostgresErrorMappedResult::new(
                    ErrorCode::ExceededMemoryLimit,
                    "Exceeded available memory on the server.",
                    Some(msg),
                )
            } else {
                PostgresErrorMappedResult {
                    error_code: ErrorCode::InternalError,
                    error_message: generic_internal_error_message(),
                    internal_note: Some(msg),
                }
            }
        }
        SqlState::INVALID_TEXT_REPRESENTATION => PostgresErrorMappedResult {
            error_code: ErrorCode::FailedToParse,
            error_message: msg,
            internal_note: Some("invalid text representation error."),
        },
        SqlState::INVALID_PARAMETER_VALUE => PostgresErrorMappedResult {
            error_code: ErrorCode::BadValue,
            error_message: msg,
            internal_note: Some("invalid parameter value error."),
        },
        SqlState::INVALID_ARGUMENT_FOR_NTH_VALUE => PostgresErrorMappedResult {
            error_code: ErrorCode::BadValue,
            error_message: msg,
            internal_note: Some("invalid argument for nth value error."),
        },
        SqlState::READ_ONLY_SQL_TRANSACTION if is_replica_cluster => {
            let error_message = "Cannot execute the operation on this replica cluster";
            tracing::error!(activity_id = activity_id, "{error_message}");
            PostgresErrorMappedResult {
                error_code: ErrorCode::IllegalOperation,
                error_message,
                internal_note: Some(msg),
            }
        }
        SqlState::READ_ONLY_SQL_TRANSACTION => PostgresErrorMappedResult {
            error_code: ErrorCode::ExceededTimeLimit,
            error_message: "Exceeded time limit while waiting for a new primary to be elected",
            internal_note: Some(msg),
        },
        SqlState::INSUFFICIENT_PRIVILEGE => PostgresErrorMappedResult {
            error_code: ErrorCode::Unauthorized,
            error_message: "User is not authorized to perform this action",
            internal_note: Some(msg),
        },
        SqlState::T_R_DEADLOCK_DETECTED => PostgresErrorMappedResult {
            error_code: ErrorCode::WriteConflict,
            error_message: "Could not acquire lock for operation due to deadlock",
            internal_note: Some(msg),
        },
        SqlState::UNDEFINED_OBJECT => PostgresErrorMappedResult {
            error_code: ErrorCode::RoleNotFound,
            error_message: msg,
            internal_note: Some("The specified role does not exist."),
        },
        SqlState::DUPLICATE_OBJECT => PostgresErrorMappedResult {
            error_code: ErrorCode::Location51003,
            error_message: msg,
            internal_note: Some("duplicate object error."),
        },
        SqlState::CARDINALITY_VIOLATION => {
            if msg.contains("MERGE command cannot affect row a second time") {
                let error_message = "$merge cannot update a row a second time";
                PostgresErrorMappedResult {
                    error_code: ErrorCode::CommandNotSupported,
                    error_message,
                    internal_note: Some(error_message),
                }
            } else {
                PostgresErrorMappedResult {
                    error_code: ErrorCode::InternalError,
                    error_message: generic_internal_error_message(),
                    internal_note: Some("generic cardinality violation error."),
                }
            }
        }
        SqlState::DUPLICATE_TABLE => PostgresErrorMappedResult {
            error_code: ErrorCode::NamespaceExists,
            error_message: msg,
            internal_note: Some("duplicate table error."),
        },
        SqlState::TOO_MANY_CONNECTIONS => PostgresErrorMappedResult {
            error_code: ErrorCode::TooManyLogicalSessions,
            error_message: msg,
            internal_note: Some(msg),
        },
        SqlState::T_R_SERIALIZATION_FAILURE => {
            let error_message =
                "Could not complete operation due to conflict with internal apply operation";
            tracing::error!(activity_id = activity_id, "{error_message}");
            PostgresErrorMappedResult {
                error_code: ErrorCode::ConflictingOperationInProgress,
                error_message,
                internal_note: Some(msg),
            }
        }
        SqlState::IN_FAILED_SQL_TRANSACTION => {
            let error_message = "Operation was attempted in a transaction that was aborted";
            PostgresErrorMappedResult {
                error_code: ErrorCode::OperationNotSupportedInTransaction,
                error_message,
                internal_note: Some(msg),
            }
        }
        SqlState::OUT_OF_MEMORY => {
            let error_message = "Exceeded available memory on the server.";
            tracing::error!(activity_id = activity_id, "{error_message}");
            PostgresErrorMappedResult {
                error_code: ErrorCode::ExceededMemoryLimit,
                error_message,
                internal_note: Some(msg),
            }
        }
        SqlState::INSUFFICIENT_RESOURCES => {
            // Closest proxy — all cases seen so far have been OOM for this error code.
            let error_message = "Exceeded available resources on the server.";
            tracing::error!(activity_id = activity_id, "{error_message}");
            PostgresErrorMappedResult {
                error_code: ErrorCode::ExceededMemoryLimit,
                error_message,
                internal_note: Some(msg),
            }
        }
        SqlState::CANNOT_CONNECT_NOW => {
            let error_message = "Request terminated due to shutdown on the server.";
            tracing::error!(activity_id = activity_id, "{error_message}");
            PostgresErrorMappedResult {
                error_code: ErrorCode::ShutdownInProgress,
                error_message,
                internal_note: Some(msg),
            }
        }
        SqlState::TOO_MANY_COLUMNS => {
            let error_message = "Too many compound keys for index.";
            PostgresErrorMappedResult::new(
                ErrorCode::Location13103,
                error_message,
                Some(error_message),
            )
        }
        SqlState::DUPLICATE_COLUMN => {
            let error_message = "Entity already exists.";
            PostgresErrorMappedResult::new(
                ErrorCode::DuplicateKey,
                error_message,
                Some(error_message),
            )
        }
        SqlState::INVALID_PASSWORD => {
            let error_message = "Invalid password.";
            PostgresErrorMappedResult::new(
                ErrorCode::InvalidPassword,
                error_message,
                Some(error_message),
            )
        }
        _ => PostgresErrorMappedResult {
            error_code: ErrorCode::InternalError,
            error_message: generic_internal_error_message(),
            internal_note: Some(msg),
        },
    }
}

fn transform_error(
    context: &ConnectionContext,
    error_bson: &mut Bson,
    activity_id: &str,
) -> Result<()> {
    let doc = error_bson
        .as_document_mut()
        .ok_or(DocumentDBError::internal_error(
            "Failed to convert BSON write error into BSON document.".to_owned(),
        ))?;
    let msg = doc.get_str("errmsg").unwrap_or("").to_owned();
    let code = doc
        .get_i32_mut("code")
        .map_err(|e| DocumentDBError::internal_error(pg_returned_invalid_response_message(e)))?;

    let pg_code = i32_to_postgres_sqlstate(*code)?;

    let mapped_response = map_pg_db_error(
        context.transaction.is_some(),
        context.dynamic_configuration().is_replica_cluster(),
        &pg_code,
        &msg,
        activity_id,
    );

    if mapped_response.error_code() == ErrorCode::WriteConflict
        || mapped_response.error_code() == ErrorCode::InternalError
        || mapped_response.error_code() == ErrorCode::LockTimeout
        || mapped_response.error_code() == ErrorCode::Unauthorized
    {
        return Err(DocumentDBError::error_with_loggable_message(
            mapped_response.error_code(),
            mapped_response.error_message(),
            mapped_response.internal_note().unwrap_or_default(),
        ));
    }

    let internal_note = mapped_response.internal_note();
    tracing::warn!(
        activity_id = activity_id,
        sub_status_code = ?pg_code,
        error_message_loggable = internal_note,
        external_code = mapped_response.error_code() as i32,
        "WriteError info: sub_status_code = {{sub_status_code}}, error_message_loggable = {{error_message_loggable}}, external_code = {{external_code}}.",
    );

    *code = mapped_response.error_code() as i32;
    doc.insert("errmsg", mapped_response.error_message());

    Ok(())
}

/// Response from PG. This holds ownership of the response from the backend
#[derive(Debug)]
pub struct PgResponse {
    rows: Vec<Row>,
}

impl PgResponse {
    #[must_use]
    pub const fn new(rows: Vec<Row>) -> Self {
        Self { rows }
    }

    /// Gets the first row
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub fn first(&self) -> Result<&Row> {
        self.rows
            .first()
            .ok_or(DocumentDBError::pg_response_empty())
    }

    /// Gets the response as a raw document
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub fn as_raw_document(&self) -> Result<&RawDocument> {
        match self.rows.first() {
            Some(row) => {
                let content: PgDocument = row.try_get(0)?;
                Ok(content.0)
            }
            None => Err(DocumentDBError::pg_response_empty()),
        }
    }

    /// Returns the total byte length across all columns of the first row,
    /// or 0 if the response is empty. Extracts raw byte lengths without
    /// deserializing or validating column data.
    #[must_use]
    pub fn response_byte_len(&self) -> usize {
        let Some(row) = self.rows.first() else {
            return 0;
        };
        (0..row.len())
            .filter_map(|i| row.try_get::<_, ColumnByteLen>(i).map(|col| col.0).ok())
            .sum()
    }

    /// # Errors
    /// Returns an error if the result columns cannot be read or deserialized.
    pub fn get_cursor(&self) -> Result<Option<(bool, Cursor)>> {
        match self.rows.first() {
            Some(row) => {
                let cols = row.columns();
                if cols.len() == 4 {
                    let continuation: Option<PgDocument> = row.try_get(1)?;
                    match continuation {
                        Some(continuation) => {
                            let persist: bool = row.try_get(2)?;
                            let cursor_id: i64 = row.try_get(3)?;
                            Ok(Some((
                                persist,
                                Cursor {
                                    continuation: continuation.0.to_raw_document_buf(),
                                    cursor_id: CursorId::from(cursor_id),
                                },
                            )))
                        }
                        None => Ok(None),
                    }
                } else {
                    Ok(None)
                }
            }
            None => Err(DocumentDBError::pg_response_empty()),
        }
    }

    /// Reads the `p_success` flag from column 1 of the first row.
    ///
    /// Returns `true` (success) when the row has only one column, matching
    /// queries that do not return `p_success`.  Returns an error when the
    /// response is empty.
    ///
    /// # Errors
    ///
    /// Returns an error if the response is empty or the column cannot be read.
    pub fn write_success(&self) -> Result<bool> {
        let row = self.first()?;
        if row.len() > 1 {
            row.try_get(1).map_err(Into::into)
        } else {
            Ok(true)
        }
    }

    /// If the `PostgreSQL` UDF signals failure via `p_success` (column 1) and
    /// `writeErrors` is present, transforms each error by mapping to known
    /// error codes.  When `p_success` is `true` the response is returned
    /// without inspecting `writeErrors`.
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub fn transform_write_errors(
        self,
        connection_context: &ConnectionContext,
        activity_id: &str,
    ) -> Result<Response> {
        let success = self.write_success()?;

        if !success {
            if let Ok(Some(_)) = self.as_raw_document()?.get("writeErrors") {
                let mut response = Document::try_from(self.as_raw_document()?)?;
                let write_errors = response.get_array_mut("writeErrors").map_err(|e| {
                    DocumentDBError::internal_error(pg_returned_invalid_response_message(e))
                })?;

                for value in write_errors {
                    transform_error(connection_context, value, activity_id)?;
                }
                let raw = RawDocumentBuf::from_document(&response)?;
                return Ok(Response::Raw(RawResponse::new(raw).with_write_errors()));
            }
        }

        Ok(Response::Pg(self))
    }
}

#[derive(Debug)]
pub struct PostgresErrorMappedResult<'a> {
    error_code: ErrorCode,
    error_message: &'a str,
    internal_note: Option<&'a str>,
}

impl<'a> PostgresErrorMappedResult<'a> {
    #[must_use]
    pub const fn new(
        error_code: ErrorCode,
        error_message: &'a str,
        internal_note: Option<&'a str>,
    ) -> Self {
        Self {
            error_code,
            error_message,
            internal_note,
        }
    }

    #[must_use]
    pub const fn error_code(&self) -> ErrorCode {
        self.error_code
    }

    #[must_use]
    pub const fn error_message(&self) -> &'a str {
        self.error_message
    }

    #[must_use]
    pub const fn internal_note(&self) -> Option<&'a str> {
        self.internal_note
    }
}

#[cfg(test)]
mod tests {
    use std::sync::Once;

    use super::*;
    use crate::responses::{register_custom_error_mapper, CustomPostgresErrorMapper};

    static REGISTER_TEST_MAPPER: Once = Once::new();

    fn register_test_mapper() {
        REGISTER_TEST_MAPPER.call_once(|| {
            let _ = register_custom_error_mapper(Box::new(TestMapper));
        });
    }

    #[derive(Debug)]
    struct TestMapper;

    impl CustomPostgresErrorMapper for TestMapper {
        fn map_postgres_error<'a>(
            &self,
            sql_state: &'a SqlState,
            msg: &'a str,
            _activity_id: &str,
        ) -> Option<PostgresErrorMappedResult<'a>> {
            ((*sql_state == SqlState::DISK_FULL) && msg.contains("custom_mapper_test")).then(|| {
                PostgresErrorMappedResult::new(
                    ErrorCode::CommandNotSupported,
                    "custom mapped error",
                    None,
                )
            })
        }
    }

    #[test]
    fn test_custom_postgres_error_mapper() {
        register_test_mapper();

        // Custom mapper handles DISK_FULL with a test marker and overrides the default
        // OutOfDiskSpace mapping.
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::DISK_FULL,
            "custom_mapper_test: could not extend file: No space left on device",
            "test-activity",
        );
        assert_eq!(result.error_code(), ErrorCode::CommandNotSupported);
        assert_eq!(result.error_message(), "custom mapped error");

        // For a state the custom mapper doesn't handle, it falls through to the generic logic.
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::FEATURE_NOT_SUPPORTED,
            "this feature is not supported",
            "test-activity",
        );
        assert_eq!(result.error_code(), ErrorCode::CommandNotSupported);
        assert_eq!(result.error_message(), "this feature is not supported");
    }

    #[test]
    fn test_no_custom_mapper_falls_through_to_generic() {
        // When the message doesn't match custom mapper conditions,
        // generic mapping is used directly.
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::DISK_FULL,
            "disk full",
            "test-activity",
        );
        assert_eq!(result.error_code(), ErrorCode::OutOfDiskSpace);
        assert_eq!(result.error_message(), "disk full");
    }

    #[test]
    fn test_map_with_unique_violation_in_transaction_returns_write_conflict() {
        let result = map_pg_db_error(
            true,
            false,
            &SqlState::UNIQUE_VIOLATION,
            "duplicate key value violates unique constraint",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::WriteConflict);
        assert_eq!(result.error_message(), duplicate_key_violation_message());
    }

    #[test]
    fn test_map_with_unique_violation_no_transaction_returns_duplicate_key() {
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::UNIQUE_VIOLATION,
            "duplicate key value violates unique constraint",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::DuplicateKey);
        assert_eq!(result.error_message(), duplicate_key_violation_message());
    }

    #[test]
    fn test_map_with_query_canceled_in_transaction_returns_timeout_message() {
        let result = map_pg_db_error(
            true,
            false,
            &SqlState::QUERY_CANCELED,
            "canceling statement due to statement timeout",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::ExceededTimeLimit);
        assert_eq!(
            result.error_message(),
            "The command being executed was terminated due to a command timeout. This may be due to concurrent transactions."
        );
    }

    #[test]
    fn test_map_with_query_canceled_no_transaction_suggests_max_time_ms() {
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::QUERY_CANCELED,
            "canceling statement due to statement timeout",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::ExceededTimeLimit);
        assert!(result
            .error_message()
            .contains("Consider increasing the maxTimeMS"));
    }

    #[test]
    fn test_map_with_read_only_transaction_on_replica_returns_illegal_operation() {
        let result = map_pg_db_error(
            false,
            true,
            &SqlState::READ_ONLY_SQL_TRANSACTION,
            "cannot execute INSERT in a read-only transaction",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::IllegalOperation);
        assert_eq!(
            result.error_message(),
            "Cannot execute the operation on this replica cluster"
        );
    }

    #[test]
    fn test_map_with_read_only_transaction_no_replica_returns_exceeded_time_limit() {
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::READ_ONLY_SQL_TRANSACTION,
            "cannot execute INSERT in a read-only transaction",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::ExceededTimeLimit);
        assert_eq!(
            result.error_message(),
            "Exceeded time limit while waiting for a new primary to be elected"
        );
    }

    #[test]
    fn test_map_with_program_limit_exceeded_memory_message_returns_exceeded_memory_limit() {
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::PROGRAM_LIMIT_EXCEEDED,
            "memory required is 120 MB, maintenance_work_mem is 64 MB",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::ExceededMemoryLimit);
        assert!(result
            .error_message()
            .contains("index creation requires resources too large"));
    }

    #[test]
    fn test_map_with_numeric_out_of_range_halfvec_returns_bad_value() {
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::NUMERIC_VALUE_OUT_OF_RANGE,
            "value is out of range for type halfvec",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::BadValue);
        assert_eq!(
            result.error_message(),
            "Some values in the vector are out of range for half vector index"
        );
    }

    #[test]
    fn test_map_with_internal_error_tsquery_stack_returns_bad_value() {
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::INTERNAL_ERROR,
            "tsquery stack too small",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::BadValue);
        assert!(result
            .error_message()
            .contains("$text query is exceeding the maximum allowed depth"));
    }

    #[test]
    fn test_map_with_cannot_connect_now_returns_shutdown_in_progress() {
        let result = map_pg_db_error(
            false,
            false,
            &SqlState::CANNOT_CONNECT_NOW,
            "the database system is shutting down",
            "test-activity",
        );

        assert_eq!(result.error_code(), ErrorCode::ShutdownInProgress);
        assert_eq!(
            result.error_message(),
            "Request terminated due to shutdown on the server."
        );
    }
}
