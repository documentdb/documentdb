/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/cursor.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{sync::Arc, time::Duration};

use bson::{rawdoc, RawArrayBuf};

use crate::{
    context::{
        ConnectionContext, Cursor, CursorId, CursorStoreEntry, LogicalSessionId, RequestContext,
        TransactionNumber,
    },
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{conn_mgmt::PullConnection, PgDataClient, PgDocument},
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
    let request = request_context.payload;

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

pub async fn process_get_more(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request = request_context.payload;

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
    let current_lsid = request_context.info().lsid.as_ref();
    let current_transaction_number = request_context
        .info()
        .transaction_info
        .as_ref()
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

    if !connection_context
        .service_context
        .dynamic_configuration()
        .enable_stateless_cursor_timeout()
    {
        cursor_timeout = Duration::from_secs(
            connection_context
                .service_context
                .dynamic_configuration()
                .default_cursor_idle_timeout_sec(),
        );
    }

    if let Some(row) = results.first() {
        let continuation: Option<PgDocument> = row.try_get(1)?;
        if let Some(continuation) = continuation {
            connection_context.add_cursor(
                cursor_connection,
                Cursor {
                    cursor_id: CursorId::from(id),
                    continuation: continuation.0.to_raw_document_buf(),
                },
                &db,
                &collection,
                cursor_timeout,
                lsid,
                transaction_number,
                caller,
            );
        }
    }

    Ok(Response::Pg(PgResponse::new(results)))
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
