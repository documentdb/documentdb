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

use bson::{rawdoc, RawArrayBuf};

use crate::{
    configuration::DynamicConfiguration,
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    protocol::{MAX_BSON_OBJECT_SIZE, MAX_MESSAGE_SIZE_BYTES, OK_SUCCEEDED},
    responses::{RawResponse, Response},
};

#[expect(clippy::cast_possible_truncation, reason = "timestamp fits in u32")]
#[expect(clippy::cast_sign_loss, reason = "timestamp is always positive")]
pub fn process(
    request_context: &RequestContext<'_>,
    writeable_primary_field: &str,
    connection_context: &mut ConnectionContext,
    dynamic_configuration: &Arc<dyn DynamicConfiguration>,
) -> Result<Response> {
    let request = request_context.request();
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

    let mut response_doc = rawdoc! {
        writeable_primary_field: true,
        "msg": "isdbgrid",
        "maxBsonObjectSize": MAX_BSON_OBJECT_SIZE,
        "maxMessageSizeBytes": MAX_MESSAGE_SIZE_BYTES,
        "maxWriteBatchSize": dynamic_configuration.max_write_batch_size(),
        "localTime": local_time,
        "logicalSessionTimeoutMinutes": 30,
        "minWireVersion": 0,
        "maxWireVersion": dynamic_configuration.server_version().max_wire_protocol(),
        "readOnly": dynamic_configuration.read_only(),
        "connectionId": connection_context.get_connection_id_hash(),
        "saslSupportedMechs": supported_mechanisms,
        "internal": dynamic_configuration.topology(),
        "ok": OK_SUCCEEDED,
    };

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
        auth::{AuthenticationHandler, AuthenticationManager, AuthenticationResult},
        requests::{request_tracker::RequestTracker, Request, RequestType, WireRequest},
        testing::{
            build_raw_document, test_connection_context_with_authentication_manager,
            TestDynamicConfiguration,
        },
    };

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
            .extract_common()
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
