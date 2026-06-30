/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/auth.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    str::from_utf8,
    sync::{
        atomic::{AtomicBool, Ordering},
        Arc,
    },
};

use base64::{engine::general_purpose, Engine as _};
use bson::{rawdoc, spec::BinarySubtype};
use rand::RngExt;
use serde_json::Value;
use tokio::time::{sleep, Duration};
use tokio_postgres::{error::SqlState, types::Type};

use crate::{
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    postgres::{
        conn_mgmt::{
            run_request_with_retries, Connection, ConnectionSource, QueryOptions, RequestOptions,
        },
        PgDataClient, PgDocument,
    },
    processor,
    protocol::OK_SUCCEEDED,
    requests::{RequestType, WireRequest},
    responses::{self, constant::generic_internal_error_message, RawResponse, Response},
    security::principal::Principal,
};

const NONCE_LENGTH: usize = 2;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum AuthKind {
    Native,
    ExternalIdentity,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum AuthMechanism {
    Oidc,
    ScramSha256,
    Unknown,
}

#[derive(Debug)]
pub struct ScramFirstState {
    nonce: String,
    first_message_bare: String,
    first_message: String,
}

#[derive(Debug)]
pub struct AuthState {
    authenticated: Arc<AtomicBool>,
    first_state: Option<ScramFirstState>,
    username: Option<String>,
    user_oid: Option<u32>,
    auth_kind: Option<AuthKind>,
    timer_initialized: Arc<AtomicBool>,
    auth_mechanism: AuthMechanism,
    principal: Option<Principal>,
}

impl Default for AuthState {
    fn default() -> Self {
        Self::new()
    }
}

impl AuthState {
    #[must_use]
    pub fn new() -> Self {
        Self {
            authenticated: Arc::new(AtomicBool::new(false)),
            first_state: None,
            username: None,
            user_oid: None,
            auth_kind: None,
            timer_initialized: Arc::new(AtomicBool::new(false)),
            auth_mechanism: AuthMechanism::Unknown,
            principal: None,
        }
    }

    /// Returns the principal associated with this authentication state
    ///
    /// # Errors
    ///
    /// Returns an error if the principal has not been set because the user OID is missing.
    #[inline]
    pub fn principal(&self) -> Result<&Principal> {
        // There are other mechansims in request handling that determine when authentication
        // expires. If this is valid - then at some point the user was authenticated and we
        // don't invalidate what the authenticated principal was.
        self.principal
            .as_ref()
            .ok_or(DocumentDBError::not_authenticated(
                "User is not authenticated".to_owned(),
            ))
    }

    /// Returns the username
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub fn username(&self) -> Result<&str> {
        self.username
            .as_deref()
            .ok_or(DocumentDBError::internal_error(
                "Username missing".to_owned(),
            ))
    }

    /// Returns the user OID
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub fn user_oid(&self) -> Result<u32> {
        self.user_oid.ok_or(DocumentDBError::internal_error(
            "User OID missing".to_owned(),
        ))
    }

    #[must_use]
    pub fn is_authenticated(&self) -> bool {
        self.authenticated.load(Ordering::Acquire)
    }

    pub fn set_authenticated(&self, value: bool) {
        self.authenticated.store(value, Ordering::Release);
    }

    #[must_use]
    pub const fn auth_kind(&self) -> Option<&AuthKind> {
        self.auth_kind.as_ref()
    }

    #[must_use]
    pub const fn auth_mechanism(&self) -> &AuthMechanism {
        &self.auth_mechanism
    }

    pub fn set_username(&mut self, user: &str) {
        self.username = Some(user.to_owned());
    }

    pub const fn set_user_oid(&mut self, user_oid: u32) {
        self.user_oid = Some(user_oid);
    }

    /// This will update the currently authenticated principal if the username is correctly set.
    fn update_principal(&mut self) {
        if let (Some(username), Some(user_oid)) = (&self.username, self.user_oid) {
            if self
                .principal
                .as_ref()
                .is_none_or(|p| p.name() != username || p.oid() != user_oid)
            {
                self.principal = Some(Principal::new(username.to_owned(), user_oid));
            }
        } else {
            self.principal = None;
        }
    }

    /// Sets the auth kind
    ///
    /// # Errors
    ///
    /// Returns an error if the operation fails.
    pub fn set_auth_kind(&mut self, kind: AuthKind) -> Result<()> {
        if self.auth_kind.is_none() {
            self.auth_kind = Some(kind);
            Ok(())
        } else if self.auth_kind != Some(kind) {
            Err(DocumentDBError::internal_error(
                "Auth kind is already set".to_owned(),
            ))
        } else {
            Ok(())
        }
    }

    pub const fn set_auth_mechanism(&mut self, mechanism: AuthMechanism) {
        self.auth_mechanism = mechanism;
    }

    fn initialize_expiry_timer(
        &self,
        timeout_secs: u64,
        connection_activity_id: &str,
    ) -> Result<()> {
        let timer_initialized = Arc::clone(&self.timer_initialized);
        if timer_initialized.load(Ordering::Acquire) {
            return Err(DocumentDBError::internal_error(
                "Authentication expiry timer is already initialized".to_owned(),
            ));
        }

        let authenticated = Arc::clone(&self.authenticated);
        let connection_activity_id_owned = connection_activity_id.to_owned();

        // Spawn new expiry task that counts down and sets authenticated to false
        tokio::spawn(async move {
            timer_initialized.store(true, Ordering::Release);

            sleep(Duration::from_secs(timeout_secs)).await;

            let connection_activity_id_as_str = connection_activity_id_owned.as_str();
            tracing::info!(
                activity_id = connection_activity_id_as_str,
                "Authentication expiry timer elapsed"
            );
            authenticated.store(false, Ordering::Release);
            timer_initialized.store(false, Ordering::Release);
        });

        Ok(())
    }
}

/// Should be only called by auth code paths.
async fn call_run_request_with_retries<T, F, Fut>(
    connection_context: &ConnectionContext,
    request_context: &RequestContext<'_>,
    run_func: F,
) -> Result<T>
where
    F: Fn(Arc<Connection>) -> Fut,
    Fut: std::future::Future<Output = std::result::Result<T, tokio_postgres::Error>>,
{
    let pool = connection_context
        .service_context
        .connection_pool_manager()
        .system_auth_pool();

    let query_options = QueryOptions::builder().build();

    let request_options = RequestOptions::new(
        false, // Setting in_replica_cluster_mode to false means we will alway retry in case of SqlState::READ_ONLY_SQL_TRANSACTION.
        None,  // Do not run any gateway-level command timeout for auth-related queries.
    );

    run_request_with_retries(
        ConnectionSource::Pool(pool),
        query_options,
        request_options,
        Duration::from_secs(
            connection_context
                .service_context
                .setup_configuration()
                .postgres_command_timeout_secs(),
        ),
        request_context,
        run_func,
    )
    .await
}

/// Processes an authentication request
///
/// # Errors
///
/// Returns an error if the operation fails.
#[tracing::instrument(
    name = "gateway.auth",
    skip_all,
    fields(otel.kind = "internal", auth.kind = tracing::field::Empty)
)]
pub async fn process<T>(
    connection_context: &mut ConnectionContext,
    request_context: &RequestContext<'_>,
) -> Result<Response>
where
    T: PgDataClient,
{
    let request = request_context.request();
    let request_type = request_context.request_type();
    let auth_response = handle_auth_request(connection_context, request, request_context).await?;
    if let Some(kind) = connection_context.auth_state.auth_kind() {
        tracing::Span::current().record("auth.kind", tracing::field::debug(kind));
    }
    if let Some(response) = auth_response {
        return Ok(response);
    }

    if request_type.allowed_unauthorized() {
        let service_context = Arc::clone(&connection_context.service_context);
        let data_client = T::new_unauthorized(&service_context)?;

        return processor::process_request(request_context, connection_context, &data_client).await;
    }

    Err(DocumentDBError::unauthorized(format!(
        "Command {} is not allowed as the connection is not authenticated yet.",
        request_type.to_string().to_lowercase()
    )))
}

async fn handle_auth_request(
    connection_context: &mut ConnectionContext,
    request: &WireRequest<'_>,
    request_context: &RequestContext<'_>,
) -> Result<Option<Response>> {
    match request.request_type() {
        RequestType::SaslStart => Ok(Some(
            handle_sasl_start(connection_context, request, request_context).await?,
        )),
        RequestType::SaslContinue => Ok(Some(
            handle_sasl_continue(connection_context, request, request_context).await?,
        )),
        RequestType::Logout => {
            connection_context.auth_state = AuthState::new();
            Ok(Some(Response::Raw(RawResponse::new(rawdoc! {
                "ok": OK_SUCCEEDED,
            }))))
        }
        _ => Ok(None),
    }
}

fn generate_server_nonce(client_nonce: &str) -> String {
    const CHARSET: &[u8] = b"!\"#$%&'()*+-./0123456789:;<>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
    let mut rng = rand::rng();

    let mut result = String::with_capacity(NONCE_LENGTH);
    for _ in 0..NONCE_LENGTH {
        let idx = rng.random_range(0..CHARSET.len());
        result.push(CHARSET[idx] as char);
    }

    format!("{client_nonce}{result}")
}

async fn handle_sasl_start(
    connection_context: &mut ConnectionContext,
    request: &WireRequest<'_>,
    request_context: &RequestContext<'_>,
) -> Result<Response> {
    let mechanism = request
        .document()
        .get_str("mechanism")
        .map_err(DocumentDBError::parse_failure())?;

    if mechanism != "SCRAM-SHA-256" && mechanism != "MONGODB-OIDC" {
        return Err(DocumentDBError::authentication_failed(format!(
            "Only SCRAM-SHA-256 and MONGODB-OIDC are supported, got: {mechanism}"
        )));
    }

    if mechanism == "MONGODB-OIDC" {
        return handle_oidc(connection_context, request, request_context).await;
    }

    return handle_scram(connection_context, request, request_context).await;
}

async fn handle_scram(
    connection_context: &mut ConnectionContext,
    request: &WireRequest<'_>,
    request_context: &RequestContext<'_>,
) -> Result<Response> {
    let payload = parse_sasl_payload(request, true)?;

    let username = payload
        .username
        .ok_or(DocumentDBError::authentication_failed(
            "Username missing from SaslStart.".to_owned(),
        ))?;

    let client_nonce = payload.nonce.ok_or(DocumentDBError::authentication_failed(
        "Nonce missing from SaslStart.".to_owned(),
    ))?;

    let server_nonce = generate_server_nonce(client_nonce);

    let (salt, iterations) =
        get_salt_and_iteration(connection_context, username, request_context).await?;
    let response = format!("r={server_nonce},s={salt},i={iterations}");

    connection_context.auth_state.first_state = Some(ScramFirstState {
        nonce: server_nonce,
        first_message_bare: format!("n={username},r={client_nonce}"),
        first_message: response.clone(),
    });

    connection_context.auth_state.username = Some(username.to_owned());

    connection_context
        .auth_state
        .set_auth_kind(AuthKind::Native)?;

    let binary_response = bson::Binary {
        subtype: BinarySubtype::Generic,
        bytes: response.as_bytes().to_vec(),
    };

    Ok(Response::Raw(RawResponse::new(rawdoc! {
        "payload": binary_response,
        "ok": OK_SUCCEEDED,
        "conversationId": 1,
        "done": false
    })))
}

async fn handle_oidc(
    connection_context: &mut ConnectionContext,
    request: &WireRequest<'_>,
    request_context: &RequestContext<'_>,
) -> Result<Response> {
    let payload = request
        .document()
        .get_binary("payload")
        .map_err(DocumentDBError::parse_failure())?;

    let payload_doc = bson::Document::from_reader(&mut std::io::Cursor::new(payload.bytes))
        .map_err(|e| {
            DocumentDBError::bad_value(format!("Failed to parse OIDC payload as BSON: {e}"))
        })?;

    let jwt_token = payload_doc.get_str("jwt").map_err(|_error| {
        DocumentDBError::authentication_failed("JWT token missing from OIDC payload".to_owned())
    })?;

    handle_oidc_token_authentication(connection_context, jwt_token, request_context).await
}

fn remap_oidc_auth_error(error: &DocumentDBError, connection_id: &str) -> DocumentDBError {
    if let Some(db_error) = error.as_db_error() {
        tracing::error!(
            activity_id = connection_id, // use connection id instead of activity id here.
            error = %db_error,
            sub_status = %db_error.code().code(),
            error_file_name = %db_error.file().unwrap_or("not_found"),
            error_file_line_num = %db_error.line().unwrap_or_default(),
            "DbError during authentication."
        );

        if let Some(extension_error_code) =
            responses::from_known_external_error_code(db_error.code())
        {
            if extension_error_code == ErrorCode::CommandNotSupported as i32 {
                return DocumentDBError::authentication_failed(
                    "The authentication mechanism provided is not supported in the service."
                        .to_owned(),
                );
            }
        }

        return match *db_error.code() {
            SqlState::INVALID_PASSWORD => DocumentDBError::authentication_failed(
                "The token provided is not valid.".to_owned(),
            ),
            SqlState::UNDEFINED_OBJECT => DocumentDBError::authentication_failed(
                "External identity is not present in the system.".to_owned(),
            ),
            _ => DocumentDBError::authentication_failed_internal_error(
                generic_internal_error_message().to_owned(),
                &format!(
                    "DbError during authentication: {}, code: {}, file: {}, line: {}.",
                    db_error,
                    db_error.code().code(),
                    db_error.file().unwrap_or("not_found"),
                    db_error.line().unwrap_or_default()
                ),
            ),
        };
    }

    DocumentDBError::authentication_failed_internal_error(
        generic_internal_error_message().to_owned(),
        error.to_string().as_str(),
    )
}

async fn perform_oidc_authentication(
    connection_context: &ConnectionContext,
    oid: &str,
    token_string: &str,
    request_context: &RequestContext<'_>,
) -> Result<()> {
    let query = connection_context
        .service_context
        .query_catalog()
        .authenticate_with_token();

    let run_func = |connection: Arc<Connection>| async move {
        let rows = connection
            .query(query, &[Type::TEXT, Type::TEXT], &[&oid, &token_string])
            .await?;
        rows.first().map(|row| row.try_get(0)).transpose()
    };

    let result = call_run_request_with_retries(connection_context, request_context, run_func).await;
    let connection_id = connection_context.connection_id.to_string();

    match result {
        Ok(maybe_auth_result) => {
            let auth_result: String =
                maybe_auth_result.ok_or(DocumentDBError::pg_response_empty())?;

            if auth_result.trim() != oid {
                return Err(DocumentDBError::authentication_failed(
                    "Token validation failed".to_owned(),
                ));
            }

            Ok(())
        }
        Err(error) => Err(remap_oidc_auth_error(&error, connection_id.as_str())),
    }
}

async fn handle_oidc_token_authentication(
    connection_context: &mut ConnectionContext,
    token_string: &str,
    request_context: &RequestContext<'_>,
) -> Result<Response> {
    let (oid, seconds_until_expiry) = parse_and_validate_jwt_token(token_string)?;

    perform_oidc_authentication(connection_context, &oid, token_string, request_context).await?;

    let server_signature = "";
    let payload = bson::Binary {
        subtype: BinarySubtype::Generic,
        bytes: server_signature.as_bytes().to_vec(),
    };

    connection_context.auth_state.set_username(&oid);
    connection_context.auth_state.user_oid =
        Some(get_user_oid(connection_context, &oid, request_context).await?);
    connection_context.auth_state.update_principal();

    connection_context.auth_state.set_authenticated(true);
    connection_context
        .auth_state
        .set_auth_kind(AuthKind::ExternalIdentity)?;
    connection_context
        .auth_state
        .set_auth_mechanism(AuthMechanism::Oidc);

    // Allocate a connection pool for the user after successful authentication, which will be used for subsequent requests on this connection.
    // The pool will be deallocated after a period of inactivity.
    connection_context.allocate_data_pool(token_string)?;

    /* We are setting a timer for the time until token expiry, which will set authorized to false at the end */
    // For timer related logs, use the connection ID as the activity ID as it affects the overall connection.
    let connection_activity_id = connection_context.connection_id.to_string();
    let connection_activity_id_as_str = connection_activity_id.as_str();
    tracing::info!(activity_id = connection_activity_id_as_str,
        "Setting authentication expiry timer for {seconds_until_expiry} seconds until token expiry.",
    );
    connection_context
        .auth_state
        .initialize_expiry_timer(seconds_until_expiry, connection_activity_id_as_str)?;

    Ok(Response::Raw(RawResponse::new(rawdoc! {
        "payload": payload,
        "ok": OK_SUCCEEDED,
        "conversationId": 1,
        "done": true
    })))
}

#[expect(clippy::cast_sign_loss, reason = "exp is known positive from JWT spec")]
fn parse_and_validate_jwt_token(token_string: &str) -> Result<(String, u64)> {
    let token_parts: Vec<&str> = token_string.split('.').collect();
    if token_parts.len() != 3 {
        return Err(DocumentDBError::authentication_failed(
            "Invalid JWT token format.".to_owned(),
        ));
    }

    let payload_part = token_parts[1];
    let payload_bytes = general_purpose::URL_SAFE_NO_PAD
        .decode(payload_part)
        .map_err(|_error| {
            DocumentDBError::authentication_failed("Invalid JWT token encoding.".to_owned())
        })?;

    let payload_json: Value = serde_json::from_slice(&payload_bytes).map_err(|_error| {
        DocumentDBError::authentication_failed("Invalid JWT token payload.".to_owned())
    })?;

    let oid = payload_json
        .get("oid")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            DocumentDBError::authentication_failed("Token does not contain OID.".to_owned())
        })?
        .to_owned();

    let aud = payload_json
        .get("aud")
        .and_then(|v| v.as_str())
        .ok_or_else(|| {
            DocumentDBError::authentication_failed(
                "Token does not contain audience claim.".to_owned(),
            )
        })?
        .to_owned();

    let exp = payload_json
        .get("exp")
        .and_then(serde_json::Value::as_i64)
        .ok_or_else(|| {
            DocumentDBError::authentication_failed("Token does not contain expiry time.".to_owned())
        })?;

    let valid_audiences = ["https://ossrdbms-aad.database.windows.net"];
    if !valid_audiences.contains(&aud.as_str()) {
        return Err(DocumentDBError::authentication_failed(
            "The audience claim provided in the token is not valid.".to_owned(),
        ));
    }

    let exp_datetime = std::time::UNIX_EPOCH + std::time::Duration::from_secs(exp as u64);
    let now = std::time::SystemTime::now();

    if exp_datetime < now {
        return Err(DocumentDBError::authentication_failed(
            "The token provided is expired.".to_owned(),
        ));
    }

    let timeout_seconds = exp_datetime
        .duration_since(now)
        .unwrap_or(Duration::from_secs(0))
        .as_secs();

    Ok((oid, timeout_seconds))
}

async fn handle_sasl_continue(
    connection_context: &mut ConnectionContext,
    request: &WireRequest<'_>,
    request_context: &RequestContext<'_>,
) -> Result<Response> {
    let payload = parse_sasl_payload(request, false)?;

    if let Some(first_state) = connection_context.auth_state.first_state.as_ref() {
        let mechanism_result = request.document().get_str("mechanism");

        // Only validate mechanism if it's present - it's optional in SaslContinue
        // (per auth spec, mechanism is only in saslStart, not saslContinue)
        if let Ok(mechanism) = mechanism_result {
            if mechanism == "MONGODB-OIDC" {
                return Err(DocumentDBError::authentication_failed(
                    "Auth mechanism MONGODB-OIDC is not supported in SaslContinue".to_owned(),
                ));
            }
        }

        // Username is not always provided by saslcontinue

        let client_nonce = payload.nonce.ok_or(DocumentDBError::authentication_failed(
            "Nonce missing from SaslContinue.".to_owned(),
        ))?;
        let proof = payload.proof.ok_or(DocumentDBError::authentication_failed(
            "Proof missing from SaslContinue.".to_owned(),
        ))?;
        let channel_binding =
            payload
                .channel_binding
                .ok_or(DocumentDBError::authentication_failed(
                    "Channel binding missing from SaslContinue.".to_owned(),
                ))?;
        let username = payload
            .username
            .or(connection_context.auth_state.username.as_deref())
            .ok_or(DocumentDBError::internal_error(
                "Username missing from SaslContinue".to_owned(),
            ))?;

        if client_nonce != first_state.nonce {
            return Err(DocumentDBError::authentication_failed(
                "Nonce did not match expected nonce.".to_owned(),
            ));
        }

        let auth_message = format!(
            "{},{},c={},r={}",
            first_state.first_message_bare,
            first_state.first_message,
            channel_binding,
            client_nonce
        );
        let auth_message_str = auth_message.as_str();

        let query = connection_context
            .service_context
            .query_catalog()
            .authenticate_with_scram_sha256();

        let run_func = |connection: Arc<Connection>| async move {
            let rows = connection
                .query(
                    query,
                    &[Type::TEXT, Type::TEXT, Type::TEXT],
                    &[&username, &auth_message_str, &proof],
                )
                .await?;
            let Some(row) = rows.first() else {
                return Ok(None);
            };
            let doc: PgDocument = row.try_get(0)?;
            Ok(Some(doc.0.to_raw_document_buf()))
        };

        let scram_sha256_doc =
            call_run_request_with_retries(connection_context, request_context, run_func)
                .await?
                .ok_or(DocumentDBError::pg_response_empty())?;

        if scram_sha256_doc
            .get_i32("ok")
            .map_err(DocumentDBError::pg_response_invalid)?
            != 1
        {
            return Err(DocumentDBError::authentication_failed(
                "Invalid key".to_owned(),
            ));
        }

        let server_signature = scram_sha256_doc
            .get_str("ServerSignature")
            .map_err(DocumentDBError::pg_response_invalid)?;

        let payload = bson::Binary {
            subtype: BinarySubtype::Generic,
            bytes: format!("v={server_signature}").as_bytes().to_vec(),
        };

        connection_context.auth_state.user_oid =
            Some(get_user_oid(connection_context, username, request_context).await?);

        connection_context.auth_state.set_authenticated(true);
        connection_context.allocate_data_pool("")?;

        connection_context
            .auth_state
            .set_auth_mechanism(AuthMechanism::ScramSha256);

        // This will create a Principal from the username and user_oid and store it in auth_state
        connection_context.auth_state.update_principal();

        Ok(Response::Raw(RawResponse::new(rawdoc! {
            "payload": payload,
            "ok": OK_SUCCEEDED,
            "conversationId": 1,
            "done": true
        })))
    } else {
        Err(DocumentDBError::authentication_failed(
            "SaslContinue called without SaslStart state.".to_owned(),
        ))
    }
}

struct ScramPayload<'a> {
    username: Option<&'a str>,
    nonce: Option<&'a str>,
    proof: Option<&'a str>,
    channel_binding: Option<&'a str>,
}

fn parse_sasl_payload<'a>(
    request: &'a WireRequest<'a>,
    with_header: bool,
) -> Result<ScramPayload<'a>> {
    let payload = request
        .document()
        .get_binary("payload")
        .map_err(DocumentDBError::parse_failure())?;
    let mut payload = from_utf8(payload.bytes).map_err(|e| {
        DocumentDBError::bad_value(format!("Sasl payload couldn't be converted to utf-8: {e}"))
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

    let mut username: Option<&str> = None;
    let mut nonce: Option<&str> = None;
    let mut proof: Option<&str> = None;
    let mut channel_binding: Option<&str> = None;

    for value in payload.split(',') {
        let idx = value
            .find('=')
            .ok_or(DocumentDBError::sasl_payload_invalid())?;

        let k = &value[..idx];
        let v = &value[idx + 1..];
        match k {
            "n" => username = Some(v),
            "r" => nonce = Some(v),
            "p" => proof = Some(v),
            "c" => channel_binding = Some(v),
            _ => {
                return Err(DocumentDBError::authentication_failed(
                    "Sasl payload was invalid.".to_owned(),
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

    let doc = call_run_request_with_retries(connection_context, request_context, run_func)
        .await?
        .ok_or(DocumentDBError::pg_response_empty())?;

    if doc
        .get_i32("ok")
        .map_err(|e| DocumentDBError::internal_error(e.to_string()))?
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

/// Gets the user OID from the database
///
/// # Errors
///
/// Returns an error if the operation fails.
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
    };

    let user_oid_result =
        call_run_request_with_retries(connection_context, request_context, run_func).await?;

    user_oid_result.ok_or(DocumentDBError::pg_response_empty())
}
