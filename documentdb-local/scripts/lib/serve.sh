# shellcheck shell=bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# lib/serve.sh: the rest of the boot, from the admin user on: gateway launch,
# seed data, health-check state, readiness banner and supervision.
#
# Runs when sourced, at script scope: the errexit, ERR trap and variables that
# utils.sh brings in must reach the rest of this file, and the helpers defined
# below must come after utils.sh so they win over same-named functions there.

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
            # log_min_error_statement defaults to logging the failing
            # statement text, which here carries the password. Keep the
            # SETs and the SELECT on this one connection. VERBOSITY=terse
            # stops psql itself echoing a "LINE 1:" excerpt to stderr.
            printf '%s\n' \
                "SET log_statement = 'none';" \
                "SET log_min_duration_statement = -1;" \
                "SET log_min_error_statement = 'panic';" \
                "SELECT documentdb_api.create_user('${doc_sql}');" \
                | psql -p "$port" -U "$owner" -d postgres -X -v ON_ERROR_STOP=1 -v VERBOSITY=terse
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
        echo "Waiting for PostgreSQL to be ready on localhost:$POSTGRESQL_PORT before creating the admin user..."
        if ! wait_for_pg_ready 600; then
            echo "Error: PostgreSQL did not become ready on localhost:$POSTGRESQL_PORT within ${pg_ready_timeout}s; cannot create the admin user." >&2
            exit 1
        fi
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
# at creation time: every `jq ... > "$configFile.tmp" && mv` in
# write_gateway_config (lib/gateway.sh) replaces
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

# Wait for the gateway to be ready before attempting initialization. Poll at a
# sub-second interval so readiness is detected promptly, but only
# log once per second to keep the container log readable.
echo "Waiting for gateway to be ready..."
max_attempts=240
attempt=0
while [ $attempt -lt $max_attempts ]; do
    if nc -z localhost "$DOCUMENTDB_PORT"; then
        echo "Gateway is ready on localhost:$DOCUMENTDB_PORT"
        break
    fi
    if [ $((attempt % 4)) -eq 0 ]; then
        echo "Attempt $((attempt / 4 + 1))/60: Gateway not ready yet, waiting..."
    fi
    sleep 0.25
    attempt=$((attempt + 1))
done

if [ $attempt -eq $max_attempts ]; then
    echo "Error: Gateway failed to start within 60 seconds"
    exit 1
fi

# First-boot data-initialization markers.
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
# not re-run on restart and cannot loop. User scripts should still be idempotent.
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
# not re-run the seed and crash with a duplicate-key error.
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
        echo "Sample data has been loaded into the 'StoreData' database with the following collections:"
        echo "  - stores (41,505 sample stores)"
        echo "  - ratings (2 sample ratings)"
        echo ""
        echo "Connect to your DocumentDB instance and use: use('StoreData')"
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

# Publish the resolved runtime settings for healthcheck.sh. This runs after
# gateway readiness and data initialization so the healthcheck only reports
# healthy on a fully initialized database, and it records the ports actually
# in use — which may come from CLI flags that HEALTHCHECK / `docker exec`
# sessions cannot see in their environment. Written via a temp file + mv so
# the healthcheck never reads a partially written file. A write failure is
# not fatal to the database, but the container will keep reporting unhealthy,
# so warn loudly.
if printf 'DOCUMENTDB_PORT=%s\nPOSTGRESQL_PORT=%s\n' \
        "$DOCUMENTDB_PORT" "$POSTGRESQL_PORT" \
        > "${DOCUMENTDB_RUNTIME_STATE_FILE}.tmp" \
        && mv "${DOCUMENTDB_RUNTIME_STATE_FILE}.tmp" "$DOCUMENTDB_RUNTIME_STATE_FILE"; then
    echo "Runtime state for the health check written to $DOCUMENTDB_RUNTIME_STATE_FILE"
else
    echo "Warning: could not write $DOCUMENTDB_RUNTIME_STATE_FILE; the container health check will keep reporting unhealthy." >&2
fi

# Start the anonymous usage-telemetry emitter. Started only after the gateway
# is serving so a launch event means a deployment that actually came up, and
# backgrounded with its PID in the cleanup trap so it stops with everything
# else. The script exits immediately when telemetry is disabled or opted out,
# and every request it makes is fire-and-forget, so nothing here can delay or
# fail the container.
telemetry_script="$SCRIPT_DIR/usage_telemetry.sh"
if [ -f "$telemetry_script" ]; then
    bash "$telemetry_script" &
    USAGE_TELEMETRY_PID=$!
else
    echo "Warning: usage telemetry emitter not found at $telemetry_script; skipping." >&2
fi

echo ""
echo "=== DocumentDB is ready ==="
echo ""
echo "Connect with mongosh (replace <password> with the password you set):"
echo "  mongosh 'mongodb://${USERNAME}:<password>@localhost:${DOCUMENTDB_PORT}/mydb?tls=true&tlsAllowInvalidCertificates=true'"
echo "  (Replace mydb with any DB name; a fresh DB is created on first insert.)"
echo ""
echo "Data is stored in ${DATA_PATH}; mount a volume there to persist it across container recreation."
echo "  Named volume (fast first boot, recommended): docker run -v mydata:${DATA_PATH} ..."
echo "  Host directory (first boot runs a slower full initialization): docker run -v <host-dir>:${DATA_PATH} ..."
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

# Watch the owned postmaster: enable shutdown responses after 3 missed polls,
# exit after the timeout, and clear shutdown mode once connections resume.
# Keep waits interruptible and capture gateway failures so set -e cannot skip cleanup.
gateway_rc=0
if [ "${START_POSTGRESQL:-}" = "true" ]; then
    postmaster_running() {
        local pid executable
        pid="$(sed -n 1p "$DATA_PATH/postmaster.pid" 2>/dev/null | tr -dc 0-9)"
        [ -n "$pid" ] || return 1
        executable="$(readlink "/proc/$pid/exe" 2>/dev/null)" || return 1
        [ "${executable##*/}" = "postgres" ] && [ "$DATA_PATH" -ef "/proc/$pid/cwd" ]
    }

    postmaster_exit_timeout="$(sanitize_uint "${DOCUMENTDB_POSTMASTER_EXIT_TIMEOUT:-20}" 20 DOCUMENTDB_POSTMASTER_EXIT_TIMEOUT)"
    postmaster_exit_timeout=$((10#$postmaster_exit_timeout))
    postmaster_down_for=0
    backend_marked_down=false
    while kill -0 "$gateway_pid" 2>/dev/null; do
        if postmaster_running; then
            postmaster_down_for=0
            if [ "$backend_marked_down" = "true" ] \
                    && pg_isready -q -h localhost -p "$POSTGRESQL_PORT" -t 1 >/dev/null 2>&1 \
                    && write_host_config false; then
                backend_marked_down=false
                echo "PostgreSQL is accepting connections again; the gateway serves requests normally."
            fi
        else
            postmaster_down_for=$((postmaster_down_for + 1))
            if [ "$postmaster_down_for" -gt "$postmaster_exit_timeout" ]; then
                echo "Error: PostgreSQL has not been running for ${postmaster_exit_timeout} seconds; stopping the container. See the PostgreSQL server log at $DATA_PATH/pglog.log." >&2
                exit 1
            elif [ "$postmaster_down_for" -ge 3 ] && [ "$backend_marked_down" = "false" ] \
                    && [ -n "$hostConfigFile" ] && write_host_config true; then
                backend_marked_down=true
                echo "Warning: PostgreSQL is not running; the gateway answers requests with ShutdownInProgress (91) until it is back." >&2
            fi
        fi
        sleep 1 &
        wait $! || true
    done
fi
wait $gateway_pid || gateway_rc=$?

# Stop PostgreSQL even when the gateway exits without a signal.
echo "Gateway process exited with status ${gateway_rc}."
exit "$gateway_rc"
