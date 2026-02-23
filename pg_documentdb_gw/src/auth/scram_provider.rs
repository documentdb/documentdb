/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * src/auth/scram_provider.rs
 *
 * ScramProvider — SCRAM-SHA-256 authentication provider.
 * Extracted from the monolithic auth.rs handler.
 *
 *-------------------------------------------------------------------------
 */

use std::str::from_utf8;

use async_trait::async_trait;
use bson::{rawdoc, spec::BinarySubtype};
use rand::Rng;
use tokio_postgres::types::Type;

use crate::{
    auth::provider::{AuthProvider, ProviderConfig},
    auth_legacy::{AuthKind, ScramFirstState},
    context::ConnectionContext,
    error::{DocumentDBError, ErrorCode, Result},
    postgres::PgDocument,
    protocol::OK_SUCCEEDED,
    requests::{request_tracker::RequestTracker, Request},
    responses::{RawResponse, Response},
};

const NONCE_LENGTH: usize = 2;

pub struct ScramProvider {
    config: Option<ProviderConfig>,
}

impl ScramProvider {
    pub fn new() -> Self {
        ScramProvider { config: None }
    }
}

#[async_trait]
impl AuthProvider for ScramProvider {
    fn mechanism_name(&self) -> &str {
        "SCRAM-SHA-256"
    }

    fn supports_continue(&self) -> bool {
        true
    }

    async fn handle_sasl_start(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response> {
        let payload = parse_sasl_payload(request, true)?;

        let username = payload
            .username
            .ok_or(DocumentDBError::authentication_failed(
                "SCRAM-SHA-256: Username missing from SaslStart.".to_string(),
            ))?;

        let client_nonce = payload.nonce.ok_or(DocumentDBError::authentication_failed(
            "SCRAM-SHA-256: Nonce missing from SaslStart.".to_string(),
        ))?;

        let server_nonce = generate_server_nonce(client_nonce);

        let (salt, iterations) =
            get_salt_and_iteration(connection_context, username).await?;
        let response = format!("r={server_nonce},s={salt},i={iterations}");

        connection_context.auth_state.first_state = Some(ScramFirstState {
            nonce: server_nonce,
            first_message_bare: format!("n={username},r={client_nonce}"),
            first_message: response.clone(),
        });

        connection_context.auth_state.username = Some(username.to_string());

        connection_context
            .auth_state
            .set_auth_kind(AuthKind::Native)?;

        let binary_response = bson::Binary {
            subtype: BinarySubtype::Generic,
            bytes: response.as_bytes().to_vec(),
        };

        Ok(Response::Raw(RawResponse(rawdoc! {
            "payload": binary_response,
            "ok": OK_SUCCEEDED,
            "conversationId": 1,
            "done": false
        })))
    }

    async fn handle_sasl_continue(
        &self,
        connection_context: &mut ConnectionContext,
        request: &Request<'_>,
    ) -> Result<Response> {
        let payload = parse_sasl_payload(request, false)?;

        if let Some(first_state) = connection_context.auth_state.first_state.as_ref() {
            let mechanism_result = request.document().get_str("mechanism");

            // Only validate mechanism if it's present — it's optional in SaslContinue
            if let Ok(mechanism) = mechanism_result {
                if mechanism == "MONGODB-OIDC" {
                    return Err(DocumentDBError::authentication_failed(
                        "SCRAM-SHA-256: Auth mechanism MONGODB-OIDC is not supported in SaslContinue".to_string(),
                    ));
                }
            } else {
                tracing::warn!("SCRAM-SHA-256: Auth mechanism not provided in SaslContinue");
            }

            let client_nonce =
                payload.nonce.ok_or(DocumentDBError::authentication_failed(
                    "SCRAM-SHA-256: Nonce missing from SaslContinue.".to_string(),
                ))?;
            let proof = payload.proof.ok_or(DocumentDBError::authentication_failed(
                "SCRAM-SHA-256: Proof missing from SaslContinue.".to_string(),
            ))?;
            let channel_binding =
                payload
                    .channel_binding
                    .ok_or(DocumentDBError::authentication_failed(
                        "SCRAM-SHA-256: Channel binding missing from SaslContinue.".to_string(),
                    ))?;
            let username = payload
                .username
                .or(connection_context.auth_state.username.as_deref())
                .ok_or(DocumentDBError::internal_error(
                    "SCRAM-SHA-256: Username missing from SaslContinue".to_string(),
                ))?;

            if client_nonce != first_state.nonce {
                return Err(DocumentDBError::authentication_failed(
                    "SCRAM-SHA-256: Nonce did not match expected nonce.".to_string(),
                ));
            }

            let auth_message = format!(
                "{},{},c={},r={}",
                first_state.first_message_bare,
                first_state.first_message,
                channel_binding,
                client_nonce
            );

            let scram_sha256_row = connection_context
                .service_context
                .connection_pool_manager()
                .authentication_connection()
                .await?
                .query(
                    connection_context
                        .service_context
                        .query_catalog()
                        .authenticate_with_scram_sha256(),
                    &[Type::TEXT, Type::TEXT, Type::TEXT],
                    &[&username, &auth_message, &proof],
                    None,
                    &RequestTracker::new(),
                )
                .await?;

            let scram_sha256_doc: PgDocument = scram_sha256_row
                .first()
                .ok_or(DocumentDBError::pg_response_empty())?
                .try_get(0)?;

            if scram_sha256_doc
                .0
                .get_i32("ok")
                .map_err(DocumentDBError::pg_response_invalid)?
                != 1
            {
                return Err(DocumentDBError::authentication_failed(
                    "SCRAM-SHA-256: Invalid key".to_string(),
                ));
            }

            let server_signature = scram_sha256_doc
                .0
                .get_str("ServerSignature")
                .map_err(DocumentDBError::pg_response_invalid)?;

            let payload = bson::Binary {
                subtype: BinarySubtype::Generic,
                bytes: format!("v={server_signature}").as_bytes().to_vec(),
            };

            connection_context.auth_state.password = Some("".to_string());
            connection_context.auth_state.user_oid =
                Some(get_user_oid(connection_context, username).await?);

            *connection_context.auth_state.is_authorized().write().await = true;

            Ok(Response::Raw(RawResponse(rawdoc! {
                "payload": payload,
                "ok": OK_SUCCEEDED,
                "conversationId": 1,
                "done": true
            })))
        } else {
            Err(DocumentDBError::authentication_failed(
                "SCRAM-SHA-256: SaslContinue called without SaslStart state.".to_string(),
            ))
        }
    }

    async fn initialize(&mut self, config: &ProviderConfig) -> Result<()> {
        self.config = Some(config.clone());
        Ok(())
    }
}

// ---------------------------------------------------------------------------
// Helper functions (moved from auth_legacy.rs)
// ---------------------------------------------------------------------------

fn generate_server_nonce(client_nonce: &str) -> String {
    const CHARSET: &[u8] = b"!\"#$%&'()*+-./0123456789:;<>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
    let mut rng = rand::thread_rng();

    let mut result = String::with_capacity(NONCE_LENGTH);
    for _ in 0..NONCE_LENGTH {
        let idx = rng.gen_range(0..CHARSET.len());
        result.push(CHARSET[idx] as char);
    }

    format!("{client_nonce}{result}")
}

#[derive(Debug)]
struct ScramPayload<'a> {
    username: Option<&'a str>,
    nonce: Option<&'a str>,
    proof: Option<&'a str>,
    channel_binding: Option<&'a str>,
}

fn parse_sasl_payload<'a, 'b: 'a>(
    request: &'b Request<'a>,
    with_header: bool,
) -> Result<ScramPayload<'a>> {
    let payload = request
        .document()
        .get_binary("payload")
        .map_err(DocumentDBError::parse_failure())?;
    let mut payload = from_utf8(payload.bytes).map_err(|e| {
        DocumentDBError::bad_value(format!(
            "SCRAM-SHA-256: Sasl payload couldn't be converted to utf-8: {e}"
        ))
    })?;

    if with_header {
        if payload.len() < 3 {
            return Err(DocumentDBError::authentication_failed(
                "SCRAM-SHA-256: Sasl payload invalid.".to_string(),
            ));
        }
        match &payload[0..=2] {
            "n,," => (),
            "p,," => (),
            "y,," => (),
            _ => {
                return Err(DocumentDBError::authentication_failed(
                    "SCRAM-SHA-256: Sasl payload invalid.".to_string(),
                ))
            }
        }
        payload = &payload[3..];
    }

    let mut username: Option<&str> = None;
    let mut nonce: Option<&str> = None;
    let mut proof: Option<&str> = None;
    let mut channel_binding: Option<&str> = None;

    for value in payload.split(',') {
        let idx = value.find('=').ok_or(DocumentDBError::authentication_failed(
            "SCRAM-SHA-256: Sasl payload invalid.".to_string(),
        ))?;

        let k = &value[..idx];
        let v = &value[idx + 1..];
        match k {
            "n" => username = Some(v),
            "r" => nonce = Some(v),
            "p" => proof = Some(v),
            "c" => channel_binding = Some(v),
            _ => {
                return Err(DocumentDBError::authentication_failed(
                    "SCRAM-SHA-256: Sasl payload was invalid.".to_string(),
                ))
            }
        }
    }

    Ok(ScramPayload {
        username,
        nonce,
        proof,
        channel_binding,
    })
}

async fn get_salt_and_iteration(
    connection_context: &ConnectionContext,
    username: &str,
) -> Result<(String, i32)> {
    for blocked_prefix in connection_context
        .service_context
        .setup_configuration()
        .blocked_role_prefixes()
    {
        if username
            .to_lowercase()
            .starts_with(&blocked_prefix.to_lowercase())
        {
            return Err(DocumentDBError::authentication_failed(
                "SCRAM-SHA-256: Username is invalid.".to_string(),
            ));
        }
    }

    let results = connection_context
        .service_context
        .connection_pool_manager()
        .authentication_connection()
        .await?
        .query(
            connection_context
                .service_context
                .query_catalog()
                .salt_and_iterations(),
            &[Type::TEXT],
            &[&username],
            None,
            &RequestTracker::new(),
        )
        .await?;

    let doc: PgDocument = results
        .first()
        .ok_or(DocumentDBError::pg_response_empty())?
        .try_get(0)?;
    if doc
        .0
        .get_i32("ok")
        .map_err(|e| DocumentDBError::internal_error(e.to_string()))?
        != 1
    {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::AuthenticationFailed,
            "SCRAM-SHA-256: Invalid account: User details not found in the database".to_string(),
        ));
    }

    let iterations = doc
        .0
        .get_i32("iterations")
        .map_err(DocumentDBError::pg_response_invalid)?;
    let salt = doc
        .0
        .get_str("salt")
        .map_err(DocumentDBError::pg_response_invalid)?;

    Ok((salt.to_string(), iterations))
}

pub async fn get_user_oid(
    connection_context: &ConnectionContext,
    username: &str,
) -> Result<u32> {
    let user_oid_rows = connection_context
        .service_context
        .connection_pool_manager()
        .authentication_connection()
        .await?
        .query(
            "SELECT oid from pg_roles WHERE rolname = $1",
            &[Type::TEXT],
            &[&username],
            None,
            &RequestTracker::new(),
        )
        .await?;

    let user_oid = user_oid_rows
        .first()
        .ok_or(DocumentDBError::pg_response_empty())?
        .try_get::<_, tokio_postgres::types::Oid>(0)?;

    Ok(user_oid)
}


#[cfg(test)]
mod tests {
    use super::*;
    use crate::auth::provider::{AuthProvider, ProviderConfig};
    use crate::requests::RequestType;
    use bson::{rawdoc, spec::BinarySubtype};

    // Helper to build a Request with a binary SASL payload.
    fn make_sasl_request(payload_str: &str) -> Request<'static> {
        let binary = bson::Binary {
            subtype: BinarySubtype::Generic,
            bytes: payload_str.as_bytes().to_vec(),
        };
        let doc = rawdoc! {
            "saslStart": 1,
            "mechanism": "SCRAM-SHA-256",
            "payload": binary,
            "$db": "admin"
        };
        Request::RawBuf(RequestType::SaslStart, doc)
    }

    // -----------------------------------------------------------------------
    // Trait method tests
    // -----------------------------------------------------------------------

    #[test]
    fn mechanism_name_returns_scram_sha_256() {
        let provider = ScramProvider::new();
        assert_eq!(provider.mechanism_name(), "SCRAM-SHA-256");
    }

    #[test]
    fn supports_continue_returns_true() {
        let provider = ScramProvider::new();
        assert!(provider.supports_continue());
    }

    #[tokio::test]
    async fn initialize_stores_config() {
        let mut provider = ScramProvider::new();
        assert!(provider.config.is_none());

        let config = ProviderConfig::default();
        provider.initialize(&config).await.unwrap();

        assert!(provider.config.is_some());
        assert!(provider.config.as_ref().unwrap().enabled);
    }

    // -----------------------------------------------------------------------
    // Server nonce generation tests
    // -----------------------------------------------------------------------

    #[test]
    fn server_nonce_starts_with_client_nonce() {
        let client_nonce = "rOprNGfwEbeRWgbNEkqO";
        let server_nonce = generate_server_nonce(client_nonce);
        assert!(
            server_nonce.starts_with(client_nonce),
            "Server nonce should start with client nonce"
        );
    }

    #[test]
    fn server_nonce_is_longer_than_client_nonce() {
        let client_nonce = "abc123";
        let server_nonce = generate_server_nonce(client_nonce);
        assert_eq!(
            server_nonce.len(),
            client_nonce.len() + NONCE_LENGTH,
            "Server nonce should be client nonce + {NONCE_LENGTH} chars"
        );
    }

    #[test]
    fn server_nonce_appended_chars_are_printable() {
        let client_nonce = "test";
        for _ in 0..50 {
            let server_nonce = generate_server_nonce(client_nonce);
            let appended = &server_nonce[client_nonce.len()..];
            for c in appended.chars() {
                assert!(
                    c.is_ascii_graphic(),
                    "Appended char '{c}' should be ASCII graphic"
                );
            }
        }
    }

    // -----------------------------------------------------------------------
    // SASL payload parsing tests
    // -----------------------------------------------------------------------

    #[test]
    fn parse_valid_gs2_header_n() {
        let request = make_sasl_request("n,,n=user,r=nonce123");
        let payload = parse_sasl_payload(&request, true).unwrap();
        assert_eq!(payload.username, Some("user"));
        assert_eq!(payload.nonce, Some("nonce123"));
    }

    #[test]
    fn parse_valid_gs2_header_p() {
        let request = make_sasl_request("p,,n=user,r=nonce123");
        let payload = parse_sasl_payload(&request, true).unwrap();
        assert_eq!(payload.username, Some("user"));
    }

    #[test]
    fn parse_valid_gs2_header_y() {
        let request = make_sasl_request("y,,n=user,r=nonce123");
        let payload = parse_sasl_payload(&request, true).unwrap();
        assert_eq!(payload.username, Some("user"));
    }

    #[test]
    fn parse_invalid_gs2_header_rejected() {
        let request = make_sasl_request("x,,n=user,r=nonce123");
        let result = parse_sasl_payload(&request, true);
        assert!(result.is_err());
    }

    #[test]
    fn parse_too_short_payload_rejected() {
        let request = make_sasl_request("n,");
        let result = parse_sasl_payload(&request, true);
        assert!(result.is_err());
    }

    #[test]
    fn parse_without_header() {
        let request = make_sasl_request("n=user,r=nonce123");
        let payload = parse_sasl_payload(&request, false).unwrap();
        assert_eq!(payload.username, Some("user"));
        assert_eq!(payload.nonce, Some("nonce123"));
    }

    #[test]
    fn parse_continue_payload_with_proof() {
        let request = make_sasl_request("c=biws,r=nonce123,p=dHVyYm8=");
        let payload = parse_sasl_payload(&request, false).unwrap();
        assert_eq!(payload.channel_binding, Some("biws"));
        assert_eq!(payload.nonce, Some("nonce123"));
        assert_eq!(payload.proof, Some("dHVyYm8="));
    }

    #[test]
    fn parse_unknown_key_rejected() {
        let request = make_sasl_request("n,,n=user,r=nonce,z=bad");
        let result = parse_sasl_payload(&request, true);
        assert!(result.is_err());
    }

    #[test]
    fn parse_missing_equals_rejected() {
        let request = make_sasl_request("n,,nuser");
        let result = parse_sasl_payload(&request, true);
        assert!(result.is_err());
    }

    // -----------------------------------------------------------------------
    // Error message tests — verify provider name is included (Requirement 1.10)
    // -----------------------------------------------------------------------

    /// Helper: assert that a DocumentDBError's debug output contains "SCRAM-SHA-256".
    fn assert_error_contains_provider_name(err: DocumentDBError) {
        let err_str = format!("{err}");
        assert!(
            err_str.contains("SCRAM-SHA-256"),
            "Error should contain provider name 'SCRAM-SHA-256', got: {err_str}"
        );
    }

    #[test]
    fn error_invalid_gs2_header_contains_provider_name() {
        let request = make_sasl_request("x,,n=user,r=nonce");
        let err = parse_sasl_payload(&request, true).unwrap_err();
        assert_error_contains_provider_name(err);
    }

    #[test]
    fn error_too_short_payload_contains_provider_name() {
        let request = make_sasl_request("n,");
        let err = parse_sasl_payload(&request, true).unwrap_err();
        assert_error_contains_provider_name(err);
    }

    #[test]
    fn error_unknown_key_contains_provider_name() {
        let request = make_sasl_request("n,,n=user,r=nonce,z=bad");
        let err = parse_sasl_payload(&request, true).unwrap_err();
        assert_error_contains_provider_name(err);
    }

    #[test]
    fn error_missing_equals_contains_provider_name() {
        let request = make_sasl_request("n,,nuser");
        let err = parse_sasl_payload(&request, true).unwrap_err();
        assert_error_contains_provider_name(err);
    }

    #[test]
    fn error_empty_payload_contains_provider_name() {
        let request = make_sasl_request("");
        let err = parse_sasl_payload(&request, true).unwrap_err();
        assert_error_contains_provider_name(err);
    }

    #[test]
    fn error_garbage_payload_contains_provider_name() {
        let request = make_sasl_request("!!!garbage!!!");
        let err = parse_sasl_payload(&request, true).unwrap_err();
        assert_error_contains_provider_name(err);
    }
}
