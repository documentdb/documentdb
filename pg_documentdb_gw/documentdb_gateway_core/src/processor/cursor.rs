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
    context::{ConnectionContext, Cursor, CursorId, CursorStoreEntry, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{conn_mgmt::PullConnection, PgDataClient, PgDocument},
    protocol::OK_SUCCEEDED,
    responses::{PgResponse, RawResponse, Response},
};

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
        .kill_cursors(connection_context.auth_state.username()?, &cursor_ids);

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

    Ok(Response::Raw(RawResponse(rawdoc! {
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
    let id = id.ok_or(DocumentDBError::bad_value(
        "getMore not present in document".to_owned(),
    ))?;
    let CursorStoreEntry {
        conn: cursor_connection,
        cursor,
        db,
        collection,
        session_id,
        mut cursor_timeout,
        ..
    } = connection_context
        .get_cursor(id, connection_context.auth_state.username()?)
        .ok_or(DocumentDBError::documentdb_error(
            ErrorCode::CursorNotFound,
            "Provided cursor was not found.".to_owned(),
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
                connection_context.auth_state.username()?,
                &db,
                &collection,
                cursor_timeout,
                session_id,
            );
        }
    }

    Ok(Response::Pg(PgResponse::new(results)))
}
