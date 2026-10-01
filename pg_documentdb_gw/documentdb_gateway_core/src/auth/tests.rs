/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/auth/tests.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::{
    atomic::{AtomicBool, Ordering},
    Arc,
};

use async_trait::async_trait;
use bson::{doc, spec::BinarySubtype, Binary};
use serde_json::Value;

use crate::{
    auth::{
        handle_authentication, scram::SCRAM_SHA256_SCHEME, AuthenticationFailed,
        AuthenticationHandler, AuthenticationManager, AuthenticationResult, AuthenticationSuccess,
        UserAuthState,
    },
    context::{ConnectionContext, RequestContext},
    error::{ErrorCode, Result},
    postgres::conn_mgmt::PgPoolSettings,
    requests::{request_tracker::RequestTracker, Request, RequestType, WireRequest},
    security::principal::Principal,
    testing::{
        build_raw_document, test_connection_context,
        test_connection_context_with_authentication_manager, TestDynamicConfiguration,
    },
};

#[derive(Debug)]
struct ChallengeHandler;

#[async_trait]
impl AuthenticationHandler for ChallengeHandler {
    async fn handle_authenticate(
        &self,
        _connection_context: &mut ConnectionContext,
        _request_context: &RequestContext<'_>,
    ) -> Result<AuthenticationResult> {
        Ok(AuthenticationResult::Challenge(Vec::new()))
    }
}

#[derive(Debug)]
struct ConfigurableHandler {
    enabled: Arc<AtomicBool>,
}

#[async_trait]
impl AuthenticationHandler for ConfigurableHandler {
    fn enabled(&self) -> bool {
        self.enabled.load(Ordering::Relaxed)
    }

    async fn handle_authenticate(
        &self,
        _connection_context: &mut ConnectionContext,
        _request_context: &RequestContext<'_>,
    ) -> Result<AuthenticationResult> {
        Ok(AuthenticationResult::Challenge(Vec::new()))
    }
}

#[derive(Debug)]
struct SuccessHandler {
    principal: Principal,
}

#[async_trait]
impl AuthenticationHandler for SuccessHandler {
    async fn handle_authenticate(
        &self,
        _connection_context: &mut ConnectionContext,
        _request_context: &RequestContext<'_>,
    ) -> Result<AuthenticationResult> {
        Ok(AuthenticationResult::Success(AuthenticationSuccess::new(
            self.principal.clone(),
            Vec::new(),
            "TEST",
            String::new(),
            None,
            None,
        )))
    }
}

#[derive(Debug)]
struct ChallengeThenSuccessHandler {
    challenged: AtomicBool,
    principal: Principal,
}

#[async_trait]
impl AuthenticationHandler for ChallengeThenSuccessHandler {
    async fn handle_authenticate(
        &self,
        _connection_context: &mut ConnectionContext,
        _request_context: &RequestContext<'_>,
    ) -> Result<AuthenticationResult> {
        if !self.challenged.swap(true, Ordering::Relaxed) {
            return Ok(AuthenticationResult::Challenge(Vec::new()));
        }

        Ok(AuthenticationResult::Success(AuthenticationSuccess::new(
            self.principal.clone(),
            Vec::new(),
            "TEST",
            String::new(),
            None,
            None,
        )))
    }
}

#[derive(Debug)]
struct FailedHandler;

#[async_trait]
impl AuthenticationHandler for FailedHandler {
    async fn handle_authenticate(
        &self,
        connection_context: &mut ConnectionContext,
        _request_context: &RequestContext<'_>,
    ) -> Result<AuthenticationResult> {
        connection_context
            .user_mut()
            .set_metadata("TEST", Value::Bool(true))?;
        Ok(AuthenticationResult::Failed(AuthenticationFailed::new(
            Vec::new(),
        )))
    }
}

fn authentication_request() -> Request {
    let document = doc! {
        "saslStart": 1_i32,
        "mechanism": "TEST",
        "payload": Binary {
            subtype: BinarySubtype::Generic,
            bytes: Vec::new(),
        },
        "$db": "admin",
    };

    Request::RawBuf(RequestType::SaslStart, build_raw_document(&document))
}

#[test]
fn authentication_success_debug_redacts_pool_secret() {
    let secret = "header.payload.signature";
    let result = AuthenticationResult::Success(AuthenticationSuccess::new(
        Principal::new("external-user", 1),
        Vec::new(),
        "TEST",
        secret.to_owned(),
        None,
        None,
    ));

    let debug_output = format!("{result:?}");

    assert!(!debug_output.contains(secret));
    assert!(debug_output.contains("pool_secret: \"<redacted>\""));
}

#[tokio::test]
async fn sasl_start_clears_authenticated_user_and_pool_settings() {
    let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
    let mut connection_context = test_connection_context(false, dynamic_configuration, None).await;
    connection_context
        .set_authenticated_user(
            UserAuthState::authenticated(
                "existing-scheme",
                Principal::new("existing-user", 1),
                None,
                None,
            ),
            "existing-secret",
        )
        .expect("initial authenticated user and data pool should be installed");

    let mut authentication_manager = AuthenticationManager::default();
    authentication_manager
        .register_scheme("TEST", Box::new(ChallengeHandler))
        .expect("test scheme should register");
    let request = authentication_request();
    let request_info = request
        .extract_common()
        .expect("saslStart request should have valid common fields");
    let wire_request = WireRequest::from_request_and_info(&request, request_info);
    let request_tracker = RequestTracker::new();
    let request_context =
        RequestContext::new("activity-sasl-start", &wire_request, &request_tracker);

    let result = authentication_manager
        .authenticate(&mut connection_context, &request_context)
        .await
        .expect("test authentication handler should return a challenge");

    assert!(matches!(result, AuthenticationResult::Challenge(_)));
    assert!(!connection_context.user().is_authenticated());
    connection_context
        .user()
        .principal()
        .expect_err("starting authentication should clear the prior principal");
    connection_context
        .user()
        .data_pool_settings()
        .expect_err("starting authentication should clear prior pool settings");
}

#[tokio::test]
async fn authentication_can_switch_principal() {
    let new_principal = Principal::new("different-user", 2);
    let mut authentication_manager = AuthenticationManager::default();
    authentication_manager
        .register_scheme(
            "TEST",
            Box::new(SuccessHandler {
                principal: new_principal.clone(),
            }),
        )
        .expect("test scheme should register");
    let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
    let mut connection_context = test_connection_context_with_authentication_manager(
        false,
        dynamic_configuration,
        None,
        authentication_manager,
    )
    .await;
    connection_context
        .set_authenticated_user(
            UserAuthState::authenticated(
                "existing-scheme",
                Principal::new("existing-user", 1),
                None,
                None,
            ),
            "existing-secret",
        )
        .expect("initial authenticated user and data pool should be installed");
    let existing_settings = connection_context
        .user()
        .data_pool_settings()
        .expect("existing user should retain its pool settings");
    let existing_pool = connection_context
        .service_context
        .connection_pool_manager()
        .get_data_pool_with_settings("existing-user", existing_settings)
        .expect("existing user pool should be available");

    let request = authentication_request();
    let request_info = request
        .extract_common()
        .expect("saslStart request should have valid common fields");
    let wire_request = WireRequest::from_request_and_info(&request, request_info);
    let request_tracker = RequestTracker::new();
    let request_context =
        RequestContext::new("activity-user-switch", &wire_request, &request_tracker);

    handle_authentication(&mut connection_context, &request_context)
        .await
        .expect("authentication should allow replacing an authenticated principal")
        .expect("authentication request should produce a response");

    assert_eq!(
        connection_context
            .user()
            .principal()
            .expect("new principal should be authenticated"),
        &new_principal
    );
    let new_settings = connection_context
        .user()
        .data_pool_settings()
        .expect("new user should retain its pool settings");
    let new_pool = connection_context
        .service_context
        .connection_pool_manager()
        .get_data_pool_with_settings(new_principal.name(), new_settings)
        .expect("new user pool should be available");
    assert!(
        !Arc::ptr_eq(&existing_pool, &new_pool),
        "switching users must not reuse the previous user's connection pool"
    );
}

#[tokio::test]
async fn reauthentication_requires_the_same_principal() {
    let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
    let mut connection_context = test_connection_context(false, dynamic_configuration, None).await;
    connection_context.set_user(UserAuthState::authenticated(
        "existing-scheme",
        Principal::new("existing-user", 1),
        None,
        Some(0),
    ));
    connection_context.update_user_expiration_status();

    let mut authentication_manager = AuthenticationManager::default();
    authentication_manager
        .register_scheme(
            "TEST",
            Box::new(ChallengeThenSuccessHandler {
                challenged: AtomicBool::new(false),
                principal: Principal::new("different-user", 2),
            }),
        )
        .expect("test scheme should register");
    let request = authentication_request();
    let request_info = request
        .extract_common()
        .expect("saslStart request should have valid common fields");
    let wire_request = WireRequest::from_request_and_info(&request, request_info);
    let request_tracker = RequestTracker::new();
    let request_context = RequestContext::new("activity-reauth", &wire_request, &request_tracker);

    let first_result = authentication_manager
        .authenticate(&mut connection_context, &request_context)
        .await
        .expect("an incomplete reauthentication should return a challenge");
    assert!(matches!(first_result, AuthenticationResult::Challenge(_)));

    let error = authentication_manager
        .authenticate(&mut connection_context, &request_context)
        .await
        .expect_err("reauthentication cannot replace the verified principal");

    assert_eq!(error.error_code(), ErrorCode::AuthenticationFailed);
    assert!(!connection_context.user().is_authenticated());
    connection_context
        .user()
        .principal()
        .expect_err("rejected reauthentication must not install a new principal");
}

#[tokio::test]
async fn reauthentication_accepts_the_same_principal() {
    let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
    let mut connection_context = test_connection_context(false, dynamic_configuration, None).await;
    let principal = Principal::new("existing-user", 1);
    connection_context.set_user(UserAuthState::authenticated(
        "existing-scheme",
        principal.clone(),
        None,
        Some(0),
    ));
    connection_context.update_user_expiration_status();

    let mut authentication_manager = AuthenticationManager::default();
    authentication_manager
        .register_scheme(
            "TEST",
            Box::new(SuccessHandler {
                principal: principal.clone(),
            }),
        )
        .expect("test scheme should register");
    let request = authentication_request();
    let request_info = request
        .extract_common()
        .expect("saslStart request should have valid common fields");
    let wire_request = WireRequest::from_request_and_info(&request, request_info);
    let request_tracker = RequestTracker::new();
    let request_context = RequestContext::new("activity-reauth", &wire_request, &request_tracker);

    let result = authentication_manager
        .authenticate(&mut connection_context, &request_context)
        .await
        .expect("reauthentication should accept the same verified principal");

    let AuthenticationResult::Success(success) = result else {
        panic!("reauthentication should complete successfully");
    };
    assert_eq!(success.principal(), &principal);
}

#[test]
fn registration_rejects_duplicate_schemes() {
    let mut authentication_manager = AuthenticationManager::default();
    authentication_manager
        .register_scheme("TEST", Box::new(ChallengeHandler))
        .expect("first handler should register");

    authentication_manager
        .register_scheme("TEST", Box::new(ChallengeHandler))
        .expect_err("duplicate schemes must be rejected");
}

#[tokio::test]
async fn terminal_failure_clears_mechanism_state() {
    let dynamic_configuration: Arc<dyn crate::configuration::DynamicConfiguration> =
        Arc::new(TestDynamicConfiguration::default());
    let mut authentication_manager = AuthenticationManager::new();
    authentication_manager
        .register_scheme("TEST", Box::new(FailedHandler))
        .expect("test scheme should register");
    let mut connection_context = test_connection_context_with_authentication_manager(
        false,
        dynamic_configuration,
        None,
        authentication_manager,
    )
    .await;
    let request = authentication_request();
    let request_info = request
        .extract_common()
        .expect("saslStart request should have valid common fields");
    let wire_request = WireRequest::from_request_and_info(&request, request_info);
    let request_tracker = RequestTracker::new();
    let request_context = RequestContext::new("activity-failed", &wire_request, &request_tracker);

    let response = handle_authentication(&mut connection_context, &request_context)
        .await
        .expect("terminal failure should produce a response")
        .expect("authentication command should be handled")
        .as_json()
        .expect("authentication response should be valid BSON");

    assert!(response
        .get_bool("done")
        .expect("response should have done"));
    assert_eq!(connection_context.user().scheme(), None);
    assert_eq!(connection_context.user().metadata("TEST"), None);
    assert!(!connection_context.user().is_authenticated());
}

#[test]
fn supported_schemes_are_sorted_and_enabled() {
    let enabled = Arc::new(AtomicBool::new(false));
    let mut authentication_manager = AuthenticationManager::default();
    authentication_manager
        .register_scheme("SECOND", Box::new(ChallengeHandler))
        .expect("second scheme should register");
    authentication_manager
        .register_scheme(
            "FIRST",
            Box::new(ConfigurableHandler {
                enabled: Arc::clone(&enabled),
            }),
        )
        .expect("first scheme should register");

    assert_eq!(authentication_manager.supported_schemes(), vec!["SECOND"]);

    enabled.store(true, Ordering::Relaxed);

    assert_eq!(
        authentication_manager.supported_schemes(),
        vec!["FIRST", "SECOND"]
    );
}

#[test]
fn telemetry_scheme_collapses_disabled_and_unregistered_input() {
    let enabled = Arc::new(AtomicBool::new(false));
    let mut authentication_manager = AuthenticationManager::new();
    authentication_manager
        .register_scheme(
            "TEST",
            Box::new(ConfigurableHandler {
                enabled: Arc::clone(&enabled),
            }),
        )
        .expect("test scheme should register");

    assert_eq!(
        authentication_manager.telemetry_scheme(Some(SCRAM_SHA256_SCHEME)),
        SCRAM_SHA256_SCHEME
    );
    assert_eq!(
        authentication_manager.telemetry_scheme(Some("TEST")),
        "unsupported"
    );
    assert_eq!(
        authentication_manager.telemetry_scheme(Some("client-controlled-value")),
        "unsupported"
    );
    assert_eq!(authentication_manager.telemetry_scheme(None), "unsupported");

    enabled.store(true, Ordering::Relaxed);

    assert_eq!(
        authentication_manager.telemetry_scheme(Some("TEST")),
        "TEST"
    );
}

#[tokio::test]
async fn authentication_rejects_a_disabled_handler() {
    let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
    let service_dynamic_configuration = Arc::clone(&dynamic_configuration);
    let mut connection_context =
        test_connection_context(false, service_dynamic_configuration, None).await;
    let mut authentication_manager = AuthenticationManager::default();
    let enabled = Arc::new(AtomicBool::new(false));
    authentication_manager
        .register_scheme(
            "TEST",
            Box::new(ConfigurableHandler {
                enabled: Arc::clone(&enabled),
            }),
        )
        .expect("test scheme should register");
    let request = authentication_request();
    let request_info = request
        .extract_common()
        .expect("saslStart request should have valid common fields");
    let wire_request = WireRequest::from_request_and_info(&request, request_info);
    let request_tracker = RequestTracker::new();
    let request_context = RequestContext::new("activity-disabled", &wire_request, &request_tracker);

    let error = authentication_manager
        .authenticate(&mut connection_context, &request_context)
        .await
        .expect_err("disabled authentication handler should be rejected");
    assert_eq!(error.error_code(), ErrorCode::AuthenticationFailed);
    assert_eq!(connection_context.user().scheme(), None);

    enabled.store(true, Ordering::Relaxed);

    let result = authentication_manager
        .authenticate(&mut connection_context, &request_context)
        .await
        .expect("enabled authentication handler should be invoked");
    assert!(matches!(result, AuthenticationResult::Challenge(_)));
}

#[test]
fn authentication_metadata_is_scoped_to_owning_scheme() {
    let mut user = UserAuthState::begin("FIRST", None);
    user.set_metadata("FIRST", Value::Bool(true))
        .expect("owning scheme should store metadata");

    assert_eq!(user.metadata("FIRST"), Some(&Value::Bool(true)));
    assert_eq!(user.metadata("SECOND"), None);
    user.set_metadata("SECOND", Value::Bool(false))
        .expect_err("another scheme must not replace conversation state");
}

#[test]
fn failed_reauthentication_clears_transient_state_and_restores_expired_state() {
    let principal = Principal::new("existing-user", 1);
    let mut user = UserAuthState::begin("TEST", Some(principal.clone()));
    user.set_metadata("TEST", Value::Bool(true))
        .expect("owning scheme should store metadata");

    user.clear_failed_attempt();

    assert_eq!(user.scheme(), None);
    assert_eq!(user.metadata("TEST"), None);
    assert_eq!(user.reauthentication_principal(), Some(&principal));
    assert!(!user.is_authenticated());
    assert!(user.is_expired());
}

#[tokio::test]
async fn disabled_reauthentication_scheme_preserves_expired_principal() {
    let principal = Principal::new("existing-user", 1);
    let dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
    let mut authentication_manager = AuthenticationManager::default();
    authentication_manager
        .register_scheme(
            "TEST",
            Box::new(ConfigurableHandler {
                enabled: Arc::new(AtomicBool::new(false)),
            }),
        )
        .expect("test scheme should register");
    let mut connection_context = test_connection_context_with_authentication_manager(
        false,
        dynamic_configuration,
        None,
        authentication_manager,
    )
    .await;
    connection_context.set_user(UserAuthState::authenticated(
        "TEST",
        principal.clone(),
        None,
        Some(0),
    ));
    let request = authentication_request();
    let request_info = request
        .extract_common()
        .expect("saslStart request should have valid common fields");
    let wire_request = WireRequest::from_request_and_info(&request, request_info);
    let request_tracker = RequestTracker::new();
    let request_context =
        RequestContext::new("activity-disabled-reauth", &wire_request, &request_tracker);

    let error = handle_authentication(&mut connection_context, &request_context)
        .await
        .expect_err("disabled reauthentication scheme should be rejected");

    assert_eq!(error.error_code(), ErrorCode::AuthenticationFailed);
    assert_eq!(
        connection_context.user().reauthentication_principal(),
        Some(&principal)
    );
    assert!(!connection_context.user().is_authenticated());
    assert!(connection_context.user().is_expired());
}

#[test]
fn failed_initial_authentication_clears_transient_state() {
    let mut user = UserAuthState::begin("TEST", None);
    user.set_metadata("TEST", Value::Bool(true))
        .expect("owning scheme should store metadata");

    user.clear_failed_attempt();

    assert_eq!(user.scheme(), None);
    assert_eq!(user.metadata("TEST"), None);
    assert_eq!(user.reauthentication_principal(), None);
    assert!(!user.is_authenticated());
    assert!(!user.is_expired());
}

#[test]
fn expiration_clears_data_pool_settings() {
    let mut user =
        UserAuthState::authenticated("TEST", Principal::new("external-user", 1), None, Some(0));
    user.set_data_pool_settings(PgPoolSettings::system_pool_settings(1));

    assert!(user.update_expiration_status());
    assert!(user.is_expired());
    user.data_pool_settings()
        .expect_err("expired authentication must not retain data pool settings");
}
