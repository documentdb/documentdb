# shellcheck shell=bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# lib/runtime.sh: layout, log streaming and the health-check state file.
#
# Sourced by emulator_entrypoint.sh; defines functions only.

# Function to start log streaming
start_log_streaming() {
    local log_file="$1"
    local log_prefix="$2"
    local pid_var="$3"
    
    if [ -f "$log_file" ]; then
        echo "Starting log streaming from $log_file with prefix [$log_prefix]..."
        tail -F "$log_file" 2>/dev/null | while IFS= read -r line; do
            echo "[$log_prefix] $line"
        done &
        local tail_pid=$!
        printf -v "$pid_var" '%s' "$tail_pid"
        echo "Log streaming started with PID: $tail_pid"
        return 0
    else
        echo "Log file $log_file not found, skipping streaming"
        return 1
    fi
}

# sanitize_uint VALUE DEFAULT NAME: echo VALUE when it is a non-negative
# integer, otherwise warn on stderr and echo DEFAULT. Callers needing a lower
# bound (e.g. a >=1 interval) apply that clamp separately, and callers feeding
# the result into $(( )) should normalize a possible leading zero with
# $((10#...)) at the arithmetic site. Validating up front keeps a bad override
# from making downstream arithmetic/sleep loops hang, busy-spin, or abort mid-way.
sanitize_uint() {
    local value="$1" default="$2" name="$3"
    case "$value" in
        ''|*[!0-9]*)
            echo "Warning: invalid ${name}='${value}'; using ${default}." >&2
            printf '%s' "$default" ;;
        *)
            printf '%s' "$value" ;;
    esac
}

# wait_for_pg_ready DEFAULT_TIMEOUT: poll pg_isready on POSTGRESQL_PORT until
# it answers or DOCUMENTDB_PG_READY_TIMEOUT (else DEFAULT_TIMEOUT) seconds pass;
# returns 1 on timeout. Counts wall-clock time, since pg_isready itself can
# block for seconds per probe. Leaves the bound in pg_ready_timeout for the
# caller's message.
wait_for_pg_ready() {
    local interval start
    pg_ready_timeout="$(sanitize_uint "${DOCUMENTDB_PG_READY_TIMEOUT:-$1}" "$1" DOCUMENTDB_PG_READY_TIMEOUT)"
    pg_ready_timeout=$((10#$pg_ready_timeout))
    # A 0 interval would busy-spin between probes.
    interval="$(sanitize_uint "${DOCUMENTDB_PG_READY_INTERVAL:-1}" 1 DOCUMENTDB_PG_READY_INTERVAL)"
    interval=$((10#$interval))
    [ "$interval" -ge 1 ] || interval=1
    start=$SECONDS
    while ! pg_isready -h localhost -p "$POSTGRESQL_PORT" >/dev/null 2>&1; do
        [ $((SECONDS - start)) -lt "$pg_ready_timeout" ] || return 1
        sleep "$interval"
    done
}

reset_runtime_state() {
    # Runtime state file consumed by healthcheck.sh. Written only once startup
    # completes (see the ready banner in lib/serve.sh), so its presence doubles as the
    # readiness marker. Remove any leftover from a previous boot of this
    # container (e.g. `docker restart`) so the healthcheck cannot report healthy
    # while this boot is still starting up — and verify both the removal and
    # that the path is writable, failing NOW rather than at the publish: a
    # failure discovered there would surface only after the full (up to
    # multi-minute) boot, as a container that works but never reports healthy.
    export DOCUMENTDB_RUNTIME_STATE_FILE=${DOCUMENTDB_RUNTIME_STATE_FILE:-/tmp/documentdb-local-runtime.env}
    rm -f "$DOCUMENTDB_RUNTIME_STATE_FILE" "${DOCUMENTDB_RUNTIME_STATE_FILE}.tmp" 2>/dev/null
    if [ -e "$DOCUMENTDB_RUNTIME_STATE_FILE" ] \
            || ! : > "${DOCUMENTDB_RUNTIME_STATE_FILE}.tmp" 2>/dev/null; then
        echo "Error: cannot reset or write the runtime state file at $DOCUMENTDB_RUNTIME_STATE_FILE, which the container health check depends on. Set DOCUMENTDB_RUNTIME_STATE_FILE to a writable path." >&2
        exit 1
    fi
    rm -f "${DOCUMENTDB_RUNTIME_STATE_FILE}.tmp"
}

resolve_layout() {
    # Image-internal paths and identities. Not operator settings: they describe
    # where this image put things, and only a source-checkout run overrides them.
    export GATEWAY_HOME=${GATEWAY_HOME:-/home/documentdb/gateway}
    export DOCUMENTDB_LOG_DIR=${DOCUMENTDB_LOG_DIR:-/var/log/documentdb}
    # The PostgreSQL major this run assumes, resolved once. Inside the image
    # PG_VERSION_USED always comes from the Dockerfile; the fallback only applies
    # to a source checkout, where it means the developer's PostgreSQL.
    PG_MAJOR_ASSUMED=${PG_VERSION_USED:-17}
    export POSTGRES_LOG_VERSION=${PG_MAJOR_ASSUMED}
    export SYSTEM_POSTGRES_LOG=${SYSTEM_POSTGRES_LOG:-/var/log/postgresql/postgresql-${POSTGRES_LOG_VERSION}-main.log}
    export DOCUMENTDB_RUNTIME_USER=${DOCUMENTDB_RUNTIME_USER:-documentdb}
    export DOCUMENTDB_RUNTIME_GROUP=${DOCUMENTDB_RUNTIME_GROUP:-$DOCUMENTDB_RUNTIME_USER}

    # Resolve script and data directories.
    # Package-installed paths take priority over the legacy Docker layout.
    # CONFIG_DIR can be overridden for testing.
    if [ -f "/usr/share/documentdb/scripts/start_oss_server.sh" ] \
            && [ -f "/usr/share/documentdb/scripts/utils.sh" ]; then
        # Prefer the package-installed layout only when the scripts this
        # entrypoint actually sources/execs (start_oss_server.sh and utils.sh)
        # are present there. The documentdb-common package creates
        # /usr/share/documentdb/scripts but ships only a subset
        # (documentdb_postgresql_service.sh, init_documentdb_data.sh), so keying
        # off the directory alone would select a path missing start_oss_server.sh
        # / utils.sh once that package is co-installed with this image.
        SCRIPT_DIR="/usr/share/documentdb/scripts"
        SAMPLE_DATA_DIR="/usr/share/documentdb/sample-data"
        CONFIG_DIR="${CONFIG_DIR:-/etc/documentdb/gateway}"
    else
        SCRIPT_DIR="${GATEWAY_HOME}/scripts"
        SAMPLE_DATA_DIR="${GATEWAY_HOME}/sample-data"
        CONFIG_DIR="${CONFIG_DIR:-${GATEWAY_HOME}/pg_documentdb_gw}"
    fi
}

setup_log_dir() {
    # Setup centralized log directory structure
    echo "Setting up centralized log directory at $DOCUMENTDB_LOG_DIR..."
    sudo mkdir -p "$DOCUMENTDB_LOG_DIR/postgres"
    sudo chown -R "${DOCUMENTDB_RUNTIME_USER}:${DOCUMENTDB_RUNTIME_GROUP}" "$DOCUMENTDB_LOG_DIR"
    sudo chmod -R 755 "$DOCUMENTDB_LOG_DIR"

    # Define centralized log file paths
    export ENTRYPOINT_LOG="$DOCUMENTDB_LOG_DIR/gateway_entrypoint.log"
    export GATEWAY_LOG="$DOCUMENTDB_LOG_DIR/gateway.log"
    export OSS_SERVER_LOG="$DOCUMENTDB_LOG_DIR/oss_server.log"
    # Note: PostgreSQL log will be symlinked after PostgreSQL starts
    export PG_LOG_FILE="$DOCUMENTDB_LOG_DIR/postgres/pglog.log"

    echo "Centralized log directory created with the following structure:"
    echo "  $DOCUMENTDB_LOG_DIR/gateway_entrypoint.log"
    echo "  $DOCUMENTDB_LOG_DIR/gateway.log"
    echo "  $DOCUMENTDB_LOG_DIR/oss_server.log"
    echo "  $DOCUMENTDB_LOG_DIR/postgres/pglog.log (will be symlinked)"
}
