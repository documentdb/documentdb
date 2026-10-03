/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_gateway_core/src/processor/constant.rs
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
    protocol::{self, OK_SUCCEEDED},
    responses::{RawResponse, Response},
};

pub fn ok_response() -> Response {
    Response::Raw(RawResponse::new(rawdoc! {
        "ok": OK_SUCCEEDED
    }))
}

pub fn plan_cache_list_filters_response() -> Response {
    let mut doc = RawDocumentBuf::new();
    doc.append("filters", RawArrayBuf::new());
    doc.append("ok", OK_SUCCEEDED);
    Response::Raw(RawResponse::new(doc))
}

pub fn process_build_info(dynamic_config: &Arc<dyn DynamicConfiguration>) -> Response {
    let version = dynamic_config.server_version();
    Response::Raw(RawResponse::new(rawdoc! {
        "version": version.as_str(),
        "versionArray": version.as_bson_array(),
        "bits": 64,
        "maxBsonObjectSize": protocol::MAX_BSON_OBJECT_SIZE,
        "ok":OK_SUCCEEDED,
    }))
}

pub fn process_get_cmd_line_opts() -> Response {
    Response::Raw(RawResponse::new(rawdoc! {
        "argv": [],
        "ok":OK_SUCCEEDED,
    }))
}

pub fn process_is_db_grid(context: &ConnectionContext) -> Response {
    Response::Raw(RawResponse::new(rawdoc! {
        "isdbgrid":1.0,
        "hostname":context.service_context.setup_configuration().node_host_name(),
        "ok":OK_SUCCEEDED,
    }))
}

pub fn process_get_rw_concern(request_context: &RequestContext<'_>) -> Result<Response> {
    let request = request_context.request();

    request.extract_fields(|k, _| match k {
        "getDefaultRWConcern" | "inMemory" | "comment" | "lsid" | "$db" => Ok(()),
        other => Err(DocumentDBError::documentdb_error(
            ErrorCode::UnknownBsonField,
            format!("Not a valid value for getDefaultRWConcern: {other}"),
        )),
    })?;

    if request.db() != "admin" {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::Unauthorized,
            "Only the admin database can process getDefaultRWConcern.".to_owned(),
        ));
    }

    Ok(Response::Raw(RawResponse::new(rawdoc! {
        "defaultReadConcern": {
            "level":"majority",
        },
        "defaultWriteConcern": {
            "w": "majority",
            "wtimeout": 0,
        },
        "defaultReadConcernSource": "implicit",
        "defaultWriteConcernSource": "implicit",
        "ok":OK_SUCCEEDED,
    })))
}

pub fn process_get_log() -> Response {
    Response::Raw(RawResponse::new(rawdoc! {
        "log":[],
        "totalLinesWritten":0,
        "ok":OK_SUCCEEDED,
    }))
}

pub fn process_connection_status() -> Response {
    Response::Raw(RawResponse::new(rawdoc! {
        "authInfo": {
            "authenticatedUsers": [],
            "authenticatedUserRoles": [],
            "authenticatedUserPrivileges": [],
        },
        "ok":OK_SUCCEEDED,
    }))
}

fn local_time() -> Result<u32> {
    u32::try_from(
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(|error| {
                tracing::error!("Failed to get the current time: {error}");
                DocumentDBError::internal_error("Failed to get the current time".to_owned())
            })?
            .as_secs(),
    )
    .map_err(|error| {
        tracing::error!("Current time exceeded an u32: {error}");
        DocumentDBError::internal_error("Current time exceeded an u32".to_owned())
    })
}

pub fn process_host_info() -> Result<Response> {
    Ok(Response::Raw(RawResponse::new(rawdoc! {
        "system": {
            "currentTime": bson::Timestamp{ time: local_time()?, increment: 0},
            "memSizeMB": 0,
        },
        "os": {
            "name":"",
            "type":"",
        },
        "extra": {
            "cpuFrequencyMHz": 0,
        },
        "ok": OK_SUCCEEDED,
    })))
}

pub fn process_prepare_transaction() -> Result<Response> {
    Ok(Response::Raw(RawResponse::new(rawdoc! {
        "prepareTimestamp":  bson::Timestamp{ time: local_time()?, increment: 0 },
        "ok": OK_SUCCEEDED,
    })))
}

pub fn process_whats_my_uri() -> Response {
    Response::Raw(RawResponse::new(rawdoc! {
        "ok": OK_SUCCEEDED,
    }))
}
