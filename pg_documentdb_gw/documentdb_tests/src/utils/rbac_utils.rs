/*-------------------------------------------------------------------------
 * Copyright (c) Microsoft Corporation.  All rights reserved.
 *
 * documentdb_tests/src/utils/rbac_utils.rs
 *
 *-------------------------------------------------------------------------
 */

/// Used in role and user CRUD tests to verify these names are rejected.
pub const RESERVED_ROLE_NAMES: &[&str] = &[
    "documentdb_admin_role",
    "documentdb_api_find_role",
    "documentdb_api_insert_role",
    "documentdb_api_remove_role",
    "documentdb_api_update_role",
    "documentdb_bg_worker_role",
    "documentdb_cluster_admin_role",
    "documentdb_readonly_role",
    "documentdb_readwrite_role",
    "documentdb_root_role",
    "documentdb_user_admin_role",
];

/// Used in role CRUD tests to verify these names cannot be used for custom roles.
pub const NATIVE_BUILTIN_ROLE_NAMES: &[&str] = &[
    "__system",
    "autoCompact",
    "backup",
    "backupAndRestore",
    "clusterAdmin",
    "clusterManager",
    "clusterMonitor",
    "dbAdmin",
    "dbAdminAnyDatabase",
    "dbOwner",
    "directShardOperations",
    "enableSharding",
    "killOpSession",
    "manageShardBalancer",
    "MongodbAutomationAgentUserRole",
    "read",
    "readAnyDatabase",
    "readWrite",
    "readWriteAnyDatabase",
    "restore",
    "root",
    "searchCoordinator",
    "userAdmin",
    "userAdminAnyDatabase",
];
