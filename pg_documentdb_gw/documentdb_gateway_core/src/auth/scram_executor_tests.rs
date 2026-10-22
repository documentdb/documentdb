/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation. All rights reserved.
 * SPDX-License-Identifier: MIT
 *
 *-------------------------------------------------------------------------
 */

//! Exercises the actual SCRAM conversation with an isolated database executor.

use std::{
    collections::VecDeque,
    sync::{Arc, Mutex},
};

use async_trait::async_trait;
use bson::{doc, spec::BinarySubtype, Binary};
use bytes::BytesMut;
use tokio_postgres::{
    types::{Kind, ToSql, Type},
    Row,
};

use super::{
    handle_authentication,
    query::AuthenticationQueryExecutor,
    scram::{ScramAuthenticationHandler, SCRAM_SHA256_SCHEME},
    AuthenticationManager,
};
use crate::{
    context::{ConnectionContext, RequestContext},
    error::{DocumentDBError, ErrorCode, Result},
    requests::{request_tracker::RequestTracker, Request, RequestType, WireRequest},
    testing::{
        build_raw_document, test_connection_context_with_authentication_manager, test_postgres_row,
        TestDynamicConfiguration,
    },
};

#[derive(Debug)]
struct Database {
    responses: Mutex<VecDeque<Result<Vec<Row>>>>,
    arguments: Mutex<Vec<Vec<Vec<u8>>>>,
}

#[async_trait]
impl AuthenticationQueryExecutor for Database {
    async fn query(
        &self,
        _connection: &ConnectionContext,
        _request: &RequestContext<'_>,
        _sql: &str,
        parameter_types: &[Type],
        parameters: &[&(dyn ToSql + Sync)],
    ) -> Result<Vec<Row>> {
        let arguments = parameters
            .iter()
            .zip(parameter_types)
            .map(|(parameter, ty)| {
                let mut bytes = BytesMut::new();
                parameter.to_sql_checked(ty, &mut bytes).unwrap();
                bytes.to_vec()
            })
            .collect();
        self.arguments.lock().unwrap().push(arguments);
        self.responses
            .lock()
            .unwrap()
            .pop_front()
            .expect("unexpected query")
    }
}

async fn invoke(
    connection: &mut ConnectionContext,
    request_type: RequestType,
    payload: String,
) -> Result<bson::Document> {
    let command = doc! {
        request_type.to_command_str(): 1,
        "mechanism": SCRAM_SHA256_SCHEME,
        "payload": Binary { subtype: BinarySubtype::Generic, bytes: payload.into_bytes() },
        "$db": "admin",
    };
    let request = Request::RawBuf(request_type, build_raw_document(&command));
    let info = request.extract_common(true).unwrap();
    let wire = WireRequest::from_request_and_info(&request, info);
    let tracker = RequestTracker::new();
    let context = RequestContext::new("auth-test", &wire, &tracker);
    let response = handle_authentication(connection, &context).await?.unwrap();
    bson::from_slice(response.as_raw_document()?.as_bytes())
        .map_err(|error| DocumentDBError::internal_error(error.to_string()))
}

#[tokio::test]
async fn injected_executor_preserves_scram_conversation_and_principal() {
    let bson_type = Type::new("bson".to_owned(), 9999, Kind::Simple, "public".to_owned());
    let salt = test_postgres_row(
        bson_type.clone(),
        bson::to_vec(&doc! {
            "ok": 1, "salt": "salt", "iterations": 4096,
        })
        .unwrap(),
    )
    .await;
    let proof = test_postgres_row(
        bson_type,
        bson::to_vec(&doc! {
            "ok": 1, "ServerSignature": "signature",
        })
        .unwrap(),
    )
    .await;
    let oid = test_postgres_row(Type::OID, 42_u32.to_be_bytes().to_vec()).await;
    let database = Arc::new(Database {
        responses: Mutex::new(VecDeque::from([
            Ok(vec![salt]),
            Ok(vec![proof]),
            Ok(vec![oid]),
        ])),
        arguments: Mutex::new(Vec::new()),
    });
    let mut manager = AuthenticationManager::default();
    manager
        .register_scheme(
            SCRAM_SHA256_SCHEME,
            Box::new(ScramAuthenticationHandler::with_executor(
                Arc::<Database>::clone(&database),
            )),
        )
        .unwrap();
    let mut connection = test_connection_context_with_authentication_manager(
        false,
        Arc::new(TestDynamicConfiguration::default()),
        None,
        manager,
    )
    .await;
    let first = invoke(
        &mut connection,
        RequestType::SaslStart,
        "n,,n=user,r=client".to_owned(),
    )
    .await
    .unwrap();
    assert!(!first.get_bool("done").unwrap());
    let challenge = std::str::from_utf8(first.get_binary_generic("payload").unwrap()).unwrap();
    let nonce = challenge
        .split(',')
        .next()
        .unwrap()
        .strip_prefix("r=")
        .unwrap();
    let final_response = invoke(
        &mut connection,
        RequestType::SaslContinue,
        format!("c=biws,r={nonce},p=proof"),
    )
    .await
    .unwrap();
    assert!(final_response.get_bool("done").unwrap());
    assert_eq!(
        final_response.get_binary_generic("payload").unwrap(),
        b"v=signature"
    );
    assert_eq!(connection.user().principal().unwrap().oid(), 42);
    assert!(connection.user().is_authenticated());
    let calls = database.arguments.lock().unwrap();
    assert_eq!(calls.len(), 3);
    assert_eq!(calls[0][0], b"user");
    assert_eq!(calls[1][0], b"user");
    assert_eq!(
        calls[1][1],
        format!("n=user,r=client,{challenge},c=biws,r={nonce}").as_bytes()
    );
    assert_eq!(calls[1][2], b"proof");
    assert_eq!(calls[2][0], b"user");
    drop(calls);
}

#[tokio::test]
async fn final_database_failure_clears_the_real_conversation() {
    let bson_type = Type::new("bson".to_owned(), 9999, Kind::Simple, "public".to_owned());
    let salt = test_postgres_row(
        bson_type,
        bson::to_vec(&doc! {
            "ok": 1, "salt": "salt", "iterations": 4096,
        })
        .unwrap(),
    )
    .await;
    let database = Arc::new(Database {
        responses: Mutex::new(VecDeque::from([
            Ok(vec![salt]),
            Err(DocumentDBError::authentication_failed(
                "proof rejected".to_owned(),
            )),
        ])),
        arguments: Mutex::new(Vec::new()),
    });
    let mut manager = AuthenticationManager::default();
    manager
        .register_scheme(
            SCRAM_SHA256_SCHEME,
            Box::new(ScramAuthenticationHandler::with_executor(
                Arc::<Database>::clone(&database),
            )),
        )
        .unwrap();
    let mut connection = test_connection_context_with_authentication_manager(
        false,
        Arc::new(TestDynamicConfiguration::default()),
        None,
        manager,
    )
    .await;
    let first = invoke(
        &mut connection,
        RequestType::SaslStart,
        "n,,n=user,r=client".to_owned(),
    )
    .await
    .unwrap();
    let challenge = std::str::from_utf8(first.get_binary_generic("payload").unwrap()).unwrap();
    let nonce = challenge
        .split(',')
        .next()
        .unwrap()
        .strip_prefix("r=")
        .unwrap();
    let error = invoke(
        &mut connection,
        RequestType::SaslContinue,
        format!("c=biws,r={nonce},p=bad"),
    )
    .await
    .unwrap_err();
    assert_eq!(error.error_code(), ErrorCode::AuthenticationFailed);
    assert!(!connection.user().is_authenticated());
    assert!(connection.user().metadata(SCRAM_SHA256_SCHEME).is_none());
    assert_eq!(database.arguments.lock().unwrap().len(), 2);
}
