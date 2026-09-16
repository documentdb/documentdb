# shellcheck shell=bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb_local_settings.sh: every operator setting of the documentdb-local
# image, declared once. Sourced, not executed.
#
# emulator_entrypoint.sh parses, defaults and validates from this table.
# healthcheck.sh, init_documentdb_data.sh and documentdb_prepare_data_directory.sh
# read their defaults from it. The Dockerfile's ENV block mirrors the defaults
# so `docker inspect` and `docker run -e` see them; ImageDefaultPinTests holds
# that mirror equal to this file.
#
# Row: FLAG|ENV_VAR|DEFAULT|TYPE|LABEL
#   FLAG     command-line spelling; every flag takes one value
#   DEFAULT  applied when the variable is unset or empty; "" means none
#   TYPE     uint | bool (true/false) | enum:a,b,c | string
#   LABEL    how error messages name the setting
#
# Two defaults are applied by the entrypoint itself, not by the generic pass:
# OWNER (computed as the current user) and DOCUMENTDB_TOAST_COMPRESSION (the
# entrypoint must still tell an explicit request from the built-in default).
DOCUMENTDB_LOCAL_SETTINGS=(
    "--documentdb-port|DOCUMENTDB_PORT|10260|uint|port"
    "--pg-port|POSTGRESQL_PORT|9712|uint|PostgreSQL port"
    "--username|USERNAME|default_user|string|username"
    "--password|PASSWORD|Admin100|string|password"
    "--owner|OWNER||string|owner"
    "--data-path|DATA_PATH|/data|string|data path"
    "--init-data-path|INIT_DATA_PATH|/init_doc_db.d|string|init-data-path"
    "--init-data|INIT_DATA||bool|init-data"
    "--create-user|CREATE_USER|true|bool|create-user"
    "--start-pg|START_POSTGRESQL|true|bool|start-pg"
    "--allow-external-connections|ALLOW_EXTERNAL_CONNECTIONS|false|bool|allow-external-connections"
    "--enable-telemetry|ENABLE_TELEMETRY|false|bool|enable-telemetry"
    "--log-level|LOG_LEVEL|info|enum:quiet,error,warn,info,debug,trace|log level"
    "--tlsMode|TLS_MODE|allowTLS|enum:disabled,allowTLS,requireTLS|tlsMode"
    "--cert-path|CERT_PATH||string|cert-path"
    "--key-file|KEY_FILE||string|key-file"
    "--toast-compression|DOCUMENTDB_TOAST_COMPRESSION|lz4|enum:lz4,pglz,default|TOAST compression"
)

# documentdb_local_setting_row <ENV_VAR>: print the row for a variable.
documentdb_local_setting_row() {
    local row
    for row in "${DOCUMENTDB_LOCAL_SETTINGS[@]}"; do
        case "$row" in
            *"|$1|"*) printf '%s' "$row"; return 0 ;;
        esac
    done
    return 1
}

# documentdb_local_setting_row_by_flag <--flag>: print the row for a flag.
documentdb_local_setting_row_by_flag() {
    local row
    for row in "${DOCUMENTDB_LOCAL_SETTINGS[@]}"; do
        case "$row" in
            "$1|"*) printf '%s' "$row"; return 0 ;;
        esac
    done
    return 1
}

# documentdb_local_setting_default <ENV_VAR>: print the declared default.
documentdb_local_setting_default() {
    local row rest
    row="$(documentdb_local_setting_row "$1")" || return 1
    rest="${row#*|}"; rest="${rest#*|}"
    printf '%s' "${rest%%|*}"
}

# documentdb_local_setting_allowed <ENV_VAR>: print the enum values as
# "a, b, c", or nothing for other types.
documentdb_local_setting_allowed() {
    local row type
    row="$(documentdb_local_setting_row "$1")" || return 1
    type="${row#*|}"; type="${type#*|}"; type="${type#*|}"; type="${type%%|*}"
    case "$type" in
        enum:*) printf '%s' "${type#enum:}" | sed 's/,/, /g' ;;
    esac
}
