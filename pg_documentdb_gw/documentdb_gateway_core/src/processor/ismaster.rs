/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/ismaster.rs
 *
 *-------------------------------------------------------------------------
 */

use std::{
    sync::Arc,
    time::{SystemTime, UNIX_EPOCH},
};

use bson::{rawdoc, RawArrayBuf, RawDocumentBuf};

use crate::{
    configuration::DynamicConfiguration,
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    protocol::{MAX_BSON_OBJECT_SIZE, MAX_MESSAGE_SIZE_BYTES, OK_FAILED, OK_SUCCEEDED},
    requests::RequestType,
    responses::{RawResponse, Response},
};

/// Reported when this node declines to serve handshakes for the endpoint the
/// client connected with.
const ENDPOINT_NOT_ROUTABLE_MESSAGE: &str = "Endpoint is not available for routing.";

#[expect(clippy::cast_possible_truncation, reason = "timestamp fits in u32")]
#[expect(clippy::cast_sign_loss, reason = "timestamp is always positive")]
pub fn process(
    request_context: &RequestContext<'_>,
    writeable_primary_field: &str,
    connection_context: &mut ConnectionContext,
    dynamic_configuration: &Arc<dyn DynamicConfiguration>,
) -> Result<Response> {
    let request = request_context.request();
    let is_legacy_is_master = request.request_type() == RequestType::IsMaster;
    let supported_schemes = connection_context
        .service_context
        .authentication_manager()
        .supported_schemes();
    let mut supported_mechanisms = RawArrayBuf::new();
    for scheme in supported_schemes {
        supported_mechanisms.push(scheme);
    }
    let local_time = i64::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| {
                tracing::error!("Failed to get the current time: {error}");
                DocumentDBError::internal_error("Failed to get the current time".to_owned())
            })?
            .as_millis(),
    )
    .map_err(|error| {
        tracing::error!("Current time exceeded an i64: {error}");
        DocumentDBError::internal_error("Current time exceeded an i64".to_owned())
    })?;

    if let Ok(client) = request.document().get_document("client") {
        if connection_context.client_information.is_some() {
            return Err(DocumentDBError::documentdb_error(
                ErrorCode::ClientMetadataCannotBeMutated,
                "Client metadata cannot be mutated".to_owned(),
            ));
        }
        connection_context.client_information = Some(client.to_raw_document_buf());
    }

    let server_name = connection_context.tls_server_name();
    let routable = dynamic_configuration.is_endpoint_routable(server_name);
    let is_pre_auth_is_master =
        is_legacy_is_master && !connection_context.user().is_authenticated();

    // An unauthenticated isMaster that is refused for routing carries only the
    // fields a driver needs to treat the reply as a failed handshake.
    if !routable && is_pre_auth_is_master {
        return Ok(Response::Raw(RawResponse::new(rawdoc! {
            "connectionId": connection_context.get_connection_id_hash(),
            "helloOk": true,
            "errmsg": ENDPOINT_NOT_ROUTABLE_MESSAGE,
            "ok": OK_FAILED,
        })));
    }

    let mut response_doc = RawDocumentBuf::new();
    if routable {
        response_doc.append(writeable_primary_field, true);
        response_doc.append("msg", "isdbgrid");
        response_doc.append("maxBsonObjectSize", MAX_BSON_OBJECT_SIZE);
        response_doc.append("maxMessageSizeBytes", MAX_MESSAGE_SIZE_BYTES);
        response_doc.append(
            "maxWriteBatchSize",
            dynamic_configuration.max_write_batch_size(),
        );
        response_doc.append("localTime", local_time);
        response_doc.append("logicalSessionTimeoutMinutes", 30);
        response_doc.append("minWireVersion", 0);
        response_doc.append("maxWireVersion", dynamic_configuration.max_wire_version());
    } else {
        response_doc.append("errmsg", ENDPOINT_NOT_ROUTABLE_MESSAGE);
    }

    // The endpoint hint is only meaningful on the handshake shape that carries
    // the server capabilities, so it is left off an unauthenticated isMaster.
    if !is_pre_auth_is_master && dynamic_configuration.report_endpoint_name() {
        if let Some(server_name) = server_name {
            response_doc.append("endpointName", server_name);
        }
    }

    response_doc.append("readOnly", dynamic_configuration.read_only());
    response_doc.append("connectionId", connection_context.get_connection_id_hash());
    response_doc.append("saslSupportedMechs", supported_mechanisms);
    response_doc.append("internal", dynamic_configuration.topology());
    response_doc.append("ok", if routable { OK_SUCCEEDED } else { OK_FAILED });

    // Add the operationTime field if change streams GUC is enabled
    if dynamic_configuration.enable_change_streams() {
        response_doc.append(
            "operationTime",
            bson::Timestamp {
                time: (local_time / 1000) as u32,
                increment: (local_time % 1000) as u32,
            },
        );
    }

    Ok(Response::Raw(RawResponse::new(response_doc)))
}

#[cfg(test)]
mod tests {
    use std::sync::atomic::{AtomicBool, Ordering};

    use async_trait::async_trait;
    use bson::{doc, Bson};

    use super::*;
    use crate::{
        auth::{AuthenticationHandler, AuthenticationManager, AuthenticationResult, UserAuthState},
        requests::{request_tracker::RequestTracker, Request, RequestExecutionMode, WireRequest},
        security::principal::Principal,
        testing::{
            build_raw_document, test_connection_context,
            test_connection_context_with_authentication_manager, TestDynamicConfiguration,
        },
    };

    const GLOBAL_SERVER_NAME: &str = "node.global.example.net";

    #[expect(
        clippy::struct_excessive_bools,
        reason = "test fixture toggles independent handshake conditions"
    )]
    struct HandshakeCase {
        request_type: RequestType,
        authenticated: bool,
        routable: bool,
        report_endpoint_name: bool,
        enable_change_streams: bool,
        server_name: Option<&'static str>,
    }

    impl HandshakeCase {
        const fn new(request_type: RequestType) -> Self {
            Self {
                request_type,
                authenticated: false,
                routable: true,
                report_endpoint_name: false,
                enable_change_streams: false,
                server_name: Some(GLOBAL_SERVER_NAME),
            }
        }
    }

    async fn run_handshake(case: HandshakeCase) -> bson::Document {
        let test_dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        test_dynamic_configuration.set_endpoint_routable(case.routable);
        test_dynamic_configuration.set_report_endpoint_name(case.report_endpoint_name);
        test_dynamic_configuration.set_enable_change_streams(case.enable_change_streams);
        let dynamic_configuration: Arc<dyn DynamicConfiguration> = test_dynamic_configuration;
        let mut connection_context =
            test_connection_context(false, Arc::clone(&dynamic_configuration), None).await;
        connection_context.set_tls_server_name(case.server_name.map(str::to_owned));
        if case.authenticated {
            *connection_context.user_mut() = UserAuthState::authenticated(
                "SCRAM-SHA-256",
                Principal::new("alice".to_owned(), 3),
                None,
                None,
            );
        }

        let (command, writeable_primary_field) = if case.request_type == RequestType::IsMaster {
            ("isMaster", "ismaster")
        } else {
            ("hello", "isWritablePrimary")
        };
        let document = doc! { command: 1_i32, "$db": "admin" };
        let wire_request = WireRequest::from_owned_command_document(
            case.request_type,
            RequestExecutionMode::Normal,
            None,
            build_raw_document(&document),
            None,
        )
        .expect("handshake request should have valid common fields");
        let request_tracker = RequestTracker::new();
        let request_context =
            RequestContext::new("activity-handshake", &wire_request, &request_tracker);

        process(
            &request_context,
            writeable_primary_field,
            &mut connection_context,
            &dynamic_configuration,
        )
        .expect("handshake should produce a response")
        .as_json()
        .expect("handshake response should be valid BSON")
    }

    fn assert_not_routable_hello_shape(response: &bson::Document, writeable_primary_field: &str) {
        assert_eq!(response.get_f64("ok"), Ok(OK_FAILED));
        assert_eq!(
            response.get_str("errmsg"),
            Ok(ENDPOINT_NOT_ROUTABLE_MESSAGE)
        );
        for field in [
            writeable_primary_field,
            "msg",
            "maxBsonObjectSize",
            "maxMessageSizeBytes",
            "maxWriteBatchSize",
            "localTime",
            "logicalSessionTimeoutMinutes",
            "minWireVersion",
            "maxWireVersion",
        ] {
            assert!(!response.contains_key(field), "unexpected field {field}");
        }
        for field in ["readOnly", "connectionId", "saslSupportedMechs", "internal"] {
            assert!(response.contains_key(field), "missing field {field}");
        }
    }

    #[tokio::test]
    async fn routable_hello_reports_success_without_endpoint_name_by_default() {
        let response = run_handshake(HandshakeCase::new(RequestType::Hello)).await;

        assert_eq!(response.get_f64("ok"), Ok(OK_SUCCEEDED));
        assert_eq!(response.get_bool("isWritablePrimary"), Ok(true));
        assert!(!response.contains_key("errmsg"));
        assert!(!response.contains_key("endpointName"));
    }

    #[tokio::test]
    async fn routable_hello_reports_endpoint_name_when_enabled() {
        let response = run_handshake(HandshakeCase {
            report_endpoint_name: true,
            ..HandshakeCase::new(RequestType::Hello)
        })
        .await;

        assert_eq!(response.get_f64("ok"), Ok(OK_SUCCEEDED));
        assert_eq!(response.get_str("endpointName"), Ok(GLOBAL_SERVER_NAME));
    }

    #[tokio::test]
    async fn endpoint_name_is_omitted_without_server_name() {
        let response = run_handshake(HandshakeCase {
            report_endpoint_name: true,
            server_name: None,
            ..HandshakeCase::new(RequestType::Hello)
        })
        .await;

        assert!(!response.contains_key("endpointName"));
    }

    #[tokio::test]
    async fn not_routable_hello_returns_failed_handshake() {
        for authenticated in [false, true] {
            let response = run_handshake(HandshakeCase {
                authenticated,
                routable: false,
                report_endpoint_name: true,
                ..HandshakeCase::new(RequestType::Hello)
            })
            .await;

            assert_not_routable_hello_shape(&response, "isWritablePrimary");
            assert_eq!(response.get_str("endpointName"), Ok(GLOBAL_SERVER_NAME));
        }
    }

    #[tokio::test]
    async fn operation_time_is_reported_whenever_change_streams_are_enabled() {
        for routable in [true, false] {
            let response = run_handshake(HandshakeCase {
                routable,
                enable_change_streams: true,
                ..HandshakeCase::new(RequestType::Hello)
            })
            .await;

            assert!(
                matches!(response.get("operationTime"), Some(&Bson::Timestamp(_))),
                "missing operationTime for routable={routable}"
            );
        }
    }

    #[tokio::test]
    async fn operation_time_is_omitted_when_change_streams_are_disabled() {
        let response = run_handshake(HandshakeCase::new(RequestType::Hello)).await;

        assert!(!response.contains_key("operationTime"));
    }

    #[tokio::test]
    async fn not_routable_authenticated_is_master_returns_failed_handshake() {
        let response = run_handshake(HandshakeCase {
            authenticated: true,
            routable: false,
            report_endpoint_name: true,
            ..HandshakeCase::new(RequestType::IsMaster)
        })
        .await;

        assert_not_routable_hello_shape(&response, "ismaster");
        assert_eq!(response.get_str("endpointName"), Ok(GLOBAL_SERVER_NAME));
    }

    #[tokio::test]
    async fn not_routable_unauthenticated_is_master_returns_minimal_reply() {
        let response = run_handshake(HandshakeCase {
            routable: false,
            report_endpoint_name: true,
            ..HandshakeCase::new(RequestType::IsMaster)
        })
        .await;

        let keys: Vec<&str> = response.keys().map(String::as_str).collect();
        assert_eq!(keys, ["connectionId", "helloOk", "errmsg", "ok"]);
        assert_eq!(response.get_bool("helloOk"), Ok(true));
        assert_eq!(
            response.get_str("errmsg"),
            Ok(ENDPOINT_NOT_ROUTABLE_MESSAGE)
        );
        assert_eq!(response.get_f64("ok"), Ok(OK_FAILED));
    }

    #[tokio::test]
    async fn routable_is_master_reports_success() {
        let response = run_handshake(HandshakeCase::new(RequestType::IsMaster)).await;

        assert_eq!(response.get_f64("ok"), Ok(OK_SUCCEEDED));
        assert_eq!(response.get_bool("ismaster"), Ok(true));
        assert!(!response.contains_key("errmsg"));
    }

    #[tokio::test]
    async fn unauthenticated_is_master_never_reports_endpoint_name() {
        let response = run_handshake(HandshakeCase {
            report_endpoint_name: true,
            ..HandshakeCase::new(RequestType::IsMaster)
        })
        .await;

        assert_eq!(response.get_f64("ok"), Ok(OK_SUCCEEDED));
        assert!(!response.contains_key("endpointName"));
    }

    #[tokio::test]
    async fn routable_hello_preserves_default_field_order() {
        let response = run_handshake(HandshakeCase::new(RequestType::Hello)).await;

        let keys: Vec<&str> = response.keys().map(String::as_str).collect();
        assert_eq!(
            keys,
            [
                "isWritablePrimary",
                "msg",
                "maxBsonObjectSize",
                "maxMessageSizeBytes",
                "maxWriteBatchSize",
                "localTime",
                "logicalSessionTimeoutMinutes",
                "minWireVersion",
                "maxWireVersion",
                "readOnly",
                "connectionId",
                "saslSupportedMechs",
                "internal",
                "ok",
            ]
        );
    }

    #[derive(Debug)]
    struct TestAuthenticationHandler {
        enabled: Arc<AtomicBool>,
    }

    #[async_trait]
    impl AuthenticationHandler for TestAuthenticationHandler {
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

    #[tokio::test]
    async fn hello_advertises_enabled_authentication_schemes() {
        let test_dynamic_configuration = Arc::new(TestDynamicConfiguration::default());
        let concrete_dynamic_configuration = Arc::clone(&test_dynamic_configuration);
        let dynamic_configuration: Arc<dyn DynamicConfiguration> = concrete_dynamic_configuration;
        let authentication_enabled = Arc::new(AtomicBool::new(false));
        let mut authentication_manager = AuthenticationManager::new();
        authentication_manager
            .register_scheme(
                "TEST",
                Box::new(TestAuthenticationHandler {
                    enabled: Arc::clone(&authentication_enabled),
                }),
            )
            .expect("test scheme should register");
        let mut connection_context = test_connection_context_with_authentication_manager(
            false,
            Arc::clone(&dynamic_configuration),
            None,
            authentication_manager,
        )
        .await;
        let document = doc! { "hello": 1_i32, "$db": "admin" };
        let request = Request::RawBuf(RequestType::Hello, build_raw_document(&document));
        let request_info = request
            .extract_common(true, true)
            .expect("hello request should have valid common fields");
        let wire_request = WireRequest::from_request_and_info(&request, request_info);
        let request_tracker = RequestTracker::new();
        let request_context =
            RequestContext::new("activity-hello", &wire_request, &request_tracker);

        let response = process(
            &request_context,
            "isWritablePrimary",
            &mut connection_context,
            &dynamic_configuration,
        )
        .expect("hello should succeed")
        .as_json()
        .expect("hello response should be valid BSON");

        assert_eq!(
            response
                .get_array("saslSupportedMechs")
                .expect("hello should advertise authentication schemes"),
            &vec![Bson::String("SCRAM-SHA-256".to_owned())]
        );

        authentication_enabled.store(true, Ordering::Relaxed);

        let response = process(
            &request_context,
            "isWritablePrimary",
            &mut connection_context,
            &dynamic_configuration,
        )
        .expect("hello should succeed")
        .as_json()
        .expect("hello response should be valid BSON");

        assert_eq!(
            response
                .get_array("saslSupportedMechs")
                .expect("hello should advertise authentication schemes"),
            &vec![
                Bson::String("SCRAM-SHA-256".to_owned()),
                Bson::String("TEST".to_owned()),
            ]
        );
    }
}
