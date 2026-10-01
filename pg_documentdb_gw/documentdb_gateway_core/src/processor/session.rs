/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/session.rs
 *
 *-------------------------------------------------------------------------
 */

use bson::{spec::BinarySubtype, RawArray, RawBsonRef, RawDocument};

use crate::{
    context::{map_transaction_error, ConnectionContext, LogicalSessionId, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::PgDataClient,
    requests::RequestType,
    responses::Response,
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

fn parse_logical_session_ids(sessions_field: &RawArray) -> Result<Vec<LogicalSessionId>> {
    let mut logical_session_ids = Vec::new();
    for session in sessions_field {
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
    }
    Ok(logical_session_ids)
}

async fn terminate_sessions(
    request_context: &RequestContext<'_>,
    connection_context: &ConnectionContext,
    pg_data_client: &impl PgDataClient,
    sessions_field: &RawArray,
) -> Result<()> {
    let logical_session_ids = parse_logical_session_ids(sessions_field)?;
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

    let key = if request_context.request_type() == RequestType::KillSessions {
        "killSessions"
    } else {
        "endSessions"
    };

    let command_value = request
        .document()
        .get(key)?
        .ok_or_else(|| session_command_missing_field(key))?;

    let sessions_field = match command_value {
        RawBsonRef::Null => return Err(session_command_missing_field(key)),
        RawBsonRef::Array(sessions_field) => sessions_field,
        _ => {
            return Err(DocumentDBError::type_mismatch(format!(
                "BSON field '{key}' is the wrong type, expected type 'array'"
            )))
        }
    };

    terminate_sessions(
        request_context,
        connection_context,
        pg_data_client,
        sessions_field,
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

/// Validates the `killAllSessions` command argument shape.
///
/// The command value must be an array of `{ user, db }` documents, where both
/// `user` and `db` are strings. An empty array is accepted and targets all
/// sessions. Shape violations are reported with wire-protocol-compatible error
/// codes so that strict clients observe the documented semantics. The command
/// otherwise remains a no-op that acknowledges with a successful response.
pub fn validate_kill_all_sessions(request_context: &RequestContext<'_>) -> Result<Response> {
    const KEY: &str = "killAllSessions";
    let request = request_context.request();

    let command_value = request
        .document()
        .get(KEY)?
        .ok_or_else(|| session_command_missing_field(KEY))?;

    let entries = match command_value {
        RawBsonRef::Null => return Err(session_command_missing_field(KEY)),
        RawBsonRef::Array(entries) => entries,
        _ => {
            return Err(DocumentDBError::type_mismatch(format!(
                "BSON field '{KEY}' is the wrong type, expected type 'array'"
            )))
        }
    };

    for entry in entries {
        match entry? {
            // Null array elements are accepted and ignored.
            RawBsonRef::Null => {}
            RawBsonRef::Document(entry_doc) => validate_kill_all_sessions_entry(entry_doc)?,
            _ => {
                return Err(DocumentDBError::type_mismatch(
                    "killAllSessions user entry must be a document".to_owned(),
                ))
            }
        }
    }

    Ok(Response::ok())
}

fn validate_kill_all_sessions_entry(entry: &RawDocument) -> Result<()> {
    let mut has_user = false;
    let mut has_db = false;

    for field in entry {
        let (key, value) = field?;
        match key {
            "user" => {
                validate_kill_all_sessions_string_field("user", value)?;
                has_user = true;
            }
            "db" => {
                validate_kill_all_sessions_string_field("db", value)?;
                has_db = true;
            }
            _ => {
                return Err(DocumentDBError::documentdb_error(
                    ErrorCode::UnknownBsonField,
                    format!("BSON field 'killAllSessions.{key}' is an unknown field"),
                ))
            }
        }
    }

    if !has_user {
        return Err(kill_all_sessions_missing_field("user"));
    }
    if !has_db {
        return Err(kill_all_sessions_missing_field("db"));
    }

    Ok(())
}

fn validate_kill_all_sessions_string_field(name: &str, value: RawBsonRef) -> Result<()> {
    match value {
        // A null value is reported as a missing required field.
        RawBsonRef::Null => Err(kill_all_sessions_missing_field(name)),
        RawBsonRef::String(_) => Ok(()),
        _ => Err(DocumentDBError::type_mismatch(format!(
            "BSON field 'killAllSessions.{name}' is the wrong type, expected type 'string'"
        ))),
    }
}

fn kill_all_sessions_missing_field(name: &str) -> DocumentDBError {
    DocumentDBError::documentdb_error(
        ErrorCode::Location40414,
        format!("BSON field 'killAllSessions.{name}' is missing but a required field"),
    )
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
        let ids = parse_logical_session_ids(&arr).unwrap();
        assert_eq!(ids.len(), 1);
    }

    #[test]
    fn logical_session_ids_empty_ok() {
        let arr = RawArrayBuf::new();
        assert!(parse_logical_session_ids(&arr).unwrap().is_empty());
    }

    #[test]
    fn logical_session_ids_rejects_non_document_element() {
        let mut arr = RawArrayBuf::new();
        arr.push(1_i32);
        let err = parse_logical_session_ids(&arr).unwrap_err();
        assert_eq!(err.error_code(), ErrorCode::TypeMismatch);
    }

    #[test]
    fn kill_all_entry_valid() {
        let doc = rawdoc! { "user": "u", "db": "admin" };
        validate_kill_all_sessions_entry(&doc).unwrap();
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
