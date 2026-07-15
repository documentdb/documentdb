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

use bson::{rawdoc, RawArrayBuf, RawBson, RawDocumentBuf};

use crate::{
    bson::convert_to_bool,
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

/// Command-envelope fields that drivers/mongosh attach to every request. These
/// are not `getParameter` parameter names and must be ignored when collecting
/// the requested parameters.
fn is_generic_command_field(key: &str) -> bool {
    key.starts_with('$')
        || matches!(
            key,
            "lsid"
                | "comment"
                | "maxTimeMS"
                | "apiVersion"
                | "apiStrict"
                | "apiDeprecationErrors"
                | "readConcern"
                | "writeConcern"
                | "txnNumber"
                | "autocommit"
                | "startTransaction"
                | "stmtId"
                | "clusterTime"
                | "signature"
        )
}

/// Returns the value and mutability metadata for a parameter the gateway
/// exposes via `getParameter`, or `None` if the parameter is not supported.
///
/// The returned tuple is `(value, settableAtRuntime, settableAtStartup)`.
fn known_parameter(
    name: &str,
    dynamic_config: &Arc<dyn DynamicConfiguration>,
) -> Option<(RawBson, bool, bool)> {
    match name {
        "featureCompatibilityVersion" => {
            let version = dynamic_config.server_version();
            let fcv = version.feature_compatibility_version();
            Some((
                RawBson::Document(rawdoc! { "version": fcv }),
                false,
                false,
            ))
        }
        _ => None,
    }
}

/// Every parameter name the gateway can report, used for the `*` /
/// `allParameters` forms.
const KNOWN_PARAMETER_NAMES: &[&str] = &["featureCompatibilityVersion"];

fn append_parameter(
    result: &mut RawDocumentBuf,
    name: &str,
    value: RawBson,
    settable_at_runtime: bool,
    settable_at_startup: bool,
    show_details: bool,
) {
    if show_details {
        result.append(
            name,
            rawdoc! {
                "value": value,
                "settableAtRuntime": settable_at_runtime,
                "settableAtStartup": settable_at_startup,
            },
        );
    } else {
        result.append(name, value);
    }
}

/// Handles the `getParameter` command natively in the gateway, without a
/// database round-trip. Only the `admin` database may run it.
pub fn process_get_parameter(
    request_context: &RequestContext<'_>,
    dynamic_config: &Arc<dyn DynamicConfiguration>,
) -> Result<Response> {
    let request = request_context.request();

    let mut all_parameters = false;
    let mut show_details = false;
    let mut star = false;
    let mut requested = Vec::new();

    request.extract_fields(|k, v| {
        match k {
            "getParameter" => {
                if v.as_str().is_some_and(|s| s == "*") {
                    star = true;
                } else if let Some(doc) = v.as_document() {
                    for pair in doc {
                        let (dk, dv) = pair?;
                        match dk {
                            "allParameters" => {
                                all_parameters =
                                    convert_to_bool(dv).ok_or_else(|| {
                                        DocumentDBError::type_mismatch(
                                            "allParameters should be a bool".to_owned(),
                                        )
                                    })?;
                            }
                            "showDetails" => {
                                show_details =
                                    convert_to_bool(dv).ok_or_else(|| {
                                        DocumentDBError::type_mismatch(
                                            "showDetails should be convertible to a bool"
                                                .to_owned(),
                                        )
                                    })?;
                            }
                            _ => {}
                        }
                    }
                }
            }
            "allParameters" => {
                all_parameters = convert_to_bool(v).ok_or_else(|| {
                    DocumentDBError::type_mismatch("allParameters should be a bool".to_owned())
                })?;
            }
            "showDetails" => {
                show_details = convert_to_bool(v).ok_or_else(|| {
                    DocumentDBError::type_mismatch(
                        "showDetails should be convertible to a bool".to_owned(),
                    )
                })?;
            }
            other if is_generic_command_field(other) => {}
            other => requested.push(other.to_owned()),
        }
        Ok(())
    })?;

    if request.db() != "admin" {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::Unauthorized,
            "getParameter may only be run against the admin database.".to_owned(),
        ));
    }

    let mut result = RawDocumentBuf::new();

    if star || all_parameters {
        for name in KNOWN_PARAMETER_NAMES {
            if let Some((value, runtime, startup)) = known_parameter(name, dynamic_config) {
                append_parameter(&mut result, name, value, runtime, startup, show_details);
            }
        }
    } else if requested.is_empty() {
        return Err(DocumentDBError::documentdb_error(
            ErrorCode::FailedToParse,
            "no parameters specified".to_owned(),
        ));
    } else {
        for name in &requested {
            match known_parameter(name, dynamic_config) {
                Some((value, runtime, startup)) => {
                    append_parameter(&mut result, name, value, runtime, startup, show_details);
                }
                None => {
                    return Err(DocumentDBError::documentdb_error(
                        ErrorCode::InvalidOptions,
                        format!("no option found to get: {name}"),
                    ));
                }
            }
        }
    }

    result.append("ok", OK_SUCCEEDED);
    Ok(Response::Raw(RawResponse::new(result)))
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

struct CommandInfo {
    command_name: &'static str,
    admin_only: bool,
    help: &'static str,
    secondary_ok: bool,
    requires_auth: bool,
    secondary_override_ok: Option<bool>,
}

static SUPPORTED_COMMANDS : [CommandInfo; 69] = [
	CommandInfo {
		command_name: "abortTransaction",
		admin_only: true,
		help: "Takes a transaction that's active and aborts it.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "aggregate",
		admin_only: false,
		help: "Performs aggregation on the data, such as filtering, grouping, and sorting, and returns computed results. For more details, refer to https://aka.ms/AAxl8do.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: Some(false),
	},
	CommandInfo {
		command_name: "authenticate",
		admin_only: false,
		help: "Authenticates the underlying connection using user-supplied credentials.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "balancerStart",
		admin_only: true,
		help: "Enables the sharded cluster balancer, allowing automatic migration of chunks between shards.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "balancerStatus",
		admin_only: true,
		help: "Returns the current status of the sharded cluster balancer.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "balancerStop",
		admin_only: true,
		help: "Disables the sharded cluster balancer, preventing automatic chunk migrations.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "buildInfo",
		admin_only: false,
		help: "Returns the version information for the cluster.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "collMod",
		admin_only: false,
		help: "Configure options for a collection.\ne.g. { collMod: 'name', index: {keyPattern: {key: 1}, expireAfterSeconds: 10}, dryRun: false }\n     { collMod: 'name', index: {name: 'indexName', expireAfterSeconds: 120} }\n",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "collStats",
		admin_only: false,
		help: "Get statistics about a collection, returns the average size in bytes.\ne.g. { collStats : \"shelter.dogs\" , scale : 1048576 } (returns result in Mb)",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "commitTransaction",
		admin_only: true,
		help: "Finish a running transaction.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "connectionStatus",
		admin_only: false,
		help: "Get information about a connection like the roles of logged in users.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "count",
		admin_only: false,
		help: "Get the number of documents in a collection. For more details, refer to https://aka.ms/AAxl0ve.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: Some(false),
	},
	CommandInfo {
		command_name: "create",
		admin_only: false,
		help: "Create a new collection (or view).",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "createIndex",
		admin_only: false,
		help: "Create an index on a collection.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "createIndexes",
		admin_only: false,
		help: "Create multiple indexes on a collection.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "currentOp",
		admin_only: true,
		help: "Get information about currently running operations.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "dbStats",
		admin_only: false,
		help: "Get statistics about a database, returns the average size in bytes.\ne.g. { dbStats : 1 , scale : 1048576 } (returns result in Mb).",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "delete",
		admin_only: false,
		help: "Remove documents from a collection. For more details, refer to https://aka.ms/AAxl8en.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "distinct",
		admin_only: false,
		help: "Get the unique values for a field in a collection. For more details, refer to https://aka.ms/AAxl0vh.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: Some(false),
	},
	CommandInfo {
		command_name: "drop",
		admin_only: false,
		help: "Remove a collection.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "dropDatabase",
		admin_only: false,
		help: "Remove an entire database.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "dropIndexes",
		admin_only: false,
		help: "Remove the indexes from a collection.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "enableSharding",
		admin_only: true,
		help: "Marks the database as shard-enabled, allowing sharded collections to be created.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "endSessions",
		admin_only: false,
		help: "Stop multiple sessions and their operations.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "explain",
		admin_only: false,
		help: "Get information about an operation.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: Some(false),
	},
	CommandInfo {
		command_name: "find",
		admin_only: false,
		help: "Search for documents in a collection. For more details, refer to https://aka.ms/AAxlf5o.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: Some(false),
	},
	CommandInfo {
		command_name: "findAndModify",
		admin_only: false,
		help: "Update the fields of a single document that matches a query. For more details, refer to https://aka.ms/AAxl0vr.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "getCmdLineOpts",
		admin_only: true,
		help: "Get the command line options used to start the server.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "getDefaultRWConcern",
		admin_only: true,
		help: "Get the Read/Write concern for the cluster.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "getLastError",
		admin_only: false,
		help: "Get the error information for the most recent operation run.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "getLog",
		admin_only: true,
		help: "Get recent log entries.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "getMore",
		admin_only: false,
		help: "Get the next page of documents from a cursor. For more details, refer to https://aka.ms/AAxl8es.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "getParameter",
		admin_only: true,
		help: "Get the value of a particular parameter.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "getShardMap",
		admin_only: true,
		help: "Returns internal metadata describing shard ownership and data distribution.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "getnonce",
		admin_only: false,
		help: "unused",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "hello",
		admin_only: false,
		help: "Gets information about the cluster topology.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "hostInfo",
		admin_only: false,
		help: "Get details about the host machine.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "insert",
		admin_only: false,
		help: "The insert command can be used to add one or more documents to a collection. For more details, refer to https://aka.ms/AAxkukq.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "isMaster",
		admin_only: false,
		help: "Gets information about the cluster topology.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "isdbgrid",
		admin_only: false,
		help: "Check if the instance is sharded.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "killAllSessions",
		admin_only: false,
		help: "kill all logical sessions",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "killAllSessionsByPattern",
		admin_only: false,
		help: "kill logical sessions by pattern",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "killCursors",
		admin_only: false,
		help: "Stop a set of cursors.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "killOp",
		admin_only: true,
		help: "Stop a running operation.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "killSessions",
		admin_only: false,
		help: "Stop a session along with its operations.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "listCollections",
		admin_only: false,
		help: "Show all collections in a particular database.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: Some(false),
	},
	CommandInfo {
		command_name: "listCommands",
		admin_only: false,
		help: "Show all possible commands.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "listDatabases",
		admin_only: true,
		help: "Show all databases on the cluster.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: Some(false),
	},
	CommandInfo {
		command_name: "listIndexes",
		admin_only: false,
		help: "Show all indexes on a particular collection.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: Some(false),
	},
	CommandInfo {
		command_name: "listShards",
		admin_only: true,
		help: "Lists all shards in the cluster and their associated connection endpoints.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "logout",
		admin_only: false,
		help: "Log out of the current session.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "ping",
		admin_only: false,
		help: "Check if the server is able to respond to network requests.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "planCacheClear",
		admin_only: false,
		help: "clear the plan cache",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "planCacheClearFilters",
		admin_only: false,
		help: "clear plan cache index filters",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "planCacheListFilters",
		admin_only: false,
		help: "list plan cache index filters",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "planCacheSetFilter",
		admin_only: false,
		help: "set a plan cache index filter",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "reIndex",
		admin_only: false,
		help: "Rebuild an index.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "refreshSessions",
		admin_only: false,
		help: "refresh logical session records",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "renameCollection",
		admin_only: true,
		help: "Change the name of a collection.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "reshardCollection",
		admin_only: true,
		help: "Change a sharded collection's shard key.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "saslContinue",
		admin_only: false,
		help: "Perform the next steps of a SASL authentication.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "saslStart",
		admin_only: false,
		help: "Initiate a SASL authentication.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "serverStatus",
		admin_only: false,
		help: "Get administrative details about the server.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "shardCollection",
		admin_only: true,
		help: "Make a collection sharded using a given key.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "startSession",
		admin_only: false,
		help: "Initiate a logical session for isolating operations.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "unshardCollection",
		admin_only: true,
		help: "Remove sharding from a collection.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "update",
		admin_only: false,
		help: "The update command can be used to update one or multiple documents based on filtering criteria. Values of fields can be changed, new fields and values can be added and existing fields can be removed. For more details, refer to https://aka.ms/AAxjzfd.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "validate",
		admin_only: false,
		help: "Check for correctness on a particular collection.",
		secondary_ok: false,
		requires_auth: true,
		secondary_override_ok: None,
	},
	CommandInfo {
		command_name: "whatsmyuri",
		admin_only: false,
		help: "Get the URI of the current connection.",
		secondary_ok: false,
		requires_auth: false,
		secondary_override_ok: None,
	}
];

pub fn list_commands() -> Response {
    let mut commands_doc = RawDocumentBuf::new();
    for command in &SUPPORTED_COMMANDS {
        let mut doc = rawdoc! {
            "adminOnly": command.admin_only,
            "apiVersions": [],
            "deprecatedApiVersions": [],
            "help": command.help,
            "secondaryOk": command.secondary_ok,
            "requiresAuth": command.requires_auth,
        };
        if let Some(secondary_override) = command.secondary_override_ok {
            doc.append("secondaryOverrideOk", secondary_override);
        }
        commands_doc.append(command.command_name, doc);
    }

    Response::Raw(RawResponse::new(rawdoc! {
        "commands": commands_doc,
        "ok": OK_SUCCEEDED,
    }))
}
