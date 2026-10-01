/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/auth/scram.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{future::Future, str::from_utf8, sync::Arc};

use async_trait::async_trait;
use rand::RngExt;
use serde::{Deserialize, Serialize};
use tokio::time::Duration;
use tokio_postgres::types::Type;

use crate::{
    auth::{AuthenticationHandler, AuthenticationResult, AuthenticationSuccess},
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{
        conn_mgmt::{
            run_request_with_retries, Connection, ConnectionSource, QueryOptions, RequestOptions,
            StatementError,
        },
        PgDocument,
    },
    requests::{RequestType, WireRequest},
    security::principal::Principal,
};

pub const SCRAM_SHA256_SCHEME: &str = "SCRAM-SHA-256";

/// Number of random characters appended to the client nonce to form the server nonce.
const SERVER_NONCE_SUFFIX_LEN: usize = 24;

/// In-flight SCRAM-SHA-256 conversation state.
///
/// Established during `saslStart` and consumed on the matching `saslContinue`
/// to verify the client's proof against the server's stored challenge.
#[derive(Debug, Deserialize, Serialize)]
struct ScramConversation {
    server_nonce: String,
    first_message_bare: String,
    server_first_message: String,
    username: String,
}

/// Salted Challenge Response Authentication Mechanism (SCRAM)
#[derive(Debug, Default)]
pub struct ScramAuthenticationHandler;

impl ScramAuthenticationHandler {
    #[must_use]
    pub const fn new() -> Self {
        Self
    }
}

#[async_trait]
impl AuthenticationHandler for ScramAuthenticationHandler {
    async fn handle_authenticate(
        &self,
        connection_context: &mut ConnectionContext,
        request_context: &RequestContext<'_>,
    ) -> Result<AuthenticationResult> {
        match request_context.request_type() {
            RequestType::SaslStart => handle_sasl_start(connection_context, request_context).await,
            RequestType::SaslContinue => {
                handle_sasl_continue(connection_context, request_context).await
            }
            request_type => Err(DocumentDBError::authentication_failed_internal_error(
                "Authentication Failed".to_owned(),
                &format!(
                    "ScramAuthenticationHandler received an unsupported request type `{request_type}`"
                ),
            )),
        }
    }
}

/// Registers the SCRAM-SHA-256 handler with the authentication manager.
#[must_use]
pub fn create_handler() -> Box<dyn AuthenticationHandler> {
    Box::new(ScramAuthenticationHandler::new())
}

/// Handles the `saslStart` round: establishes the conversation and returns the
/// server-first challenge (`r=<nonce>,s=<salt>,i=<iterations>`).
async fn handle_sasl_start(
    connection_context: &mut ConnectionContext,
    request_context: &RequestContext<'_>,
) -> Result<AuthenticationResult> {
    let payload = parse_sasl_payload(request_context.request(), true)?;

    let username = payload.username.ok_or_else(|| {
        DocumentDBError::authentication_failed("Username missing from SaslStart.".to_owned())
    })?;
    let client_nonce = payload.nonce.ok_or_else(|| {
        DocumentDBError::authentication_failed("Nonce missing from SaslStart.".to_owned())
    })?;

    let server_nonce = generate_server_nonce(client_nonce);
    let (salt, iterations) =
        get_salt_and_iterations(connection_context, username, request_context).await?;

    let server_first_message = format!("r={server_nonce},s={salt},i={iterations}");

    let conversation = ScramConversation {
        server_nonce,
        first_message_bare: format!("n={username},r={client_nonce}"),
        server_first_message: server_first_message.clone(),
        username: username.to_owned(),
    };
    let metadata = serde_json::to_value(conversation)
        .map_err(|error| DocumentDBError::internal_error(error.to_string()))?;
    connection_context
        .user_mut()
        .set_metadata(SCRAM_SHA256_SCHEME, metadata)?;

    Ok(AuthenticationResult::Challenge(
        server_first_message.into_bytes(),
    ))
}

/// Handles the `saslContinue` round: verifies the client proof against the
/// stored conversation and returns the server-final payload (`v=<signature>`).
async fn handle_sasl_continue(
    connection_context: &ConnectionContext,
    request_context: &RequestContext<'_>,
) -> Result<AuthenticationResult> {
    let conversation: ScramConversation = connection_context
        .user()
        .metadata(SCRAM_SHA256_SCHEME)
        .cloned()
        .map(serde_json::from_value)
        .transpose()
        .map_err(|error| DocumentDBError::internal_error(error.to_string()))?
        .ok_or_else(|| {
            DocumentDBError::authentication_failed(
                "SaslContinue called without SaslStart state.".to_owned(),
            )
        })?;

    let payload = parse_sasl_payload(request_context.request(), false)?;

    let client_nonce = payload.nonce.ok_or_else(|| {
        DocumentDBError::authentication_failed("Nonce missing from SaslContinue.".to_owned())
    })?;
    let proof = payload.proof.ok_or_else(|| {
        DocumentDBError::authentication_failed("Proof missing from SaslContinue.".to_owned())
    })?;
    let channel_binding = payload.channel_binding.ok_or_else(|| {
        DocumentDBError::authentication_failed(
            "Channel binding missing from SaslContinue.".to_owned(),
        )
    })?;

    if client_nonce != conversation.server_nonce {
        return Err(DocumentDBError::authentication_failed(
            "Nonce did not match expected nonce.".to_owned(),
        ));
    }

    validate_continuation_username(conversation.username.as_str(), payload.username)?;
    let username = conversation.username.as_str();

    let auth_message = format!(
        "{},{},c={},r={}",
        conversation.first_message_bare,
        conversation.server_first_message,
        channel_binding,
        client_nonce
    );

    let server_signature = verify_scram_proof(
        connection_context,
        username,
        &auth_message,
        proof,
        request_context,
    )
    .await?;

    let user_oid = get_user_oid(connection_context, username, request_context).await?;
    let principal = Principal::new(username, user_oid);

    Ok(AuthenticationResult::Success(AuthenticationSuccess::new(
        principal,
        format!("v={server_signature}").into_bytes(),
        SCRAM_SHA256_SCHEME,
        String::new(),
        None,
        None,
    )))
}

fn validate_continuation_username(
    initial_username: &str,
    continuation_username: Option<&str>,
) -> Result<()> {
    if continuation_username.is_some_and(|username| username != initial_username) {
        return Err(DocumentDBError::authentication_failed(
            "Username did not match SaslStart.".to_owned(),
        ));
    }

    Ok(())
}

/// Generates the server nonce by appending random printable characters to the
/// client nonce, per the SCRAM specification.
fn generate_server_nonce(client_nonce: &str) -> String {
    // SCRAM printable ASCII, excluding ',' which is the message field separator.
    const CHARSET: &[u8] = b"!\"#$%&'()*+-./0123456789:;<>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";

    let mut rng = rand::rng();
    let mut nonce = String::with_capacity(client_nonce.len() + SERVER_NONCE_SUFFIX_LEN);
    nonce.push_str(client_nonce);
    for _ in 0..SERVER_NONCE_SUFFIX_LEN {
        let index = rng.random_range(0..CHARSET.len());
        nonce.push(CHARSET[index] as char);
    }

    nonce
}

/// The fields of a parsed SCRAM SASL payload.
struct ScramPayload<'a> {
    username: Option<&'a str>,
    nonce: Option<&'a str>,
    proof: Option<&'a str>,
    channel_binding: Option<&'a str>,
}

/// Parses the `payload` binary of a SASL request into its SCRAM fields.
///
/// When `with_header` is set (the `saslStart` message), the leading GS2 header
/// (`n,,` / `p,,` / `y,,`) is validated and stripped.
fn parse_sasl_payload<'a>(
    request: &'a WireRequest<'a>,
    with_header: bool,
) -> Result<ScramPayload<'a>> {
    let payload = request
        .document()
        .get_binary("payload")
        .map_err(DocumentDBError::parse_failure())?;
    let mut payload = from_utf8(payload.bytes).map_err(|error| {
        DocumentDBError::bad_value(format!(
            "Sasl payload couldn't be converted to utf-8: {error}"
        ))
    })?;

    if with_header {
        if payload.len() < 3 {
            return Err(DocumentDBError::sasl_payload_invalid());
        }
        match &payload[0..=2] {
            "n,," | "p,," | "y,," => (),
            _ => return Err(DocumentDBError::sasl_payload_invalid()),
        }
        payload = &payload[3..];
    }

    let mut scram_payload = ScramPayload {
        username: None,
        nonce: None,
        proof: None,
        channel_binding: None,
    };

    for field in payload.split(',') {
        let separator = field
            .find('=')
            .ok_or_else(DocumentDBError::sasl_payload_invalid)?;
        let (key, value) = (&field[..separator], &field[separator + 1..]);
        match key {
            "n" => scram_payload.username = Some(value),
            "r" => scram_payload.nonce = Some(value),
            "p" => scram_payload.proof = Some(value),
            "c" => scram_payload.channel_binding = Some(value),
            _ => {
                return Err(DocumentDBError::authentication_failed(
                    "Sasl payload was invalid.".to_owned(),
                ))
            }
        }
    }

    Ok(scram_payload)
}

/// Looks up the SCRAM salt and iteration count for `username` from Postgres.
async fn get_salt_and_iterations(
    connection_context: &ConnectionContext,
    username: &str,
    request_context: &RequestContext<'_>,
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
                "Username is invalid.".to_owned(),
            ));
        }
    }

    let query = connection_context
        .service_context
        .query_catalog()
        .salt_and_iterations();

    let run_func = |connection: Arc<Connection>| async move {
        let rows = connection.query(query, &[Type::TEXT], &[&username]).await?;
        let Some(row) = rows.first() else {
            return Ok(None);
        };
        let doc: PgDocument = row.try_get(0)?;
        Ok(Some(doc.0.to_raw_document_buf()))
    };

    let doc = run_auth_query(connection_context, request_context, run_func)
        .await?
        .ok_or_else(DocumentDBError::pg_response_empty)?;

    if doc
        .get_i32("ok")
        .map_err(|error| DocumentDBError::internal_error(error.to_string()))?
        != 1
    {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::AuthenticationFailed,
            "Invalid account: User details not found in the database".to_owned(),
        ));
    }

    let iterations = doc
        .get_i32("iterations")
        .map_err(DocumentDBError::pg_response_invalid)?;
    let salt = doc
        .get_str("salt")
        .map_err(DocumentDBError::pg_response_invalid)?;

    Ok((salt.to_owned(), iterations))
}

/// Verifies the client proof through Postgres and returns the server signature.
async fn verify_scram_proof(
    connection_context: &ConnectionContext,
    username: &str,
    auth_message: &str,
    proof: &str,
    request_context: &RequestContext<'_>,
) -> Result<String> {
    let query = connection_context
        .service_context
        .query_catalog()
        .authenticate_with_scram_sha256();

    let run_func = |connection: Arc<Connection>| async move {
        let rows = connection
            .query(
                query,
                &[Type::TEXT, Type::TEXT, Type::TEXT],
                &[&username, &auth_message, &proof],
            )
            .await?;
        let Some(row) = rows.first() else {
            return Ok(None);
        };
        let doc: PgDocument = row.try_get(0)?;
        Ok(Some(doc.0.to_raw_document_buf()))
    };

    let scram_doc = run_auth_query(connection_context, request_context, run_func)
        .await?
        .ok_or_else(DocumentDBError::pg_response_empty)?;

    if scram_doc
        .get_i32("ok")
        .map_err(DocumentDBError::pg_response_invalid)?
        != 1
    {
        return Err(DocumentDBError::authentication_failed(
            "Invalid key".to_owned(),
        ));
    }

    scram_doc
        .get_str("ServerSignature")
        .map(str::to_owned)
        .map_err(DocumentDBError::pg_response_invalid)
}

/// Resolves the Postgres OID backing `username`.
///
/// # Errors
///
/// Returns an error when the role query fails or the user does not exist.
pub async fn get_user_oid(
    connection_context: &ConnectionContext,
    username: &str,
    request_context: &RequestContext<'_>,
) -> Result<u32> {
    let run_func = |connection: Arc<Connection>| async move {
        let rows = connection
            .query(
                "SELECT oid from pg_roles WHERE rolname = $1",
                &[Type::TEXT],
                &[&username],
            )
            .await?;
        rows.first()
            .map(|row| row.try_get::<_, tokio_postgres::types::Oid>(0))
            .transpose()
            .map_err(StatementError::from)
    };

    run_auth_query(connection_context, request_context, run_func)
        .await?
        .ok_or_else(DocumentDBError::pg_response_empty)
}

/// Runs an authentication query against the system auth pool with retries.
async fn run_auth_query<T, F, Fut>(
    connection_context: &ConnectionContext,
    request_context: &RequestContext<'_>,
    run_func: F,
) -> Result<T>
where
    F: Fn(Arc<Connection>) -> Fut,
    Fut: Future<Output = std::result::Result<T, StatementError>>,
{
    let pool = connection_context
        .service_context
        .connection_pool_manager()
        .system_auth_pool();

    let query_options = QueryOptions::builder().build();
    let request_options = RequestOptions::new(
        false, // in_replica_cluster_mode: always retry auth queries.
        None,  // no gateway-level command timeout for auth queries.
    );
    let dynamic_configuration = connection_context.dynamic_configuration();

    run_request_with_retries(
        ConnectionSource::Pool(pool),
        query_options,
        request_options,
        Duration::from_secs(
            connection_context
                .service_context
                .dynamic_configuration()
                .max_request_timeout_sec(),
        ),
        dynamic_configuration.as_ref(),
        request_context,
        run_func,
    )
    .await
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn continuation_username_must_match_initial_username() {
        validate_continuation_username("initial-user", None)
            .expect("a continuation may omit the username");
        validate_continuation_username("initial-user", Some("initial-user"))
            .expect("a continuation may repeat the initial username");

        let error = validate_continuation_username("initial-user", Some("different-user"))
            .expect_err("a continuation cannot change the authentication identity");
        assert_eq!(error.error_code(), ErrorCode::AuthenticationFailed);
    }
}
