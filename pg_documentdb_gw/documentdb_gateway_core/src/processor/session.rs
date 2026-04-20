/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/session.rs
 *
 *-------------------------------------------------------------------------
 */

use std::collections::HashSet;

use bson::RawArray;

use crate::{
    context::{ConnectionContext, RequestContext, SessionId},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::PgDataClient,
    requests::RequestType,
    responses::Response,
};

const ADMIN_DB: &str = "admin";

type SessionUserPatterns = HashSet<(String, String)>;

fn parse_session_ids(sessions_field: &RawArray) -> Result<Vec<SessionId>> {
    let mut session_ids = Vec::new();
    for session in sessions_field {
        let session_doc = session?
            .as_document()
            .ok_or_else(|| DocumentDBError::bad_value("Session should be a document".to_owned()))?;

        let session_id = SessionId::from(
            session_doc
                .get_binary("id")
                .map_err(DocumentDBError::parse_failure())?
                .bytes,
        );

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

    for session_id in &session_ids {
        // Remove all cursors for the session
        let mut cursor_ids = connection_context
            .service_context
            .cursor_store()
            .invalidate_cursors_by_session(session_id);

        if let Some((_, (_, transaction))) = transaction_store
            .remove_transaction_by_session(session_id)
            .await?
        {
            cursor_ids.extend(transaction.cursors.invalidate_all_cursors());
        }

        cursor_ids.sort_unstable();
        cursor_ids.dedup();

        if !cursor_ids.is_empty() {
            if let Err(e) = pg_data_client
                .execute_kill_cursors(request_context, connection_context, &cursor_ids)
                .await
            {
                tracing::warn!("Error killing cursors for session {:?}: {}", session_id, e);
            }
        }
    }

    Ok(())
}

fn parse_kill_all_session_users(users_field: &RawArray) -> Result<Option<SessionUserPatterns>> {
    let mut users = SessionUserPatterns::new();

    for user in users_field {
        let user_doc = user?.as_document().ok_or_else(|| {
            DocumentDBError::bad_value("Each killAllSessions entry must be a document".to_owned())
        })?;

        let username = user_doc
            .get_str("user")
            .map_err(DocumentDBError::parse_failure())?;
        let db = user_doc
            .get_str("db")
            .map_err(DocumentDBError::parse_failure())?;

        users.insert((username.to_owned(), db.to_owned()));
    }

    Ok((!users.is_empty()).then_some(users))
}

fn validate_admin_db(request_context: &RequestContext<'_>, command_name: &str) -> Result<()> {
    if request_context.info.db()? != ADMIN_DB {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::Unauthorized,
            format!("{command_name} may only be run against the admin database."),
        ));
    }

    Ok(())
}

async fn kill_matching_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    users: Option<&SessionUserPatterns>,
) -> Result<()> {
    let mut cursor_ids = match users {
        Some(users) => {
            let usernames = users
                .iter()
                .filter(|(_, db)| db == ADMIN_DB)
                .map(|(user, _)| user.clone())
                .collect::<HashSet<_>>();

            let mut cursor_ids = Vec::new();
            for username in usernames {
                cursor_ids.extend(
                    connection_context
                        .service_context
                        .cursor_store()
                        .invalidate_cursors_by_user(&username),
                );
            }

            for (_, (_, transaction)) in connection_context
                .service_context
                .transaction_store()
                .remove_transactions_by_users(users)
                .await?
            {
                cursor_ids.extend(transaction.cursors.invalidate_all_cursors());
            }

            cursor_ids
        }
        None => {
            let mut cursor_ids = connection_context
                .service_context
                .cursor_store()
                .invalidate_all_cursors();

            for (_, (_, transaction)) in connection_context
                .service_context
                .transaction_store()
                .remove_all_transactions()
                .await?
            {
                cursor_ids.extend(transaction.cursors.invalidate_all_cursors());
            }

            cursor_ids
        }
    };

    cursor_ids.sort_unstable();
    cursor_ids.dedup();

    if !cursor_ids.is_empty() {
        if let Err(e) = pg_data_client
            .execute_kill_cursors(request_context, connection_context, &cursor_ids)
            .await
        {
            tracing::warn!("Error killing cursors during killAllSessions: {e}");
        }
    }

    Ok(())
}

pub async fn end_or_kill_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request = request_context.payload;

    let key = if request_context.payload.request_type() == RequestType::KillSessions {
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

pub async fn kill_all_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    validate_admin_db(request_context, "killAllSessions")?;

    let users_field = request_context
        .payload
        .document()
        .get_array("killAllSessions")
        .map_err(DocumentDBError::parse_failure())?;

    let users = parse_kill_all_session_users(users_field)?;

    kill_matching_sessions(
        request_context,
        connection_context,
        pg_data_client,
        users.as_ref(),
    )
    .await?;

    Ok(Response::ok())
}

#[cfg(test)]
mod tests {
    use bson::rawdoc;

    use super::parse_kill_all_session_users;

    #[test]
    fn parse_kill_all_sessions_empty_array_returns_none() {
        let request = rawdoc! {
            "killAllSessions": []
        };

        let users = parse_kill_all_session_users(request.get_array("killAllSessions").unwrap())
            .expect("killAllSessions parsing should succeed");

        assert!(users.is_none());
    }

    #[test]
    fn parse_kill_all_sessions_users_returns_patterns() {
        let request = rawdoc! {
            "killAllSessions": [
                { "user": "alice", "db": "admin" },
                { "user": "bob", "db": "admin" }
            ]
        };

        let users = parse_kill_all_session_users(request.get_array("killAllSessions").unwrap())
            .expect("killAllSessions parsing should succeed")
            .expect("killAllSessions should contain user patterns");

        assert!(users.contains(&("alice".to_owned(), "admin".to_owned())));
        assert!(users.contains(&("bob".to_owned(), "admin".to_owned())));
        assert_eq!(users.len(), 2);
    }
}
