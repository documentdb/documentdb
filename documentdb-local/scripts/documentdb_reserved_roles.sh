#!/usr/bin/env bash
# Internal DocumentDB roles reserved by the pg_documentdb extension. A
# documentdb-local username may not exactly match any of these, mirroring the
# gateway's createUser/createRole rejection.
#
# Source of truth: the gateway's RESERVED_ROLE_NAMES registry
# (pg_documentdb_gw/documentdb_tests/src/utils/rbac_utils.rs) and the
# documentdb_*_role names created by the pg_documentdb extension. Keep this list
# in sync with those (the internal-only "azure_ai_settings_manager" role is not
# part of the OSS gateway and is intentionally excluded).
#
# This file is meant to be sourced, not executed.
DOCUMENTDB_RESERVED_ROLE_NAMES=(
    "documentdb_admin_role"
    "documentdb_api_find_role"
    "documentdb_api_insert_role"
    "documentdb_api_remove_role"
    "documentdb_api_update_role"
    "documentdb_bg_worker_role"
    "documentdb_cluster_admin_role"
    "documentdb_readonly_role"
    "documentdb_readwrite_role"
    "documentdb_root_role"
    "documentdb_user_admin_role"
)
