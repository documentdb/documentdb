#!/bin/bash

# Cleanup function to handle container shutdown gracefully.
# Runs on BOTH shutdown paths: the SIGTERM/SIGINT trap (docker stop) and the
# gateway self-exit path (crash/OOM) after the final `wait` returns — without
# the latter, this script (PID 1) would simply exit and the kernel would
# SIGKILL the daemonized postmaster, forcing WAL recovery on the next boot.
# Takes an optional exit code (default 0) so the self-exit path can propagate
# the gateway's status.
configFile=""

# Initialized up front so cleanup() — which can now also run from the gateway
# self-exit path — never dereferences an unset PID var under the `set -u`
# that sourcing utils.sh (CREATE_USER=true path) turns on.
PG_LOG_TAIL_PID=""
SYSTEM_PG_LOG_TAIL_PID=""
OSS_LOG_TAIL_PID=""
GATEWAY_LOG_TAIL_PID=""
POSTGRES_STOPPED=false

cleanup() {
    # Mask further TERM/INT: a signal landing while the self-exit path is
    # already running cleanup would re-enter it with NO argument and
    # `exit "${1:-0}"` — discarding the gateway's real exit status.
    trap '' TERM INT
    echo "Shutting down DocumentDB components..."
    
    # Kill log streaming processes if they exist
    for pid_var in PG_LOG_TAIL_PID SYSTEM_PG_LOG_TAIL_PID OSS_LOG_TAIL_PID GATEWAY_LOG_TAIL_PID; do
        pid_value=$(eval echo \$${pid_var})
        if [ -n "$pid_value" ]; then
            echo "Stopping log streaming process $pid_var (PID: $pid_value)"
            kill $pid_value 2>/dev/null || true
        fi
    done
    
    # Kill gateway process if it exists
    if [ -n "${gateway_pid:-}" ]; then
        echo "Stopping gateway process (PID: $gateway_pid)"
        kill $gateway_pid 2>/dev/null || true
    fi

    # Gracefully stop PostgreSQL. It is daemonized via pg_ctl, so the
    # container's SIGTERM never reaches the postmaster — without an explicit
    # fast stop here every `docker stop` is an unclean shutdown that forces WAL
    # recovery on the next boot. Only applies when this entrypoint started PG.
    # The POSTGRES_STOPPED guard prevents a double stop when a signal arrives
    # while the gateway self-exit path is already running this cleanup.
    if [ "${POSTGRES_STOPPED:-false}" != "true" ]; then
        POSTGRES_STOPPED=true
        if [ "${START_POSTGRESQL:-true}" = "true" ] && [ -n "${DATA_PATH:-}" ] \
                && [ -f "${DATA_PATH}/postmaster.pid" ]; then
            pgctl_bin="$(command -v pg_ctl 2>/dev/null || true)"
            if [ -n "$pgctl_bin" ]; then
                echo "Stopping PostgreSQL (fast) at ${DATA_PATH}..."
                "$pgctl_bin" stop -D "${DATA_PATH}" -m fast 2>/dev/null || true
            else
                echo "Warning: pg_ctl not found; cannot cleanly stop PostgreSQL at ${DATA_PATH}." >&2
            fi
        fi
    fi

    echo "Cleanup completed"
    exit "${1:-0}"
}

cleanup_temp_config() {
    # Only clean up files we created via mktemp; if the caller provided
    # DOCUMENTDB_CONFIG_FILE, the caller owns the lifecycle.
    if [ -z "${DOCUMENTDB_CONFIG_FILE:-}" ] && [ -n "${configFile:-}" ] && [ -f "$configFile" ]; then
        rm -f "$configFile"
    fi
}

# Set up signal handlers for graceful shutdown
trap cleanup SIGTERM SIGINT
trap cleanup_temp_config EXIT

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
        eval "$pid_var=$tail_pid"
        echo "Log streaming started with PID: $tail_pid"
        return 0
    else
        echo "Log file $log_file not found, skipping streaming"
        return 1
    fi
}

# Print help message
usage() {
    cat << EOF
Launches DocumentDB

Optional arguments:
  -h, --help            Display information on available configuration
  --cert-path [PATH]    Specify a path to a PEM certificate for securing traffic. You need to mount this file into
                        the container (e.g. if CERT_PATH=/mycert.pem, you'd add an option like the following to your
                        docker run: --mount type=bind,source=./mycert.pem,target=/mycert.pem)
                        PEM certificates must be provided together with --key-file.
                        Overrides CERT_PATH environment variable.
  --key-file [PATH]     Specify the PEM private key that matches --cert-path. You need to mount this file into the
                        container (e.g. if KEY_FILE=/mykey.key, you'd add an option like the following to your
                        docker run: --mount type=bind,source=./mykey.key,target=/mykey.key)
                        Overrides KEY_FILE environment variable.
  --data-path [PATH]    Specify a directory for data. Frequently used with docker run --mount option 
                        (e.g. if DATA_PATH=/usr/documentdb/data, you'd add an option like the following to your 
                        docker run: --mount type=bind,source=./.local/data,target=/usr/documentdb/data)
                        Defaults to /data
                        Overrides DATA_PATH environment variable.
  --documentdb-port     The port of the DocumentDB endpoint on the container. 
                        You still need to publish this port (e.g. -p 10260:10260).
                        Defaults to 10260
                        Overrides DOCUMENTDB_PORT environment variable.
  --enable-telemetry    Enable telemetry data sent to the usage colletor (Azure Application Insights). 
                        Overrides ENABLE_TELEMETRY environment variable.
  --log-level           The verbosity of logs that will be emitted.
                        Overrides LOG_LEVEL environment variable.
                          quiet, error, warn, info (default), debug, trace
  --username            Specify the username for the DocumentDB.
                        Defaults to default_user
                        Overrides USERNAME environment variable.
  --password            Specify the password for the DocumentDB.
                        REQUIRED.
                        Overrides PASSWORD environment variable.
  --create-user         Specify whether to create a user. 
                        Defaults to true.
  --start-pg            Specify whether to start the PostgreSQL server.
                        Defaults to true.
  --pg-port             Specify the port for the PostgreSQL server.
                        Defaults to 9712.
                        Overrides POSTGRESQL_PORT environment variable.
  --owner               Specify the owner of the DocumentDB.
                        Overrides OWNER environment variable.
                        defaults to documentdb.
  --allow-external-connections [true|false]
                        Open the container's internal PostgreSQL server to all
                        interfaces (listen_addresses='*' + a permissive pg_hba
                        entry). This does NOT affect the gateway, which always
                        listens on all interfaces on the DocumentDB port; it
                        only exposes the backend PostgreSQL port directly.
                        Defaults to false.
                        Overrides ALLOW_EXTERNAL_CONNECTIONS environment variable.
  --init-data [true|false]
                        Enable initialization with built-in sample data.
                        Seeded once per data volume (on a fresh volume); re-create the
                        volume to seed again.
                        Defaults to false.
                        Overrides INIT_DATA environment variable.
  --init-data-path [PATH]
                        Specify a directory containing JavaScript files for database initialization.
                        Files will be executed in alphabetical order using mongosh.
                        Runs once per data volume (on a fresh volume), so scripts should be
                        idempotent; a failed run is not retried on restart. To re-run, start
                        with a fresh data volume.
                        Defaults to /init_doc_db.d
                        Overrides INIT_DATA_PATH environment variable.
  --skip-init-data      Skip initialization with built-in sample data.
                        Legacy alias for --init-data false.
                        Does not affect --init-data-path; custom data is
                        still loaded once per fresh data volume.
                        Overrides SKIP_INIT_DATA environment variable.
  --disable-extended-rum
                        Disable the use of extended_rum for indexes.
                        By default, extended rum is enabled.
                        Overrides DISABLE_EXTENDED_RUM environment variable.
  --tlsMode [MODE]      Set the TLS mode for client connections.
                        Supported modes: disabled, allowTLS, requireTLS.
                        By default, the gateway accepts both plain and TLS connections (allowTLS).
                        disabled behaves the same as allowTLS; the gateway has no plain-only mode.
                        When set to requireTLS, plain (non-TLS) connections are rejected.
                        Overrides TLS_MODE environment variable.
EOF
}

# sanitize_uint VALUE DEFAULT NAME: echo VALUE when it is a non-negative
# integer, otherwise warn on stderr and echo DEFAULT. Callers needing a lower
# bound (e.g. a >=1 interval) apply that clamp separately, and callers feeding
# the result into $(( )) should normalize a possible leading zero with
# $((10#...)) at the arithmetic site. This script has no `set -e`, so validating
# up front keeps a bad override from making downstream arithmetic/sleep loops
# hang, busy-spin, or abort mid-way.
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

if [[ -f "/version.txt" ]]; then
  DocumentDB_RELEASE_VERSION=$(cat /version.txt)
  echo "Release Version: $DocumentDB_RELEASE_VERSION"
fi

echo "[ENTRYPOINT] DocumentDB container starting..."
echo "[ENTRYPOINT] Log streaming will be enabled for PostgreSQL logs"

# Handle arguments

while [[ $# -gt 0 ]];
do
  case $1 in
    -h|--help) 
        usage;
        exit 0;;

    --cert-path)
        shift
        export CERT_PATH=$1
        shift;;

    --key-file)
        shift
        export KEY_FILE=$1
        shift;;

    --data-path)
        shift
        export DATA_PATH=$1
        shift;;

    --documentdb-port)
        shift
        export DOCUMENTDB_PORT=$1
        shift;;

    --enable-telemetry)
        shift
        export ENABLE_TELEMETRY=$1
        shift;;
        
    --log-level)
        shift
        export LOG_LEVEL=$1
        shift;;

    --username)
        shift
        export USERNAME=$1
        shift;;

    --password)
        shift
        export PASSWORD=$1
        shift;;

    --create-user)
        shift
        export CREATE_USER=$1
        shift;;

    --start-pg)
        shift
        export START_POSTGRESQL=$1
        shift;;

    --pg-port)
        shift
        export POSTGRESQL_PORT=$1
        shift;;

    --owner)
        shift
        export OWNER=$1
        shift;;

    --allow-external-connections)
        shift
        export ALLOW_EXTERNAL_CONNECTIONS=$1
        shift;;

    --init-data)
        shift
        export INIT_DATA=$1
        shift;;

    --init-data-path)
        shift
        export INIT_DATA_PATH=$1
        shift;;

    --skip-init-data)
        export INIT_DATA=false
        export SKIP_INIT_DATA=true
        shift;;

    --disable-extended-rum)
        export DISABLE_EXTENDED_RUM=true
        shift;;

    --tlsMode)
        export TLS_MODE="$2"
        shift; shift;;

    -*)
        echo "Unknown option $1"
        exit 1;; 
  esac
done

# Set default values if not provided.
#
# Track whether USERNAME / PASSWORD came from the operator (CLI flag or
# explicit env var) vs. Fell back to the built-in default. The built-in
# defaults exist for legacy / evaluation use, but a loud warning is
# printed when they apply because anyone reachable on the published port
# can authenticate with default_user / Admin100. A future major version
# will refuse to start without --password / PASSWORD set explicitly.
# A single flag suffices: the warning below fires when EITHER the username or
# the password fell back to the built-in default, and the warning text is
# static (it does not distinguish which one defaulted).
USING_DEFAULT_CREDS=false
if [ -z "${USERNAME:-}" ] || [ -z "${PASSWORD:-}" ]; then
    USING_DEFAULT_CREDS=true
fi
export OWNER=${OWNER:-$(whoami)}
export DATA_PATH=${DATA_PATH:-/data}
export DOCUMENTDB_PORT=${DOCUMENTDB_PORT:-10260}
export POSTGRESQL_PORT=${POSTGRESQL_PORT:-9712}
export USERNAME=${USERNAME:-default_user}
export PASSWORD=${PASSWORD:-Admin100}
export CREATE_USER=${CREATE_USER:-true}
export START_POSTGRESQL=${START_POSTGRESQL:-true}
export INIT_DATA=${INIT_DATA:-}
export INIT_DATA_PATH=${INIT_DATA_PATH:-/init_doc_db.d}
export SKIP_INIT_DATA=${SKIP_INIT_DATA:-}
export DISABLE_EXTENDED_RUM=${DISABLE_EXTENDED_RUM:-false}
export TLS_MODE=${TLS_MODE:-allowTLS}
export GATEWAY_HOME=${GATEWAY_HOME:-/home/documentdb/gateway}
export DOCUMENTDB_LOG_DIR=${DOCUMENTDB_LOG_DIR:-/var/log/documentdb}
export POSTGRES_LOG_VERSION=${PG_VERSION_USED:-17}
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
elif [ -n "${GATEWAY_HOME:-}" ]; then
    SCRIPT_DIR="${GATEWAY_HOME}/scripts"
    SAMPLE_DATA_DIR="${GATEWAY_HOME}/sample-data"
    CONFIG_DIR="${CONFIG_DIR:-${GATEWAY_HOME}/pg_documentdb_gw}"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    SAMPLE_DATA_DIR="$(dirname "$SCRIPT_DIR")/sample-data"
    CONFIG_DIR="${CONFIG_DIR:-$(dirname "$SCRIPT_DIR")/pg_documentdb_gw}"
fi

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

# Validate required parameters
if [ -z "${PASSWORD:-}" ]; then
    echo "Error: PASSWORD is required. Please provide a password using --password argument or PASSWORD environment variable."
    exit 1
fi

# Loud, unmissable warning when the operator did NOT supply an explicit
# username / password and we fell back to the built-in defaults. These
# defaults are well-known, public, and not safe outside short-lived
# evaluation. Refusing to start by default is the eventual goal; for now
# we keep the legacy compatibility but make the noise hard to miss.
# Operators who knowingly want the defaults (for example CI smoke tests
# that depend on the historical defaults) can suppress with
# DOCUMENTDB_ALLOW_DEFAULT_PASSWORD=true.
if [ "${USING_DEFAULT_CREDS}" = "true" ]; then
    if [ "${DOCUMENTDB_ALLOW_DEFAULT_PASSWORD:-false}" != "true" ]; then
        cat >&2 <<'WARN'
========================================================================
WARNING: DocumentDB is starting with the BUILT-IN DEFAULT CREDENTIALS.
========================================================================

  Username: default_user   (because --username / USERNAME was not set)
  Password: Admin100       (because --password / PASSWORD was not set)

These credentials are PUBLIC and well-known. Any client that can reach
the gateway port can authenticate as the admin user. Do NOT use this
configuration outside short-lived local evaluation.

To suppress this warning intentionally (for example in evaluation
scripts), set DOCUMENTDB_ALLOW_DEFAULT_PASSWORD=true. To fix:

  docker run ... --env USERNAME=<your-user> --env PASSWORD=<your-pw> ...
  or
  documentdb-local --username <your-user> --password <your-pw>

In a future release the emulator will REFUSE to start when --password
and --username are not provided, so please migrate now.
========================================================================
WARN
    fi
fi

echo "Using username: $USERNAME"
echo "Using owner: $OWNER"
echo "Using data path: $DATA_PATH"

# Reject a username the gateway would refuse at authentication time (a reserved
# role name or a BlockedRolePrefix) before starting anything, so the container
# never reports ready with a user that can never authenticate.
bash "$(dirname "${BASH_SOURCE[0]}")/documentdb_validate_username.sh" "$USERNAME" || exit 1

if { [ -n "${CERT_PATH:-}" ] && [ -z "${KEY_FILE:-}" ]; } || \
   { [ -z "${CERT_PATH:-}" ] && [ -n "${KEY_FILE:-}" ]; }; then
    echo "Error: Both CERT_PATH and KEY_FILE must be set together, or neither should be set."
    exit 1
fi

num='^[0-9]+$'
if ! [[ "$DOCUMENTDB_PORT" =~ $num ]]; then
    echo "Invalid port value $DOCUMENTDB_PORT, must be a number"
    exit 1
fi
# Normalize to base-10 so a zero-padded value (e.g. "010260") is not later
# parsed as invalid octal by the jq ".GatewayListenPort = $DOCUMENTDB_PORT"
# numeric assignment, which would error and — with no `set -e` — skip the
# &&-chained config mv, silently leaving the gateway on the default port.
DOCUMENTDB_PORT=$((10#$DOCUMENTDB_PORT))

if ! [[ "$POSTGRESQL_PORT" =~ $num ]]; then
    echo "Invalid PostgreSQL port value $POSTGRESQL_PORT, must be a number"
    exit 1
fi
POSTGRESQL_PORT=$((10#$POSTGRESQL_PORT))

if [ -n "$ENABLE_TELEMETRY" ] && \
   [ "$ENABLE_TELEMETRY" != "true" ] && \
   [ "$ENABLE_TELEMETRY" != "false" ]; then
    echo "Invalid enable-telemetry value $ENABLE_TELEMETRY, must be true or false"
    exit 1
fi

if [ -n "$LOG_LEVEL" ] && \
   [ "$LOG_LEVEL" != "quiet" ] && \
   [ "$LOG_LEVEL" != "error" ] && \
   [ "$LOG_LEVEL" != "warn" ] && \
   [ "$LOG_LEVEL" != "info" ] && \
   [ "$LOG_LEVEL" != "debug" ] && \
   [ "$LOG_LEVEL" != "trace" ]; then
    echo "Invalid log level value $LOG_LEVEL, must be one of: quiet, error, warn, info, debug, trace"
    exit 1
fi

if [ -n "$INIT_DATA" ] && \
   [ "$INIT_DATA" != "true" ] && \
   [ "$INIT_DATA" != "false" ]; then
    echo "Invalid init-data value $INIT_DATA, must be true or false"
    exit 1
fi

if [ -n "$SKIP_INIT_DATA" ] && \
   [ "$SKIP_INIT_DATA" != "true" ] && \
   [ "$SKIP_INIT_DATA" != "false" ]; then
    echo "Invalid skip-init-data value $SKIP_INIT_DATA, must be true or false"
    exit 1
fi

# Same strict true/false contract as the other booleans above. This matters
# more than usual here: before the --allow-external-connections fix this
# setting was accidentally always-on, so legacy users may be passing 1/yes/
# TRUE and expecting an open PostgreSQL port — silently treating those as
# false would close their port with nothing in the logs explaining why.
if [ -n "${ALLOW_EXTERNAL_CONNECTIONS:-}" ] && \
   [ "$ALLOW_EXTERNAL_CONNECTIONS" != "true" ] && \
   [ "$ALLOW_EXTERNAL_CONNECTIONS" != "false" ]; then
    echo "Invalid allow-external-connections value $ALLOW_EXTERNAL_CONNECTIONS, must be true or false"
    exit 1
fi

if [ -z "$INIT_DATA" ]; then
    if [ "$SKIP_INIT_DATA" = "false" ]; then
        export INIT_DATA=true
    else
        export INIT_DATA=false
    fi
fi

if [ "$INIT_DATA" = "true" ]; then
    export SKIP_INIT_DATA=false
else
    export SKIP_INIT_DATA=true
fi

case "$TLS_MODE" in
    disabled|allowTLS|requireTLS) ;;
    *)
        echo "Invalid tlsMode value '$TLS_MODE', must be one of: disabled, allowTLS, requireTLS"
        exit 1;;
esac

if [ "$START_POSTGRESQL" = "true" ]; then
    echo "Starting PostgreSQL server on port $POSTGRESQL_PORT..."
    exec > >(tee -a "$ENTRYPOINT_LOG") 2> >(tee -a "$ENTRYPOINT_LOG" >&2)
    
    # Fix permissions on data directory to prevent "Permission denied" errors
    echo "Ensuring proper permissions on data directory: $DATA_PATH"
    if [ ! -d "$DATA_PATH" ]; then
        echo "Creating data directory: $DATA_PATH"
        sudo mkdir -p "$DATA_PATH"
    fi
    
    # Change ownership to the runtime user to ensure we can write/delete files
    echo "Setting ownership of $DATA_PATH to ${DOCUMENTDB_RUNTIME_USER}:${DOCUMENTDB_RUNTIME_GROUP}"
    sudo chown -R "${DOCUMENTDB_RUNTIME_USER}:${DOCUMENTDB_RUNTIME_GROUP}" "$DATA_PATH"
    
    # Ensure we have full permissions on the directory
    echo "Setting permissions on $DATA_PATH"
    sudo chmod -R 750 "$DATA_PATH"
    
    if [ "${ALLOW_EXTERNAL_CONNECTIONS:-false}" = "true" ]; then
        echo "Allowing external connections to PostgreSQL..."
        export PGOPTIONS="-e"
    fi
    echo "Starting OSS server..."
    EXTENDED_RUM_FLAG="-r"
    if [ "$DISABLE_EXTENDED_RUM" = "true" ]; then
        EXTENDED_RUM_FLAG=""
    fi
    start_oss_server_args=()
    if [ -n "$EXTENDED_RUM_FLAG" ]; then
        start_oss_server_args+=("$EXTENDED_RUM_FLAG")
    fi
    if [ -n "${PGOPTIONS:-}" ]; then
        IFS=' ' read -r -a pgoptions_array <<< "$PGOPTIONS"
        start_oss_server_args+=("${pgoptions_array[@]}")
    fi
    if [ "$CREATE_USER" = "false" ]; then
        start_oss_server_args+=(-u "")
    else
        start_oss_server_args+=(-u "$USERNAME" -a "$PASSWORD")
    fi
    start_oss_server_args+=(-d "$DATA_PATH" -p "$POSTGRESQL_PORT")

    "$SCRIPT_DIR/start_oss_server.sh" "${start_oss_server_args[@]}" | tee -a "$OSS_SERVER_LOG"

    echo "OSS server started."
    echo "[ENTRYPOINT] Setting up PostgreSQL log streaming..."

    # Start streaming PostgreSQL logs to docker logs
    # Note: We exclude ENTRYPOINT_LOG_TAIL_PID to prevent recursion
    PG_LOG_TAIL_PID=""
    SYSTEM_PG_LOG_TAIL_PID=""
    OSS_LOG_TAIL_PID=""
    GATEWAY_LOG_TAIL_PID=""
    
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

    # Install the emulator-only getParameter rejection stub for the bundled
    # PostgreSQL (issue #650). Extracted to a sibling script to keep this
    # entrypoint lean; see that script for the full rationale.
    bash "$(dirname "${BASH_SOURCE[0]}")/documentdb_install_getparameter_stub.sh" "$POSTGRESQL_PORT" || exit 1
else
    echo "Skipping PostgreSQL server start."
fi

# Setting up the configuration file
configFile="${DOCUMENTDB_CONFIG_FILE:-$(mktemp /tmp/SetupConfiguration_XXXXXX.json)}"
cp "$CONFIG_DIR/SetupConfiguration.json" "$configFile"
chmod 600 "$configFile"

if [ -n "${DOCUMENTDB_PORT:-}" ]; then
    echo "Updating GatewayListenPort in the configuration file..."
    jq ".GatewayListenPort = $DOCUMENTDB_PORT" "$configFile" > "$configFile.tmp" && \
    mv "$configFile.tmp" "$configFile"
fi

if [ -n "${POSTGRESQL_PORT:-}" ]; then
    echo "Updating PostgresPort in the configuration file..."
    jq ".PostgresPort = $POSTGRESQL_PORT" "$configFile" > "$configFile.tmp" && \
    mv "$configFile.tmp" "$configFile"
fi

if [ -n "${CERT_PATH:-}" ] && [ -n "${KEY_FILE:-}" ]; then
    echo "Adding CertificateOptions to the configuration file..."
    jq --arg certPath "$CERT_PATH" --arg keyFilePath "$KEY_FILE" \
       '.CertificateOptions = { "CertType": "PemFile", "FilePath": $certPath, "KeyFilePath": $keyFilePath }' \
       "$configFile" > "$configFile.tmp" && \
    mv "$configFile.tmp" "$configFile"
fi

echo "Setting TLS mode to '$TLS_MODE'..."
jq --arg tlsMode "$TLS_MODE" '.TlsMode = $tlsMode' "$configFile" > "$configFile.tmp" && \
mv "$configFile.tmp" "$configFile"

# Translate the requested TLS mode into the EnforceTls flag the gateway actually
# reads. requireTLS enforces TLS for every connection; allowTLS and disabled let
# the gateway accept both plain (non-TLS) and TLS clients on the same port.
if [ "$TLS_MODE" = "requireTLS" ]; then
    enforceTls=true
else
    enforceTls=false
    if [ "$TLS_MODE" = "disabled" ]; then
        echo "Warning: tlsMode 'disabled' does not turn TLS off. The gateway has no plain-only mode, so it behaves like 'allowTLS' and still accepts TLS connections (plain connections are accepted as well)." >&2
    fi
fi

# Fail fast if the EnforceTls write does not succeed: a stale config would leave
# EnforceTls unset, which the gateway treats as "enforce TLS", silently rejecting
# the plain connections this setting is meant to allow.
if ! jq --argjson enforceTls "$enforceTls" '.EnforceTls = $enforceTls' "$configFile" > "$configFile.tmp"; then
    echo "Error: failed to write EnforceTls to the gateway configuration file." >&2
    exit 1
fi
mv "$configFile.tmp" "$configFile"

echo "Starting gateway in the background..."
if [ "$CREATE_USER" = "false" ]; then
    echo "Skipping user creation and starting the gateway..."
else
    # Create the admin user before starting the gateway.
    . "$SCRIPT_DIR/utils.sh"

    # SECURITY: the stock SetupCustomAdminUser in utils.sh interpolates the
    # raw password into psql's argv (inside the -c SQL string), where it is
    # world-readable via /proc/<pid>/cmdline for as long as psql runs, and
    # into the create_user JSON unescaped, where a double quote or backslash
    # in the password corrupts the document and breaks user creation.
    # utils.sh is shared with non-container callers (start_oss_server.sh,
    # build_and_start_gateway.sh), so it is left untouched; instead, shadow
    # ONLY its stock implementation here with a hardened same-signature
    # variant that:
    #   - JSON-encodes the password with jq --rawfile from a 0600 temp file
    #     (jq is already a hard dependency of this entrypoint), and
    #   - feeds all SQL to psql over stdin — never argv — embedding the
    #     username via a psql variable and the create_user document as a
    #     single-quote-doubled SQL literal.
    # A non-stock definition sourced from utils.sh (a site override or test
    # stub) is honored as-is; only the known-insecure implementation is
    # replaced.
    if declare -f SetupCustomAdminUser 2>/dev/null | grep -q 'documentdb_api\.create_user'; then
        SetupCustomAdminUser() {
            local user="$1" pass="$2" port="$3" owner="$4"
            echo "Setting up custom user $user with owner $owner."
            local role_probe
            role_probe="$(printf '%s\n' "SELECT 1 FROM pg_roles WHERE rolname = :'u';" \
                | psql -p "$port" -U "$owner" -d postgres -X -tA -v "u=${user}")"
            if printf '%s' "$role_probe" | grep -q 1; then
                echo "Role $user already exists."
                return 0
            fi
            local pw_file create_user_doc jq_rc doc_sql
            pw_file="$(mktemp /tmp/documentdb_admin_pw_XXXXXX)" || return 1
            chmod 600 "$pw_file"
            printf '%s' "$pass" > "$pw_file"
            create_user_doc="$(jq -cn --rawfile pwd "$pw_file" --arg user "$user" \
                '{createUser: $user, pwd: $pwd, roles: [{role: "readWriteAnyDatabase", db: "admin"}, {role: "clusterAdmin", db: "admin"}]}')"
            jq_rc=$?
            rm -f "$pw_file"
            if [ "$jq_rc" -ne 0 ]; then
                echo "Error: failed to build the create_user document." >&2
                return 1
            fi
            # Embed the document as a SQL string literal (single quotes
            # doubled) and pipe the statement on stdin so the password never
            # appears in any process's argv.
            doc_sql=${create_user_doc//\'/\'\'}
            # ON_ERROR_STOP matters: for stdin-scripted input psql exits 0
            # on SQL errors unless it is set (the stock -c form exited 1),
            # so without it a failed create_user would slip past the
            # caller's error guard and the container would report ready
            # with no usable admin login.
            printf '%s\n' "SELECT documentdb_api.create_user('${doc_sql}');" \
                | psql -p "$port" -U "$owner" -d postgres -X -v ON_ERROR_STOP=1
        }
    fi

    # Wait for PostgreSQL to accept connections before creating the admin
    # user. With an external PostgreSQL (START_POSTGRESQL=false) the server
    # may still be coming up; without this gate SetupCustomAdminUser would run
    # against a not-yet-ready server and the admin user would silently never
    # be created. Mirrors the readiness gate the previous
    # build_and_start_gateway.sh path enforced. The timeout/interval are
    # overridable so tests can exercise the timeout path without a long wait.
    if command -v pg_isready >/dev/null 2>&1; then
        pg_ready_timeout="$(sanitize_uint "${DOCUMENTDB_PG_READY_TIMEOUT:-600}" 600 DOCUMENTDB_PG_READY_TIMEOUT)"
        pg_ready_interval="$(sanitize_uint "${DOCUMENTDB_PG_READY_INTERVAL:-5}" 5 DOCUMENTDB_PG_READY_INTERVAL)"
        # Interval needs a >=1 lower bound (a 0 would busy-spin forever since
        # elapsed never advances), then base-10 normalization so a zero-padded
        # value (e.g. "08") is not parsed as invalid octal by the $(( )) below.
        [ "$pg_ready_interval" -ge 1 ] || pg_ready_interval=1
        pg_ready_interval=$((10#$pg_ready_interval))
        pg_ready_elapsed=0
        echo "Waiting for PostgreSQL to be ready on localhost:$POSTGRESQL_PORT before creating the admin user..."
        while ! pg_isready -h localhost -p "$POSTGRESQL_PORT" >/dev/null 2>&1; do
            if [ "$pg_ready_elapsed" -ge "$pg_ready_timeout" ]; then
                echo "Error: PostgreSQL did not become ready on localhost:$POSTGRESQL_PORT within ${pg_ready_timeout}s; cannot create the admin user." >&2
                exit 1
            fi
            sleep "$pg_ready_interval"
            pg_ready_elapsed=$((pg_ready_elapsed + pg_ready_interval))
        done
        echo "PostgreSQL is ready."
    else
        echo "Warning: pg_isready not found; creating the admin user without a readiness wait." >&2
    fi

    # Fail loudly if the admin user cannot be created instead of launching the
    # gateway with no usable login.
    if ! SetupCustomAdminUser "$USERNAME" "$PASSWORD" "$POSTGRESQL_PORT" "$OWNER"; then
        echo "Error: failed to create the admin user '$USERNAME'." >&2
        exit 1
    fi
fi

# Launch the gateway binary directly. Prefer the package-installed wrapper at
# /usr/bin/documentdb-gateway; when the gateway is not installed as a system
# package (e.g. the documentdb-local image stages the binary under
# $GATEWAY_HOME instead), fall back to that staged binary.
gateway_bin="/usr/bin/documentdb-gateway"
if [ ! -x "$gateway_bin" ]; then
    gateway_bin="$GATEWAY_HOME/pg_documentdb_gw/target/release-with-symbols/documentdb_gateway"
fi

# Re-apply the restrictive mode HERE rather than trusting the `chmod 600`
# at creation time: every `jq ... > "$configFile.tmp" && mv` above replaces
# the inode, so the surviving file carries the umask-derived mode of the
# last temp file, not the one we set.
chmod 600 "$configFile"

# The packaged /usr/bin/documentdb-gateway wrapper drops root to the
# documentdb-gateway user (runuser) before exec'ing the daemon, so a
# root-owned 0600 config becomes unreadable to the process that has to
# parse it: the daemon fails with EACCES, never binds, and the readiness
# loop below reports the misleading "Gateway failed to start". Hand the
# config to that user when — and only when — the wrapper will actually
# perform the drop (root, wrapper in use, gateway user present, not under
# systemd, mirroring _maybe_runuser_down's own conditions). The shipped
# emulator image runs as USER documentdb, so this is a no-op there.
if [ "$gateway_bin" = "/usr/bin/documentdb-gateway" ] \
        && [ "$(id -u)" -eq 0 ] \
        && [ -z "${INVOCATION_ID:-}" ] \
        && id -u documentdb-gateway >/dev/null 2>&1; then
    echo "Handing gateway configuration to the documentdb-gateway user (wrapper will drop privileges)."
    chown documentdb-gateway "$configFile"
fi
# Redirect through a process substitution rather than a pipeline. With
# `... | tee -a "$GATEWAY_LOG" &`, $! is the LAST element of the pipeline —
# tee — so cleanup() killed the logger and left the gateway running: on
# `docker stop` the gateway kept serving connections against a PostgreSQL
# that was already fast-stopping, and only died at the container SIGKILL.
# With `> >(tee ...)` the gateway itself is the backgrounded job, so $!,
# the cleanup kill, and the `wait` at the end of this script all refer to
# the process we actually mean.
"$gateway_bin" "$configFile" > >(tee -a "$GATEWAY_LOG") 2>&1 &

gateway_pid=$! # Capture the PID of the gateway process

# Wait for the gateway to be ready before attempting initialization
echo "Waiting for gateway to be ready..."
max_attempts=60
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if nc -z localhost "$DOCUMENTDB_PORT"; then
        echo "Gateway is ready on localhost:$DOCUMENTDB_PORT"
        break
    fi
    echo "Attempt $((attempt + 1))/$max_attempts: Gateway not ready yet, waiting..."
    sleep 1
    attempt=$((attempt + 1))
done

if [ $attempt -eq $max_attempts ]; then
    echo "Error: Gateway failed to start within $max_attempts seconds"
    exit 1
fi

# First-boot data-initialization markers (#612).
# Markers live inside the persistent data dir ($DATA_PATH) so they survive container
# restarts, `docker compose down && up`, host reboots, and volume backups. They make data
# initialization one-shot and prevent the restart loop caused by re-running non-idempotent
# seed scripts against already-seeded data. Like common database container images,
# initialization runs only on a fresh data directory; to re-initialize, start the container
# with an empty/new data volume.
INIT_MARKER_DIR="$DATA_PATH/.documentdb-local"

# init_marker_present <marker-file>: succeeds when initialization already ran on this volume.
init_marker_present() {
    [ -f "$1" ]
}

# write_init_marker <marker-file>: record a successful initialization. A failure to write is
# only a warning; it would cause a redundant re-init attempt on the next boot, not data loss.
write_init_marker() {
    if ! mkdir -p "$INIT_MARKER_DIR" 2>/dev/null || ! touch "$1" 2>/dev/null; then
        echo "Warning: could not write init marker $1; initialization may run again on restart."
    fi
}

# Initialize database with custom (user-provided) data if the directory has JS files.
# One-shot per data volume: init_documentdb_data.sh records $custom_attempt_marker right
# before the first user script runs, so a non-idempotent custom init that fails partway is
# not re-run on restart and cannot loop (#612). User scripts should still be idempotent.
# To re-run after fixing scripts, start with a fresh data volume.
custom_data_initialized=false
custom_attempt_marker="$INIT_MARKER_DIR/custom_data_attempted"
custom_success_marker="$INIT_MARKER_DIR/custom_data_succeeded"
if [ -d "$INIT_DATA_PATH" ] && [ "$(ls -A "$INIT_DATA_PATH"/*.js 2>/dev/null)" ] && init_marker_present "$custom_attempt_marker"; then
    if init_marker_present "$custom_success_marker"; then
        echo "Custom data already initialized (found $custom_success_marker); skipping. To re-run, start with a fresh data volume."
    else
        echo "Warning: a previous custom data initialization was attempted but its success was not recorded; it may have failed or only partially applied."
        echo "Skipping to avoid re-running non-idempotent scripts. To retry from clean, start with a fresh data volume."
    fi
    custom_data_initialized=true
elif [ -d "$INIT_DATA_PATH" ] && [ "$(ls -A "$INIT_DATA_PATH"/*.js 2>/dev/null)" ]; then
    echo "Initializing database with custom data from: $INIT_DATA_PATH"
    
    # Use the dedicated initialization script
    init_script="$SCRIPT_DIR/init_documentdb_data.sh"
    if [ -f "$init_script" ]; then
        echo "Using custom initialization data from: $INIT_DATA_PATH"
        if DOCUMENTDB_PASSWORD="$PASSWORD" "$init_script" -H localhost -P "$DOCUMENTDB_PORT" -u "$USERNAME" -d "$INIT_DATA_PATH" --attempt-marker "$custom_attempt_marker" -v; then
            echo "Custom data initialization completed."
            write_init_marker "$custom_success_marker"
            custom_data_initialized=true
        else
            echo "Error: Custom data initialization failed; it will not be retried on restart if it had begun applying data."
            echo "Fix your initialization scripts and start with a fresh data volume to re-run."
            exit 1
        fi
    else
        echo "Warning: Initialization script not found at $init_script"
    fi
fi

# Initialize database with built-in sample data if explicitly enabled.
# Guarded by a one-shot marker (in $DATA_PATH) so a restart with a persistent volume does
# not re-run the seed and crash with a duplicate-key error (#612).
sample_init_marker="$INIT_MARKER_DIR/sample_data_initialized"
if [ "$INIT_DATA" = "true" ] && init_marker_present "$sample_init_marker"; then
    echo "Sample data already initialized (found $sample_init_marker); skipping. To re-run, start with a fresh data volume."
elif [ "$INIT_DATA" = "true" ]; then
    echo "Initializing database with built-in sample data..."
    
    # Use the sample data directory
    sample_data_path="$SAMPLE_DATA_DIR"
    init_script="$SCRIPT_DIR/init_documentdb_data.sh"
    
    if [ -f "$init_script" ] && [ -d "$sample_data_path" ]; then
        echo "Loading sample data from: $sample_data_path"
        if DOCUMENTDB_PASSWORD="$PASSWORD" "$init_script" -H localhost -P "$DOCUMENTDB_PORT" -u "$USERNAME" -d "$sample_data_path" -v; then
            echo "Sample data initialization completed."
            write_init_marker "$sample_init_marker"
        else
            echo "Error: Sample data initialization failed"
            exit 1
        fi
        echo ""
        echo "Sample data has been loaded into the 'sampledb' database with the following collections:"
        echo "  - users (5 sample users)"
        echo "  - products (5 sample products)"  
        echo "  - orders (4 sample orders)"
        echo "  - analytics (sample metrics and activity data)"
        echo ""
        echo "Connect to your DocumentDB instance and use: use('sampledb')"
    else
        echo "Warning: Sample data or initialization script not found"
        if [ ! -f "$init_script" ]; then
            echo "  - Missing: $init_script"
        fi
        if [ ! -d "$sample_data_path" ]; then
            echo "  - Missing: $sample_data_path"
        fi
    fi
fi

if [ "$custom_data_initialized" = "false" ] && [ "$INIT_DATA" != "true" ]; then
    echo "No initialization data loaded."
    echo "To load data: use --init-data true for built-in sample data, or --init-data-path [PATH] for custom data."
fi
# Also stream existing gateway logs (for historical logs that might already exist)
if [ -f "$GATEWAY_LOG" ]; then
    echo "Starting gateway log streaming for existing logs..."
    tail -F "$GATEWAY_LOG" 2>/dev/null | while IFS= read -r line; do
        echo "[GATEWAY-FILE] $line"
    done &
    GATEWAY_LOG_TAIL_PID=$!
    echo "Gateway log file streaming started with PID: $GATEWAY_LOG_TAIL_PID"
fi

echo "Gateway started with PID: $gateway_pid"
echo ""
echo "=== DocumentDB is ready ==="
echo ""
echo "Connect with mongosh (replace <password> with the password you set):"
echo "  mongosh 'mongodb://${USERNAME}:<password>@localhost:${DOCUMENTDB_PORT}/mydb?tls=true&tlsAllowInvalidCertificates=true'"
echo "  (Replace mydb with any DB name; a fresh DB is created on first insert.)"
echo ""
echo "Data is stored in ${DATA_PATH}; mount a volume there (docker run -v <host-dir>:/data ...) to persist it across container recreation."
echo ""
echo "All logs are being streamed to docker logs with prefixes:"
echo "  [POSTGRES] - PostgreSQL database logs ($PG_LOG_FILE)"
echo "  [POSTGRES-SYSTEM] - System PostgreSQL logs ($SYSTEM_POSTGRES_LOG)"
echo "  [OSS-SERVER] - OSS server logs ($OSS_SERVER_LOG)"
echo "  [ENTRYPOINT] - Entrypoint script logs ($ENTRYPOINT_LOG)"
echo "  [GATEWAY] - Gateway application logs (live output via tee)"
echo "  [GATEWAY-FILE] - Gateway log file content ($GATEWAY_LOG)"
echo ""
echo "Centralized log directory structure:"
echo "  $DOCUMENTDB_LOG_DIR/"
echo "  ├── gateway_entrypoint.log"
echo "  ├── gateway.log"
echo "  ├── oss_server.log"
echo "  └── postgres/"
echo "      └── pglog.log -> $DATA_PATH/pglog.log"
echo ""
echo "View all logs with: docker logs <container_name>"
echo "View live logs with: docker logs -f <container_name>"
echo "Filter specific logs: docker logs <container_name> | grep '[PREFIX]'"
echo "Example: docker logs <container_name> | grep '[POSTGRES]'"
echo "=========================="
echo ""

# Wait for the gateway process to keep the container alive
# The wait will be interrupted by signals, allowing cleanup to run.
# The `|| gateway_rc=$?` capture matters: sourcing utils.sh above (the
# CREATE_USER=true path) turns on `set -e` plus an ERR trap, so a bare
# `wait` on a gateway that crashed with a nonzero status would abort the
# script right here — skipping the clean PostgreSQL stop below, which is
# the exact crash path it exists for.
gateway_rc=0
wait $gateway_pid || gateway_rc=$?

# Gateway self-exit path (crash/OOM/normal exit): no signal was delivered, so
# the SIGTERM/SIGINT trap never ran. Run the same cleanup the trap uses —
# including the pg_ctl fast stop — otherwise this script would simply exit as
# PID 1 and the daemonized postmaster would be SIGKILLed, forcing the WAL
# recovery on next boot that the clean stop exists to prevent. cleanup exits
# with the gateway's status so the container reports the real failure.
echo "Gateway process exited with status ${gateway_rc}."
cleanup "$gateway_rc"
