/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/session.rs
 *
 *-------------------------------------------------------------------------
 */

use std::collections::HashSet;

use bson::{spec::BinarySubtype, RawArray, RawBsonRef, RawDocument};

use crate::{
    context::{map_transaction_error, ConnectionContext, LogicalSessionId, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::PgDataClient,
    requests::RequestType,
    responses::Response,
    security::principal::Principal,
};

/// Validates a single logical-session-id document and returns its session id.
///
/// The document must contain exactly one field, `id`, whose value is a binary
/// value of UUID subtype. Any other field is rejected as an unknown field, a
/// missing or null `id` is reported as a missing required field, and a
/// non-UUID `id` value is reported as a type mismatch.
fn parse_session_id_document(session_doc: &RawDocument) -> Result<LogicalSessionId> {
    let mut id_value: Option<RawBsonRef> = None;

    for entry in session_doc {
        let (key, value) = entry?;
        if key == "id" {
            id_value = Some(value);
        } else {
            return Err(DocumentDBError::documentdb_error(
                ErrorCode::UnknownBsonField,
                format!("BSON field 'id' is an unknown field: '{key}'"),
            ));
        }
    }

    let id_value = id_value.ok_or_else(|| {
        DocumentDBError::documentdb_error(
            ErrorCode::Location40414,
            "BSON field 'lsid.id' is missing but a required field".to_owned(),
        )
    })?;

    match id_value {
        RawBsonRef::Null => Err(DocumentDBError::documentdb_error(
            ErrorCode::Location40414,
            "BSON field 'lsid.id' is missing but a required field".to_owned(),
        )),
        RawBsonRef::Binary(binary) if binary.subtype == BinarySubtype::Uuid => {
            Ok(LogicalSessionId::from(binary.bytes))
        }
        _ => Err(DocumentDBError::type_mismatch(
            "BSON field 'lsid.id' is the wrong type, expected type 'binData'".to_owned(),
        )),
    }
}

fn parse_logical_session_ids(
    sessions_field: &RawArray,
    strict: bool,
) -> Result<Vec<LogicalSessionId>> {
    let mut logical_session_ids = Vec::new();
    for session in sessions_field {
        if strict {
            match session? {
                // Null array elements are accepted and contribute no session id.
                RawBsonRef::Null => {}
                RawBsonRef::Document(session_doc) => {
                    logical_session_ids.push(parse_session_id_document(session_doc)?);
                }
                _ => {
                    return Err(DocumentDBError::type_mismatch(
                        "Session id entry must be a document".to_owned(),
                    ))
                }
            }
        } else {
            let session_doc = session?.as_document().ok_or_else(|| {
                DocumentDBError::bad_value("Session should be a document".to_owned())
            })?;

            let lsid = LogicalSessionId::from(
                session_doc
                    .get_binary("id")
                    .map_err(DocumentDBError::parse_failure())?
                    .bytes,
            );

            logical_session_ids.push(lsid);
        }
    }
    Ok(logical_session_ids)
}

async fn terminate_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    sessions_field: &RawArray,
    strict: bool,
) -> Result<()> {
    let logical_session_ids = parse_logical_session_ids(sessions_field, strict)?;
    let caller = connection_context.user().principal()?;
    let transaction_store = connection_context.service_context.transaction_store();
    let is_replica_cluster = connection_context
        .dynamic_configuration()
        .is_replica_cluster();
    let activity_id = request_context.activity_id;

    for lsid in &logical_session_ids {
        // Remove all cursors for the session
        let cursor_ids = connection_context
            .service_context
            .cursor_store()
            .invalidate_cursors_by_session(lsid);

        if !cursor_ids.is_empty() {
            if let Err(e) = pg_data_client
                .execute_kill_cursors(request_context, connection_context, &cursor_ids)
                .await
            {
                tracing::warn!("Error killing cursors for session {:?}: {}", lsid, e);
            }
        }

        // Best effort to remove any transaction for the session
        let _ = transaction_store
            .remove_transaction_by_session(lsid, caller)
            .await
            .map_err(|e| map_transaction_error(e, is_replica_cluster, activity_id))?;
    }

    Ok(())
}

pub async fn end_or_kill_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    let request = request_context.request();

    // Disabling shape validation must not disable authorization or termination.
    let strict = connection_context
        .dynamic_configuration()
        .enable_session_argument_validation();

    let key = if request_context.request_type() == RequestType::KillSessions {
        "killSessions"
    } else {
        "endSessions"
    };

    let sessions_field = if strict {
        let command_value = request
            .document()
            .get(key)?
            .ok_or_else(|| session_command_missing_field(key))?;

        match command_value {
            RawBsonRef::Null => return Err(session_command_missing_field(key)),
            RawBsonRef::Array(sessions_field) => sessions_field,
            _ => {
                return Err(DocumentDBError::type_mismatch(format!(
                    "BSON field '{key}' is the wrong type, expected type 'array'"
                )))
            }
        }
    } else {
        request
            .document()
            .get_array(key)
            .map_err(DocumentDBError::parse_failure())?
    };

    terminate_sessions(
        request_context,
        connection_context,
        pg_data_client,
        sessions_field,
        strict,
    )
    .await?;

    Ok(Response::ok())
}

fn session_command_missing_field(key: &str) -> DocumentDBError {
    DocumentDBError::documentdb_error(
        ErrorCode::Location40414,
        format!("BSON field '{key}' is missing but a required field"),
    )
}

/// Terminates sessions selected by the `killAllSessions` command.
///
/// The command value must be an array of `{ user, db }` documents. Shape
/// violations are reported with wire-protocol-compatible error codes so that
/// strict clients observe the documented semantics.
///
/// Authorization follows the documented `killAnySession` privilege model:
///
/// * A caller may always terminate its own sessions by naming only itself in
///   the filter.
/// * Terminating another principal's sessions, or every session via an empty
///   filter, requires the `killAnySession` privilege. A caller without it
///   receives an `Unauthorized` error and nothing is terminated, so the empty
///   and other-user forms cannot be used to bypass the check (including a
///   filter that mixes the caller with other principals).
///
/// For a privileged caller an empty array selects every session and a non-empty
/// array selects the sessions owned by the named users. A supported user
/// authenticates against the `admin` database, so an entry is matched only when
/// its `db` is `admin`; an entry naming any other database refers to a
/// principal that cannot exist and therefore matches nothing.
///
/// Termination mirrors `killSessions`/`endSessions`: every selected cursor is
/// invalidated (and killed on the backend) and every selected active
/// transaction is aborted.
pub async fn kill_all_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<Response> {
    const KEY: &str = "killAllSessions";
    // Supported users authenticate against the `admin` database, so it is the
    // only database in which a named principal can own a live session.
    const AUTHENTICATION_DATABASE: &str = "admin";
    let request = request_context.request();

    let strict = connection_context
        .dynamic_configuration()
        .enable_session_argument_validation();
    let entries = if strict {
        let command_value = request
            .document()
            .get(KEY)?
            .ok_or_else(|| session_command_missing_field(KEY))?;
        match command_value {
            RawBsonRef::Null => return Err(session_command_missing_field(KEY)),
            RawBsonRef::Array(entries) => entries,
            _ => {
                return Err(DocumentDBError::type_mismatch(format!(
                    "BSON field '{KEY}' is the wrong type, expected type 'array'"
                )))
            }
        }
    } else {
        request
            .document()
            .get_array(KEY)
            .map_err(DocumentDBError::parse_failure())?
    };

    let caller = connection_context.user().principal()?;

    let mut target_users = HashSet::new();
    let mut has_entries = false;
    let mut every_entry_is_caller = true;
    for entry in entries {
        match entry? {
            // Null array elements are accepted and ignored.
            RawBsonRef::Null => {}
            RawBsonRef::Document(entry_doc) => {
                has_entries = true;
                let (user, db) = if strict {
                    validate_kill_all_sessions_entry(entry_doc)?
                } else {
                    (
                        entry_doc
                            .get_str("user")
                            .map_err(DocumentDBError::parse_failure())?,
                        entry_doc
                            .get_str("db")
                            .map_err(DocumentDBError::parse_failure())?,
                    )
                };
                // A supported user lives in the `admin` database, so only
                // `admin` entries can select a live session.
                let matches_live_principal = db == AUTHENTICATION_DATABASE;
                if matches_live_principal {
                    target_users.insert(user.to_owned());
                }
                if !(matches_live_principal && user == caller.name()) {
                    every_entry_is_caller = false;
                }
            }
            _ => {
                return Err(DocumentDBError::type_mismatch(
                    "killAllSessions user entry must be a document".to_owned(),
                ))
            }
        }
    }

    // A caller may always terminate its own sessions. This holds only when the
    // filter names at least one principal and every named principal is the
    // caller in its own authentication database.
    let targets_only_caller = has_entries && every_entry_is_caller;
    if targets_only_caller {
        terminate_owner_sessions(request_context, connection_context, pg_data_client, caller)
            .await?;
        return Ok(Response::ok());
    }

    // Every other form (an empty filter, or a filter naming any other
    // principal) terminates sessions the caller does not necessarily own and
    // requires the cluster-wide privilege.
    if !pg_data_client
        .caller_holds_kill_any_session(request_context, connection_context)
        .await?
    {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::Unauthorized,
            "Not authorized to terminate sessions for other users; the killAnySession \
             privilege is required."
                .to_owned(),
        ));
    }

    if has_entries {
        terminate_sessions_for_users(
            request_context,
            connection_context,
            pg_data_client,
            &target_users,
        )
        .await?;
    } else {
        terminate_all_sessions(request_context, connection_context, pg_data_client).await?;
    }

    Ok(Response::ok())
}

/// Terminates every session owned by `owner`.
async fn terminate_owner_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    owner: &Principal,
) -> Result<()> {
    let cursor_ids = connection_context
        .service_context
        .cursor_store()
        .invalidate_cursors_by_owner(owner);
    kill_backend_cursors(
        request_context,
        connection_context,
        pg_data_client,
        &cursor_ids,
    )
    .await;

    connection_context
        .service_context
        .transaction_store()
        .remove_transactions_by_owner(owner)
        .await;

    Ok(())
}

/// Terminates every session owned by a principal whose name is in `user_names`.
async fn terminate_sessions_for_users(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    user_names: &HashSet<String>,
) -> Result<()> {
    let cursor_ids = connection_context
        .service_context
        .cursor_store()
        .invalidate_cursors_by_owner_names(user_names);
    kill_backend_cursors(
        request_context,
        connection_context,
        pg_data_client,
        &cursor_ids,
    )
    .await;

    connection_context
        .service_context
        .transaction_store()
        .remove_transactions_by_owner_names(user_names)
        .await;

    Ok(())
}

/// Terminates every session, regardless of owner.
async fn terminate_all_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
) -> Result<()> {
    let cursor_ids = connection_context
        .service_context
        .cursor_store()
        .invalidate_all_cursors();
    kill_backend_cursors(
        request_context,
        connection_context,
        pg_data_client,
        &cursor_ids,
    )
    .await;

    connection_context
        .service_context
        .transaction_store()
        .remove_all_transactions()
        .await;

    Ok(())
}

/// Frees the given cursors on the backend. Failures are logged and swallowed so
/// that gateway-side termination still completes.
async fn kill_backend_cursors(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    cursor_ids: &[i64],
) {
    if cursor_ids.is_empty() {
        return;
    }

    if let Err(e) = pg_data_client
        .execute_kill_cursors(request_context, connection_context, cursor_ids)
        .await
    {
        tracing::warn!("Error killing cursors during killAllSessions: {e}");
    }
}

fn kill_all_sessions_missing_field(name: &str) -> DocumentDBError {
    DocumentDBError::documentdb_error(
        ErrorCode::Location40414,
        format!("BSON field 'killAllSessions.{name}' is missing but a required field"),
    )
}

/// Validates a single `killAllSessions` `{ user, db }` entry and returns the
/// borrowed `(user, db)` values that select the sessions to terminate.
fn validate_kill_all_sessions_entry(entry: &RawDocument) -> Result<(&str, &str)> {
    let mut user: Option<&str> = None;
    let mut db: Option<&str> = None;

    for field in entry {
        let (key, value) = field?;
        match key {
            "user" => {
                user = Some(validate_kill_all_sessions_string_field("user", value)?);
            }
            "db" => {
                db = Some(validate_kill_all_sessions_string_field("db", value)?);
            }
            _ => {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::UnknownBsonField,
                    format!("BSON field 'killAllSessions.{key}' is an unknown field"),
                ))
            }
        }
    }

    let user = user.ok_or_else(|| kill_all_sessions_missing_field("user"))?;
    let db = db.ok_or_else(|| kill_all_sessions_missing_field("db"))?;

    Ok((user, db))
}

fn validate_kill_all_sessions_string_field<'a>(
    name: &str,
    value: RawBsonRef<'a>,
) -> Result<&'a str> {
    match value {
        // A null value is reported as a missing required field.
        RawBsonRef::Null => Err(kill_all_sessions_missing_field(name)),
        RawBsonRef::String(value) => Ok(value),
        _ => Err(DocumentDBError::type_mismatch(format!(
            "BSON field 'killAllSessions.{name}' is the wrong type, expected type 'string'"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use bson::{rawdoc, Binary, RawArrayBuf, RawBson};

    use super::*;

    fn uuid_binary() -> Binary {
        Binary {
            subtype: BinarySubtype::Uuid,
            bytes: vec![0_u8; 16],
        }
    }

    #[test]
    fn session_id_document_valid() {
        let doc = rawdoc! { "id": uuid_binary() };
        parse_session_id_document(&doc).unwrap();
    }

    #[test]
    fn session_id_document_unknown_extra_field() {
        let doc = rawdoc! { "id": uuid_binary(), "extra": 1_i32 };
        let err = parse_session_id_document(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::UnknownBsonField);
    }

    #[test]
    fn session_id_document_wrong_field_name() {
        let doc = rawdoc! { "notId": uuid_binary() };
        let err = parse_session_id_document(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::UnknownBsonField);
    }

    #[test]
    fn session_id_document_missing_id() {
        let doc = rawdoc! {};
        let err = parse_session_id_document(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location40414);
    }

    #[test]
    fn session_id_document_null_id() {
        let doc = rawdoc! { "id": RawBson::Null };
        let err = parse_session_id_document(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location40414);
    }

    #[test]
    fn session_id_document_non_uuid_binary() {
        let doc =
            rawdoc! { "id": Binary { subtype: BinarySubtype::Generic, bytes: vec![0_u8; 16] } };
        let err = parse_session_id_document(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::TypeMismatch);
    }

    #[test]
    fn session_id_document_string_id() {
        let doc = rawdoc! { "id": "not-binary" };
        let err = parse_session_id_document(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::TypeMismatch);
    }

    #[test]
    fn logical_session_ids_accepts_null_elements() {
        let mut arr = RawArrayBuf::new();
        arr.push(RawBson::Null);
        arr.push(rawdoc! { "id": uuid_binary() });
        let ids = parse_logical_session_ids(&arr, true).unwrap();
        assert_eq!(ids.len(), 1);
    }

    #[test]
    fn logical_session_ids_empty_ok() {
        let arr = RawArrayBuf::new();
        assert!(parse_logical_session_ids(&arr, true).unwrap().is_empty());
    }

    #[test]
    fn logical_session_ids_rejects_non_document_element() {
        let mut arr = RawArrayBuf::new();
        arr.push(1_i32);
        let err = parse_logical_session_ids(&arr, true).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::TypeMismatch);
    }

    #[test]
    fn kill_all_entry_valid() {
        let doc = rawdoc! { "user": "u", "db": "admin" };
        assert_eq!(
            validate_kill_all_sessions_entry(&doc).unwrap(),
            ("u", "admin")
        );
    }

    #[test]
    fn kill_all_entry_non_admin_db_round_trips() {
        let doc = rawdoc! { "user": "u", "db": "other" };
        assert_eq!(
            validate_kill_all_sessions_entry(&doc).unwrap(),
            ("u", "other")
        );
    }

    #[test]
    fn kill_all_entry_empty_missing_field() {
        let doc = rawdoc! {};
        let err = validate_kill_all_sessions_entry(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location40414);
    }

    #[test]
    fn kill_all_entry_missing_db() {
        let doc = rawdoc! { "user": "u" };
        let err = validate_kill_all_sessions_entry(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location40414);
    }

    #[test]
    fn kill_all_entry_missing_user() {
        let doc = rawdoc! { "db": "admin" };
        let err = validate_kill_all_sessions_entry(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location40414);
    }

    #[test]
    fn kill_all_entry_null_user_is_missing() {
        let doc = rawdoc! { "user": RawBson::Null, "db": "admin" };
        let err = validate_kill_all_sessions_entry(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::Location40414);
    }

    #[test]
    fn kill_all_entry_non_string_user() {
        let doc = rawdoc! { "user": 1_i32, "db": "admin" };
        let err = validate_kill_all_sessions_entry(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::TypeMismatch);
    }

    #[test]
    fn kill_all_entry_non_string_db() {
        let doc = rawdoc! { "user": "u", "db": 1_i32 };
        let err = validate_kill_all_sessions_entry(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::TypeMismatch);
    }

    #[test]
    fn kill_all_entry_extra_field() {
        let doc = rawdoc! { "user": "u", "db": "admin", "extra": 1_i32 };
        let err = validate_kill_all_sessions_entry(&doc).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::UnknownBsonField);
    }
}
