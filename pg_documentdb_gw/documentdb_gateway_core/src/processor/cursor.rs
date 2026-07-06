/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/cursor.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{sync::Arc, time::Duration};

use bson::{rawdoc, RawArrayBuf, RawDocumentBuf};

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
    responses::{PgResponse, RawResponse, Response},
};

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
            // ErrorCode: 50736
            return Err(DocumentDBError::internal_error(format!(
                "Cannot run getMore on cursor, which was not created in a session, in session {req_sid:?}"
            )));
        }
        (None, Some(cur_sid)) => {
            // ErrorCode: 50737
            return Err(DocumentDBError::internal_error(format!(
                "Cannot run getMore on cursor, which was created in session {cur_sid:?}, without an lsid."
            )));
        }
        (Some(req_sid), Some(cur_sid)) if req_sid != cur_sid => {
            // ErrorCode: 50738
            return Err(DocumentDBError::internal_error(format!(
                "Cannot run getMore on cursor, which was created in session {cur_sid:?}, in session {req_sid:?}"
            )));
        }
        _ => {}
    }

    // Transaction number validation (only when there is no session)
    if connection_lsid.is_none() {
        match (connection_transaction_number, cursor_transaction_number) {
            (Some(req_tn), None) => {
                // ErrorCode: 50739
                return Err(DocumentDBError::internal_error(format!(
                    "Cannot run getMore on cursor, which was not created in a transaction, in transaction {req_tn}"
                )));
            }
            (None, Some(cur_tn)) => {
                // ErrorCode: 50740
                return Err(DocumentDBError::internal_error(format!(
                    "Cannot run getMore on cursor, which was created in a transaction {cur_tn}, without a transaction."
                )));
            }
            (Some(req_tn), Some(cur_tn)) if req_tn != cur_tn => {
                // ErrorCode: 50741
                return Err(DocumentDBError::internal_error(format!(
                    "Cannot run getMore on cursor, which was created in a transaction {cur_tn}, in transaction {req_tn}"
                )));
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
    let (removed_cursors, missing_cursors) = connection_context
        .service_context
        .cursor_store()
        .kill_cursors(&cursor_ids, connection_context.auth_state.principal()?);

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

#[expect(
    clippy::too_many_arguments,
    reason = "helper extracted from process_get_more"
)]
async fn post_process_get_more_results(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    results: Vec<tokio_postgres::Row>,
    cursor_id: i64,
    cursor_connection: Option<&Arc<Connection>>,
    db: &str,
    cursor_timeout: &mut Duration,
) -> Result<(Vec<tokio_postgres::Row>, Option<RawDocumentBuf>)> {
    if !connection_context
        .service_context
        .dynamic_configuration()
        .enable_stateless_cursor_timeout()
    {
        *cursor_timeout = Duration::from_secs(
            connection_context
                .service_context
                .dynamic_configuration()
                .default_cursor_idle_timeout_sec(),
        );
    }

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

    let mut id = None;
    request.extract_fields(|k, v| {
        if k == "getMore" {
            id = Some(v.as_i64().ok_or(DocumentDBError::bad_value(
                "getMore value should be an i64".to_owned(),
            ))?);
        }
        Ok(())
    })?;

    let caller = connection_context.auth_state.principal()?;

    let id = id.ok_or(DocumentDBError::bad_value(
        "getMore not present in document".to_owned(),
    ))?;

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
        mut cursor_timeout,
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
        &mut cursor_timeout,
    )
    .await?;

    if let Some(continuation) = final_continuation {
        connection_context.add_cursor(
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
        assert!(
            err.to_string().contains("was not created in a session"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_get_more_request_cursor_session_but_request_has_none() {
        let s = sid(b"session-1");
        let err = validate_get_more_request(None, None, Some(&s), None).unwrap_err();
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
        let msg = err.to_string();
        assert!(msg.contains("session-cur") || msg.contains("SessionId"));
        assert!(msg.contains("in session"), "unexpected error: {err}");
    }

    #[test]
    fn validate_get_more_request_request_transaction_but_cursor_has_none() {
        let t = tn(3);
        let err = validate_get_more_request(None, Some(&t), None, None).unwrap_err();
        assert!(
            err.to_string().contains("was not created in a transaction"),
            "unexpected error: {err}"
        );
    }

    #[test]
    fn validate_get_more_request_cursor_transaction_but_request_has_none() {
        let t = tn(3);
        let err = validate_get_more_request(None, None, None, Some(&t)).unwrap_err();
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
}
