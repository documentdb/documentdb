# shellcheck shell=bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# lib/cli.sh: command line, setting defaults and validation.
#
# Sourced by emulator_entrypoint.sh; defines functions only.

# Print help message
usage() {
    local d_gw d_pg d_user d_data d_init d_log d_tls d_toast
    d_gw="$(documentdb_local_setting_default DOCUMENTDB_PORT)"
    d_pg="$(documentdb_local_setting_default POSTGRESQL_PORT)"
    d_user="$(documentdb_local_setting_default USERNAME)"
    d_data="$(documentdb_local_setting_default DATA_PATH)"
    d_init="$(documentdb_local_setting_default INIT_DATA_PATH)"
    d_log="$(documentdb_local_setting_default LOG_LEVEL)"
    d_tls="$(documentdb_local_setting_default TLS_MODE)"
    d_toast="$(documentdb_local_setting_default DOCUMENTDB_TOAST_COMPRESSION)"
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
                        Defaults to ${d_data}
                        Overrides DATA_PATH environment variable.
                        Fast first boot: the image ships a pre-initialized
                        data directory that Docker copies into fresh NAMED or
                        ANONYMOUS volumes on /data; empty custom paths are
                        populated from it too. A bind-mounted host directory
                        on /data is NOT populated by Docker, so its first
                        boot runs full initialization and is slower. The
                        cluster's locale/encoding are fixed inside the
                        pre-built directory; only a full re-initialization
                        re-reads locale environment variables.
                        If PostgreSQL reports a permission error on files a
                        previously interrupted start left behind, set
                        DOCUMENTDB_FORCE_OWNERSHIP_REPAIR=true to force a
                        full recursive ownership repair on the next start.
                        A leftover postmaster.pid from an unclean stop
                        (docker kill, OOM, host crash) is removed on the next
                        start when this image's directory lock shows its
                        postmaster wrote it. That trusts the volume's flock,
                        so a volume shared by several hosts is unsupported.
                        Any other postmaster.pid refuses
                        to start, because a container without the lock (an
                        older image) may still be serving the volume. Once no
                        other container uses it, create or recreate the
                        container with
                        DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID=true
                        (docker start cannot add it) to remove the file; it
                        stays in force on every later start until removed.
  --documentdb-port     The port of the DocumentDB endpoint on the container. 
                        You still need to publish this port (e.g. -p ${d_gw}:${d_gw}).
                        Defaults to ${d_gw}
                        Overrides DOCUMENTDB_PORT environment variable.
  --enable-telemetry <true|false>
                        Accepted but has no effect in this release. The gateway's operational
                        metrics are set by TelemetryOptions in its configuration file, which
                        ships with them off.
                        This is a separate setting from the anonymous usage telemetry below:
                        ENABLE_TELEMETRY=false does not turn that off. Use --usage-telemetry false for it.
                        Overrides ENABLE_TELEMETRY environment variable.
  --usage-telemetry <true|false>
                        Anonymous usage telemetry that reports only this image's version, platform
                        and CPU architecture at startup and periodically, so the project can count
                        running deployments. No database, collection or user names, queries, document
                        contents or credentials are ever sent. Separate from the gateway's
                        operational metrics.
                        Defaults to $(documentdb_local_setting_default DOCUMENTDB_USAGE_TELEMETRY) (on). Skipped when CI, GITHUB_ACTIONS or
                        TF_BUILD is set in this container; docker run does not forward those
                        from the host, so in a pipeline set this to false explicitly.
                        Overrides DOCUMENTDB_USAGE_TELEMETRY environment variable.
                        DOCUMENTDB_USAGE_TELEMETRY_ENDPOINT and DOCUMENTDB_USAGE_TELEMETRY_INTERVAL_S
                        tune where and how often it reports. Details in
                        /home/documentdb/PRIVACY.md in this container, or
                        https://github.com/documentdb/documentdb/blob/main/documentdb-local/PRIVACY.md
  --disable-usage-telemetry
                        Turn off the usage telemetry above. Equivalent to --usage-telemetry false.
                        Setting NO_ANALYTICS=1 or DO_NOT_TRACK=1 also turns it off and wins
                        over any enable.
  --log-level           The verbosity of the gateway's logs. DOCUMENTDB_LOG_LEVEL or RUST_LOG,
                        when set, take precedence (both accept tracing filters such as
                        documentdb_gateway=debug).
                        Overrides LOG_LEVEL environment variable.
                          $(documentdb_local_setting_allowed LOG_LEVEL)
                        Defaults to ${d_log}.
  --username            Specify the username for the DocumentDB.
                        Defaults to ${d_user}
                        Overrides USERNAME environment variable.
  --password            Password for the DocumentDB user. REQUIRED.
                        Overrides PASSWORD environment variable; both are visible to docker inspect.
                        DOCUMENTDB_ALLOW_DEFAULT_PASSWORD=true gives a newly created user the public default (evaluation only).
                        Not needed with --create-user false unless data is loaded.
  --create-user         Specify whether to create a user. 
                        Defaults to $(documentdb_local_setting_default CREATE_USER).
  --start-pg            Start PostgreSQL (default: $(documentdb_local_setting_default START_POSTGRESQL)).
                        On process loss, enable shutdown responses after a short
                        grace period; exit 1 if still down after
                        DOCUMENTDB_POSTMASTER_EXIT_TIMEOUT seconds (default 20).
                        Advanced/test use only: false requires PostgreSQL listening
                        on localhost at --pg-port. Skips server setup and
                        --toast-compression; getParameter returns undefined-function
                        rather than unsupported-command.
  --pg-port             Specify the port for the PostgreSQL server.
                        Defaults to ${d_pg}.
                        Overrides POSTGRESQL_PORT environment variable.
  --owner               Specify the owner of the DocumentDB.
                        Overrides OWNER environment variable.
                        Defaults to the current user.
  --allow-external-connections [true|false]
                        Open the container's internal PostgreSQL server to all
                        interfaces (listen_addresses='*' + a permissive pg_hba
                        entry). This does NOT affect the gateway, which always
                        listens on all interfaces on the DocumentDB port; it
                        only exposes the backend PostgreSQL port directly.
                        Defaults to $(documentdb_local_setting_default ALLOW_EXTERNAL_CONNECTIONS).
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
                        Defaults to ${d_init}
                        Overrides INIT_DATA_PATH environment variable.
  --skip-init-data      Skip initialization with built-in sample data.
                        Legacy alias for --init-data false.
                        Does not affect --init-data-path; custom data is
                        still loaded once per fresh data volume.
                        Overrides SKIP_INIT_DATA environment variable.
  --disable-extended-rum
                        Deprecated and ignored: extended_rum is always enabled
                        when a data volume is initialized. Accepted for
                        compatibility through either this flag or the
                        DISABLE_EXTENDED_RUM environment variable, and will be
                        removed in the next minor release. To use the plain rum
                        access method instead, set the PostgreSQL setting
                        documentdb.alternate_index_handler_name = 'rum' in the
                        data volume's postgresql.conf and restart the
                        container. That is the only route that reaches every
                        gateway connection: the gateway pools PostgreSQL
                        sessions per authenticated user, so a per-role setting
                        covers one role and skips already-pooled sessions, and
                        a mongosh client never holds a PostgreSQL session of
                        its own.
  --toast-compression [lz4|pglz|default]
                        Compression used for values the container's PostgreSQL
                        stores out of line (TOAST). ${d_toast} (the default)
                        decompresses faster for large documents; pglz is
                        PostgreSQL's built-in method; default leaves the
                        server's own setting alone. Affects newly written
                        values only. Values written with lz4 are readable
                        only by lz4-capable PostgreSQL builds (the images
                        this entrypoint ships in include lz4). Applies only
                        when this container starts PostgreSQL; with
                        --start-pg false it is validated and then ignored
                        with a warning.
                        Overrides DOCUMENTDB_TOAST_COMPRESSION environment variable.
  --tlsMode [MODE]      Set the TLS mode for client connections.
                        Supported modes: disabled, allowTLS, requireTLS.
                        By default, the gateway accepts both plain and TLS connections (${d_tls}).
                        disabled behaves the same as allowTLS; the gateway has no plain-only mode.
                        When set to requireTLS, plain (non-TLS) connections are rejected.
                        Overrides TLS_MODE environment variable.
EOF
}

parse_args() {
    # Handle arguments. Every value flag is looked up in the settings table and
    # exported as its environment variable, so child processes see CLI values as
    # env. Only the flags that are not "one flag, one value" are spelled here.
    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)
                usage
                exit 0 ;;
            --skip-init-data)
                # Legacy alias for --init-data false; the two variables are
                # reconciled below.
                export INIT_DATA=false
                export SKIP_INIT_DATA=true
                shift
                continue ;;
            --disable-extended-rum)
                # Deprecated bare flag retained so existing invocations start.
                export DISABLE_EXTENDED_RUM=true
                shift
                continue ;;
            --disable-usage-telemetry)
                # Negative spelling of --usage-telemetry false, matching the
                # standard opt-out wording users expect.
                export DOCUMENTDB_USAGE_TELEMETRY=false
                shift
                continue ;;
        esac
        if ! _setting_row="$(documentdb_local_setting_row_by_flag "$1")"; then
            echo "Unknown option $1" >&2
            exit 1
        fi
        _setting_var="${_setting_row#*|}"
        _setting_var="${_setting_var%%|*}"
        if [ $# -lt 2 ] || [ -z "$2" ]; then
            # A missing or empty value would read as "not set" and take the
            # default silently; fail loudly instead.
            _setting_allowed="$(documentdb_local_setting_allowed "${_setting_var}")"
            echo "$1 requires a value${_setting_allowed:+: ${_setting_allowed}}." >&2
            exit 1
        fi
        export "${_setting_var}=$2"
        shift 2
    done
    unset _setting_row _setting_var _setting_allowed
}

setting_is_explicit() {
    case "${DOCUMENTDB_LOCAL_EXPLICIT}" in
        *" $1 "*) return 0 ;;
        *) return 1 ;;
    esac
}

apply_setting_defaults() {
    # Empty would silently become allowTLS and accept plaintext; other settings may be empty.
    if [[ -v TLS_MODE && -z $TLS_MODE ]]; then
        echo "Error: TLS_MODE is set but empty; use one of $(documentdb_local_setting_allowed TLS_MODE), or unset it." >&2
        exit 1
    fi

    # Record which settings the operator supplied (CLI flag or non-empty
    # environment variable) BEFORE any default is applied. Two things read this:
    # the default-password refusal, and the TOAST resolution, which fails
    # loudly on an explicit request the build cannot honour but degrades quietly
    # for the built-in default.
    DOCUMENTDB_LOCAL_EXPLICIT=" "
    for _setting_row in "${DOCUMENTDB_LOCAL_SETTINGS[@]}"; do
        IFS='|' read -r _f _setting_var _setting_default _setting_type _setting_label <<< "${_setting_row}"
        if [ -n "${!_setting_var:-}" ]; then
            DOCUMENTDB_LOCAL_EXPLICIT="${DOCUMENTDB_LOCAL_EXPLICIT}${_setting_var} "
        elif [ -n "${_setting_default}" ] && [ "${_setting_var}" != "DOCUMENTDB_TOAST_COMPRESSION" ]; then
            # Inside the image the Dockerfile's ENV block already supplies these;
            # the table default is what makes a source-checkout run work.
            export "${_setting_var}=${_setting_default}"
        fi
    done

    # The built-in password is public; a defaulted username behind a real one is harmless.
    if ! setting_is_explicit PASSWORD; then
        if [ "${DOCUMENTDB_ALLOW_DEFAULT_PASSWORD:-false}" = "true" ]; then
            echo "WARNING: DOCUMENTDB_ALLOW_DEFAULT_PASSWORD=true: no password supplied, so the public built-in password '${PASSWORD}' is used to create user '${USERNAME}' (an existing user keeps its password; --create-user false creates none). Anyone who knows it can log in; use this only for short-lived local evaluation." >&2
        elif [ "${CREATE_USER}" = "false" ]; then
            # No user is created, so nothing gets the public password; loading data still needs the real one.
            export PASSWORD=""
        else
            cat >&2 <<'EOF'
Error: no password was supplied. Set PASSWORD (docker run -e PASSWORD=<password> ...) or pass --password <password>.
On an existing data volume, the user keeps the password it was created with.
For short-lived local evaluation only, DOCUMENTDB_ALLOW_DEFAULT_PASSWORD=true gives a newly created user the public built-in password.
EOF
            exit 1
        fi
    fi

    # The one computed default: the user this process runs as.
    export OWNER=${OWNER:-$(whoami)}
}

validate_settings() {
    # Validate every set value against its declared type. An empty value counts
    # as unset (INIT_DATA, CERT_PATH and KEY_FILE are legitimately empty).
    # Unsigned integers are also normalized to base 10 so a zero-padded value
    # such as "010260" cannot be read as octal by a later $(( )).
    for _setting_row in "${DOCUMENTDB_LOCAL_SETTINGS[@]}"; do
        IFS='|' read -r _f _setting_var _setting_default _setting_type _setting_label <<< "${_setting_row}"
        _setting_value="${!_setting_var:-}"
        [ -n "${_setting_value}" ] || continue
        case "${_setting_type}" in
            uint)
                if ! [[ "${_setting_value}" =~ ^[0-9]+$ ]]; then
                    echo "Invalid ${_setting_label} value ${_setting_value}, must be a number" >&2
                    exit 1
                fi
                export "${_setting_var}=$((10#${_setting_value}))" ;;
            bool)
                if [ "${_setting_value}" != "true" ] && [ "${_setting_value}" != "false" ]; then
                    echo "Invalid ${_setting_label} value ${_setting_value}, must be true or false" >&2
                    exit 1
                fi ;;
            boolish)
                # Accept any reasonable spelling and normalize it, rather than
                # aborting: every boolish setting is an off switch, so rejecting
                # an unusual spelling would make turning the feature off break
                # the container instead.
                if ! _setting_normalized="$(documentdb_local_parse_boolish "${_setting_value}")"; then
                    echo "Warning: unrecognized ${_setting_label} value '${_setting_value}'; treating it as false. Use true or false." >&2
                fi
                export "${_setting_var}=${_setting_normalized}" ;;
            enum:*)
                # One member, not a run of them: "allowTLS,requireTLS" is a substring of the list.
                if [[ "${_setting_value}" == *,* || ",${_setting_type#enum:}," != *",${_setting_value},"* ]]; then
                    echo "Invalid ${_setting_label} value '${_setting_value}', must be one of: $(documentdb_local_setting_allowed "${_setting_var}")" >&2
                    exit 1
                fi ;;
        esac
    done
    unset _setting_row _f _setting_var _setting_default _setting_type _setting_label _setting_value _setting_normalized

    # Cross-setting rules the table cannot express.
    if { [ -n "${CERT_PATH:-}" ] && [ -z "${KEY_FILE:-}" ]; } || \
       { [ -z "${CERT_PATH:-}" ] && [ -n "${KEY_FILE:-}" ]; }; then
        echo "Error: Both CERT_PATH and KEY_FILE must be set together, or neither should be set." >&2
        exit 1
    fi

    # SKIP_INIT_DATA is the legacy negative spelling of INIT_DATA. Reconcile
    # once, then only INIT_DATA is consulted: an unset INIT_DATA follows
    # SKIP_INIT_DATA (false enables sample data), and SKIP_INIT_DATA is rewritten
    # from the result so both read consistently.
    export SKIP_INIT_DATA=${SKIP_INIT_DATA:-}
    if [ -n "$SKIP_INIT_DATA" ] && [ "$SKIP_INIT_DATA" != "true" ] && [ "$SKIP_INIT_DATA" != "false" ]; then
        echo "Invalid skip-init-data value $SKIP_INIT_DATA, must be true or false" >&2
        exit 1
    fi
    if [ -z "${INIT_DATA:-}" ]; then
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

    # The gateway reads DOCUMENTDB_LOG_LEVEL, then RUST_LOG, never LOG_LEVEL.
    # Either one the operator set wins; "quiet" is "off" to the gateway.
    if [ -z "${DOCUMENTDB_LOG_LEVEL:-}" ] && [ -z "${RUST_LOG:-}" ]; then
        if [ "$LOG_LEVEL" = "quiet" ]; then
            export DOCUMENTDB_LOG_LEVEL=off
        else
            export DOCUMENTDB_LOG_LEVEL="$LOG_LEVEL"
        fi
    fi

    # Still accepted so existing invocations start; nothing reads it any more.
    if [ "${DISABLE_EXTENDED_RUM:-}" = "true" ]; then
        echo "Warning: --disable-extended-rum (DISABLE_EXTENDED_RUM) is deprecated and has no effect; documentdb_extended_rum is always enabled for a data volume this image initializes. To use the plain rum access method instead, set documentdb.alternate_index_handler_name = 'rum' in the data volume's postgresql.conf and restart the container. This option will be removed in the next minor release." >&2
    fi
    unset DISABLE_EXTENDED_RUM
}

check_credentials() {
    echo "Using username: $USERNAME"
    echo "Using owner: $OWNER"
    echo "Using data path: $DATA_PATH"

    # Reject a username the gateway would refuse at authentication time (a
    # BlockedRolePrefix) before starting anything, so the container never reports
    # ready with a user that can never authenticate. Pass CONFIG_DIR explicitly:
    # the validator's own default resolves to the legacy layout, while the gateway
    # is started from $CONFIG_DIR/SetupConfiguration.json (see write_gateway_config).
    bash "$entrypoint_dir/documentdb_validate_username.sh" \
        "$USERNAME" "$CONFIG_DIR/SetupConfiguration.json" || exit 1
}
