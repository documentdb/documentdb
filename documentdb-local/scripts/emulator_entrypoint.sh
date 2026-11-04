#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# emulator_entrypoint.sh
#
# PID 1 of the documentdb-local image. The boot sequence is at the bottom;
# the steps live in lib/:
#   cli.sh       command line, setting defaults and validation
#   runtime.sh   layout, log streaming, health-check state file
#   toast.sh     default_toast_compression for the bundled PostgreSQL
#   postgres.sh  prepare, start and configure the bundled PostgreSQL
#   gateway.sh   gateway configuration file and host config
#   serve.sh     admin user, gateway launch, seed data, supervision
# This file keeps the shutdown handling, and the data-directory claim, whose
# helper re-executes this file by path and locks fd 200 in this shell.

entrypoint_dir="$(dirname "${BASH_SOURCE[0]}")"

configFile=""
hostConfigFile=""

# Every operator setting (flag, env var, default, type) is declared once in
# the sibling settings table; this script parses, defaults and validates from it.
# shellcheck source=documentdb_local_settings.sh
. "$entrypoint_dir/documentdb_local_settings.sh" || {
    echo "Error: cannot load documentdb_local_settings.sh beside this script." >&2
    exit 1
}
. "$entrypoint_dir/documentdb_claim_data_directory.sh" || {
    echo "Error: cannot load documentdb_claim_data_directory.sh beside this script." >&2
    exit 1
}

# Set up front: cleanup() can run at any exit, under utils.sh's `set -u`.
PG_LOG_TAIL_PID=""
SYSTEM_PG_LOG_TAIL_PID=""
OSS_LOG_TAIL_PID=""
GATEWAY_LOG_TAIL_PID=""
USAGE_TELEMETRY_PID=""
# Set just before this boot starts PostgreSQL, so a postmaster.pid this boot
# did not create is never stopped.
POSTGRES_STARTED=false

# Fast-stop the PostgreSQL this boot started. It is daemonized via pg_ctl, so
# the container's SIGTERM never reaches the postmaster; without this every exit
# is an unclean shutdown that forces WAL recovery on the next boot.
stop_owned_postgresql() {
    [ "$POSTGRES_STARTED" = "true" ] || return 0
    [ -f "${DATA_PATH}/postmaster.pid" ] || return 0
    local pgctl_bin
    pgctl_bin="$(command -v pg_ctl 2>/dev/null || true)"
    if [ -n "$pgctl_bin" ]; then
        echo "Stopping PostgreSQL (fast) at ${DATA_PATH}..."
        "$pgctl_bin" stop -D "${DATA_PATH}" -m fast 2>/dev/null || true
    else
        echo "Warning: pg_ctl not found; cannot cleanly stop PostgreSQL at ${DATA_PATH}." >&2
    fi
}

# The only shutdown path. Signals, `exit N`, errexit and the gateway's own exit
# all end here, and the script then exits with the status it was leaving with.
cleanup() {
    # A signal now would exit 0 from inside this handler and drop the status.
    trap '' TERM INT
    # utils.sh's errexit and ERR trap must not cut the shutdown short.
    set +e
    trap - ERR
    local started=false
    if [ "$POSTGRES_STARTED" = "true" ] || [ -n "${gateway_pid:-}" ]; then
        started=true
        echo "Shutting down DocumentDB components..."
    fi

    for pid_var in PG_LOG_TAIL_PID SYSTEM_PG_LOG_TAIL_PID OSS_LOG_TAIL_PID GATEWAY_LOG_TAIL_PID; do
        pid_value="${!pid_var:-}"
        if [ -n "$pid_value" ]; then
            echo "Stopping log streaming process $pid_var (PID: $pid_value)"
            kill $pid_value 2>/dev/null
        fi
    done

    # A plain sleep loop with no state to flush, so a kill is a clean stop.
    if [ -n "${USAGE_TELEMETRY_PID:-}" ]; then
        echo "Stopping usage telemetry emitter (PID: $USAGE_TELEMETRY_PID)"
        kill $USAGE_TELEMETRY_PID 2>/dev/null
    fi

    if [ -n "${gateway_pid:-}" ]; then
        echo "Stopping gateway process (PID: $gateway_pid)"
        kill $gateway_pid 2>/dev/null
    fi

    stop_owned_postgresql

    # Only remove files we created via mktemp; a caller-provided
    # DOCUMENTDB_CONFIG_FILE belongs to the caller.
    if [ -z "${DOCUMENTDB_CONFIG_FILE:-}" ] && [ -n "${configFile:-}" ] && [ -f "$configFile" ]; then
        rm -f "$configFile"
    fi
    if [ -n "${hostConfigFile:-}" ]; then
        rm -f "$hostConfigFile" "$hostConfigFile.tmp"
    fi

    [ "$started" = "false" ] || echo "Cleanup completed"
}

trap 'exit 0' TERM INT
trap cleanup EXIT

# shellcheck source=lib/cli.sh
. "$entrypoint_dir/lib/cli.sh" || { echo "Error: cannot load lib/cli.sh beside this script." >&2; exit 1; }
# shellcheck source=lib/runtime.sh
. "$entrypoint_dir/lib/runtime.sh" || { echo "Error: cannot load lib/runtime.sh beside this script." >&2; exit 1; }
# shellcheck source=lib/toast.sh
. "$entrypoint_dir/lib/toast.sh" || { echo "Error: cannot load lib/toast.sh beside this script." >&2; exit 1; }
# shellcheck source=lib/postgres.sh
. "$entrypoint_dir/lib/postgres.sh" || { echo "Error: cannot load lib/postgres.sh beside this script." >&2; exit 1; }
# shellcheck source=lib/gateway.sh
. "$entrypoint_dir/lib/gateway.sh" || { echo "Error: cannot load lib/gateway.sh beside this script." >&2; exit 1; }
# serve.sh runs only at the end of the boot; check it now, before anything starts.
[ -f "$entrypoint_dir/lib/serve.sh" ] && [ -r "$entrypoint_dir/lib/serve.sh" ] || { echo "Error: cannot load lib/serve.sh beside this script." >&2; exit 1; }

# Defined here, not in lib/: when the data directory needs root, the claim
# helper re-executes ${BASH_SOURCE[1]}, which must be this file. It also opens
# and locks fd 200 in this shell, so the postmaster inherits the lock.
claim_data_path() {
    exec 6>&2

    # Fix permissions on data directory to prevent "Permission denied" errors
    echo "Ensuring proper permissions on data directory: $DATA_PATH"
    if [ ! -d "$DATA_PATH" ]; then
        echo "Creating data directory: $DATA_PATH"
        sudo mkdir -p "$DATA_PATH"
    fi

    claim_data_directory "$DATA_PATH" 2>&6
    exec > >(tee -a "$ENTRYPOINT_LOG") 2> >(tee -a "$ENTRYPOINT_LOG" >&2)
}

# The boot sequence.
_argc=$#
parse_args "$@"
# Re-exec without arguments so values like --password leave PID 1's argv; every flag is exported.
[ "$_argc" -eq 0 ] || exec "$BASH" "${BASH_SOURCE[0]}"

if [[ -f "/version.txt" ]]; then
  DocumentDB_RELEASE_VERSION=$(cat /version.txt)
  echo "Release Version: $DocumentDB_RELEASE_VERSION"
fi

echo "[ENTRYPOINT] DocumentDB container starting..."
echo "[ENTRYPOINT] Log streaming will be enabled for PostgreSQL logs"

apply_setting_defaults
reset_runtime_state
validate_settings
resolve_layout
setup_log_dir
check_credentials
resolve_toast_request

if [ "$START_POSTGRESQL" = "true" ]; then
    echo "Starting PostgreSQL server on port $POSTGRESQL_PORT..."
    claim_data_path
    prepare_data_path
    POSTGRES_STARTED=true
    start_postgresql
    configure_running_postgresql
else
    echo "Skipping PostgreSQL server start."
fi

write_gateway_config

# Sourced at script scope, not called as functions: see lib/serve.sh.
# shellcheck source=lib/serve.sh
. "$entrypoint_dir/lib/serve.sh"
# serve.sh ends in an exit, so reaching this line means it failed to load or
# returned early. (No `|| ...` on the source: that would disable errexit and
# the ERR trap inside it.)
echo "Error: cannot run lib/serve.sh beside this script." >&2
exit 1
