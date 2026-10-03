/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * SPDX-License-Identifier: MIT
 *
 * documentdb_gateway_core/src/processor/list_commands.rs
 *
 *-------------------------------------------------------------------------
 */

use std::sync::LazyLock;

use bson::{rawdoc, RawDocumentBuf};

use crate::{
    configuration::DynamicConfiguration,
    protocol::OK_SUCCEEDED,
    responses::{RawResponse, Response},
};

struct CommandInfo {
    command_name: &'static str,
    admin_only: bool,
    help: &'static str,
    secondary_ok: bool,
    requires_auth: bool,
    secondary_override_ok: Option<bool>,
}

static CORE_COMMANDS : [CommandInfo; 69] = [
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

static CORE_COMMANDS_DOCUMENT: LazyLock<RawDocumentBuf> = LazyLock::new(commands_list_core);
static CREATE_ROLE_COMMAND: CommandInfo = CommandInfo {
    command_name: "createRole",
    admin_only: true,
    help: "Creates a user-defined role.",
    secondary_ok: false,
    requires_auth: true,
    secondary_override_ok: None,
};

pub fn process(dynamic_config: &dyn DynamicConfiguration) -> Response {
    Response::Raw(RawResponse::new(commands_list_dynamic(dynamic_config)))
}

fn commands_list_core() -> RawDocumentBuf {
    let mut commands_doc = RawDocumentBuf::new();
    for command in &CORE_COMMANDS {
        append_command(&mut commands_doc, command);
    }

    commands_doc
}

fn commands_list_dynamic(dynamic_config: &dyn DynamicConfiguration) -> RawDocumentBuf {
    let mut enabled_commands = Vec::new();

    if dynamic_config.enable_role_crud() {
        enabled_commands.push(&CREATE_ROLE_COMMAND);
    }

    let commands_doc = if enabled_commands.is_empty() {
        CORE_COMMANDS_DOCUMENT.clone()
    } else {
        enabled_commands.extend(&CORE_COMMANDS);
        enabled_commands.sort_unstable_by(|left, right| left.command_name.cmp(right.command_name));

        let mut commands_doc = RawDocumentBuf::new();
        for command in enabled_commands {
            append_command(&mut commands_doc, command);
        }
        commands_doc
    };

    rawdoc! {
        "commands": commands_doc,
        "ok": OK_SUCCEEDED,
    }
}

fn append_command(commands_doc: &mut RawDocumentBuf, command: &CommandInfo) {
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

#[cfg(test)]
mod tests {
    use bson::Document;

    use super::*;
    use crate::testing::TestDynamicConfiguration;

    /// Verifies that the disabled configuration returns exactly the core command
    /// set, preserving each command's order and advertised metadata.
    #[test]
    fn list_commands_returns_all_core_commands_when_role_crud_is_disabled() {
        let dynamic_config = TestDynamicConfiguration::default();
        let response = process(&dynamic_config)
            .as_json()
            .expect("listCommands response should be valid");
        let commands = response
            .get_document("commands")
            .expect("commands document");

        assert_eq!(
            response.get_f64("ok").expect("ok").to_bits(),
            OK_SUCCEEDED.to_bits()
        );
        assert_eq!(CORE_COMMANDS.len(), 69);
        assert_eq!(commands.len(), CORE_COMMANDS.len());

        for ((actual_name, actual_info), expected) in commands.iter().zip(&CORE_COMMANDS) {
            assert_eq!(actual_name, expected.command_name);
            assert_command_info(
                actual_info
                    .as_document()
                    .expect("command info should be a document"),
                expected,
            );
        }
    }

    /// Verifies that enabling role CRUD preserves the core command list and
    /// inserts `createRole` in alphabetical order with the expected metadata.
    #[test]
    fn list_commands_inserts_create_role_in_order_when_role_crud_is_enabled() {
        let dynamic_config = TestDynamicConfiguration::default();
        let disabled_response = process(&dynamic_config)
            .as_json()
            .expect("disabled listCommands response should be valid");
        dynamic_config.set_enable_role_crud(true);
        let response = process(&dynamic_config)
            .as_json()
            .expect("listCommands response should be valid");
        let commands = response
            .get_document("commands")
            .expect("commands document");
        assert_eq!(commands.len(), CORE_COMMANDS.len() + 1);

        let command_names = commands.keys().map(String::as_str).collect::<Vec<_>>();
        assert!(command_names.windows(2).all(|names| names[0] <= names[1]));

        let create_role = commands
            .get_document("createRole")
            .expect("createRole command should be a document");
        assert!(create_role.get_bool("adminOnly").expect("adminOnly"));
        assert!(create_role
            .get_array("apiVersions")
            .expect("apiVersions")
            .is_empty());
        assert!(create_role
            .get_array("deprecatedApiVersions")
            .expect("deprecatedApiVersions")
            .is_empty());
        assert_eq!(
            create_role.get_str("help").expect("help"),
            "Creates a user-defined role."
        );
        assert!(!create_role.get_bool("secondaryOk").expect("secondaryOk"));
        assert!(create_role.get_bool("requiresAuth").expect("requiresAuth"));

        let mut enabled_commands_without_create_role = commands.clone();
        enabled_commands_without_create_role.remove("createRole");
        assert_eq!(
            enabled_commands_without_create_role,
            *disabled_response
                .get_document("commands")
                .expect("disabled commands document")
        );
    }

    /// Verifies that building the enabled response does not modify the cached
    /// core document used by later disabled responses.
    #[test]
    fn list_commands_preserves_cached_core_commands_after_enabled_response() {
        let dynamic_config = TestDynamicConfiguration::default();
        dynamic_config.set_enable_role_crud(true);
        let enabled_response = process(&dynamic_config)
            .as_json()
            .expect("enabled listCommands response should be valid");
        assert!(enabled_response
            .get_document("commands")
            .expect("enabled commands document")
            .contains_key("createRole"));

        dynamic_config.set_enable_role_crud(false);
        let disabled_response = process(&dynamic_config)
            .as_json()
            .expect("disabled listCommands response should be valid");
        let disabled_commands = disabled_response
            .get_document("commands")
            .expect("disabled commands document");

        assert_eq!(disabled_commands.len(), CORE_COMMANDS.len());
        assert!(!disabled_commands.contains_key("createRole"));
    }

    fn assert_command_info(actual: &Document, expected: &CommandInfo) {
        assert_eq!(
            actual.get_bool("adminOnly").expect("adminOnly"),
            expected.admin_only
        );
        assert!(actual
            .get_array("apiVersions")
            .expect("apiVersions")
            .is_empty());
        assert!(actual
            .get_array("deprecatedApiVersions")
            .expect("deprecatedApiVersions")
            .is_empty());
        assert_eq!(actual.get_str("help").expect("help"), expected.help);
        assert_eq!(
            actual.get_bool("secondaryOk").expect("secondaryOk"),
            expected.secondary_ok
        );
        assert_eq!(
            actual.get_bool("requiresAuth").expect("requiresAuth"),
            expected.requires_auth
        );

        match expected.secondary_override_ok {
            Some(expected_value) => assert_eq!(
                actual
                    .get_bool("secondaryOverrideOk")
                    .expect("secondaryOverrideOk"),
                expected_value
            ),
            None => assert!(!actual.contains_key("secondaryOverrideOk")),
        }
    }
}
