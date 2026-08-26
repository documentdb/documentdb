#!/bin/bash
#
# documentdb_validate_username.sh
#
# Reject a documentdb-local username the gateway would refuse at authentication
# time, BEFORE the container starts anything, so it never reports "ready" with a
# user that can never authenticate. Mirrors two independent gateway mechanisms:
#
#   1. exact internal DocumentDB role names -- sourced from
#      documentdb_reserved_roles.sh (kept in sync with the gateway's
#      RESERVED_ROLE_NAMES registry); and
#   2. the case-insensitive BlockedRolePrefixes read from the gateway's own
#      SetupConfiguration.json (so the emulator's policy always matches the
#      gateway's, including entries like documentdb / citus / pg / internal_role).
#
# Usage:
#   documentdb_validate_username.sh <username> [setup_configuration_json]
#
# The config path defaults to $GATEWAY_HOME/pg_documentdb_gw/SetupConfiguration.json.
# Exits 0 if the username is allowed, or 1 (with a diagnostic on stderr) otherwise.

username="$1"
gateway_setup_config="${2:-$GATEWAY_HOME/pg_documentdb_gw/SetupConfiguration.json}"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

# Exact internal DocumentDB roles are reserved independently of the prefix list.
reserved_roles_file="$script_dir/documentdb_reserved_roles.sh"
if [ ! -f "$reserved_roles_file" ]; then
    echo "Error: reserved-roles definition '$reserved_roles_file' not found; cannot validate the username." >&2
    exit 1
fi
source "$reserved_roles_file"
for reserved_role_name in "${DOCUMENTDB_RESERVED_ROLE_NAMES[@]}"; do
    if [ "$username" = "$reserved_role_name" ]; then
        echo "Error: username '$username' is reserved for an internal DocumentDB role." >&2
        exit 1
    fi
done

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
