#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb_validate_username.sh
#
# Reject a documentdb-local username the gateway would refuse at authentication
# time, BEFORE the container starts anything, so it never reports "ready" with a
# user that can never authenticate. Mirrors the gateway's own policy: the
# case-insensitive BlockedRolePrefixes read from its SetupConfiguration.json, so
# the emulator's policy always matches the gateway's, including entries like
# documentdb / citus / pg / internal_role.
#
# Usage:
#   documentdb_validate_username.sh <username> [setup_configuration_json]
#
# The config path defaults to $GATEWAY_HOME/pg_documentdb_gw/SetupConfiguration.json.
# Exits 0 if the username is allowed, or 1 (with a diagnostic on stderr) otherwise.

username="$1"
gateway_setup_config="${2:-$GATEWAY_HOME/pg_documentdb_gw/SetupConfiguration.json}"

# Names PostgreSQL truncates or reserves, checked only when the caller creates
# or logs in as the user (USERNAME_IN_USE, default true). The packaged tools'
# other rules are skipped: this runs on every start, and existing volumes may
# use such names.
if [ "${USERNAME_IN_USE:-true}" = "true" ]; then
    username_bytes=$(LC_ALL=C; echo "${#username}")
    if [ "$username_bytes" -gt 63 ]; then
        echo "Error: username '$username' is $username_bytes bytes; PostgreSQL role names are at most 63." >&2
        exit 1
    fi
    case "$username" in
        public|none)
            echo "Error: username '$username' is reserved by PostgreSQL." >&2
            exit 1
            ;;
    esac
fi

if [ ! -f "$gateway_setup_config" ]; then
    echo "Error: gateway configuration '$gateway_setup_config' not found; cannot validate the username against reserved role prefixes." >&2
    exit 1
fi

# BlockedRolePrefixes is a required array of strings; fail closed on any other
# shape rather than silently skipping validation. An empty array is valid.
if ! blocked_prefixes_type=$(jq -r '.BlockedRolePrefixes | type' "$gateway_setup_config" 2>/dev/null); then
    echo "Error: failed to parse gateway configuration '$gateway_setup_config'; cannot validate the username against reserved role prefixes." >&2
    exit 1
fi
if [ "$blocked_prefixes_type" != "array" ]; then
    echo "Error: BlockedRolePrefixes in '$gateway_setup_config' must be a JSON array of strings." >&2
    exit 1
fi
if ! jq -e 'all(.BlockedRolePrefixes[]; type == "string")' "$gateway_setup_config" >/dev/null 2>&1; then
    echo "Error: BlockedRolePrefixes in '$gateway_setup_config' must contain only strings." >&2
    exit 1
fi

# Process substitution preserves a stray empty prefix that command substitution
# would drop with the trailing newline.
mapfile -t blocked_role_prefixes < <(jq -r '.BlockedRolePrefixes[]?' "$gateway_setup_config")
if [ "${#blocked_role_prefixes[@]}" -gt 0 ]; then
    username_lower=${username,,}
    blocked_list=$(printf '%s, ' "${blocked_role_prefixes[@]}")
    blocked_list=${blocked_list%, }
    for blocked_prefix in "${blocked_role_prefixes[@]}"; do
        prefix_lower=${blocked_prefix,,}
        if [ -z "$prefix_lower" ]; then
            # An empty prefix (gateway starts_with("")) would block every username.
            echo "Error: BlockedRolePrefixes in '$gateway_setup_config' contains an empty entry, which the gateway treats as blocking every username. Fix the gateway configuration." >&2
            exit 1
        fi
        case "$username_lower" in
            "$prefix_lower"*)
                echo "Error: username '$username' uses reserved prefix '$blocked_prefix'." >&2
                echo "Choose a username that does not begin with any of: ${blocked_list}." >&2
                exit 1
                ;;
        esac
    done
fi

exit 0
