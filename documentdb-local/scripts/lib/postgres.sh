# shellcheck shell=bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# lib/postgres.sh: prepare, start and configure the bundled PostgreSQL.
#
# Sourced by emulator_entrypoint.sh; defines functions only.

prepare_data_path() {
    # Repair ownership only when the data directory (or the PG_VERSION file
    # inside it, which catches e.g. a root-restored backup under a correctly
    # owned top-level directory) is not already owned by the runtime user. An
    # unconditional recursive chown/chmod rewrites metadata for every file in
    # the cluster on every boot, which gets slow on large data volumes.
    # Known residual: this two-sample probe can miss interior files left
    # foreign-owned by a repair interrupted after the top directory was
    # converted (GNU chown -R converts post-order, so this needs the top dir
    # to have been correct already). PostgreSQL then fails with a clear
    # permission error; DOCUMENTDB_FORCE_OWNERSHIP_REPAIR=true is the escape
    # hatch that forces the full recursive repair without sacrificing the
    # fast path for everyone else.
    data_dir_owner=$(stat -c '%U' "$DATA_PATH" 2>/dev/null)
    pg_version_owner="$DOCUMENTDB_RUNTIME_USER"
    if [ -f "$DATA_PATH/PG_VERSION" ]; then
        pg_version_owner=$(stat -c '%U' "$DATA_PATH/PG_VERSION" 2>/dev/null)
    fi
    if [ "${DOCUMENTDB_FORCE_OWNERSHIP_REPAIR:-false}" = "true" ] || \
       [ "$data_dir_owner" != "${DOCUMENTDB_RUNTIME_USER}" ] || \
       [ "$pg_version_owner" != "${DOCUMENTDB_RUNTIME_USER}" ]; then
        # Change ownership to the runtime user to ensure we can write/delete files
        echo "Setting ownership of $DATA_PATH to ${DOCUMENTDB_RUNTIME_USER}:${DOCUMENTDB_RUNTIME_GROUP}"
        sudo chown -R "${DOCUMENTDB_RUNTIME_USER}:${DOCUMENTDB_RUNTIME_GROUP}" "$DATA_PATH"

        # Ensure we have full permissions on the directory
        echo "Setting permissions on $DATA_PATH"
        sudo chmod -R 750 "$DATA_PATH"
    else
        chmod 750 "$DATA_PATH" 2>/dev/null || sudo chmod 750 "$DATA_PATH" || {
            echo "Error: cannot set permissions on data directory $DATA_PATH." | tee -a "$ENTRYPOINT_LOG" >&6
            exit 1
        }
    fi

    # Adopt the image-baked, pre-initialized data directory when one is present
    # so first boot skips initdb + CREATE EXTENSION. See that script for the
    # full rationale (marker lifecycle, pristineness rules, custom --data-path
    # handling). Exit 10 means the baked template holds another PostgreSQL
    # major and the server bootstrap must force a clean re-initialization;
    # any other nonzero status is a real failure.
    force_reinit_args=()
    bash "$entrypoint_dir/documentdb_prepare_data_directory.sh" "$DATA_PATH"
    prepare_data_dir_rc=$?
    case "$prepare_data_dir_rc" in
        0) ;;
        10) force_reinit_args+=(-c) ;;
        *)
            echo "Error: preparing the data directory failed (status ${prepare_data_dir_rc})." >&2
            exit "$prepare_data_dir_rc" ;;
    esac
}

start_postgresql() {
    # Deliberately an internal array, NOT the PGOPTIONS environment variable:
    # PGOPTIONS is a standard libpq CLIENT variable users legitimately set for
    # per-session GUCs, and word-splitting the ambient value into
    # start_oss_server.sh's argv let unrelated content reach its getopts --
    # where `-c` means "force cleanup" and destroys the data directory.
    external_access_args=()
    if [ "${ALLOW_EXTERNAL_CONNECTIONS}" = "true" ]; then
        echo "Allowing external connections to PostgreSQL..."
        external_access_args+=(-e)
    fi

    toast_prepare_fragment
    run_start_oss_server
    stream_postgresql_logs
    wait_for_postmaster_pid
    wait_until_accepting_connections
}

run_start_oss_server() {
    echo "Starting OSS server..."
    # No -r: start_oss_server.sh already defaults extended RUM to enabled.
    start_oss_server_args=()
    if [ ${#force_reinit_args[@]} -gt 0 ]; then
        start_oss_server_args+=("${force_reinit_args[@]}")
    fi
    if [ ${#external_access_args[@]} -gt 0 ]; then
        start_oss_server_args+=("${external_access_args[@]}")
    fi
    # Always skip the child's own admin-user step (-u ""): its stock helper
    # puts the password in psql argv. The hardened SetupCustomAdminUser
    # in lib/serve.sh creates the user before the gateway starts instead.
    start_oss_server_args+=(-u "" -d "$DATA_PATH" -p "$POSTGRESQL_PORT")

    # start_oss_server.sh returns only after crash recovery and setup, so record
    # the postmaster as soon as it holds the lock, or a kill before then would
    # leave an unrecorded pidfile that needs the override.
    (
        i=0
        while [ $i -lt 600 ] && ! vouched_postmaster "$DATA_PATH" >/dev/null; do
            sleep 0.5
            i=$((i + 1))
        done
        [ $i -lt 600 ] && record_postmaster_owner "$DATA_PATH"
    ) &
    record_watch_pid=$!
    "$SCRIPT_DIR/start_oss_server.sh" "${start_oss_server_args[@]}" | tee -a "$OSS_SERVER_LOG"
    start_oss_server_rc=${PIPESTATUS[0]}
    kill "$record_watch_pid" 2>/dev/null
    wait "$record_watch_pid" 2>/dev/null
    if [ "$start_oss_server_rc" -ne 0 ]; then
        # $? here is tee's, so the script's own status has to be read
        # explicitly. A setup step that fails *after* the postmaster
        # daemonized (e.g. CREATE EXTENSION) otherwise leaves postmaster.pid
        # in place and sails through every later gate into a healthy verdict
        # on a half-configured server.
        # Without this, a failed bootstrap (e.g. initdb dying after a forced
        # cleanup) was only discovered a full postmaster.pid timeout later,
        # under a misleading "failed to start within 60 seconds" headline.
        echo "Error: start_oss_server.sh failed (status ${start_oss_server_rc}); see $OSS_SERVER_LOG and the PostgreSQL server log at $DATA_PATH/pglog.log." >&2
        exit "$start_oss_server_rc"
    fi
}

stream_postgresql_logs() {
    echo "OSS server started."
    echo "[ENTRYPOINT] Setting up PostgreSQL log streaming..."

    echo "Setting up PostgreSQL log streaming from $PG_LOG_FILE..."
    
    # Wait for PostgreSQL log file to be created in the data directory
    ACTUAL_PG_LOG="$DATA_PATH/pglog.log"
    i=0
    while [ ! -f "$ACTUAL_PG_LOG" ] && [ $i -lt 30 ]; do
        sleep 1
        i=$((i + 1))
    done
    
    # Create symlink from centralized location to actual PostgreSQL log
    if [ -f "$ACTUAL_PG_LOG" ]; then
        echo "Creating symlink: $PG_LOG_FILE -> $ACTUAL_PG_LOG"
        ln -sf "$ACTUAL_PG_LOG" "$PG_LOG_FILE"
    else
        echo "Warning: PostgreSQL log file not found at $ACTUAL_PG_LOG"
    fi
    
    # Start streaming main PostgreSQL log
    start_log_streaming "$PG_LOG_FILE" "POSTGRES" "PG_LOG_TAIL_PID"
    
    # Also stream system PostgreSQL logs if they exist
    SYSTEM_PG_LOG="$SYSTEM_POSTGRES_LOG"
    start_log_streaming "$SYSTEM_PG_LOG" "POSTGRES-SYSTEM" "SYSTEM_PG_LOG_TAIL_PID"
    
    # Stream OSS server logs
    start_log_streaming "$OSS_SERVER_LOG" "OSS-SERVER" "OSS_LOG_TAIL_PID"
    
    # NOTE: We do NOT stream entrypoint logs to prevent infinite recursion!
    # The entrypoint messages are already going to stdout/stderr and appear in docker logs
    # ENTRYPOINT_LOG="$GATEWAY_HOME/entrypoint.log"
    # start_log_streaming "$ENTRYPOINT_LOG" "ENTRYPOINT" "ENTRYPOINT_LOG_TAIL_PID"
}

wait_for_postmaster_pid() {
    echo "Checking if PostgreSQL is running..."
    i=0
    while [ ! -f "$DATA_PATH/postmaster.pid" ]; do
        sleep 1
        if [ $i -ge 60 ]; then
            echo "PostgreSQL failed to start within 60 seconds."
            cat "$OSS_SERVER_LOG"
            exit 1
        fi
        i=$((i + 1))
    done
    echo "PostgreSQL is running."
    record_postmaster_owner "$DATA_PATH"
}

wait_until_accepting_connections() {
    # postmaster.pid appears BEFORE crash recovery finishes, but every post-start
    # step below (lz4 probe, getParameter stub, config reload) needs a server
    # that ACCEPTS connections. One bounded gate keeps them from individually
    # failing on a volume that is merely slow to replay WAL; on timeout we
    # proceed and let each step report its own failure. The verdict feeds the
    # probe's SEVERITY only and never suppresses the probe, so a gate blind spot
    # (TCP ping vs unix-socket psql, or a missing pg_isready) can only soften an
    # outcome, never manufacture a hard failure from weak evidence. Same wait
    # as the admin-user one in lib/serve.sh, shorter default: this gate is advisory.
    toast_pg_accepting=unknown
    if command -v pg_isready >/dev/null 2>&1; then
        toast_pg_accepting=true
        if ! wait_for_pg_ready 60; then
            toast_pg_accepting=false
            echo "Warning: PostgreSQL is not accepting connections after ${pg_ready_timeout} seconds (still recovering? raise DOCUMENTDB_PG_READY_TIMEOUT for slow volumes); post-start configuration steps may fail." >&2
        fi
    fi
}

configure_running_postgresql() {
    # Advisory only, so no cleanup on failure; see the script for the wording.
    bash "$entrypoint_dir/documentdb_report_extended_rum.sh" "$POSTGRESQL_PORT" "$OWNER" "$toast_pg_accepting"

    toast_apply_after_start

    # Install the emulator-only getParameter rejection stub for the bundled
    # PostgreSQL; see that script for the rationale.
    bash "$entrypoint_dir/documentdb_install_getparameter_stub.sh" "$POSTGRESQL_PORT" || exit 1
}
