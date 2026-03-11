/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/oidc_provider.rs
 *
 * OidcProvider — MONGODB-OIDC authentication provider.
 * Extracted from the monolithic auth.rs handler.
 *
 *-------------------------------------------------------------------------
 */

use async_trait::async_trait;
use base64::{engine::general_purpose, Engine as _};
use bson::{rawdoc, spec::BinarySubtype};
use serde_json::Value;
use tokio::time::Duration;
use tokio_postgres::{error::SqlState, types::Type};

use crate::{
    auth::provider::{AuthProvider, ProviderConfig},
    auth::get_user_oid,
    auth_legacy::AuthKind,
    context::ConnectionContext,
    error::{DocumentDBError, ErrorCode, Result},
    protocol::OK_SUCCEEDED,
    requests::{request_tracker::RequestTracker, Request},
    responses::{PgResponse, RawResponse, Response},
};

pub struct OidcProvider {
    config: Option<ProviderConfig>,
}

impl OidcProvider {
    pub fn new() -> Self {
        OidcProvider { config: None }
    }
}

impl Default for OidcProvider {
    fn default() -> Self {
        Self::new()
    }
}

#[async_trait]
impl AuthProvider for OidcProvider {
    fn mechanism_name(&self) -> &str {
        "MONGODB-OIDC"
    }

    fn supports_continue(&self) -> bool {
        false
    }

    async fn handle_sasl_start(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response> {
        let payload = request
            .document()
            .get_binary("payload")
            .map_err(DocumentDBError::parse_failure())?;

        let payload_doc =
            bson::Document::from_reader(&mut std::io::Cursor::new(payload.bytes)).map_err(
                |e| {
                    DocumentDBError::bad_value(format!(
                        "MONGODB-OIDC: Failed to parse OIDC payload as BSON: {e}"
                    ))
                },
            )?;

        let jwt_token = payload_doc.get_str("jwt").map_err(|_| {
            DocumentDBError::authentication_failed(
                "MONGODB-OIDC: JWT token missing from OIDC payload".to_string(),
            )
        })?;

        handle_oidc_token_authentication(connection_context, jwt_token).await
    }

    async fn handle_sasl_continue(
        &self,
        _connection_context: &mut ConnectionContext,
        _request: &Request<'_>,
    ) -> Result<Response> {
        Err(DocumentDBError::authentication_failed(
            "MONGODB-OIDC: saslContinue is not supported for OIDC authentication".to_string(),
        ))
    }

    async fn initialize(&mut self, config: &ProviderConfig) -> Result<()> {
        self.config = Some(config.clone());
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Helper functions (moved from auth_legacy.rs)
// ---------------------------------------------------------------------------

async fn handle_oidc_token_authentication(
    connection_context: &mut ConnectionContext,
    token_string: &str,
) -> Result<Response> {
    let (oid, seconds_until_expiry) = parse_and_validate_jwt_token(token_string)?;

    let connection = connection_context
        .service_context
        .connection_pool_manager()
        .authentication_connection()
        .await?;

    let authentication_token_row = match connection
        .query(
            connection_context
                .service_context
                .query_catalog()
                .authenticate_with_token(),
            &[Type::TEXT, Type::TEXT],
            &[&oid, &token_string],
            None,
            &RequestTracker::new(),
        )
        .await
    {
        Ok(rows) => rows,
        Err(e) => {
            match e {
                DocumentDBError::PostgresError(pge_error, _) => match pge_error.as_db_error() {
                    Some(db_error) => {
                        tracing::error!(
                            activity_id = connection_context.connection_id.to_string().as_str(),
                            "MONGODB-OIDC: Backend error during authentication: PostgresError({:?}, {:?})",
                            db_error.code(),
                            db_error.hint()
                        );

                        if let Some((extension_error_code, _)) =
                            PgResponse::from_known_external_error_code(db_error.code())
                        {
                            if extension_error_code == ErrorCode::CommandNotSupported as i32 {
                                return Err(DocumentDBError::authentication_failed(
                                    "MONGODB-OIDC: The authentication mechanism provided is not supported in the service.".to_string(),
                                ));
                            }
                        }

                        return match *db_error.code() {
                            SqlState::INVALID_PASSWORD => {
                                Err(DocumentDBError::authentication_failed(
                                    "MONGODB-OIDC: The token provided is not valid.".to_string(),
                                ))
                            }
                            SqlState::UNDEFINED_OBJECT => {
                                Err(DocumentDBError::authentication_failed(
                                    "MONGODB-OIDC: External identity is not present in the system."
                                        .to_string(),
                                ))
                            }
                            _ => Err(DocumentDBError::authentication_failed(
                                "MONGODB-OIDC: Internal Error.".to_string(),
                            )),
                        };
                    }
                    None => {
                        tracing::error!(
                            activity_id = connection_context.connection_id.to_string().as_str(),
                            "MONGODB-OIDC: DbError not found in PostgresError, which is unexpected."
                        );
                        return Err(DocumentDBError::authentication_failed(
                            "MONGODB-OIDC: Internal Error.".to_string(),
                        ));
                    }
                },
                _ => return Err(e),
            }
        }
    };

    let authentication_result: String = authentication_token_row
        .first()
        .ok_or(DocumentDBError::pg_response_empty())?
        .try_get(0)?;

    if authentication_result.trim() != oid {
        return Err(DocumentDBError::authentication_failed(
            "MONGODB-OIDC: Token validation failed".to_string(),
        ));
    }

    let server_signature = "";
    let payload = bson::Binary {
        subtype: BinarySubtype::Generic,
        bytes: server_signature.as_bytes().to_vec(),
    };

    connection_context.auth_state.set_username(&oid);
    connection_context.auth_state.password = Some(token_string.to_string());
    connection_context.auth_state.user_oid =
        Some(get_user_oid(connection_context, &oid).await?);

    *connection_context.auth_state.is_authorized().write().await = true;
    connection_context
        .auth_state
        .set_auth_kind(AuthKind::ExternalIdentity)?;

    let connection_activity_id = connection_context.connection_id.to_string();
    let connection_activity_id_as_str = connection_activity_id.as_str();
    tracing::info!(
        activity_id = connection_activity_id_as_str,
        "MONGODB-OIDC: Setting authentication expiry timer for {seconds_until_expiry} seconds until token expiry.",
    );
    connection_context
        .auth_state
        .initialize_expiry_timer(seconds_until_expiry, connection_activity_id_as_str)
        .await?;

    Ok(Response::Raw(RawResponse(rawdoc! {
        "payload": payload,
        "ok": OK_SUCCEEDED,
        "conversationId": 1,
        "done": true
    })))
}

fn parse_and_validate_jwt_token(token_string: &str) -> Result<(String, u64)> {
    let token_parts: Vec<&str> = token_string.split('.').collect();
    if token_parts.len() != 3 {
        return Err(DocumentDBError::authentication_failed(
            "MONGODB-OIDC: Invalid JWT token format.".to_string(),
        ));
    }

    let payload_part = token_parts[1];
    let payload_bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(payload_part)
        .map_err(|_| {
            DocumentDBError::authentication_failed(
                "MONGODB-OIDC: Invalid JWT token encoding.".to_string(),
            )
        })?;

    let payload_json: Value = serde_json::from_slice(&payload_bytes).map_err(|_| {
        DocumentDBError::authentication_failed(
            "MONGODB-OIDC: Invalid JWT token payload.".to_string(),
        )
    })?;

    let oid = payload_json
        .get("oid")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            DocumentDBError::authentication_failed(
                "MONGODB-OIDC: Token does not contain OID.".to_string(),
            )
        })?
        .to_string();

    let aud = payload_json
        .get("aud")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            DocumentDBError::authentication_failed(
                "MONGODB-OIDC: Token does not contain audience claim.".to_string(),
            )
        })?
        .to_string();

    let exp = payload_json
        .get("exp")
        .and_then(|v| v.as_i64())
        .ok_or_else(|| {
            DocumentDBError::authentication_failed(
                "MONGODB-OIDC: Token does not contain expiry time.".to_string(),
            )
        })?;

    let valid_audiences = ["https://ossrdbms-aad.database.windows.net"];
    if !valid_audiences.contains(&aud.as_str()) {
        return Err(DocumentDBError::authentication_failed(
            "MONGODB-OIDC: The audience claim provided in the token is not valid.".to_string(),
        ));
    }

    let exp_datetime = std::time::UNIX_EPOCH + std::time::Duration::from_secs(exp as u64);
    let now = std::time::SystemTime::now();

    if exp_datetime < now {
        return Err(DocumentDBError::authentication_failed(
            "MONGODB-OIDC: The token provided is expired.".to_string(),
        ));
    }

    let timeout_seconds = exp_datetime
        .duration_since(now)
        .unwrap_or(Duration::from_secs(0))
        .as_secs();

    Ok((oid, timeout_seconds))
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::provider::{AuthProvider, ProviderConfig};
    use base64::engine::general_purpose;

    /// Build a fake JWT token (header.payload.signature) with the given JSON payload.
    fn make_jwt(payload_json: &str) -> String {
        let header = general_purpose::URL_SAFE_NO_PAD.encode(r#"{"alg":"RS256","typ":"JWT"}"#);
        let payload = general_purpose::URL_SAFE_NO_PAD.encode(payload_json);
        let signature = general_purpose::URL_SAFE_NO_PAD.encode("fake-signature");
        format!("{header}.{payload}.{signature}")
    }

    /// Build a JWT with a valid structure but a future expiry.
    fn make_valid_jwt() -> String {
        let exp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3600; // 1 hour from now
        make_jwt(&format!(
            r#"{{"oid":"test-oid","aud":"https://ossrdbms-aad.database.windows.net","exp":{exp}}}"#
        ))
    }

    // -----------------------------------------------------------------------
    // Trait method tests
    // -----------------------------------------------------------------------

    #[test]
    fn mechanism_name_returns_mongodb_oidc() {
        let provider = OidcProvider::new();
        assert_eq!(provider.mechanism_name(), "MONGODB-OIDC");
    }

    #[test]
    fn supports_continue_returns_false() {
        let provider = OidcProvider::new();
        assert!(!provider.supports_continue());
    }

    #[tokio::test]
    async fn initialize_stores_config() {
        let mut provider = OidcProvider::new();
        assert!(provider.config.is_none());

        let config = ProviderConfig::default();
        provider.initialize(&config).await.unwrap();

        assert!(provider.config.is_some());
    }

    // -----------------------------------------------------------------------
    // JWT parsing tests
    // -----------------------------------------------------------------------

    #[test]
    fn jwt_invalid_format_not_three_parts() {
        let result = parse_and_validate_jwt_token("only.two");
        assert!(result.is_err());
    }

    #[test]
    fn jwt_invalid_format_single_string() {
        let result = parse_and_validate_jwt_token("notajwt");
        assert!(result.is_err());
    }

    #[test]
    fn jwt_invalid_base64_payload() {
        let result = parse_and_validate_jwt_token("header.!!!invalid-base64!!!.signature");
        assert!(result.is_err());
    }

    #[test]
    fn jwt_invalid_json_payload() {
        let bad_payload = general_purpose::URL_SAFE_NO_PAD.encode("not json");
        let token = format!("header.{bad_payload}.signature");
        let result = parse_and_validate_jwt_token(&token);
        assert!(result.is_err());
    }

    #[test]
    fn jwt_missing_oid() {
        let token = make_jwt(r#"{"aud":"https://ossrdbms-aad.database.windows.net","exp":9999999999}"#);
        let result = parse_and_validate_jwt_token(&token);
        assert!(result.is_err());
        let err_str = format!("{}", result.unwrap_err());
        assert!(err_str.contains("OID"));
    }

    #[test]
    fn jwt_missing_audience() {
        let token = make_jwt(r#"{"oid":"test-oid","exp":9999999999}"#);
        let result = parse_and_validate_jwt_token(&token);
        assert!(result.is_err());
        let err_str = format!("{}", result.unwrap_err());
        assert!(err_str.contains("audience"));
    }

    #[test]
    fn jwt_missing_expiry() {
        let token = make_jwt(
            r#"{"oid":"test-oid","aud":"https://ossrdbms-aad.database.windows.net"}"#,
        );
        let result = parse_and_validate_jwt_token(&token);
        assert!(result.is_err());
        let err_str = format!("{}", result.unwrap_err());
        assert!(err_str.contains("expiry"));
    }

    #[test]
    fn jwt_expired_token() {
        let token = make_jwt(
            r#"{"oid":"test-oid","aud":"https://ossrdbms-aad.database.windows.net","exp":1000000}"#,
        );
        let result = parse_and_validate_jwt_token(&token);
        assert!(result.is_err());
        let err_str = format!("{}", result.unwrap_err());
        assert!(err_str.contains("expired"));
    }

    #[test]
    fn jwt_invalid_audience() {
        let exp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3600;
        let token = make_jwt(&format!(
            r#"{{"oid":"test-oid","aud":"https://wrong-audience.example.com","exp":{exp}}}"#
        ));
        let result = parse_and_validate_jwt_token(&token);
        assert!(result.is_err());
        let err_str = format!("{}", result.unwrap_err());
        assert!(err_str.contains("audience"));
    }

    #[test]
    fn jwt_valid_token_parses_successfully() {
        let token = make_valid_jwt();
        let result = parse_and_validate_jwt_token(&token);
        assert!(result.is_ok());
        let (oid, timeout) = result.unwrap();
        assert_eq!(oid, "test-oid");
        assert!(timeout > 0);
    }

    // -----------------------------------------------------------------------
    // Error message tests — verify provider name is included
    // -----------------------------------------------------------------------

    fn assert_error_contains_provider_name(err: DocumentDBError) {
        let err_str = format!("{err}");
        assert!(
            err_str.contains("MONGODB-OIDC"),
            "Error should contain provider name 'MONGODB-OIDC', got: {err_str}"
        );
    }

    #[test]
    fn error_invalid_format_contains_provider_name() {
        let err = parse_and_validate_jwt_token("bad").unwrap_err();
        assert_error_contains_provider_name(err);
    }

    #[test]
    fn error_invalid_base64_contains_provider_name() {
        let err = parse_and_validate_jwt_token("a.!!!.b").unwrap_err();
        assert_error_contains_provider_name(err);
    }

    #[test]
    fn error_expired_token_contains_provider_name() {
        let token = make_jwt(
            r#"{"oid":"x","aud":"https://ossrdbms-aad.database.windows.net","exp":1000000}"#,
        );
        let err = parse_and_validate_jwt_token(&token).unwrap_err();
        assert_error_contains_provider_name(err);
    }

    #[test]
    fn error_invalid_audience_contains_provider_name() {
        let exp = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs()
            + 3600;
        let token = make_jwt(&format!(
            r#"{{"oid":"x","aud":"https://bad.example.com","exp":{exp}}}"#
        ));
        let err = parse_and_validate_jwt_token(&token).unwrap_err();
        assert_error_contains_provider_name(err);
    }
}
