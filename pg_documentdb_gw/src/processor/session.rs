/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/processor/session.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::RawArray;

use crate::{
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, Result},
    postgres::PgDataClient,
    requests::RequestType,
    responses::Response,
};

fn parse_session_ids(sessions_field: &RawArray) -> Result<Vec<&[u8]>> {
    let mut session_ids = Vec::new();
    for session in sessions_field {
        let session_doc = session?.as_document().ok_or_else(|| {
            DocumentDBError::bad_value("Session should be a document".to_string())
        })?;

        let session_id = session_doc
            .get_binary("id")
            .map_err(DocumentDBError::parse_failure())?
            .bytes;

        session_ids.push(session_id);
    }
    Ok(session_ids)
}

async fn terminate_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    sessions_field: &RawArray,
) -> Result<()> {
    let session_ids = parse_session_ids(sessions_field)?;

    let transaction_store = connection_context.service_context.transaction_store();

    for session_id in session_ids {
        // Remove all cursors for the session
        let cursor_ids = connection_context
            .service_context
            .cursor_store()
            .invalidate_cursors_by_session(session_id);

        if !cursor_ids.is_empty() {
            if let Err(e) = pg_data_client
                .execute_kill_cursors(request_context, connection_context, &cursor_ids)
                .await
            {
                tracing::warn!("Error killing cursors for session {:?}: {}", session_id, e);
            }
        }

        // Best effort to remove any transaction for the session
        let _ = transaction_store
            .remove_transaction_by_session(session_id)
            .await?;
    }

    Ok(())
}

pub async fn end_or_kill_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request = request_context.payload;

    let key = if request_context.payload.request_type() == &RequestType::KillSessions {
        "killSessions"
    } else {
        "endSessions"
    };

    let sessions_field = request
        .document()
        .get_array(key)
        .map_err(DocumentDBError::parse_failure())?;

    terminate_sessions(
        request_context,
        connection_context,
        pg_data_client,
        sessions_field,
    )
    .await?;

    Ok(Response::ok())
}
