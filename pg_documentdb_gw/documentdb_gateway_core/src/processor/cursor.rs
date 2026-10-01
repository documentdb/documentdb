/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/cursor.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{sync::Arc, time::Duration};

use bson::{rawdoc, Decimal128, RawArrayBuf, RawBsonRef, RawDocumentBuf};

use crate::{
    context::{
        ConnectionContext, Cursor, CursorId, CursorStoreEntry, LogicalSessionId, RequestContext,
        TransactionNumber,
    },
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{
        conn_mgmt::{Connection, PullConnection},
        PgDataClient, PgDocument,
    },
    protocol::OK_SUCCEEDED,
    requests::WireRequest,
    responses::{PgResponse, RawResponse, Response},
};

/// Top-level fields recognized by the getMore command. Any other field that is
/// not command metadata (metadata fields are prefixed with `$`) is rejected as
/// unrecognized to match the documented wire-protocol semantics.
const GET_MORE_RECOGNIZED_FIELDS: &[&str] = &[
    "getMore",
    "collection",
    "batchSize",
    "maxTimeMS",
    "term",
    "lastKnownCommittedOpTime",
    "lsid",
    "txnNumber",
    "autocommit",
    "startTransaction",
    "stmtId",
    "comment",
    "readConcern",
    "apiVersion",
    "apiStrict",
    "apiDeprecationErrors",
];

/// Validates the argument fields of a getMore command and returns the requested
/// cursor id.
///
/// Enforces wire-protocol-compatible type and value semantics: the cursor id
/// must be an int64, the collection must be a string, batchSize must be a
/// non-negative number, and unrecognized fields are rejected. A null cursor id
/// or collection is treated as a missing required field. maxTimeMS type
/// validation is handled during common command parsing.
fn validate_get_more_arguments(request: &WireRequest) -> Result<i64> {
    let mut cursor_id = None;
    let mut collection_present = false;

    request.extract_fields(|key, value| {
        match key {
            "getMore" => match value {
                RawBsonRef::Int64(id) => cursor_id = Some(id),
                RawBsonRef::Null => {}
                _ => {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::TypeMismatch,
                        "getMore field must be of type long".to_owned(),
                    ));
                }
            },
            "collection" => match value {
                RawBsonRef::String(_) => collection_present = true,
                RawBsonRef::Null => {}
                _ => {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::TypeMismatch,
                        "collection field must be of type string".to_owned(),
                    ));
                }
            },
            "batchSize" => validate_get_more_batch_size(value)?,
            _ => {
                if !key.starts_with('$') && !GET_MORE_RECOGNIZED_FIELDS.contains(&key) {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::UnknownBsonField,
                        format!("BSON field 'getMore.{key}' is an unknown field."),
                    ));
                }
            }
        }
        Ok(())
    })?;

    let cursor_id = cursor_id.ok_or_else(|| {
        DocumentDBError::documentdb_error(
            ErrorCode::Location40414,
            "BSON field 'getMore.getMore' is missing but a required field".to_owned(),
        )
    })?;

    if !collection_present {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::Location40414,
            "BSON field 'getMore.collection' is missing but a required field".to_owned(),
        ));
    }

    Ok(cursor_id)
}

/// Validates the getMore `batchSize` argument. Only numeric types (int32,
/// int64, double, Decimal128) and null are accepted; any other type is a type
/// mismatch. A value that coerces to a negative integer is rejected as out of
/// range. Valid values are accepted and left to the existing cursor paging
/// behavior.
fn validate_get_more_batch_size(value: RawBsonRef) -> Result<()> {
    let is_negative = match value {
        RawBsonRef::Int32(v) => i64::from(v) < 0,
        RawBsonRef::Int64(v) => v < 0,
        // Doubles truncate toward zero, so only values that truncate to a
        // negative integer (including negative infinity) are rejected.
        RawBsonRef::Double(d) => d.trunc() < 0.0,
        RawBsonRef::Decimal128(d) => decimal128_rounds_negative(&d),
        RawBsonRef::Null => false,
        _ => {
            return Err(DocumentDBError::documentdb_error(
                ErrorCode::TypeMismatch,
                "batchSize field must be a number".to_owned(),
            ));
        }
    };

    if is_negative {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::BadValue,
            "batchSize value must not be negative".to_owned(),
        ));
    }

    Ok(())
}

/// Returns true when a Decimal128 batchSize rounds (round-half-to-even) to a
/// negative integer. Decimal128 uses banker's rounding, so every finite value
/// strictly less than -0.5 rounds to -1 or lower and is negative, while values
/// in [-0.5, 0] round to zero and are not. Negative infinity is negative; NaN
/// and positive infinity are not.
///
/// The comparison is performed on the exact canonical decimal string rather
/// than a `f64` conversion, which would lose precision arbitrarily close to the
/// -0.5 boundary and could accept a value that rounds to a negative integer.
fn decimal128_rounds_negative(value: &Decimal128) -> bool {
    decimal128_string_less_than_neg_half(&value.to_string())
}

/// Returns true when the canonical Decimal128 string `s` represents a value
/// strictly less than -0.5. Handles the special strings (`NaN`, `-NaN`,
/// `Infinity`, `-Infinity`) and both plain (`-0.5`) and scientific (`-5E-30`)
/// notation emitted for the type.
fn decimal128_string_less_than_neg_half(s: &str) -> bool {
    match s {
        "Infinity" | "NaN" | "-NaN" => return false,
        "-Infinity" => return true,
        _ => {}
    }

    // Only negative finite values can be less than -0.5. A leading '-' is the
    // sign; the remaining text is the magnitude to compare against 0.5.
    match s.strip_prefix('-') {
        Some(magnitude) => decimal128_magnitude_greater_than_half(magnitude),
        None => false,
    }
}

/// Returns true when the canonical non-negative decimal magnitude `magnitude`
/// is strictly greater than 0.5. `magnitude` is either plain notation (`0.5`,
/// `1.25`) or scientific notation (`5E-30`, `1.2E+40`).
fn decimal128_magnitude_greater_than_half(magnitude: &str) -> bool {
    if let Some((mantissa, exponent)) = magnitude.split_once('E') {
        // Scientific notation: value = mantissa * 10^exponent with the mantissa
        // in [1, 10). exponent >= 0 gives a value >= 1; exponent <= -2 gives a
        // value < 0.1; exponent == -1 gives mantissa / 10, which exceeds 0.5
        // only when the mantissa exceeds 5.
        let Ok(exponent) = exponent.parse::<i32>() else {
            return false;
        };
        if exponent >= 0 {
            return true;
        }
        if exponent <= -2 {
            return false;
        }
        decimal128_digits_greater_than_5(mantissa)
    } else {
        let (integer_part, fraction_part) = magnitude.split_once('.').unwrap_or((magnitude, ""));
        // A non-zero integer part means the value is at least 1.
        if integer_part.bytes().any(|b| b != b'0') {
            return true;
        }
        decimal128_fraction_greater_than_half(fraction_part)
    }
}

/// Returns true when the fractional digits `fraction` represent a value
/// strictly greater than 0.5 (that is, `0.fraction > 0.5`).
fn decimal128_fraction_greater_than_half(fraction: &str) -> bool {
    let digits = fraction.as_bytes();
    match digits.first() {
        Some(&first) if first > b'5' => true,
        Some(&first) if first < b'5' => false,
        // Leading digit is exactly 5: greater than 0.5 only if any later digit
        // is non-zero.
        Some(_) => digits[1..].iter().any(|&b| b != b'0'),
        None => false,
    }
}

/// Returns true when the single-integer-digit decimal `digits` (for example
/// `5`, `5.0001`, `1.2`) is strictly greater than 5.
fn decimal128_digits_greater_than_5(digits: &str) -> bool {
    let (integer_part, fraction_part) = digits.split_once('.').unwrap_or((digits, ""));
    match integer_part.bytes().next() {
        Some(first) if first > b'5' => true,
        Some(first) if first < b'5' => false,
        Some(_) => fraction_part.bytes().any(|b| b != b'0'),
        None => false,
    }
}

/// Validates that a request is correct and enforces correct usage of a cursor.
fn validate_get_more_request(
    connection_lsid: Option<&LogicalSessionId>,
    connection_transaction_number: Option<&TransactionNumber>,
    cursor_lsid: Option<&LogicalSessionId>,
    cursor_transaction_number: Option<&TransactionNumber>,
) -> Result<()> {
    // Session id validation
    match (connection_lsid, cursor_lsid) {
        (Some(req_sid), None) => {
            return Err(DocumentDBError::documentdb_error(
                ErrorCode::Location50736,
                format!(
                    "Cannot run getMore on cursor, which was not created in a session, in session {req_sid:?}"
                ),
            ));
        }
        (None, Some(cur_sid)) => {
            return Err(DocumentDBError::documentdb_error(
                ErrorCode::Location50737,
                format!(
                    "Cannot run getMore on cursor, which was created in session {cur_sid:?}, without an lsid."
                ),
            ));
        }
        (Some(req_sid), Some(cur_sid)) if req_sid != cur_sid => {
            return Err(DocumentDBError::documentdb_error(
                ErrorCode::Location50738,
                format!(
                    "Cannot run getMore on cursor, which was created in session {cur_sid:?}, in session {req_sid:?}"
                ),
            ));
        }
        _ => {}
    }

    // Transaction number validation (only when there is no session)
    if connection_lsid.is_none() {
        match (connection_transaction_number, cursor_transaction_number) {
            (Some(req_tn), None) => {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::Location50739,
                    format!(
                        "Cannot run getMore on cursor, which was not created in a transaction, in transaction {req_tn}"
                    ),
                ));
            }
            (None, Some(cur_tn)) => {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::Location50740,
                    format!(
                        "Cannot run getMore on cursor, which was created in a transaction {cur_tn}, without a transaction."
                    ),
                ));
            }
            (Some(req_tn), Some(cur_tn)) if req_tn != cur_tn => {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::Location50741,
                    format!(
                        "Cannot run getMore on cursor, which was created in a transaction {cur_tn}, in transaction {req_tn}"
                    ),
                ));
            }
            _ => {}
        }
    }

    Ok(())
}

pub async fn process_kill_cursors(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request = request_context.request();

    let _ = request
        .document()
        .get_str("killCursors")
        .map_err(DocumentDBError::parse_failure())?;

    let cursors = request
        .document()
        .get("cursors")?
        .ok_or(DocumentDBError::bad_value(
            "cursors was missing in killCursors request".to_owned(),
        ))?
        .as_array()
        .ok_or(DocumentDBError::documentdb_error(
            ErrorCode::TypeMismatch,
            "killCursors cursors should be an array".to_owned(),
        ))?;

    let mut cursor_ids = Vec::new();
    for value in cursors {
        let cursor = value?.as_i64().ok_or(DocumentDBError::bad_value(
            "Cursor was not a valid i64".to_owned(),
        ))?;
        cursor_ids.push(cursor);
    }

    // Surface the cursor id for diagnostics only when a single cursor is targeted;
    // the diagnostic field holds a single value.
    if let [single_cursor_id] = cursor_ids.as_slice() {
        request_context.tracker.set_cursor_id(*single_cursor_id);
    }

    let (removed_cursors, missing_cursors) = connection_context
        .service_context
        .cursor_store()
        .kill_cursors(&cursor_ids, connection_context.user().principal()?);

    if !removed_cursors.is_empty() {
        pg_data_client
            .execute_kill_cursors(request_context, connection_context, &removed_cursors)
            .await?;
    }

    let mut removed_cursor_buf = RawArrayBuf::new();
    for cursor in removed_cursors {
        removed_cursor_buf.push(cursor);
    }
    let mut missing_cursor_buf = RawArrayBuf::new();
    for cursor in missing_cursors {
        missing_cursor_buf.push(cursor);
    }

    Ok(Response::Raw(RawResponse::new(rawdoc! {
        "ok":OK_SUCCEEDED,
        "cursorsKilled": removed_cursor_buf,
        "cursorsNotFound": missing_cursor_buf,
        "cursorsAlive": [],
        "cursorsUnknown":[],
    })))
}

/// Reads maxAwaitTimeMS from the V2 getMore result.
///
/// The V2 getMore query projects only the columns this gateway consumes —
/// `cursorPage, continuation, maxAwaitTimeMS` — so maxAwaitTimeMS is at column
/// index 2. Returns 0 when the result has fewer than 3 columns (e.g. a V1
/// result, which omits the column) or the value is null; 0 disables polling.
fn extract_max_await_time_ms(results: &[tokio_postgres::Row]) -> i64 {
    results
        .first()
        .filter(|row| row.columns().len() > 2)
        .and_then(|row| row.try_get::<_, i64>(2).ok())
        .unwrap_or(0)
}

/// Reads the continuation document from column index 1 of the result.
///
/// A failure here means the backend returned an unexpected shape, which must
/// surface as an error instead of being silently treated as a drained cursor.
fn extract_continuation(results: &[tokio_postgres::Row]) -> Result<Option<RawDocumentBuf>> {
    let Some(row) = results.first() else {
        return Ok(None);
    };
    let continuation: Option<PgDocument> = row.try_get(1)?;
    Ok(continuation.map(|doc| doc.0.to_raw_document_buf()))
}

/// Groups parameters for the tailable cursor polling loop.
struct PollCursorState<'a> {
    cursor_id: i64,
    cursor_connection: &'a Option<Arc<Connection>>,
    db: &'a str,
    max_await_time_ms: i64,
}

/// Polls a tailable cursor with `awaitData` until new data arrives or the
/// `maxAwaitTimeMS` budget expires.
async fn poll_tailable_cursor(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    initial_results: Vec<tokio_postgres::Row>,
    state: &PollCursorState<'_>,
) -> Result<(Vec<tokio_postgres::Row>, Option<RawDocumentBuf>)> {
    let dynamic_config = connection_context.service_context.dynamic_configuration();
    let slice_interval_ms = dynamic_config.tailable_cursor_await_time_slice_interval_ms();
    // Clamp to >= 1ms so a misconfigured 0 (or negative) interval can't turn the
    // poll loop into a busy-loop that hammers the backend with getMore calls.
    let slice_interval =
        Duration::from_millis(u64::try_from(slice_interval_ms).unwrap_or(1).max(1));

    let start = tokio::time::Instant::now();
    let max_await = Duration::from_millis(u64::try_from(state.max_await_time_ms).unwrap_or(0));
    let mut current_results = initial_results;

    loop {
        // Recompute remaining budget each iteration so the total wait never
        // exceeds max_await by more than the time spent in the getMore call
        // itself. A fixed slice_duration sleep would otherwise overshoot the
        // budget by up to one full slice interval near the deadline.
        let remaining = max_await.saturating_sub(start.elapsed());
        if remaining.is_zero() {
            break;
        }

        // If there's no continuation, the cursor is exhausted.
        let Some(continuation) = extract_continuation(&current_results)? else {
            break;
        };

        let sleep_duration = std::cmp::min(slice_interval, remaining);
        tokio::time::sleep(sleep_duration).await;

        let poll_cursor = Cursor {
            cursor_id: CursorId::from(state.cursor_id),
            continuation,
        };

        current_results = pg_data_client
            .execute_cursor_get_more(
                request_context,
                state.db,
                &poll_cursor,
                match state.cursor_connection {
                    Some(conn) => PullConnection::Cursor(Arc::clone(conn)),
                    None => PullConnection::PoolOrTransaction,
                },
                connection_context,
            )
            .await?;

        // Backend returns maxAwaitTimeMS == 0 when data is present.
        if extract_max_await_time_ms(&current_results) == 0 {
            break;
        }
    }

    let final_continuation = extract_continuation(&current_results)?;
    Ok((current_results, final_continuation))
}

async fn post_process_get_more_results(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    results: Vec<tokio_postgres::Row>,
    cursor_id: i64,
    cursor_connection: Option<&Arc<Connection>>,
    db: &str,
) -> Result<(Vec<tokio_postgres::Row>, Option<RawDocumentBuf>)> {
    // Check if the backend returned maxAwaitTimeMS (column index 2 when present).
    // If > 0, this is a tailable cursor with an empty batch — poll until data arrives
    // or the timeout expires. Polling is gated by the enableTailableCursorMaxAwaitTime config.
    let max_await_time_ms = extract_max_await_time_ms(&results);
    let polling_enabled = connection_context
        .service_context
        .dynamic_configuration()
        .enable_tailable_cursor_max_await_time();

    if max_await_time_ms > 0 && polling_enabled {
        let cursor_connection_owned = cursor_connection.cloned();
        poll_tailable_cursor(
            request_context,
            connection_context,
            pg_data_client,
            results,
            &PollCursorState {
                cursor_id,
                cursor_connection: &cursor_connection_owned,
                db,
                max_await_time_ms,
            },
        )
        .await
    } else {
        let continuation = extract_continuation(&results)?;
        Ok((results, continuation))
    }
}

pub async fn process_get_more(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request = request_context.request();

    let id = validate_get_more_arguments(request)?;

    let caller = connection_context.user().principal()?;

    // Surface the continued cursor id for diagnostics.
    request_context.tracker.set_cursor_id(id);

    // We use the session id from the request context since we may, or may not be in a transaction.
    let current_lsid = request_context.request().lsid();
    let current_transaction_number = request_context
        .request()
        .transaction_info()
        .map(|t| &t.transaction_number);

    let cursor_ref =
        connection_context
            .get_cursor_ref(id, caller)
            .ok_or(DocumentDBError::documentdb_error(
                ErrorCode::CursorNotFound,
                "Cursor not found in server".to_owned(),
            ))?;

    // Validate Get More Request
    validate_get_more_request(
        current_lsid,
        current_transaction_number,
        cursor_ref.lsid(),
        cursor_ref.transaction_number(),
    )?;

    let CursorStoreEntry {
        conn: cursor_connection,
        cursor,
        db,
        collection,
        lsid,
        transaction_number,
        cursor_timeout,
        ..
    } = connection_context
        .get_cursor(id, caller)
        .ok_or(DocumentDBError::documentdb_error(
            ErrorCode::CursorNotFound,
            "Cursor not found in server".to_owned(),
        ))?;

    let results = pg_data_client
        .execute_cursor_get_more(
            request_context,
            &db,
            &cursor,
            match &cursor_connection {
                Some(conn) => PullConnection::Cursor(Arc::clone(conn)),
                None => PullConnection::PoolOrTransaction,
            },
            connection_context,
        )
        .await?;

    let (final_results, final_continuation) = post_process_get_more_results(
        request_context,
        connection_context,
        pg_data_client,
        results,
        id,
        cursor_connection.as_ref(),
        &db,
    )
    .await?;

    if let Some(continuation) = final_continuation {
        connection_context.return_cursor(
            cursor_connection,
            Cursor {
                cursor_id: CursorId::from(id),
                continuation,
            },
            &db,
            &collection,
            cursor_timeout,
            lsid,
            transaction_number,
            caller,
        );
    } else {
        connection_context.close_cursor(
            lsid.as_ref(),
            transaction_number,
            CursorId::from(id),
            caller,
        );
    }

    Ok(Response::Pg(PgResponse::new(final_results)))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn sid(bytes: &[u8]) -> LogicalSessionId {
        LogicalSessionId::from(bytes)
    }

    fn tn(value: i64) -> TransactionNumber {
        TransactionNumber::from(value)
    }

    #[test]
    fn validate_get_more_request_no_session_no_transaction_ok() {
        validate_get_more_request(None, None, None, None).unwrap();
    }

    #[test]
    fn validate_get_more_request_matching_session_ok() {
        let s = sid(b"session-1");
        validate_get_more_request(Some(&s), None, Some(&s), None).unwrap();
    }

    #[test]
    fn validate_get_more_request_matching_session_and_transaction_ok() {
        let s = sid(b"session-1");
        let t = tn(7);
        validate_get_more_request(Some(&s), Some(&t), Some(&s), Some(&t)).unwrap();
    }

    #[test]
    fn validate_get_more_request_request_session_but_cursor_has_none() {
        let s = sid(b"session-1");
        let err = validate_get_more_request(Some(&s), None, None, None).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location50736);
        assert!(
            err.to_string().contains("was not created in a session"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_get_more_request_cursor_session_but_request_has_none() {
        let s = sid(b"session-1");
        let err = validate_get_more_request(None, None, Some(&s), None).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location50737);
        assert!(
            err.to_string().contains("without an lsid"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_get_more_request_session_mismatch() {
        let req = sid(b"session-req");
        let cur = sid(b"session-cur");
        let err = validate_get_more_request(Some(&req), None, Some(&cur), None).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location50738);
        let msg = err.to_string();
        assert!(msg.contains("session-cur") || msg.contains("SessionId"));
        assert!(msg.contains("in session"), "unexpected error: {err}");
    }

    #[test]
    fn validate_get_more_request_request_transaction_but_cursor_has_none() {
        let t = tn(3);
        let err = validate_get_more_request(None, Some(&t), None, None).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location50739);
        assert!(
            err.to_string().contains("was not created in a transaction"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_get_more_request_cursor_transaction_but_request_has_none() {
        let t = tn(3);
        let err = validate_get_more_request(None, None, None, Some(&t)).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location50740);
        assert!(
            err.to_string().contains("without a transaction"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_get_more_request_transaction_mismatch() {
        let req = tn(1);
        let cur = tn(2);
        let err = validate_get_more_request(None, Some(&req), None, Some(&cur)).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location50741);
        let msg = err.to_string();
        assert!(
            msg.contains("created in a transaction 2") && msg.contains("in transaction 1"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_get_more_request_transaction_check_skipped_when_session_present() {
        // When a session id is present on the connection, transaction-number
        // mismatches are not checked.
        let s = sid(b"session-1");
        let req = tn(1);
        let cur = tn(2);
        validate_get_more_request(Some(&s), Some(&req), Some(&s), Some(&cur)).unwrap();
    }

    #[test]
    fn validate_get_more_request_session_error_takes_precedence_over_transaction() {
        let req_s = sid(b"session-req");
        let cur_s = sid(b"session-cur");
        let req_t = tn(1);
        let cur_t = tn(2);
        let err = validate_get_more_request(Some(&req_s), Some(&req_t), Some(&cur_s), Some(&cur_t))
            .unwrap_err();
        assert!(
            err.to_string().contains("session"),
            "expected session error, got: {err}"
        );
    }

    use std::str::FromStr;

    use crate::requests::{RequestExecutionMode, RequestType};

    fn get_more_request(doc: RawDocumentBuf) -> WireRequest<'static> {
        WireRequest::from_owned_command_document(
            RequestType::GetMore,
            RequestExecutionMode::Normal,
            None,
            doc,
            None,
        )
        .expect("getMore command should parse common fields")
    }

    fn expect_arg_error(doc: RawDocumentBuf) -> ErrorCode {
        validate_get_more_arguments(&get_more_request(doc))
            .expect_err("expected getMore argument validation to fail")
            .error_code()
    }

    #[test]
    fn get_more_args_valid_returns_cursor_id() {
        let doc = rawdoc! { "getMore": 42_i64, "collection": "users", "$db": "app" };
        let id = validate_get_more_arguments(&get_more_request(doc)).expect("valid getMore");
        assert_eq!(id, 42);
    }

    #[test]
    fn get_more_args_cursor_id_wrong_type_is_type_mismatch() {
        for doc in [
            rawdoc! { "getMore": 42_i32, "collection": "users", "$db": "app" },
            rawdoc! { "getMore": 1.0_f64, "collection": "users", "$db": "app" },
            rawdoc! { "getMore": "123", "collection": "users", "$db": "app" },
            rawdoc! { "getMore": true, "collection": "users", "$db": "app" },
        ] {
            assert_eq!(expect_arg_error(doc), ErrorCode::TypeMismatch);
        }
    }

    #[test]
    fn get_more_args_null_cursor_id_is_missing_field() {
        let doc = rawdoc! { "getMore": bson::RawBson::Null, "collection": "users", "$db": "app" };
        assert_eq!(expect_arg_error(doc), ErrorCode::Location40414);
    }

    #[test]
    fn get_more_args_collection_wrong_type_is_type_mismatch() {
        let doc = rawdoc! { "getMore": 1_i64, "collection": 5_i32, "$db": "app" };
        assert_eq!(expect_arg_error(doc), ErrorCode::TypeMismatch);
    }

    #[test]
    fn get_more_args_null_or_missing_collection_is_missing_field() {
        let null_collection =
            rawdoc! { "getMore": 1_i64, "collection": bson::RawBson::Null, "$db": "app" };
        assert_eq!(expect_arg_error(null_collection), ErrorCode::Location40414);

        let missing_collection = rawdoc! { "getMore": 1_i64, "$db": "app" };
        assert_eq!(
            expect_arg_error(missing_collection),
            ErrorCode::Location40414
        );
    }

    #[test]
    fn get_more_args_batch_size_wrong_type_is_type_mismatch() {
        for doc in [
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": "1", "$db": "app" },
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": true, "$db": "app" },
        ] {
            assert_eq!(expect_arg_error(doc), ErrorCode::TypeMismatch);
        }
    }

    #[test]
    fn get_more_args_negative_batch_size_is_bad_value() {
        for doc in [
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": -1_i32, "$db": "app" },
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": -5_i64, "$db": "app" },
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": -1.5_f64, "$db": "app" },
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": f64::NEG_INFINITY, "$db": "app" },
            rawdoc! {
                "getMore": 1_i64,
                "collection": "users",
                "batchSize": Decimal128::from_str("-0.50001").unwrap(),
                "$db": "app",
            },
            rawdoc! {
                "getMore": 1_i64,
                "collection": "users",
                "batchSize": Decimal128::from_str("-Infinity").unwrap(),
                "$db": "app",
            },
        ] {
            assert_eq!(expect_arg_error(doc), ErrorCode::BadValue);
        }
    }

    #[test]
    fn get_more_args_accepts_non_negative_batch_size() {
        for doc in [
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": 0_i32, "$db": "app" },
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": 4_i64, "$db": "app" },
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": 1.5_f64, "$db": "app" },
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": -0.0_f64, "$db": "app" },
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": f64::INFINITY, "$db": "app" },
            rawdoc! {
                "getMore": 1_i64,
                "collection": "users",
                "batchSize": Decimal128::from_str("-0.5").unwrap(),
                "$db": "app",
            },
            rawdoc! { "getMore": 1_i64, "collection": "users", "batchSize": bson::RawBson::Null, "$db": "app" },
        ] {
            validate_get_more_arguments(&get_more_request(doc))
                .expect("non-negative batchSize should be accepted");
        }
    }

    #[test]
    fn get_more_args_unrecognized_field_is_unknown_bson_field() {
        for doc in [
            rawdoc! { "getMore": 1_i64, "collection": "users", "filter": { "x": 1_i32 }, "$db": "app" },
            rawdoc! { "getMore": 1_i64, "collection": "users", "unknownField": 123_i32, "$db": "app" },
        ] {
            assert_eq!(expect_arg_error(doc), ErrorCode::UnknownBsonField);
        }
    }

    #[test]
    fn get_more_args_allows_metadata_and_recognized_fields() {
        let doc = rawdoc! {
            "getMore": 7_i64,
            "collection": "users",
            "batchSize": 10_i32,
            "comment": "trace",
            "lsid": { "id": bson::Binary { subtype: bson::spec::BinarySubtype::Uuid, bytes: vec![0_u8; 16] } },
            "txnNumber": 1_i64,
            "autocommit": false,
            "startTransaction": true,
            "stmtId": 1_i32,
            "$clusterTime": { "clusterTime": bson::Timestamp { time: 1, increment: 1 } },
            "$db": "app",
        };
        let id = validate_get_more_arguments(&get_more_request(doc))
            .expect("recognized and metadata fields should be accepted");
        assert_eq!(id, 7);
    }

    #[test]
    fn decimal128_rounds_negative_matches_exact_boundary() {
        // Values strictly less than -0.5 round to a negative integer.
        for s in [
            "-0.50001",
            "-0.5000000000000000000000000000000001",
            "-0.6",
            "-1",
            "-1.5",
            "-9999999999999999999999999999999999",
            "-Infinity",
        ] {
            let value = Decimal128::from_str(s).unwrap();
            assert!(
                decimal128_rounds_negative(&value),
                "expected {s} to be treated as negative"
            );
        }

        // Values in [-0.5, 0], positive values, NaN, and positive infinity do
        // not round to a negative integer.
        for s in [
            "-0.5",
            "-0.4999999999999999999999999999999999",
            "-0.4",
            "-0.0",
            "-5E-30",
            "0",
            "0.5",
            "1",
            "1.5",
            "0.50001",
            "Infinity",
            "NaN",
            "-NaN",
        ] {
            let value = Decimal128::from_str(s).unwrap();
            assert!(
                !decimal128_rounds_negative(&value),
                "expected {s} to not be treated as negative"
            );
        }
    }

    #[test]
    fn get_more_args_sub_ulp_negative_decimal_is_bad_value() {
        // A value indistinguishable from -0.5 as an f64 but exactly less than
        // -0.5 must still be rejected.
        let doc = rawdoc! {
            "getMore": 1_i64,
            "collection": "users",
            "batchSize": Decimal128::from_str("-0.5000000000000000000000000000000001").unwrap(),
            "$db": "app",
        };
        assert_eq!(expect_arg_error(doc), ErrorCode::BadValue);
    }

    #[test]
    fn get_more_args_just_above_neg_half_decimal_is_accepted() {
        // A value indistinguishable from -0.5 as an f64 but exactly greater than
        // -0.5 must be accepted.
        let doc = rawdoc! {
            "getMore": 1_i64,
            "collection": "users",
            "batchSize": Decimal128::from_str("-0.4999999999999999999999999999999999").unwrap(),
            "$db": "app",
        };
        validate_get_more_arguments(&get_more_request(doc))
            .expect("value greater than -0.5 should be accepted");
    }
}
