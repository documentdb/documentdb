#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-setup — the stand-alone package's setup wizard. Single
# orchestration command after `apt install documentdb`. Handles
# greenfield (initdb a private PostgreSQL instance) and brownfield
# (adopt an existing PostgreSQL instance via --target-postgres-instance)
# with backup-and-rollback safety around every invasive change.
# Delegates postgresql.conf to documentdb-tune and hba/ident/role/
# connection-URL-file to documentdb-register-gateway per
# packaging-design.md §4.4.

set -euo pipefail

# Restrict default permissions so temp files are never world-readable.
umask 077

SCRIPT_SOURCE="${BASH_SOURCE[0]}"
while [[ -L "${SCRIPT_SOURCE}" ]]; do
    SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
    SCRIPT_SOURCE="$(readlink "${SCRIPT_SOURCE}")"
    [[ "${SCRIPT_SOURCE}" != /* ]] && SCRIPT_SOURCE="${SCRIPT_DIR}/${SCRIPT_SOURCE}"
done
SCRIPT_DIR="$(cd -P "$(dirname "${SCRIPT_SOURCE}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

readonly POSTGRES_CONF_BLOCK_START="# >>> documentdb-setup managed configuration >>>"
readonly POSTGRES_CONF_BLOCK_END="# <<< documentdb-setup managed configuration <<<"
readonly POSTGRES_LISTEN_BLOCK_START="# >>> documentdb-setup managed listen >>>"
readonly POSTGRES_LISTEN_BLOCK_END="# <<< documentdb-setup managed listen <<<"
readonly PG_HBA_BLOCK_START="# >>> documentdb-setup managed hba >>>"
readonly PG_HBA_BLOCK_END="# <<< documentdb-setup managed hba <<<"
readonly PG_IDENT_BLOCK_START="# >>> documentdb-setup managed pg_ident >>>"
readonly PG_IDENT_BLOCK_END="# <<< documentdb-setup managed pg_ident <<<"
readonly POSTGRES_SERVICE_ENV_FILE="/etc/documentdb/documentdb-postgresql.env"
# The prior sentinel was 9712 (the legacy dev port from earlier developer
# instructions). That was confusing and
# brittle because contributors mistook it for an intentional default. Use 0
# (an invalid TCP port — IANA reserved) so the value is obviously a sentinel
# that MUST be replaced by the per-major default (9700 + PG_VERSION) once
# PostgreSQL detection completes. The range validation later in
# parse_arguments catches any case where this leaks through. Equality checks
# `[[ PG_PORT == DEFAULT_PG_PORT ]]` continue to work as the "still at
# sentinel default" discriminator without further refactoring.
readonly DEFAULT_PG_PORT="0"
readonly DEFAULT_GATEWAY_PORT="10260"
readonly DEFAULT_DATA_DIR="/var/lib/documentdb-local/data"
readonly DEFAULT_PG_SOCKET_DIR="/run/documentdb-local/postgresql"
# Must match the meta packages' default major (build-meta-deb.sh
# DEFAULT_PG_MAJOR and documentdb-local-meta.spec %define default_pg_major);
# a contract test pins all three together. Bump them in lockstep.
readonly PUBLIC_ALIAS_PG_MAJOR="18"
PG_SOCKET_DIR="${DEFAULT_PG_SOCKET_DIR}"

VERBOSE=false
USERNAME=""
PASSWORD=""
PASSWORD_FILE=""
PASSWORD_FROM_STDIN=false
TLS_CERT_FILE=""
TLS_KEY_FILE=""
TLS_AUTO_GENERATE=""
TEMP_FILES=()
# Deliberately NOT inherited from the environment: an exported PG_VERSION
# (e.g. left over from a PostgreSQL build workflow in a root shell) is not
# treated as authoritative for version selection (auto-detect re-pins it),
# but it USED to leak into the parse-time port/data-dir defaults — a PG 18
# host with PG_VERSION=15 exported got its cluster initdb'd into
# /var/lib/documentdb-local/15/data on port 9715 while state was recorded
# under /etc/documentdb/local/18/. Version selection is CLI-only
# (--pg-version); the env var is ignored.
PG_VERSION=""
PG_VERSION_EXPLICIT=false
PG_PORT=""
PG_PORT_EXPLICIT=false
GATEWAY_PORT="${DEFAULT_GATEWAY_PORT}"
GATEWAY_PORT_EXPLICIT=false
DATA_DIR=""
DATA_DIR_EXPLICIT=false
NO_ENABLE=false
LOAD_SAMPLE_DATA=false
YES=false
DRY_RUN=false
RESTORE=false
PRINT_CONFIG=false
STATUS_ONLY=false
USE_PRIVATE_CLUSTER=false
TARGET_CLUSTER=""
PG_OWNER=""

GATEWAY_BINARY=""
CONFIG_FILE=""
SAMPLE_DATA_DIR=""
INIT_DATA_SCRIPT=""
HAS_WORKING_SYSTEMD=false
HAS_EXTENDED_RUM=false
EXTENSION_CONTROL_FILE=""
EXTENDED_RUM_CONTROL_FILE=""
PG_BIN_DIR=""
PG_CONFIG=""
INITDB=""
PG_CTL=""
PSQL=""
PG_ISREADY=""
LIVE_DATA_DIR=""
LIVE_CONFIG_FILE=""
LIVE_HBA_FILE=""
LIVE_IDENT_FILE=""
LIVE_PRELOAD_LIBRARIES=""
PG_CONFIG_CHANGED=false
PG_RELOAD_CHANGED=false
GATEWAY_WAS_ACTIVE=false

error() {
    local line_number="$1"
    local exit_code="${2:-1}"
    cleanup_temp_files
    echo "Error on or near line ${line_number}; exiting with status ${exit_code}" >&2
    exit "${exit_code}"
}
trap 'error ${LINENO} $?' ERR
trap cleanup_temp_files EXIT

usage() {
    cat <<'EOF'
Usage: documentdb-setup [OPTIONS]

Appliance setup wizard for DocumentDB Local.

Required:
  --admin-user <USER>    Admin username to create (also: --username).
                         When omitted on an interactive terminal the
                         wizard prompts (default: "admin").

Authentication (one of the following; interactive prompt is the default):
  --admin-password-file <FILE>  Read the admin password from a file
                         (also: --password-file; for non-interactive/CI use).
                         File should be mode 0600.
  --admin-password-stdin Read the admin password from stdin (single line).
                         Best practice for piping a secret without
                         touching disk:
                           printf '%s' "$PW" | sudo documentdb-setup ... \
                             --admin-password-stdin
  DOCUMENTDB_PASSWORD    Environment variable alternative (DEPRECATED —
                         leaks via /proc/<pid>/environ; prefer
                         --admin-password-file or --admin-password-stdin).
  (interactive prompt)   Default when running on a TTY without the above.

TLS for the gateway listener (all three are pass-through to the per-major
gateway env file; design §4.3 is the source of truth on precedence):
  --tls-cert <FILE>      PEM certificate file; must be paired with --tls-key.
  --tls-key  <FILE>      PEM private key file; must be paired with --tls-cert.
  --tls-auto-generate <true|false>
                         Force or disable auto-generated self-signed
                         certificate. Defaults to true when neither
                         --tls-cert nor --tls-key is set (the design's
                         standalone default).

Options:
  --pg-version <VER>      PostgreSQL version (auto-detected if not specified)
  --pg-port <PORT>        PostgreSQL port (default: 9700 + PG_VERSION)
  --listen-port <PORT>    Gateway listen port (default: 10260; also: --gateway-port)
  --data-dir <DIR>        PostgreSQL data directory
                          (default: /var/lib/documentdb-local/<VER>/data)
  --use-new-postgres-instance
                          Force greenfield: initdb a new private instance
                          (also: --use-private-cluster, deprecated)
  --target-postgres-instance <V/C>
                          Brownfield: adopt an existing PostgreSQL instance
                          named by its distro identifier (e.g., 18/main)
                          (also: --target-cluster, deprecated)
                          On an interactive terminal, if neither this nor
                          --use-new-postgres-instance is given and an adoptable
                          instance exists, the wizard offers to adopt it.
  --yes                   Non-interactive (no confirmation prompts)
  --dry-run               Preview changes without writing
  --restore               Remove managed configuration blocks and revert.
                          Sweeps every registered major by default (asks for
                          confirmation when more than one is found); combine
                          with --pg-version N to detach a single major, or
                          with --dry-run to preview without changing anything.
  --print-config          Print the resolved per-major config (paths, ports,
                          systemd units) the wizard would use, and exit. No
                          side effects.
  --status                Report the current per-major installation state
                          (PG service active, gateway service active, ports
                          listening, admin user exists), and exit.
  --no-enable             Do not start the gateway after setup
  --load-sample-data      Load built-in sample data after setup (requires mongosh)
  --skip-init-data        Skip the post-setup sample-data ingest step (the default
                          when neither --load-sample-data nor --skip-init-data
                          is passed)
  --verbose               Show detailed output
  -h, --help              Show this help message
EOF
}

log_info() {
    echo "[documentdb-setup] $*"
}

log_warn() {
    echo "[documentdb-setup] WARNING: $*" >&2
}

log_verbose() {
    if [[ "${VERBOSE}" == "true" ]]; then
        echo "[documentdb-setup] $*" >&2
    fi
}

log_success() {
    echo "[documentdb-setup] SUCCESS: $*"
}

die() {
    echo "[documentdb-setup] ERROR: $*" >&2
    exit 1
}

cleanup_temp_files() {
    if (( ${#TEMP_FILES[@]} == 0 )); then
        return 0
    fi

    rm -f "${TEMP_FILES[@]}" 2>/dev/null || true
    TEMP_FILES=()
}

register_temp_file() {
    TEMP_FILES+=("$1")
}

create_temp_file() {
    local target_var="$1"
    local template="${2:-}"
    local created_file=""
    local -n target_ref="${target_var}"

    if [[ -n "${template}" ]]; then
        created_file="$(mktemp "${template}")"
    else
        created_file="$(mktemp)"
    fi

    register_temp_file "${created_file}"
    target_ref="${created_file}"
}

# Create a temp file in the target file's directory (so the eventual mv is an
# atomic same-filesystem rename — a bare $(mktemp) lands in $TMPDIR/tmp, which
# is frequently a separate tmpfs on systemd hosts, degrading the mv to a
# non-atomic copy-then-unlink that can leave a truncated live config behind and
# leak config contents into /tmp). Registers the path for cleanup and assigns
# it to the caller-named variable. Satisfies documentdb-tools-lib.sh's contract.
create_temp_in_dir() {
    local var_name="$1"
    local target_dir="$2"
    local tmp_path=""
    tmp_path="$(mktemp "${target_dir}/.documentdb-setup.XXXXXX")" \
        || die "Failed to create temp file in ${target_dir}."
    register_temp_file "${tmp_path}"
    printf -v "${var_name}" '%s' "${tmp_path}"
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

preserve_file_metadata() {
    local source_file="$1"
    local target_file="$2"
    # Note: --reference is GNU coreutils-specific (Linux). This is acceptable
    # because the script targets DEB/RPM Linux packaging only.
    if [[ -e "${source_file}" ]]; then
        chown --reference="${source_file}" "${target_file}"
        chmod --reference="${source_file}" "${target_file}"
    fi
}

# ── Managed-block helpers (shared) ──────────────────────────────────
#
# The managed-block / config-mutation primitives and shared_preload_libraries
# helpers are single-sourced from
# documentdb-tools-lib.sh so documentdb-setup cannot drift from documentdb-tune
# and documentdb-register-gateway. Sourcing the library also makes every
# managed-block rewrite atomic — temp files are created in the target file's
# directory via create_temp_in_dir, so the final mv is a same-filesystem rename
# rather than a copy-then-unlink that could truncate a live config on a crash or
# leak config contents into /tmp — and fail-closed on a torn/unbalanced block.
# The library lives beside this script in a dev checkout and at
# /usr/share/documentdb/scripts/ when installed (documentdb-N hard-depends on
# the documentdb-postgresql-tools package that ships it). Die / log_verbose /
# create_temp_in_dir (defined above) and HAS_EXTENDED_RUM (set by
# detect_extended_rum) satisfy the library's host contract;
# has_line_outside_managed_block below is documentdb-setup-specific and calls
# the shared strip_managed_block. prepend_with_managed_block is single-sourced
# from the library so the tools cannot drift on this security-sensitive helper.
_DDB_TOOLS_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for _ddb_cand in "${_DDB_TOOLS_LIB_DIR}/documentdb-tools-lib.sh" \
                 "/usr/share/documentdb/scripts/documentdb-tools-lib.sh"; do
    if [[ -f "${_ddb_cand}" ]]; then
        # shellcheck source=documentdb-tools-lib.sh
        source "${_ddb_cand}"
        _DDB_TOOLS_LIB_LOADED=1
        break
    fi
done
[[ "${_DDB_TOOLS_LIB_LOADED:-}" == "1" ]] \
    || die "cannot locate documentdb-tools-lib.sh (looked beside ${BASH_SOURCE[0]} and in /usr/share/documentdb/scripts)."

has_line_outside_managed_block() {
    local target_file="$1"
    local block_start="$2"
    local block_end="$3"
    local line_to_find="$4"
    local stripped_file=""

    create_temp_in_dir stripped_file "$(dirname "${target_file}")"
    strip_managed_block "${target_file}" "${block_start}" "${block_end}" > "${stripped_file}"
    if grep -Fqx "${line_to_find}" "${stripped_file}"; then
        rm -f "${stripped_file}"
        return 0
    fi
    rm -f "${stripped_file}"
    return 1
}

update_json_file() {
    local json_file="$1"
    local temp_file=""
    create_temp_in_dir temp_file "$(dirname "${json_file}")"

    jq \
        --argjson pgport "${PG_PORT}" \
        --argjson gwport "${GATEWAY_PORT}" \
        --arg pguser "documentdb-local" \
        --arg pghost "${PG_SOCKET_DIR}" \
        '.PostgresPort = $pgport
         | .GatewayListenPort = $gwport
         | .PostgresSystemUser = $pguser
         | .PostgresDataUser = $pguser
         | .PostgresHostName = $pghost' \
        "${json_file}" > "${temp_file}"

    preserve_file_metadata "${json_file}" "${temp_file}"
    mv "${temp_file}" "${json_file}"
}

resolve_password() {
    if [[ -n "${PASSWORD_FILE}" ]]; then
        if [[ "${PASSWORD_FROM_STDIN}" == "true" ]]; then
            die "--admin-password-file and --admin-password-stdin are mutually exclusive."
        fi
        [[ -r "${PASSWORD_FILE}" ]] || die "--admin-password-file ${PASSWORD_FILE} is not readable."
        # Warn if password file is world-readable
        local file_perms
        file_perms="$(stat -c '%a' "${PASSWORD_FILE}" 2>/dev/null || true)"
        if [[ -n "${file_perms}" && "${file_perms}" != "600" && "${file_perms}" != "400" ]]; then
            log_warn "Password file ${PASSWORD_FILE} has permissions ${file_perms} (recommended: 0600). Other users on this system may be able to read it."
        fi
        PASSWORD="$(< "${PASSWORD_FILE}")"
    elif [[ "${PASSWORD_FROM_STDIN}" == "true" ]]; then
        # Read a single line (strip trailing newline) from stdin. Best
        # practice for "pipe a secret without touching disk" — see
        # `docker login --password-stdin`, `gh auth login --with-token`.
        # If stdin is a TTY we refuse rather than block waiting on the
        # operator to type the password without an echo prompt: that
        # would be confusing UX. Operator should use the interactive
        # prompt path (default when no auth flag is supplied) instead.
        if [[ -t 0 ]]; then
            die "--admin-password-stdin requires the password on stdin (e.g. 'printf %s \"\$PW\" | sudo documentdb-setup ... --admin-password-stdin'). Stdin is a TTY; omit the flag to use the interactive prompt."
        fi
        # `IFS= read -r` reads one line preserving leading/trailing
        # whitespace except the trailing newline. Allow non-zero exit
        # from `read` when there's no trailing newline on the pipe.
        IFS= read -r PASSWORD || true
    elif [[ -n "${DOCUMENTDB_PASSWORD:-}" ]]; then
        # Deprecation warning for the env-var path is printed earlier
        # in main so it surfaces even in --dry-run / --print-config /
        # --status. Here we just consume the value.
        PASSWORD="${DOCUMENTDB_PASSWORD}"
    elif [[ "${YES}" == "true" ]]; then
        # Non-interactive (--yes) with no password source: fail fast with an
        # actionable message instead of falling through to a hidden interactive
        # prompt that would block an automated/CI run on a TTY.
        die "--yes was given but no admin password source was provided. Supply --admin-password-file FILE or pipe the password via --admin-password-stdin, or drop --yes to be prompted interactively."
    elif [[ -t 0 ]]; then
        # Interactive TTY: prompt for password (re-prompt on mismatch instead of
        # aborting, so a beginner who mistypes the confirmation gets another try
        # rather than re-running the whole wizard).
        local pw_confirm=""
        local pw_attempts=0
        while true; do
            read -r -s -p "[documentdb-setup] Enter admin password: " PASSWORD
            echo ""
            read -r -s -p "[documentdb-setup] Confirm admin password: " pw_confirm
            echo ""
            [[ "${PASSWORD}" == "${pw_confirm}" ]] && break
            pw_attempts=$((pw_attempts + 1))
            if (( pw_attempts >= 3 )); then
                die "Passwords did not match after ${pw_attempts} attempts."
            fi
            echo "[documentdb-setup] Passwords do not match; please try again." >&2
        done
    fi

    [[ -n "${PASSWORD}" ]] || die "A password is required. Use --admin-password-file, --admin-password-stdin, set DOCUMENTDB_PASSWORD (deprecated), or run interactively to be prompted."
}

create_documentdb_user() {
    local owner="$1"
    local port="$2"
    local username="$3"
    local password="$4"
    local user_bson=""
    local user_bson_file=""

    local password_file=""

    create_temp_file password_file
    printf '%s' "${password}" > "${password_file}"
    chmod 600 "${password_file}"

    user_bson="$(
        jq -cn \
            --arg user "${username}" \
            --rawfile pwd "${password_file}" \
            '{createUser: $user, pwd: $pwd, roles: [{role: "readWriteAnyDatabase", db: "admin"}, {role: "clusterAdmin", db: "admin"}]}'
    )"
    rm -f "${password_file}"

    create_temp_file user_bson_file
    printf '%s' "${user_bson}" > "${user_bson_file}"
    chmod 600 "${user_bson_file}"
    chown "${owner}" "${user_bson_file}"

    # Idempotency guard (S38 fix): a previous successful run of this
    # wizard already created the admin user; the SQL would otherwise
    # fail on the duplicate. Capture stderr, treat "already exists"
    # as success (with a clear log line telling the operator how to
    # rotate the password instead), re-raise any other error.
    #
    # This matters for:
    #  - operators re-running `documentdb-setup` after a transient
    #  failure in a later step (idempotent re-try)
    #  - configuration-management tools (Ansible/Puppet/Chef) that
    #  converge the wizard on every run
    #  - the recovery path where setup partially succeeded and the
    #  operator wants to re-run to finish
    local create_output=""
    local create_rc=0
    create_output="$(run_as_user "${owner}" env "USER_BSON_FILE=${user_bson_file}" \
            "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${port}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL' 2>&1
-- Suppress statement logging so the password embedded in the BSON payload is
-- not written to the PostgreSQL log (log_statement / log_min_duration_statement
-- / log_min_error_statement). Mirrors documentdb-gateway-admin.sh.
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_error_statement = 'panic';
\set user_bson `cat "$USER_BSON_FILE"`
SELECT documentdb_api.create_user(:'user_bson'::documentdb_core.bson);
SQL
    )" || create_rc=$?

    if (( create_rc == 0 )); then
        [[ "${VERBOSE}" == "true" && -n "${create_output}" ]] && printf '%s\n' "${create_output}"
        return 0
    fi

    # Match common phrasings the DocumentDB user-management API uses
    # for "this user is already here": both English-style and any future
    # error-code-bearing variants land in stderr text we can scan.
    if [[ "${create_output}" == *"already exists"* ]] \
            || [[ "${create_output}" == *"User exists"* ]]; then
        log_info "Admin user '${username}' already exists; skipping bootstrap (idempotent re-run)."
        log_info "Rotate the password with: sudo documentdb-gateway-admin reset-password --username ${username} --password-stdin"
        return 0
    fi

    # Some other failure — restore the captured output for diagnostics
    # and propagate the failure so the wizard's overall trap fires.
    printf '%s\n' "${create_output}" >&2
    return "${create_rc}"
}

run_as_user() {
    local target_user="$1"
    shift

    if command_exists runuser; then
        runuser -u "${target_user}" -- "$@"
    elif command_exists sudo; then
        sudo -u "${target_user}" "$@"
    else
        local quoted_command=""
        quoted_command="$(printf '%q ' "$@")"
        su -s /bin/bash "${target_user}" -c "${quoted_command}"
    fi
}

run_as_user_shell() {
    local target_user="$1"
    local shell_command="$2"

    if command_exists runuser; then
        runuser -u "${target_user}" -- bash -lc "${shell_command}"
    elif command_exists sudo; then
        sudo -u "${target_user}" bash -lc "${shell_command}"
    else
        su -s /bin/bash "${target_user}" -c "${shell_command}"
    fi
}
find_listener_pid() {
    local port="$1"
    local pid=""

    if command_exists lsof; then
        pid="$(lsof -tiTCP:"${port}" -sTCP:LISTEN 2>/dev/null | head -n 1 || true)"
    fi

    if [[ -z "${pid}" ]] && command_exists ss; then
        pid="$(ss -ltnp "( sport = :${port} )" 2>/dev/null \
            | grep -oE 'pid=[0-9]+' \
            | head -n 1 \
            | cut -d= -f2 || true)"
    fi

    # lsof/ss may be missing in containers or minimal hosts. /proc/net/tcp{,6}
    # names the port's LISTEN-socket inode(s); as root (which every mutating
    # wizard path is, via require_root) the owning PID is then found by
    # scanning /proc/<pid>/fd for socket:[inode]. Only when that scan cannot
    # answer (unprivileged caller, hidepid without root, a listener in a
    # sibling pid-namespace sharing our netns) does the historical "1"
    # placeholder survive — callers keep their placeholder branches as the
    # degraded path. No early-exit pipes here: a `| head -1` would SIGPIPE the
    # producer and, under `set -o pipefail`, abort the wizard.
    if [[ -z "${pid}" && -r /proc/net/tcp ]]; then
        local _inodes _proc _fd _tgt _ino
        _inodes="$(port_listen_inodes "${port}")"
        if [[ -n "${_inodes}" ]]; then
            for _proc in /proc/[0-9]*; do
                [[ -d "${_proc}/fd" && -r "${_proc}/fd" ]] || continue
                for _fd in "${_proc}"/fd/*; do
                    _tgt="$(readlink "${_fd}" 2>/dev/null || true)"
                    for _ino in ${_inodes}; do
                        if [[ "${_tgt}" == "socket:[${_ino}]" ]]; then
                            pid="${_proc#/proc/}"
                            break 3
                        fi
                    done
                done
            done
            [[ -n "${pid}" ]] || pid="1"
        fi
    fi

    printf '%s' "${pid}"
}

# die_unknown_listener_owner <port> [kind]
#
# kind: "gateway" (default) or "postgres". The remedy is caller-appropriate: a
# PG-port caller must NOT be told to pkill the gateway daemon (wrong process,
# won't free the PG port), and no caller gets an unqualified host-wide pkill —
# the gateway hint names its blast radius (all majors) so an operator can make
# an informed choice.
die_unknown_listener_owner() {
    local port="$1"
    local kind="${2:-gateway}"
    local common="Port ${port} is already in use, but the owning process ID could not be determined safely (lsof/ss unavailable, or /proc/net could confirm a listener but not its owner). Install lsof or iproute2 so the owner can be identified, or stop the listener yourself, then rerun."
    if [[ "${kind}" == "postgres" ]]; then
        die "${common} If this port holds a PostgreSQL instance you manage, stop that PostgreSQL service (systemctl/pg_ctl for its cluster); do NOT assume it is a DocumentDB gateway."
    else
        die "${common} If this is a DocumentDB gateway from a PREVIOUS package version (which wrote no per-port record), stop it manually — note that 'pkill -f /usr/lib/documentdb-gateway/documentdb-gateway-daemon' would stop EVERY major's gateway on this host, so on a multi-major host identify the right one (by its --config path) before signalling."
    fi
}
wait_for_listener_to_clear() {
    local port="$1"
    local timeout_seconds="${2:-30}"
    local attempt=0
    local max_attempts=$(( timeout_seconds * 10 ))

    # EXISTENCE-only probe, never find_listener_pid: this loop polls up to
    # 10×/second, and find_listener_pid's no-ss/lsof fallback now performs a
    # full /proc fd sweep to IDENTIFY the owner — identification this loop
    # does not need. When /proc/net/tcp is readable the inode listing answers
    # "is anyone listening" in one awk; otherwise fall back to
    # find_listener_pid, whose expensive branch is unreachable in exactly
    # that case (it is gated on the same -r /proc/net/tcp).
    while (( attempt < max_attempts )); do
        if [[ -r /proc/net/tcp ]]; then
            [[ -n "$(port_listen_inodes "${port}")" ]] || return 0
        else
            [[ -n "$(find_listener_pid "${port}")" ]] || return 0
        fi
        sleep 0.1
        attempt=$(( attempt + 1 ))
    done

    return 1
}

# listener_looks_like_postgres <pid> [port]
#
# The optional <port> is required to classify the "1" placeholder PID on a
# no-systemd host: without it that case stays fail-closed, because there is no
# port-scoped record to consult.
listener_looks_like_postgres() {
    local pid="$1"
    local port="${2:-}"
    local command_name=""
    local command_line=""

    command_name="$(ps -o comm= -p "${pid}" 2>/dev/null | awk '{print $1}' || true)"
    command_line="$(ps -o args= -p "${pid}" 2>/dev/null || true)"

    if [[ "${command_name}" == "postgres" || "${command_name}" == "postmaster" ]]; then
        return 0
    fi

    if [[ "${command_line}" == *postgres* ]]; then
        return 0
    fi

    # find_listener_pid returns the
    # literal "1" placeholder when neither lsof nor ss is installed and
    # /proc/net/tcp only confirms a listener exists but can't enumerate
    # owners. On a systemd host, fall back to checking whether our PG
    # services are active — if so, the listener is in fact PG. Without
    # this, the wizard's pre-flight on the PG port wrongly reports
    # "non-PostgreSQL process" when ss/lsof aren't available (common in
    # container images) and a previous wizard run is recovering from
    # Ctrl-C-mid-setup.
    if [[ "${pid}" == "1" ]] && [[ "${HAS_WORKING_SYSTEMD:-}" == "true" ]]; then
        if systemctl list-units --state=active --no-legend --plain 2>/dev/null \
                | awk '{print $1}' \
                | grep -Eq '^documentdb-postgresql@[0-9]+\.service$'; then
            return 0
        fi
        # Also accept a system PG (brownfield adoption / Workflow A)
        if systemctl list-units --state=active --no-legend --plain 2>/dev/null \
                | awk '{print $1}' \
                | grep -Eq '^postgresql(@[0-9]+-[^.]+)?\.service$|^postgresql-[0-9]+\.service$'; then
            return 0
        fi
    fi

    # No-systemd twin of the fallback above (containers without ss/lsof PID
    # visibility, e.g. Docker without SYS_PTRACE). Consult OUR cluster's own
    # postmaster.pid, which records the port it serves, so this answers "is
    # the process on THIS port the cluster we manage?".
    #
    # The previous form asked whether ANY postmaster was alive anywhere on the
    # host. That is true on virtually every host the wizard runs on — its own
    # PG, another major's, or a distro cluster — so an unidentifiable listener
    # was accepted as PostgreSQL regardless of who actually held the port.
    # Combined with the ownership skip in resolve_live_cluster_metadata, that
    # let the wizard adopt and rewrite a PostgreSQL instance it did not own.
    if [[ "${pid}" == "1" ]] && [[ "${HAS_WORKING_SYSTEMD:-}" != "true" ]] \
            && [[ -n "${port}" ]]; then
        if postmaster_pid_owns_port "${port}"; then
            return 0
        fi
    fi

    return 1
}

# listener_looks_like_gateway <pid> [port]
#
# The optional <port> is required to classify the "1" placeholder PID on a
# no-systemd host: without it that case stays fail-closed, because there is no
# port-scoped record to consult.
listener_looks_like_gateway() {
    local pid="$1"
    local port="${2:-}"

    # Identify the process directly when the host can see it at all.
    gateway_exe_matches "${pid}" && return 0

    # When find_listener_pid returns PID 1
    # (systemd), inspect systemd's units to see whether either of our
    # gateway services is currently active. If so, the listener is
    # actually owned by us — accept it as gateway-managed even though
    # /proc/1/exe is systemd itself. Without this fallback, re-running
    # the wizard after Ctrl-C-mid-setup wrongly reports "Gateway port
    # is already in use by a non-gateway process (pid 1)".
    if [[ "${pid}" == "1" ]] && [[ "${HAS_WORKING_SYSTEMD:-}" == "true" ]]; then
        if systemctl is-active --quiet 'documentdb-gateway*.service' 2>/dev/null \
                || systemctl is-active --quiet 'documentdb-gateway-local@*.service' 2>/dev/null; then
            return 0
        fi
        # Fallback: scan active units for either wrapper unit name.
        if systemctl list-units --state=active --no-legend --plain 2>/dev/null \
                | awk '{print $1}' \
                | grep -Eq '^documentdb-gateway(-local@[0-9]+)?\.service$'; then
            return 0
        fi
    fi

    # No-systemd twin (containers without ss/lsof PID visibility): the host
    # cannot map the listener to a process, so consult the PER-PORT record the
    # nohup fallback writes when it launches a gateway. That answers the
    # question actually being asked — "is the process serving THIS port ours?"
    #
    # The previous form asked `pgrep` whether ANY gateway process was alive
    # anywhere on the host. That is true whenever another PostgreSQL major's
    # gateway is running, so it turned this fail-closed check into a fail-open
    # one: a foreign process holding the port was accepted as ours, the
    # "already in use by a non-gateway process" preflight guard stopped firing,
    # and start_gateway went on to stop gateways it had never identified.
    if [[ "${pid}" == "1" ]] && [[ "${HAS_WORKING_SYSTEMD:-}" != "true" ]] \
            && [[ -n "${port}" ]]; then
        if nohup_gateway_pid_for_port "${port}" >/dev/null 2>&1; then
            return 0
        fi
    fi

    return 1
}

resolve_nologin_shell() {
    if [[ -x /usr/sbin/nologin ]]; then
        printf '%s' "/usr/sbin/nologin"
    elif [[ -x /sbin/nologin ]]; then
        printf '%s' "/sbin/nologin"
    else
        printf '%s' "/bin/false"
    fi
}

ensure_documentdb_runtime_user() {
    local nologin_shell=""
    nologin_shell="$(resolve_nologin_shell)"

    # Per packaging-design.md §4.4 the stand-alone package's two OS users are
    # `documentdb-local` (PG data owner + PG superuser, names match for peer
    # auth) and `documentdb-gateway` (gateway service). Both are normally
    # created by sysusers.d at package install time; this function is a
    # back-stop for dev / non-packaged runs.
    if ! getent group documentdb-local >/dev/null 2>&1; then
        groupadd --system documentdb-local
    fi

    if ! id -u documentdb-local >/dev/null 2>&1; then
        useradd \
            --system \
            --no-create-home \
            --home-dir /var/lib/documentdb-local \
            --shell "${nologin_shell}" \
            --gid documentdb-local \
            documentdb-local
    fi

    if ! getent group documentdb-gateway >/dev/null 2>&1; then
        groupadd --system documentdb-gateway
    fi

    if ! id -u documentdb-gateway >/dev/null 2>&1; then
        useradd \
            --system \
            --no-create-home \
            --home-dir /nonexistent \
            --shell "${nologin_shell}" \
            --gid documentdb-gateway \
            documentdb-gateway
    fi

    install -d -m 0755 -o documentdb-local -g documentdb-local /var/lib/documentdb-local
}

# Per-step consent / dry-run helper. Each invasive operation in the wizard
# calls this with a short human-readable description and the command(s)
# that would be executed. Behavior:
#  - DRY_RUN=true → print "[dry-run]" + description, do nothing, succeed.
#  - YES=true → log the description and run the command.
#  - otherwise → prompt "[y/N/dry-run]" and act on the answer.
#
# Use as:
#  confirm_or_apply "Initialize PostgreSQL data directory ${DATA_DIR}" \
#  run_as_user documentdb-local "${INITDB}" --pgdata="${DATA_DIR}"...
#
# The trailing args are passed verbatim to "$@" so quoting is preserved.
confirm_or_apply() {
    local description="$1"
    shift

    if [[ "${DRY_RUN}" == "true" ]]; then
        log_info "[dry-run] would: ${description}"
        return 0
    fi

    if [[ "${YES}" == "true" ]]; then
        log_info "${description}"
        "$@"
        return $?
    fi

    while true; do
        printf '%s\n' "[documentdb-setup] about to: ${description}" >&2
        printf '%s' "[y = yes / N = abort setup (default; also on Enter) / dry-run = skip only this step] " >&2
        local answer=""
        read -r answer
        case "${answer}" in
            y|Y|yes|YES)
                "$@"
                return $?
                ;;
            dry|dry-run|d)
                log_info "[dry-run] skipped: ${description}"
                return 0
                ;;
            n|N|no|NO|"")
                die "Aborted by operator at: ${description}"
                ;;
            *)
                printf '%s\n' "Please answer y, N, or dry-run." >&2
                ;;
        esac
    done
}

# has_working_systemd comes from documentdb-tools-lib.sh (sourced above).

resolve_gateway_binary() {
    local packaged_path="/usr/bin/documentdb-gateway"
    local repo_path="${REPO_ROOT}/pg_documentdb_gw/target/release-with-symbols/documentdb_gateway"

    if [[ -x "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -x "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

resolve_config_file() {
    local packaged_path="/etc/documentdb/gateway/SetupConfiguration.json"
    local repo_path="${REPO_ROOT}/pg_documentdb_gw/SetupConfiguration.json"

    if [[ -f "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -f "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

resolve_sample_data_dir() {
    local packaged_path="/usr/share/documentdb/sample-data"
    local repo_path="${REPO_ROOT}/documentdb-local/sample-data"

    if [[ -d "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -d "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

resolve_init_data_script() {
    local packaged_path="/usr/share/documentdb/scripts/init_documentdb_data.sh"
    local repo_path="${SCRIPT_DIR}/init_documentdb_data.sh"

    if [[ -x "${packaged_path}" ]]; then
        printf '%s' "${packaged_path}"
        return 0
    fi

    if [[ -x "${repo_path}" ]]; then
        printf '%s' "${repo_path}"
        return 0
    fi

    return 1
}

has_systemd_unit_file() {
    local unit_name="$1"

    if [[ "${HAS_WORKING_SYSTEMD}" != "true" ]]; then
        return 1
    fi

    # `systemctl list-unit-files NAME` only matches concrete files on disk.
    # For a template instance like documentdb-gateway-local@18.service the
    # file on disk is documentdb-gateway-local@.service, so list-unit-files
    # returns 0 entries and the probe wrongly reports the unit missing.
    # `systemctl cat NAME` correctly resolves template instances by walking
    # the template -> instance binding, returning the template's contents.
    systemctl cat "${unit_name}" >/dev/null 2>&1
}

canonicalize_path() {
    local path="$1"
    local canonical_path=""

    if canonical_path="$(readlink -f "${path}" 2>/dev/null)"; then
        printf '%s\n' "${canonical_path}"
        return 0
    fi

    printf '%s\n' "${path}"
}

paths_match() {
    local left_path="$1"
    local right_path="$2"

    [[ "$(canonicalize_path "${left_path}")" == "$(canonicalize_path "${right_path}")" ]]
}

path_is_under() {
    local child_path=""
    local parent_path=""

    child_path="$(canonicalize_path "$1")"
    parent_path="$(canonicalize_path "$2")"

    [[ "${child_path}" == "${parent_path}" || "${child_path}" == "${parent_path}/"* ]]
}

read_persisted_managed_data_dir() {
    local managed_postgres=""
    local persisted_data_dir=""

    # Prefer the per-major setup.conf (the canonical Phase 10+ state
    # file). It survives Workflow C re-installs of just the
    # documentdb-gateway / documentdb-postgresql-tools packages, while
    # the legacy /etc/documentdb/documentdb-postgresql.env may be
    # wiped by apt purge on those packages.
    local per_major_state=""
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        per_major_state="/etc/documentdb/local/${PG_VERSION}/setup.conf"
        if [[ -r "${per_major_state}" ]]; then
            managed_postgres="$(grep -E '^DOCUMENTDB_MANAGED_POSTGRES=' "${per_major_state}" | head -1 | cut -d= -f2- || true)"
            persisted_data_dir="$(grep -E '^DATA_DIR=' "${per_major_state}" | head -1 | cut -d= -f2- || true)"
            if [[ "${managed_postgres}" == "true" && -n "${persisted_data_dir}" ]]; then
                printf '%s\n' "${persisted_data_dir}"
                return 0
            fi
        fi
    fi

    # Fallback: legacy env file (pre-Phase-10 deployments).
    [[ -r "${POSTGRES_SERVICE_ENV_FILE}" ]] || return 1

    managed_postgres="$(grep -E '^DOCUMENTDB_MANAGED_POSTGRES=' "${POSTGRES_SERVICE_ENV_FILE}" | head -1 | cut -d= -f2- || true)"
    persisted_data_dir="$(grep -E '^DATA_DIR=' "${POSTGRES_SERVICE_ENV_FILE}" | head -1 | cut -d= -f2- || true)"

    [[ "${managed_postgres}" == "true" && -n "${persisted_data_dir}" ]] || return 1
    printf '%s\n' "${persisted_data_dir}"
}

validate_live_cluster_paths() {
    local port="$1"
    local documentdb_uid="$2"
    local live_data_dir_uid=""
    local persisted_data_dir=""

    [[ -d "${LIVE_DATA_DIR}" ]] || die "PostgreSQL on port ${port} reports a data_directory that does not exist: ${LIVE_DATA_DIR}"
    live_data_dir_uid="$(stat -Lc '%u' "${LIVE_DATA_DIR}" 2>/dev/null || true)"
    [[ "${live_data_dir_uid}" =~ ^[0-9]+$ ]] || die "Unable to determine owner UID for PostgreSQL data_directory ${LIVE_DATA_DIR}."
    if [[ "${live_data_dir_uid}" != "${documentdb_uid}" ]]; then
        die "PostgreSQL on port ${port} uses data_directory ${LIVE_DATA_DIR}, owned by UID ${live_data_dir_uid}, not documentdb UID ${documentdb_uid}. documentdb-setup will not modify another PostgreSQL cluster. Use --pg-port for a new cluster, or stop the conflicting PostgreSQL process."
    fi

    if ! paths_match "${LIVE_DATA_DIR}" "${DATA_DIR}"; then
        die "Port ${port} is in use by a different PostgreSQL instance (data_directory: ${LIVE_DATA_DIR}). Use --data-dir ${LIVE_DATA_DIR} to manage that cluster intentionally, or use --pg-port to specify a different port."
    fi

    if ! path_is_under "${LIVE_CONFIG_FILE}" "${LIVE_DATA_DIR}"; then
        die "PostgreSQL on port ${port} uses config_file ${LIVE_CONFIG_FILE}, which is outside data_directory ${LIVE_DATA_DIR}. documentdb-setup only manages self-contained clusters it initialized. Use --pg-port with a fresh --data-dir, or manage this PostgreSQL instance manually."
    fi

    if ! path_is_under "${LIVE_HBA_FILE}" "${LIVE_DATA_DIR}"; then
        die "PostgreSQL on port ${port} uses hba_file ${LIVE_HBA_FILE}, which is outside data_directory ${LIVE_DATA_DIR}. documentdb-setup only manages self-contained clusters it initialized. Use --pg-port with a fresh --data-dir, or manage this PostgreSQL instance manually."
    fi

    if ! path_is_under "${LIVE_IDENT_FILE}" "${LIVE_DATA_DIR}"; then
        die "PostgreSQL on port ${port} uses ident_file ${LIVE_IDENT_FILE}, which is outside data_directory ${LIVE_DATA_DIR}. documentdb-setup only manages self-contained clusters it initialized. Use --pg-port with a fresh --data-dir, or manage this PostgreSQL instance manually."
    fi

    if persisted_data_dir="$(read_persisted_managed_data_dir)"; then
        if ! paths_match "${persisted_data_dir}" "${LIVE_DATA_DIR}"; then
            if [[ "${DATA_DIR_EXPLICIT}" == "true" ]] && paths_match "${DATA_DIR}" "${LIVE_DATA_DIR}"; then
                log_warn "${POSTGRES_SERVICE_ENV_FILE} records ${persisted_data_dir}, but the explicitly requested --data-dir matches the running PostgreSQL cluster in ${LIVE_DATA_DIR}; replacing persisted setup state."
            else
                die "PostgreSQL on port ${port} is running from ${LIVE_DATA_DIR}, but ${POSTGRES_SERVICE_ENV_FILE} records ${persisted_data_dir}. Stop the conflicting PostgreSQL process, or rerun documentdb-setup with the intended --data-dir."
            fi
        fi
    else
        # No persisted state file exists (e.g., setup.conf was removed
        # out-of-band, or a data directory was restored from backup
        # without its companion /etc state). Reaching this branch already
        # proves the running cluster is one we own: the checks at the top
        # of this function die unless its live data_directory is owned by
        # the documentdb-local UID, canonically resolves to the same path
        # as ${DATA_DIR} (so no --data-dir is needed to point at it), and
        # keeps its config/hba/ident files inside that data directory.
        # There is therefore no foreign cluster to clobber, and no signal
        # left that could distinguish "lost our state" from "should
        # refuse" -- they are the same cluster. Re-adopt it; the
        # subsequent sync_self_managed_postgres_service_state call
        # re-writes both the legacy env file and the per-major
        # setup.conf. Refusing here would instead force the operator to
        # pass --data-dir on every re-run after any state loss, with no
        # safety benefit.
        log_verbose "Re-adopting documentdb-local-owned PostgreSQL cluster in ${LIVE_DATA_DIR} (no persisted state to compare against; will be re-recorded)."
    fi
}

#
# The per-major setup.conf keys persist_self_managed_postgres_state writes
# itself. Must stay in sync with its printf block: a key listed here but no
# longer written is silently dropped, and a key written but missing here is
# duplicated on every re-run. Mirrors BROWNFIELD_MANAGED_KEYS_RE below and
# STATE_MANAGED_KEYS_RE in documentdb-register-gateway.sh.
readonly GREENFIELD_MANAGED_KEYS_RE='^(DOCUMENTDB_MANAGED_POSTGRES|DOCUMENTDB_MODE|PG_VERSION|PG_PORT|PG_OWNER|DATA_DIR|CONFIG_FILE|HBA_FILE|IDENT_FILE|GATEWAY_PORT)='

persist_self_managed_postgres_state() {
    local temp_file=""

    install -d -m 0755 /etc/documentdb
    create_temp_in_dir temp_file "$(dirname "${POSTGRES_SERVICE_ENV_FILE}")"
    chmod 600 "${temp_file}"

    # Persist the resolved config-file paths (not just DATA_DIR) so the deb
    # postrm and rpm %postun cleanup scriptlets can strip the documentdb-setup
    # managed configuration blocks even when the underlying cluster's config
    # files are at non-default paths under DATA_DIR (which adopted clusters
    # may use). Without this the cleanup would only handle the
    # `${DATA_DIR}/{postgresql,pg_hba,pg_ident}.conf` happy path and silently
    # leave the managed blocks behind for any cluster that puts its config
    # files elsewhere under the data directory.
    {
        printf 'DOCUMENTDB_MANAGED_POSTGRES=true\n'
        printf 'PG_VERSION=%s\n' "${PG_VERSION}"
        printf 'DATA_DIR=%s\n' "${DATA_DIR}"
        printf 'CONFIG_FILE=%s\n' "${LIVE_CONFIG_FILE}"
        printf 'HBA_FILE=%s\n' "${LIVE_HBA_FILE}"
        printf 'IDENT_FILE=%s\n' "${LIVE_IDENT_FILE}"
    } > "${temp_file}"

    mv "${temp_file}" "${POSTGRES_SERVICE_ENV_FILE}"
    chmod 600 "${POSTGRES_SERVICE_ENV_FILE}"

    # Also write per-major state file for systemd template units.
    # documentdb-postgresql@N.service has ConditionPathExists on this file.
    # The unit runs as User=documentdb-local for ExecStart, so the file
    # must be readable by that user. The contents are paths/ports, not
    # secrets, so 0644 is appropriate (mirrors postgresql.auto.conf's
    # rationale — operator-facing config the daemon must read).
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        local per_major_dir="/etc/documentdb/local/${PG_VERSION}"
        local per_major_conf="${per_major_dir}/setup.conf"
        # install -d applies -m only to its explicit arguments; under the
        # script's umask 077 an implicit /etc/documentdb/local intermediate
        # is created 0700 root-only, unreachable for the gateway group.
        # Pin every level.
        install -d -m 0755 /etc/documentdb /etc/documentdb/local "${per_major_dir}"

        # Symmetric counterpart to the greenfield check in
        # persist_brownfield_state: refuse to lay a greenfield install on top
        # of an existing brownfield adoption of the same major.
        #
        # Writing setup.conf here satisfies
        # ConditionPathExists=/etc/documentdb/local/%i/setup.conf and activates
        # the packaged documentdb-postgresql@N.service. With brownfield.conf
        # and the brownfield drop-in still in place, the gateway unit then
        # Requires= BOTH the adopted PostgreSQL service and the packaged one --
        # the drop-in's `Requires=` reset does not actually clear the
        # template's own dependency, because systemd has no empty-string reset
        # for dependency lists (unlike Environment=), it only appends. Today
        # that is masked precisely because the greenfield template is
        # ConditionPathExists-skipped; creating this file un-masks it and
        # starts a second PostgreSQL cluster behind the operator's back.
        local existing_brownfield="${per_major_dir}/brownfield.conf"
        if [[ -f "${existing_brownfield}" ]]; then
            die "A brownfield install (adopted PostgreSQL) already exists for major ${PG_VERSION} (${existing_brownfield}). Refusing to also create a package-owned private instance for the same major: that would start a second PostgreSQL cluster alongside the adopted one. Detach the existing install first with 'documentdb-setup --restore', then re-run."
        fi

        # Preserve keys another writer owns -- the same contract
        # persist_brownfield_state and register-gateway's record_state honor
        # for their state files. documentdb-register-gateway writes
        # SECRET_FILE / CLUSTER_NAME / GATEWAY_ENV_FILE / TARGET_DB into this
        # very path, and in main() we run BEFORE it
        # (sync_self_managed_postgres_service_state, then
        # register_gateway_after_pg_running). On a re-run that aborts between
        # the two -- a failed PG restart, the operator declining the restart
        # prompt, Ctrl-C -- a from-scratch rewrite here left setup.conf
        # missing all four. documentdb-gateway-admin reads TARGET_DB from this
        # file, so day-2 create-user/reset-password would silently fall back to
        # the "postgres" database instead of the operator's --target-db, and
        # --restore would lose the persisted GATEWAY_ENV_FILE pointer that
        # exists precisely to stop it stripping the wrong env file.
        local preserved_foreign=""
        if [[ -f "${per_major_conf}" ]]; then
            preserved_foreign="$(grep -Ev "${GREENFIELD_MANAGED_KEYS_RE}" "${per_major_conf}" 2>/dev/null \
                | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
        fi

        local per_major_temp=""
        create_temp_in_dir per_major_temp "${per_major_dir}"
        chmod 644 "${per_major_temp}"
        {
            if [[ -n "${preserved_foreign}" ]]; then
                printf '%s\n' "${preserved_foreign}"
            fi
            printf 'DOCUMENTDB_MANAGED_POSTGRES=true\n'
            printf 'DOCUMENTDB_MODE=greenfield\n'
            printf 'PG_VERSION=%s\n' "${PG_VERSION}"
            printf 'PG_PORT=%s\n' "${PG_PORT}"
            printf 'PG_OWNER=%s\n' "${PG_OWNER:-documentdb-local}"
            printf 'DATA_DIR=%s\n' "${DATA_DIR}"
            printf 'CONFIG_FILE=%s\n' "${LIVE_CONFIG_FILE}"
            printf 'HBA_FILE=%s\n' "${LIVE_HBA_FILE}"
            printf 'IDENT_FILE=%s\n' "${LIVE_IDENT_FILE}"
            printf 'GATEWAY_PORT=%s\n' "${GATEWAY_PORT}"
        } > "${per_major_temp}"
        mv "${per_major_temp}" "${per_major_conf}"
        chmod 644 "${per_major_conf}"
        log_verbose "Per-major state written to ${per_major_conf}"
    fi
}

# Brownfield must NOT write the per-major setup.conf
# that documentdb-postgresql@N.service's ConditionPathExists matches —
# otherwise the templated PG service activates against the adopted
# system PG instance and the stand-alone target ends up owning a
# PostgreSQL lifecycle that the operator already controls via
# postgresql@N-main.service. Per design §4.4, brownfield's stand-alone
# target only owns the gateway side.
#
# We still need a per-major state record for --restore tracking, so we
# write it under a different filename (brownfield.conf) that no
# templated unit's ConditionPathExists checks. The DEB postrm and RPM
# %postun cleanups already iterate both setup.conf and the legacy
# state filename; we extend them to also pick up brownfield.conf.
#
# The keys persist_brownfield_state below writes itself. Must stay in sync
# with the printf block in that function: a key listed here but no longer
# written is silently dropped from the state file, and a key written but
# missing here ends up duplicated on every re-run.
readonly BROWNFIELD_MANAGED_KEYS_RE='^(DOCUMENTDB_MANAGED_POSTGRES|DOCUMENTDB_MODE|PG_VERSION|PG_PORT|PG_OWNER|DATA_DIR|CONFIG_FILE|HBA_FILE|IDENT_FILE|TARGET_CLUSTER|ADOPTED_PG_SERVICE_UNIT|GATEWAY_PORT)='

persist_brownfield_state() {
    [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || return 0
    local per_major_dir="/etc/documentdb/local/${PG_VERSION}"
    local brownfield_conf="${per_major_dir}/brownfield.conf"
    local legacy_setup_conf="${per_major_dir}/setup.conf"
    # Pin intermediates too — see the umask note in
    # persist_self_managed_postgres_state.
    install -d -m 0755 /etc/documentdb /etc/documentdb/local "${per_major_dir}"

    # A host upgraded from a legacy
    # documentdb-N package may have a left-over setup.conf from an
    # earlier brownfield run that wrongly wrote setup.conf. The
    # documentdb-postgresql@N.service template has
    # ConditionPathExists=/etc/documentdb/local/%i/setup.conf, so even
    # though current versions write brownfield.conf, the stale file still
    # satisfies the activation condition. Strip it so the greenfield PG
    # service stays silent against the adopted system PG.
    #
    # Check DOCUMENTDB_MODE before deleting. persist_self_managed_postgres_state
    # writes DOCUMENTDB_MODE=greenfield into this exact path for a REAL
    # greenfield install, and this used to delete it unconditionally: pointing
    # documentdb-setup --target-postgres-instance N/main at a host that already
    # had a greenfield install for major N destroyed that install's state file
    # while logging it as "legacy". The private documentdb-postgresql@N.service
    # kept running but became silently non-startable on the next boot (its
    # ConditionPathExists gate was gone), its data directory was orphaned with
    # no state pointer, and --restore could no longer find it to strip its
    # managed blocks. Refuse instead: switching modes is a real decision that
    # needs the greenfield instance torn down first.
    if [[ -f "${legacy_setup_conf}" ]]; then
        local existing_mode
        existing_mode="$(grep -E '^DOCUMENTDB_MODE=' "${legacy_setup_conf}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        if [[ "${existing_mode}" == "greenfield" ]]; then
            die "A greenfield (package-owned) PostgreSQL install already exists for major ${PG_VERSION} (${legacy_setup_conf}). Refusing to adopt a different instance on top of it, because that would orphan the private instance's data directory and leave its service unstartable. Tear the greenfield install down first — 'documentdb-setup --restore' to detach it non-destructively, or 'documentdb-local-reset --pg-version ${PG_VERSION} --confirm-destroy' to also delete its data — then re-run this command."
        fi
        log_info "Removing legacy ${legacy_setup_conf} (brownfield mode does not own a greenfield PG service)."
        rm -f "${legacy_setup_conf}"
    fi

    local adopted_pg_unit
    adopted_pg_unit="$(resolve_brownfield_pg_service_unit)"

    # Preserve keys another writer owns, exactly as
    # documentdb-register-gateway's record_state does for the same file.
    # Ordering makes this mandatory: in the brownfield flow
    # ensure_pg_ident_map invokes documentdb-register-gateway (which writes
    # SECRET_FILE / GATEWAY_ENV_FILE / CLUSTER_NAME / TARGET_DB into
    # brownfield.conf) and only THEN do we run. A from-scratch rewrite here
    # dropped every one of those keys. GATEWAY_ENV_FILE is the costly loss:
    # register-gateway persists it precisely so a later --restore strips the
    # env file that was actually written, instead of recomputing it from
    # host state that may have drifted (e.g. documentdb-N since uninstalled)
    # and stripping the wrong one.
    local preserved_foreign=""
    if [[ -f "${brownfield_conf}" ]]; then
        preserved_foreign="$(grep -Ev "${BROWNFIELD_MANAGED_KEYS_RE}" "${brownfield_conf}" 2>/dev/null \
            | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
    fi

    local tmp=""
    create_temp_in_dir tmp "${per_major_dir}"
    chmod 600 "${tmp}"
    {
        if [[ -n "${preserved_foreign}" ]]; then
            printf '%s\n' "${preserved_foreign}"
        fi
        printf 'DOCUMENTDB_MANAGED_POSTGRES=false\n'
        printf 'DOCUMENTDB_MODE=brownfield\n'
        printf 'PG_VERSION=%s\n' "${PG_VERSION}"
        printf 'PG_PORT=%s\n' "${PG_PORT}"
        printf 'PG_OWNER=%s\n' "${PG_OWNER:-postgres}"
        printf 'DATA_DIR=%s\n' "${LIVE_DATA_DIR}"
        printf 'CONFIG_FILE=%s\n' "${LIVE_CONFIG_FILE}"
        printf 'HBA_FILE=%s\n' "${LIVE_HBA_FILE}"
        printf 'IDENT_FILE=%s\n' "${LIVE_IDENT_FILE}"
        printf 'TARGET_CLUSTER=%s\n' "${TARGET_CLUSTER}"
        printf 'ADOPTED_PG_SERVICE_UNIT=%s\n' "${adopted_pg_unit}"
        printf 'GATEWAY_PORT=%s\n' "${GATEWAY_PORT}"
    } > "${tmp}"
    mv "${tmp}" "${brownfield_conf}"
    chmod 600 "${brownfield_conf}"
    log_verbose "Per-major brownfield state written to ${brownfield_conf}"

    write_brownfield_gateway_dropin "${adopted_pg_unit}"
}

# Returns the systemd unit name of the adopted PostgreSQL service in
# brownfield mode. Debian/Ubuntu's postgresql-common ships
# postgresql@<V>-<C>.service; PGDG's RHEL packages ship postgresql-<V>.service.
# Detection mirrors start_or_restart_postgres's reload-hint logic so the
# same name is used everywhere.
resolve_brownfield_pg_service_unit() {
    # Defense in depth: prepare_brownfield_instance already validated
    # TARGET_CLUSTER as VERSION/NAME, but a future code path that calls this
    # resolver without going through that validator would otherwise produce a
    # broken Requires= (e.g. "postgresql@18-18.service") and silently get
    # baked into the on-disk drop-in. Fail loudly instead.
    [[ "${TARGET_CLUSTER}" == */* ]] \
        || die "resolve_brownfield_pg_service_unit: TARGET_CLUSTER must be VERSION/NAME; got '${TARGET_CLUSTER}'."

    if [[ -d "/etc/postgresql/${PG_VERSION}" ]]; then
        local cluster_name="${TARGET_CLUSTER#*/}"
        [[ -n "${cluster_name}" ]] || cluster_name="main"
        printf 'postgresql@%s-%s.service' "${PG_VERSION}" "${cluster_name}"
    else
        printf 'postgresql-%s.service' "${PG_VERSION}"
    fi
}

# Per packaging-design.md §4.4, in brownfield mode the stand-alone target only
# owns the gateway side and must order the gateway after the adopted PostgreSQL
# service — not the greenfield documentdb-postgresql@N.service template (whose
# ConditionPathExists is intentionally false in brownfield so it skips).
#
# The shipped documentdb-gateway-local@.service unit hard-wires Requires=/After=
# documentdb-postgresql@%i.service for the greenfield case. In brownfield we
# write a per-instance drop-in that resets those lists and re-points them at
# the adopted PG service, so reboot ordering is correct and `systemctl restart
# documentdb-local@N.target` does not depend on the (skipped) greenfield unit.
#
# The drop-in lives under /etc/systemd/system (the admin-owned tree) so package
# upgrades never overwrite it; it is removed by --restore and by the DEB postrm
# / RPM %postun on full purge.
write_brownfield_gateway_dropin() {
    local adopted_pg_unit="$1"
    [[ -n "${adopted_pg_unit}" ]] || return 0
    [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || return 0

    local dropin_dir="/etc/systemd/system/documentdb-gateway-local@${PG_VERSION}.service.d"
    local dropin_file="${dropin_dir}/brownfield.conf"

    # Don't reset mode on an admin-pre-created directory (e.g. one that was
    # locked down to 0750). Install -d -m forces the mode unconditionally.
    if [[ ! -d "${dropin_dir}" ]]; then
        install -d -m 0755 "${dropin_dir}"
    fi

    # Write the temp file into the same directory so the final rename is a
    # same-filesystem rename(2), which is atomic — mv across filesystems
    # (mktemp's default /tmp vs. /etc/systemd) is not.
    local tmp=""
    create_temp_file tmp "${dropin_dir}/.brownfield.conf.XXXXXX"
    chmod 644 "${tmp}"
    cat > "${tmp}" <<DROPIN
# Generated by documentdb-setup --target-postgres-instance ${TARGET_CLUSTER}
# Brownfield mode: gateway orders on the adopted system PostgreSQL service,
# not the (skipped) per-major greenfield documentdb-postgresql@${PG_VERSION}.service.
# See packaging-design.md §4.4 — "the stand-alone target only owns the local
# gateway side and orders it after the adopted PostgreSQL service."
[Unit]
# Reset the unit's greenfield Requires=/After= lists and re-point at the
# adopted PG service so boot ordering is correct.
Requires=
After=
Requires=${adopted_pg_unit}
After=${adopted_pg_unit}
DROPIN
    mv "${tmp}" "${dropin_file}"
    chmod 644 "${dropin_file}"
    log_verbose "Brownfield gateway drop-in written to ${dropin_file}"

    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]]; then
        systemctl daemon-reload || true
    fi
}

# Inverse of write_brownfield_gateway_dropin: used by --restore and by any
# future code path that needs to revert a per-major brownfield drop-in. The
# writer reloads systemd so its in-memory unit graph reflects the new drop-in;
# the remover must do the same so the freshly-removed brownfield Requires=/
# After= are not still present in systemd's view. The DEB postrm / RPM
# %postun bypass this function and do their own remove+reload, but any
# future caller of remove_brownfield_gateway_dropin needs the symmetry.
remove_brownfield_gateway_dropin() {
    local pg_major="$1"
    [[ -n "${pg_major}" && "${pg_major}" =~ ^[0-9]+$ ]] || return 0
    local dropin_dir="/etc/systemd/system/documentdb-gateway-local@${pg_major}.service.d"
    local existed=false
    [[ -f "${dropin_dir}/brownfield.conf" ]] && existed=true
    rm -f "${dropin_dir}/brownfield.conf"
    rmdir --ignore-fail-on-non-empty "${dropin_dir}" 2>/dev/null || true

    # Defensive: rm -f effectively always succeeds (it suppresses missing-
    # file errors), so the on-disk file is guaranteed gone. The risk is that
    # systemctl daemon-reload silently fails and systemd's in-memory unit
    # graph still has the brownfield Requires=/After=. We surface that as a
    # warning rather than an error — the file is already gone, and the
    # operator can finish the reload with `sudo systemctl daemon-reload`
    # if our attempt was suppressed.
    if [[ "${existed}" == "true" && "${HAS_WORKING_SYSTEMD}" == "true" ]]; then
        if ! systemctl daemon-reload; then
            log_warn "systemctl daemon-reload failed after removing brownfield drop-in at ${dropin_dir}. Run 'sudo systemctl daemon-reload' manually to refresh systemd's view."
        fi
    fi
}

ensure_postgres_systemd_drop_in() {
    # The packaged documentdb-postgresql@.service template intentionally does
    # NOT set PIDFile=: under systemd 245+ a PIDFile owned by the unit's
    # non-root User= can be refused (and races with ExecStartPre=+), so the
    # unit relies on Type=forking + GuessMainPID walking its cgroup to find
    # the postmaster. cgroup tracking does not depend on the data directory,
    # so a custom --data-dir needs no PIDFile override. We therefore never
    # write a drop-in here; we only strip any stale datadir.conf drop-in an
    # older version may have written — both the templated per-major path and
    # the legacy non-templated path — returning the unit to pure cgroup
    # tracking. The drop-ins live under /etc/systemd/system, so a package
    # upgrade never recreates them.
    [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || return 0
    local drop_in_dir="/etc/systemd/system/documentdb-postgresql@${PG_VERSION}.service.d"
    local drop_in_file="${drop_in_dir}/datadir.conf"
    local legacy_drop_in_dir="/etc/systemd/system/documentdb-postgresql.service.d"
    local legacy_drop_in_file="${legacy_drop_in_dir}/datadir.conf"
    local removed=false

    # Strip the legacy non-templated drop-in left on this host.
    if [[ -f "${legacy_drop_in_file}" ]]; then
        rm -f "${legacy_drop_in_file}"
        rmdir --ignore-fail-on-non-empty "${legacy_drop_in_dir}" 2>/dev/null || true
        removed=true
    fi

    # Strip a stale templated per-major drop-in left by a version that used to
    # write a PIDFile= override for a custom data dir.
    if [[ -f "${drop_in_file}" ]]; then
        rm -f "${drop_in_file}"
        rmdir --ignore-fail-on-non-empty "${drop_in_dir}" 2>/dev/null || true
        removed=true
    fi

    if [[ "${removed}" == "true" && "${HAS_WORKING_SYSTEMD}" == "true" ]]; then
        systemctl daemon-reload
    fi
}

sync_self_managed_postgres_service_state() {
    persist_self_managed_postgres_state
    ensure_postgres_systemd_drop_in
}

capture_gateway_active_state() {
    # Record whether the gateway is currently active under systemd. We use
    # this to detect when restarting PostgreSQL during this run would tear
    # the gateway down through dependency propagation (Requires= will
    # propagate a stop job for the gateway when systemctl restart is run on
    # the PG unit). Under --no-enable the operator asked us not to do
    # first-time gateway startup, but we must still preserve a previously
    # running gateway's state across our PG operations.
    #
    # The previous
    # implementation only checked documentdb-gateway.service (the
    # non-templated Workflow-B unit). But start_gateway prefers the
    # per-major templated documentdb-gateway-local@N.service when
    # available. If the per-major unit is active and PG restart
    # propagation stops it via Requires=, capture_gateway_active_state
    # would record GATEWAY_WAS_ACTIVE=false and the --no-enable branch
    # would not restore it. Check both candidate units.
    GATEWAY_WAS_ACTIVE=false
    if [[ "${HAS_WORKING_SYSTEMD}" != "true" ]]; then
        return 0
    fi
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        local per_major_unit="documentdb-gateway-local@${PG_VERSION}.service"
        if has_systemd_unit_file "${per_major_unit}" \
                && systemctl is-active --quiet "${per_major_unit}"; then
            GATEWAY_WAS_ACTIVE=true
            return 0
        fi
    fi
    if has_systemd_unit_file documentdb-gateway.service \
            && systemctl is-active --quiet documentdb-gateway.service; then
        GATEWAY_WAS_ACTIVE=true
    fi
}

set_postgres_binary_paths() {
    local major_version="$1"
    local candidate=""

    # Probe the shared Debian-then-RHEL bindir candidate list so the layout
    # cannot drift from documentdb-tune / documentdb-register-gateway.
    while IFS= read -r candidate; do
        if [[ -x "${candidate}/pg_config" ]]; then
            PG_VERSION="${major_version}"
            PG_BIN_DIR="${candidate}"
            PG_CONFIG="${candidate}/pg_config"
            INITDB="${candidate}/initdb"
            PG_CTL="${candidate}/pg_ctl"
            PSQL="${candidate}/psql"
            PG_ISREADY="${candidate}/pg_isready"
            return 0
        fi
    done < <(documentdb_pg_bindir_candidates "${major_version}")

    return 1
}

detect_postgres_installation() {
    local best_with_extension=0
    local best_without_extension=0
    local candidate_path=""
    local candidate_version=""
    local sharedir=""
    local has_extension=false

    if [[ "${PG_VERSION_EXPLICIT}" == "true" ]]; then
        set_postgres_binary_paths "${PG_VERSION}" || die "PostgreSQL ${PG_VERSION} not found in standard Debian or RHEL paths."
        return 0
    fi

    # Brownfield: when adopting a specific instance (--target-postgres-instance
    # or the interactive prompt) without an explicit --pg-version, pin the major
    # to that of the adopted cluster instead of auto-detecting the highest
    # installed one. Otherwise every major-dependent preflight step that runs
    # before prepare_brownfield_instance re-pins — the gateway-port collision
    # check, capture_gateway_active_state's per-major unit probe, start_gateway's
    # stray-listener handling, and validate_documentdb_extension_installation —
    # would operate on the wrong major on a multi-major host (missed cross-major
    # port collisions, or stopping another major's live gateway).
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        local target_major="${TARGET_CLUSTER%%/*}"
        if [[ "${target_major}" =~ ^[0-9]+$ ]]; then
            set_postgres_binary_paths "${target_major}" \
                || die "PostgreSQL ${target_major} binaries not found. Install postgresql-${target_major} first."
            return 0
        fi
    fi

    for candidate_path in /usr/lib/postgresql/*/bin /usr/pgsql-*/bin; do
        if [[ ! -x "${candidate_path}/pg_config" ]]; then
            continue
        fi

        candidate_version="$(basename "$(dirname "${candidate_path}")" | sed 's/^pgsql-//')"
        if [[ ! "${candidate_version}" =~ ^[0-9]+$ ]]; then
            continue
        fi

        sharedir="$("${candidate_path}/pg_config" --sharedir)"
        has_extension=false
        if [[ -f "${sharedir}/extension/documentdb.control" ]]; then
            has_extension=true
        fi

        if [[ "${has_extension}" == "true" ]] && (( candidate_version > best_with_extension )); then
            best_with_extension="${candidate_version}"
        fi

        if (( candidate_version > best_without_extension )); then
            best_without_extension="${candidate_version}"
        fi
    done

    if (( best_with_extension > 0 )); then
        set_postgres_binary_paths "${best_with_extension}" || die "Failed to resolve PostgreSQL ${best_with_extension} binaries after detection."
        return 0
    fi

    if (( best_without_extension > 0 )); then
        set_postgres_binary_paths "${best_without_extension}" || die "Failed to resolve PostgreSQL ${best_without_extension} binaries after detection."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" || "${STATUS_ONLY}" == "true" || "${PRINT_CONFIG}" == "true" ]]; then
        # In dry-run we don't fail when PG is missing; the apply path's
        # preflight_validation will surface the same error there.
        # --status/--print-config are read-only and print their own
        # "no PostgreSQL installation detected" fallback — a die here
        # would exit the whole script straight through their
        # `|| true` guards (a shell `exit` is not catchable), leaving
        # --status silent with exit 1 and --print-config printing
        # nothing despite being documented as side-effect-free.
        return 0
    fi
    die "PostgreSQL not found. Install PostgreSQL first (for example: apt install postgresql-17)."
}

build_postgres_conf_block() {
    local merged_preload="$1"
    local ssl_setting="${2:-}"
    local postgres_conf_block=""

    postgres_conf_block=$(
        cat <<EOF
listen_addresses = 'localhost'
port = ${PG_PORT}
unix_socket_directories = '${PG_SOCKET_DIR}'
shared_preload_libraries = '${merged_preload}'
cron.database_name = 'postgres'
cron.use_background_workers = on
documentdb.localhost_connection_string = 'host=${PG_SOCKET_DIR} port=${PG_PORT}'
EOF
    )

    if [[ -n "${ssl_setting}" ]]; then
        postgres_conf_block+=$'\n'"ssl = ${ssl_setting}"
    fi

    postgres_conf_block+=$'\n'"documentdb.enableBackgroundWorker = true"
    postgres_conf_block+=$'\n'"documentdb.enableBackgroundWorkerJobs = true"
    postgres_conf_block+=$'\n'"documentdb.indexBuildsScheduledOnBgWorker = false"

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        postgres_conf_block+=$'\n'"documentdb.rum_library_load_option = 'require_documentdb_extended_rum'"
        postgres_conf_block+=$'\n'"documentdb.alternate_index_handler_name = 'extended_rum'"
    fi

    printf '%s' "${postgres_conf_block}"
}

build_desired_hba_block() {
    # Peer auth with the documentdb-map ident map: only the OS users with
    # ident map entries ("documentdb", "documentdb-gateway", and the
    # wizard's own "documentdb-local" persona — see
    # _legacy_ensure_pg_ident_map) can connect via the Unix socket, each
    # restricted to its mapped roles.
    # All other OS users are rejected because they have no ident map entry.
    # This fallback block is greenfield-only: preflight_validation rejects
    # brownfield adoption when the delegated tools are missing.
    cat <<'EOF'
local   all   all   peer   map=documentdb-map
EOF
}

apply_managed_postgres_settings() {
    local config_file="$1"
    local hba_file="$2"
    local merged_preload="$3"
    local ssl_setting="${4:-}"
    local postgres_conf_block=""
    local desired_hba_block=""
    local existing_postgres_conf_block=""
    local existing_hba_block=""

    # Per packaging-design.md §4.4, the setup wizard delegates each invasive
    # PostgreSQL-side write to the dedicated tool that owns it:
    #  - documentdb-tune → postgresql.conf
    #  - documentdb-register-gateway → pg_hba.conf + pg_ident.conf + role
    #  + connection-URL file
    # We prefer the external tools when they are installed (which is the
    # `documentdb-postgresql-tools` hard-dep contract on the stand-alone
    # package), and fall back to the inline writes for dev / partial
    # environments where the tools may not yet be on PATH. The fallback
    # uses identical managed-block markers so the two paths are
    # interchangeable from a postrm-cleanup standpoint.
    if command_exists documentdb-tune; then
        local prev_mtime=""
        if [[ -f "${config_file}" ]]; then
            prev_mtime="$(stat -c %Y "${config_file}" 2>/dev/null || echo 0)"
        fi
        log_verbose "Delegating postgresql.conf tuning to documentdb-tune."

        # On Debian brownfield,
        # /etc/postgresql/<V>/<C>/postgresql.conf is the canonical config
        # file (not the data dir's). Passing --pgdata to documentdb-tune
        # makes it write to the data-dir postgresql.conf which Debian
        # clusters do not read. Use --pg-version/--cluster instead so
        # tune writes the per-cluster fragment under
        # /etc/postgresql-common/documentdb/<V>/<C>/documentdb.conf
        # (the design's documented path, see §4.2 / §8). Greenfield
        # (private appliance PG) keeps --pgdata because the data dir
        # IS where its postgresql.conf lives.
        local -a tune_args=()
        if [[ -n "${TARGET_CLUSTER}" && -d "/etc/postgresql/${PG_VERSION}/${TARGET_CLUSTER#*/}" ]]; then
            tune_args+=(--pg-version "${PG_VERSION}" --cluster "${TARGET_CLUSTER#*/}")
            # Forward the wizard-verified socket dir + port. In brownfield
            # PG_SOCKET_DIR was overridden to the adopted instance's distro
            # socket (prepare_brownfield_instance) and PG_PORT to the port we
            # actually connected the SHOW round-trip on, so these are the exact,
            # proven endpoint of the adopted cluster. Passing them lets
            # documentdb-tune pin documentdb.localhost_connection_string without
            # re-parsing the adopted postgresql.conf. Without them tune's
            # include-resolution guard (enforce_config_includes_resolved) fails
            # closed whenever the adopted config has any active setting AFTER its
            # `include_dir = 'conf.d'` line — an extremely common admin habit
            # (e.g. appending work_mem) — and brownfield adoption would die with
            # no operator workaround. tune still resolves and folds
            # shared_preload_libraries / data_directory itself; with the
            # overrides present its guard runs in a narrowed mode that keeps
            # protecting those against include-order mis-modeling.
            tune_args+=(--socket-dir "${PG_SOCKET_DIR}" --port "${PG_PORT}")
        else
            # Greenfield: --pgdata pins documentdb-tune at the per-major
            # private data dir's postgresql.conf. ALSO pass --pg-version
            # explicitly: tune's resolve_pg_sharedir is gated on
            # ${PG_VERSION} being set, and without it tune skips
            # extended-RUM detection. The wizard always knows the
            # major here (we resolved it during detect_postgres_installation),
            # so passing it through is free and makes tune's behaviour
            # match what `documentdb-createcluster N C` produces.
            tune_args+=(--pgdata "${LIVE_DATA_DIR}" --pg-version "${PG_VERSION}")
            # Greenfield owns the private cluster's listen settings, so hand the
            # resolved socket dir + port to tune for the localhost-connection
            # GUC (documentdb.localhost_connection_string) — the extension's
            # internal libpq connections must use the private Unix socket, not
            # host=localhost. Debian brownfield forwards the same overrides in
            # the branch above (from the adopted instance's verified endpoint);
            # RHEL brownfield also lands here, where PG_SOCKET_DIR / PG_PORT
            # already point at the adopted instance's distro socket and port.
            tune_args+=(--socket-dir "${PG_SOCKET_DIR}" --port "${PG_PORT}")
        fi
        tune_args+=(--yes)

        if ! confirm_or_apply "Write postgresql.conf managed block via documentdb-tune ${tune_args[*]}" \
                documentdb-tune "${tune_args[@]}" >/dev/null; then
            die "documentdb-tune failed; see above for details."
        fi
        local new_mtime=""
        if [[ -f "${config_file}" ]]; then
            new_mtime="$(stat -c %Y "${config_file}" 2>/dev/null || echo 0)"
        fi
        if [[ "${prev_mtime}" != "${new_mtime}" ]]; then
            PG_CONFIG_CHANGED=true
        fi

        # Per-instance isolation settings (port, socket dir, listen
        # addresses) are the WIZARD's responsibility — not tune's.
        # `documentdb-tune` is generic (it writes shared_preload_libraries
        # + the documentdb-tunable GUCs that are identical across every
        # DocumentDB-enabled instance) and intentionally does NOT touch
        # port / unix_socket_directories because those vary per-cluster
        # and a brownfield tune of a system PG instance would clobber
        # the operator's existing port choice.
        #
        # In greenfield mode we own the per-major PG instance end-to-end,
        # so we DO need to pin port = PG_PORT, unix_socket_directories =
        # /run/documentdb-local/N/postgresql, and listen_addresses =
        # localhost. Without this, the instance starts on PG's default
        # port 5432 and the default socket dir (/var/run/postgresql,
        # owned by the system postgres user) — colliding with any
        # system PG on the host AND failing to write the lock file
        # because documentdb-local can't write to postgres's socket dir.
        # In brownfield mode we skip this block entirely so the adopted
        # system PG instance keeps its operator-managed listen settings.
        if [[ -z "${TARGET_CLUSTER}" ]]; then
            local wizard_listen_block=""
            wizard_listen_block="$(cat <<EOF
listen_addresses = 'localhost'
port = ${PG_PORT}
unix_socket_directories = '${PG_SOCKET_DIR}'
documentdb.localhost_connection_string = 'host=${PG_SOCKET_DIR} port=${PG_PORT}'
# Headroom over PG's default of 100. The gateway opens two pools
# (SystemRequests + PreAuthRequests), each potentially up to ~16
# connections, plus pg_cron background workers, plus the wizard's
# own psql sessions during CREATE EXTENSION / admin bootstrap. On a
# stock 100-slot PG this can saturate after a couple of wizard
# re-runs and surface as "FATAL: sorry, too many clients already"
# on subsequent CRUD / mongosh activity.
max_connections = 500
EOF
)"
            local existing_listen_block=""
            existing_listen_block="$(extract_managed_block_content \
                "${config_file}" \
                "# >>> documentdb-setup managed listen >>>" \
                "# <<< documentdb-setup managed listen <<<")"
            if [[ "${existing_listen_block}" != "${wizard_listen_block}" ]]; then
                PG_CONFIG_CHANGED=true
            fi
            rewrite_with_managed_block "${config_file}" \
                "# >>> documentdb-setup managed listen >>>" \
                "# <<< documentdb-setup managed listen <<<" \
                "${wizard_listen_block}"
        fi
    else
        postgres_conf_block="$(build_postgres_conf_block "${merged_preload}" "${ssl_setting}")"
        existing_postgres_conf_block="$(extract_managed_block_content "${config_file}" "${POSTGRES_CONF_BLOCK_START}" "${POSTGRES_CONF_BLOCK_END}")"
        if [[ "${existing_postgres_conf_block}" != "${postgres_conf_block}" ]]; then
            PG_CONFIG_CHANGED=true
        fi
        rewrite_with_managed_block "${config_file}" "${POSTGRES_CONF_BLOCK_START}" "${POSTGRES_CONF_BLOCK_END}" "${postgres_conf_block}"
    fi

    # Phase 10 delegation: pg_hba.conf is now written by
    # documentdb-register-gateway (called from ensure_pg_ident_map), not
    # here. We still set PG_RELOAD_CHANGED so the caller knows a reload
    # is pending; the actual hba write happens in the register-gateway
    # invocation that runs immediately after this function. We keep the
    # inline write as a fallback for dev environments where tools is not
    # installed (in which case ensure_pg_ident_map also falls back).
    if ! command_exists documentdb-register-gateway; then
        desired_hba_block="$(build_desired_hba_block)"
        existing_hba_block="$(extract_managed_block_content "${hba_file}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}")"
        if [[ "${existing_hba_block}" != "${desired_hba_block}" ]]; then
            PG_RELOAD_CHANGED=true
        fi
        prepend_with_managed_block "${hba_file}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}" "${desired_hba_block}"
    fi
}

resolve_live_cluster_metadata() {
    local port="$1"
    local live_cluster_pid=""
    local detected_owner=""
    local documentdb_uid=""
    local live_cluster_uid=""
    local server_version_num=""
    local detected_major=""

    live_cluster_pid="$(find_listener_pid "${port}")"
    [[ -n "${live_cluster_pid}" ]] || die "No process is listening on PostgreSQL port ${port}."

    if ! listener_looks_like_postgres "${live_cluster_pid}" "${port}"; then
        # An unresolved placeholder must not be reported as "a non-PostgreSQL
        # process" — nothing established that. Mirror the greenfield twin's
        # honest message (a genuine pid-1 postmaster would have been accepted
        # by the classifier's exe/comm checks, so failure+placeholder means
        # the owner is truly unknown).
        if [[ "${live_cluster_pid}" == "1" ]] && ! pid1_is_postgres; then
            die_unknown_listener_owner "${port}" postgres
        fi
        die "Port ${port} is in use by a non-PostgreSQL process."
    fi

    documentdb_uid="$(id -u documentdb-local 2>/dev/null || true)"
    [[ "${documentdb_uid}" =~ ^[0-9]+$ ]] || die "The documentdb-local runtime user does not exist."

    # Resolve WHICH pid to stat for the port-owner UID check. Shared verbatim
    # with the greenfield PG-port preflight via resolve_uid_check_target (in
    # documentdb-tools-lib.sh) so the security-critical residual-"1"-placeholder
    # decision table — real pid vs. our own postmaster vs. a genuine pid-1
    # listener vs. a blind host — cannot drift between the two call sites. An
    # empty result means "nothing safe to stat"; skip the check and proceed.
    local _uid_check_target=""
    _uid_check_target="$(resolve_uid_check_target "${live_cluster_pid}" "${port}")"
    if [[ -n "${_uid_check_target}" ]]; then
        live_cluster_uid="$(stat -c '%u' "/proc/${_uid_check_target}" 2>/dev/null || true)"
        [[ "${live_cluster_uid}" =~ ^[0-9]+$ ]] || die "Unable to determine the PostgreSQL process UID on port ${port}."
        detected_owner="$(ps -o user= -p "${_uid_check_target}" 2>/dev/null | awk '{print $1}' || true)"

        if [[ "${live_cluster_uid}" != "${documentdb_uid}" ]]; then
            die "Port ${port} is in use by a PostgreSQL instance owned by UID ${live_cluster_uid} (${detected_owner:-unknown}), not the documentdb runtime UID ${documentdb_uid}. documentdb-setup will not modify another PostgreSQL cluster. Use --pg-port to specify a different port, or stop the existing PostgreSQL process."
        fi
    fi

    PG_OWNER="documentdb-local"

    # One psql round-trip for all six settings — six separate connections
    # added ~0.5-1s of pure connect overhead to every wizard run that
    # re-adopts a live cluster. -tA prints exactly one line per SHOW, in
    # statement order, and none of these settings can contain a newline.
    local -a live_settings=()
    mapfile -t live_settings < <(
        run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${port}" -d postgres -X -tA -v ON_ERROR_STOP=1 <<'SQL'
SHOW data_directory;
SHOW config_file;
SHOW hba_file;
SHOW ident_file;
SHOW shared_preload_libraries;
SHOW server_version_num;
SQL
    )
    # mapfile through process substitution swallows psql's exit status, so
    # gate on the value count instead (a failed/partial run yields fewer).
    [[ "${#live_settings[@]}" -eq 6 ]] \
        || die "Cannot read settings from the running PostgreSQL cluster on port ${port} (expected 6 values, got ${#live_settings[@]}). Is the instance healthy?"
    LIVE_DATA_DIR="${live_settings[0]}"
    LIVE_CONFIG_FILE="${live_settings[1]}"
    LIVE_HBA_FILE="${live_settings[2]}"
    LIVE_IDENT_FILE="${live_settings[3]}"
    validate_live_cluster_paths "${port}" "${documentdb_uid}"

    LIVE_PRELOAD_LIBRARIES="${live_settings[4]}"
    server_version_num="${live_settings[5]}"

    if [[ ! "${server_version_num}" =~ ^[0-9]+$ ]]; then
        die "Unable to parse PostgreSQL server_version_num from the running cluster."
    fi

    detected_major="$(( server_version_num / 10000 ))"
    if [[ "${PG_VERSION_EXPLICIT}" == "true" && "${PG_VERSION}" != "${detected_major}" ]]; then
        die "The running PostgreSQL cluster is version ${detected_major}, but --pg-version ${PG_VERSION} was requested."
    fi

    set_postgres_binary_paths "${detected_major}" || die "Unable to resolve PostgreSQL ${detected_major} client binaries for the running cluster."
    refresh_extension_state
    validate_documentdb_extension_installation
    log_verbose "Resolved running PostgreSQL cluster metadata: data_directory=${LIVE_DATA_DIR}, config_file=${LIVE_CONFIG_FILE}, hba_file=${LIVE_HBA_FILE}, ident_file=${LIVE_IDENT_FILE}"
}

require_root() {
    if [[ "$(id -u)" -ne 0 ]]; then
        die "documentdb-setup must be run as root (use sudo)."
    fi
}

validate_required_arguments() {
    [[ -n "${USERNAME}" ]] || die "--username is required."

    # Reject an admin name the GATEWAY will refuse at authentication. Without
    # this the wizard ran to completion on e.g. --admin-user pgadmin, printed
    # "SUCCESS: DocumentDB is ready" plus a connect command, and left an
    # install whose only admin failed every login with "Username is invalid"
    # (the gateway blocks the documentdb / citus / pg / internal_role
    # prefixes). Validate here, in argument validation, so nothing is mutated
    # before the operator is told.
    if declare -F documentdb_validate_gateway_username >/dev/null 2>&1; then
        documentdb_validate_gateway_username "${USERNAME}" \
            || die "Admin username '${USERNAME}' is rejected by the gateway's reserved-prefix policy (see above). Re-run with a different --admin-user."
    fi

    # TLS triple: --tls-cert / --tls-key must come together; combining
    # either with --tls-auto-generate true is a contradiction (the
    # gateway's env-overlay also rejects this, but we surface the error
    # at the wizard layer with a clearer message). When neither cert
    # nor key is set we leave TLS_AUTO_GENERATE alone; if the operator
    # didn't explicitly pass it the delegate keeps the design's
    # standalone default of auto-generate=true.
    if [[ -n "${TLS_CERT_FILE}" || -n "${TLS_KEY_FILE}" ]]; then
        [[ -n "${TLS_CERT_FILE}" ]] || die "--tls-key requires --tls-cert to also be set."
        [[ -n "${TLS_KEY_FILE}"  ]] || die "--tls-cert requires --tls-key to also be set."
        [[ -r "${TLS_CERT_FILE}" ]] || die "--tls-cert ${TLS_CERT_FILE} is not readable."
        [[ -r "${TLS_KEY_FILE}"  ]] || die "--tls-key  ${TLS_KEY_FILE} is not readable."
        if [[ "${TLS_AUTO_GENERATE}" == "true" ]]; then
            die "--tls-auto-generate=true cannot be combined with --tls-cert / --tls-key; pick one TLS source."
        fi
        # When the operator supplies a cert/key explicitly, the env file
        # must record auto-generate=false so the gateway honors the
        # provided files rather than re-generating on next start.
        TLS_AUTO_GENERATE="false"
        # The gateway daemon runs as
        # the documentdb-gateway OS user. If the operator-supplied TLS
        # files are not readable by that user (e.g. root:root 0600), the
        # gateway aborts with "Failed to create TLS provider: Permission
        # denied" — even though the wizard accepted them because root
        # can read them. Auto-fix ownership when we have privilege; bail
        # with a clear actionable error otherwise.
        local gw_user="documentdb-gateway"
        if id -u "${gw_user}" >/dev/null 2>&1; then
            local f
            for f in "${TLS_CERT_FILE}" "${TLS_KEY_FILE}"; do
                if ! sudo -n -u "${gw_user}" test -r "${f}" 2>/dev/null \
                        && ! run_as_user "${gw_user}" test -r "${f}" 2>/dev/null; then
                    if [[ "$(id -u)" -eq 0 ]]; then
                        log_info "Adjusting ownership of ${f} to root:${gw_user} mode 0640 so the gateway can read it."
                        chown "root:${gw_user}" "${f}"
                        # Cert can stay world-readable; key tightens to 0640.
                        if [[ "${f}" == "${TLS_KEY_FILE}" ]]; then
                            chmod 0640 "${f}"
                        else
                            chmod 0644 "${f}"
                        fi
                    else
                        die "TLS file ${f} is not readable by the documentdb-gateway OS user. Run as root, or manually: sudo chown root:${gw_user} ${f} && sudo chmod 0640 ${f}"
                    fi
                fi
            done
        fi
        # Tighten the
        # private-key permission warning. 0600/0640 are both fine; warn
        # only when group/world has read.
        local key_perms
        key_perms="$(stat -c '%a' "${TLS_KEY_FILE}" 2>/dev/null || true)"
        if [[ -n "${key_perms}" ]]; then
            local pad="${key_perms}"
            while [[ "${#pad}" -lt 4 ]]; do pad="0${pad}"; done
            # Other (last digit) must be 0; group readable (middle digit) is OK if owner=root and group=documentdb-gateway.
            local other_digit="${pad: -1}"
            if [[ "${other_digit}" != "0" ]]; then
                log_warn "TLS key ${TLS_KEY_FILE} is world-accessible (${pad}). Tighten to 0640 or 0600 before running in production."
            fi
        fi
    fi

    resolve_password

    if [[ "${NO_ENABLE}" == "true" && "${LOAD_SAMPLE_DATA}" == "true" ]]; then
        die "--load-sample-data requires a running gateway and cannot be combined with --no-enable."
    fi
}

resolve_runtime_paths() {
    GATEWAY_BINARY="$(resolve_gateway_binary)" || die "Unable to find the gateway binary at /usr/bin/documentdb-gateway or in the repo build output."
    CONFIG_FILE="$(resolve_config_file)" || die "Unable to find SetupConfiguration.json at /etc/documentdb/gateway/SetupConfiguration.json or in the repo. If you just installed the documentdb-gateway package, try: sudo dpkg --configure -a   (the postinst may have been skipped because an unrelated dependency was missing). Then re-run documentdb-setup."
    SAMPLE_DATA_DIR="$(resolve_sample_data_dir)" || true
    INIT_DATA_SCRIPT="$(resolve_init_data_script)" || true
    HAS_WORKING_SYSTEMD=false
    if has_working_systemd; then
        HAS_WORKING_SYSTEMD=true
    fi

    # Late default computation (Issue 4): PG_PORT and DATA_DIR depend on
    # PG_VERSION, but parse_arguments runs before detect_postgres_installation
    # so PG_VERSION may still be empty there. Recompute the defaults here,
    # AFTER detect_postgres_installation has populated PG_VERSION from the
    # installed PG binaries, so the operator gets the per-major paths the
    # design promises (PG 18 → port 9718, /var/lib/documentdb-local/18/data)
    # rather than the legacy "${DEFAULT_*}" placeholders.
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        # Only override the defaults if the operator did NOT explicitly set
        # them and they are still at the parse-time legacy value.
        if [[ "${PG_PORT_EXPLICIT}" != "true" ]] \
                && { [[ -z "${PG_PORT}" ]] || [[ "${PG_PORT}" == "${DEFAULT_PG_PORT}" ]]; }; then
            PG_PORT="$(documentdb_default_pg_port "${PG_VERSION}")"
        fi
        if [[ "${DATA_DIR_EXPLICIT}" != "true" ]] \
                && { [[ -z "${DATA_DIR}" ]] || [[ "${DATA_DIR}" == "${DEFAULT_DATA_DIR}" ]]; }; then
            DATA_DIR="/var/lib/documentdb-local/${PG_VERSION}/data"
        fi
        # Per-major Unix-socket directory under /run/ — matches the
        # documentdb-postgresql@N.service unit's expectations.
        PG_SOCKET_DIR="/run/documentdb-local/${PG_VERSION}/postgresql"
    fi
}

refresh_extension_state() {
    local _sharedir
    _sharedir="$("${PG_CONFIG}" --sharedir)"
    EXTENSION_CONTROL_FILE="${_sharedir}/extension/documentdb.control"
    EXTENDED_RUM_CONTROL_FILE="${_sharedir}/extension/documentdb_extended_rum.control"

    documentdb_detect_extended_rum "${_sharedir}"
}

validate_documentdb_extension_installation() {
    [[ -f "${EXTENSION_CONTROL_FILE}" ]] || die "The DocumentDB extension package is not installed for PostgreSQL ${PG_VERSION} (${EXTENSION_CONTROL_FILE} is missing)."
}

preflight_validation() {
    require_root
    validate_required_arguments

    command_exists jq || die "jq is required but not installed. Install with: apt install jq"

    # Brownfield adoption REQUIRES the delegated tools. The inline
    # fallbacks (build_postgres_conf_block / _legacy_ensure_pg_ident_map)
    # exist only for tools-less greenfield dev hosts: pointed at an
    # adopted operator cluster they would clobber its listen_addresses /
    # port / unix_socket_directories with greenfield defaults and write a
    # pg_hba map with no entry for the operator's OS users. Fail fast
    # BEFORE any mutation instead of leaving the adopted cluster
    # half-broken at the first delegation point.
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        if ! command_exists documentdb-tune || ! command_exists documentdb-register-gateway; then
            die "Brownfield adoption (--target-postgres-instance) requires documentdb-tune and documentdb-register-gateway on PATH (package: documentdb-postgresql-tools). The inline fallbacks are greenfield-only: against an adopted cluster they would overwrite operator-managed listen settings and lock out local access. Install documentdb-postgresql-tools and re-run."
        fi
    fi
    detect_postgres_installation
    # detect_postgres_installation resolves the AUTHORITATIVE target major
    # (highest-installed-with-extension for greenfield, or the pinned brownfield
    # major) — which can differ from the early main() probe's "highest installed"
    # on a multi-major host where the extension lives on a <16 major. Enforce the
    # gateway's PostgreSQL 16+ requirement here, before resolve_runtime_paths and
    # ensure_documentdb_runtime_user (the first host mutation), so every apply
    # path is rejected on the authoritative major before any mutation.
    enforce_gateway_pg_major_supported "${PG_VERSION}"
    resolve_runtime_paths

    # Greenfield over brownfield: refuse BEFORE any mutation. The same
    # check in persist_self_managed_postgres_state fires only after
    # initdb has run and the legacy env file has been rewritten — an
    # accidental `documentdb-setup --yes` on a brownfield host then left
    # an orphaned private data directory and clobbered legacy state
    # despite the refusal. The state-file existence test is pure, so run
    # it here first; the late check stays as defense-in-depth.
    if [[ -z "${TARGET_CLUSTER}" && -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        local preflight_brownfield="/etc/documentdb/local/${PG_VERSION}/brownfield.conf"
        if [[ -f "${preflight_brownfield}" ]]; then
            die "A brownfield install (adopted PostgreSQL) already exists for major ${PG_VERSION} (${preflight_brownfield}). Refusing to also create a package-owned private instance for the same major: that would start a second PostgreSQL cluster alongside the adopted one. Detach the existing install first with 'documentdb-setup --restore', then re-run."
        fi
    fi

    refresh_extension_state
    validate_documentdb_extension_installation
    [[ -x "${GATEWAY_BINARY}" ]] || die "The gateway binary was not found at ${GATEWAY_BINARY}."
    [[ -f "${CONFIG_FILE}" ]] || die "The gateway configuration file was not found at ${CONFIG_FILE}."

    # On greenfield, the wizard
    # ran initdb (slow!), then tried to start PG on the per-major port,
    # then failed cryptically with "pg_ctl: could not start server" if
    # the port was already in use by a foreign cluster. Worse, the state
    # file was written before the failure, leaving the install in a
    # half-broken state. Probe the port BEFORE initdb. Only applies in
    # greenfield mode; brownfield adopts the existing PG that is by
    # definition already listening. Allow our OWN greenfield PG (owned by
    # documentdb-local) on this port — that path goes through
    # resolve_live_cluster_metadata which knows how to handle a
    # re-setup against the existing private cluster.
    if [[ -z "${TARGET_CLUSTER}" && "${RESTORE}" != "true" \
            && "${STATUS_ONLY}" != "true" && "${PRINT_CONFIG}" != "true" \
            && "${DRY_RUN}" != "true" ]]; then
        local pg_listener_pid
        pg_listener_pid="$(find_listener_pid "${PG_PORT}" 2>/dev/null)"
        # Resolve the pid to stat via the shared helper — same decision table as
        # the live-cluster adoption path (see resolve_uid_check_target in
        # documentdb-tools-lib.sh). Empty result ⇒ nothing safe to stat (no
        # listener, or our own postmaster, or a genuinely blind host) ⇒ skip.
        local _pf_uid_target=""
        _pf_uid_target="$(resolve_uid_check_target "${pg_listener_pid}" "${PG_PORT}")"
        if [[ -n "${_pf_uid_target}" ]]; then
            local listener_uid="" documentdb_local_uid=""
            listener_uid="$(stat -c '%u' "/proc/${_pf_uid_target}" 2>/dev/null || true)"
            documentdb_local_uid="$(id -u documentdb-local 2>/dev/null || true)"
            if [[ -n "${listener_uid}" && -n "${documentdb_local_uid}" \
                    && "${listener_uid}" != "${documentdb_local_uid}" ]]; then
                local existing_owner=""
                existing_owner="$(ps -o user= -p "${_pf_uid_target}" 2>/dev/null | awk '{print $1}' || true)"
                die "Port ${PG_PORT} is already in use by a process owned by ${existing_owner:-uid ${listener_uid}} (pid ${_pf_uid_target}) — NOT the documentdb-local OS user. The greenfield setup wizard needs an unused per-major PG port. Choose another with --pg-port, or stop the existing service on ${PG_PORT}. (Per-major default is 9700 + PG_VERSION; 9718 for PG 18.)"
            fi
            # Else: listener IS owned by documentdb-local → our own PG.
            # Fall through; the wizard will adopt it via the live-cluster path.
        fi
    fi

    # Multi-major gateway-port collision check. When another per-major
    # install already owns GATEWAY_PORT, refusing here with an actionable
    # error is much friendlier than letting the second per-major gateway
    # service silently fail to bind. Per design §4.4 the operator owns
    # the port-allocation policy across multiple majors; we don't
    # auto-allocate but we DO catch the collision before initdb runs.
    #
    # Preserve a previous run's listen port / TLS choice BEFORE the
    # collision scan (and, crucially, before persist_self_managed_
    # postgres_state rewrites setup.conf later in the greenfield flow —
    # reading the state only from ensure_pg_ident_map was too late: the
    # wizard had already clobbered GATEWAY_PORT back to the default in
    # the very file the helper reads). Running it here also stops a bare
    # day-2 re-run of a --listen-port install from being killed by the
    # collision check comparing the DEFAULT port against the other
    # majors' recorded ports.
    default_gateway_settings_from_persisted_state
    # This check also runs for brownfield setup (TARGET_CLUSTER set): a
    # brownfield install records GATEWAY_PORT in brownfield.conf and must not
    # reuse a port another major already owns either. --restore / --status /
    # --print-config / --dry-run are excluded (they make no port claim), and
    # the same-major entry is skipped below, so a re-apply never self-collides.
    if [[ "${RESTORE}" != "true" \
            && "${STATUS_ONLY}" != "true" && "${PRINT_CONFIG}" != "true" \
            && "${DRY_RUN}" != "true" \
            && -n "${PG_VERSION}" ]]; then
        local existing_state existing_pg_ver existing_port
        # Scan both the greenfield per-major setup.conf and the brownfield
        # state file: brownfield installs deliberately record GATEWAY_PORT in
        # brownfield.conf (never setup.conf, which would wrongly activate the
        # templated PG service), so a port already claimed by a brownfield
        # install would otherwise be invisible to this collision check.
        for existing_state in /etc/documentdb/local/*/setup.conf \
                              /etc/documentdb/local/*/brownfield.conf; do
            [[ -r "${existing_state}" ]] || continue
            existing_pg_ver="$(grep -E '^PG_VERSION=' "${existing_state}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            [[ "${existing_pg_ver}" == "${PG_VERSION}" ]] && continue
            existing_port="$(grep -E '^GATEWAY_PORT=' "${existing_state}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            if [[ -n "${existing_port}" && "${existing_port}" == "${GATEWAY_PORT}" ]]; then
                # Suggest a fresh port that doesn't collide with the
                # existing per-major install. Bias upward (current + 1)
                # so the suggestion is always a higher, unused port.
                local suggested=$((existing_port + 1))
                die "Gateway port ${GATEWAY_PORT} is already in use by the documentdb-local@${existing_pg_ver} install (recorded in ${existing_state}). Per design §4.4, side-by-side major installs require distinct public gateway ports. Re-run with --gateway-port <DIFFERENT_PORT> (e.g. --gateway-port ${suggested}) to assign a fresh port for this PG ${PG_VERSION} install."
            fi
        done
    fi

    if [[ "${LOAD_SAMPLE_DATA}" == "true" ]]; then
        if [[ -z "${SAMPLE_DATA_DIR}" || ! -d "${SAMPLE_DATA_DIR}" ]]; then
            die "Sample data loading was requested but no sample-data directory could be resolved."
        fi
        if [[ -z "${INIT_DATA_SCRIPT}" || ! -x "${INIT_DATA_SCRIPT}" ]]; then
            die "Sample data loading was requested but init_documentdb_data.sh is unavailable."
        fi
        command_exists mongosh             || die "Sample data loading was requested but mongosh is not installed. Install mongosh and retry."
    fi

    if [[ "${NO_ENABLE}" != "true" ]]; then
        local gw_listener_pid=""
        gw_listener_pid="$(find_listener_pid "${GATEWAY_PORT}")"
        if [[ -n "${gw_listener_pid}" ]]; then
            if ! listener_looks_like_gateway "${gw_listener_pid}" "${GATEWAY_PORT}"; then
                # A pid-1 here is the unresolved placeholder (a genuine
                # gateway-as-pid-1 would have matched the classifier's exe
                # check against /proc/1/exe). Saying "non-gateway process
                # (pid 1)" asserted a fact nobody established — give the
                # honest unknown-owner message and its actionable remedy.
                if [[ "${gw_listener_pid}" == "1" ]]; then
                    die_unknown_listener_owner "${GATEWAY_PORT}"
                fi
                die "Gateway port ${GATEWAY_PORT} is already in use by a non-gateway process (pid ${gw_listener_pid}). Use --gateway-port to specify a different port, or --no-enable to skip gateway startup."
            fi
        fi
    fi

    ensure_documentdb_runtime_user
}

ensure_socket_dir_writable() {
    local socket_parent
    socket_parent="$(dirname "${PG_SOCKET_DIR}")"
    # The grandparent (/run/documentdb-local) would otherwise be an implicit
    # 0700 root-only intermediate under umask 077, blocking the gateway
    # user's traversal to the socket.
    install -d -m 0755 "$(dirname "${socket_parent}")"
    install -d -o documentdb-local -g documentdb-gateway -m 0750 "${socket_parent}"
    install -d -o documentdb-local -g documentdb-gateway -m 0750 "${PG_SOCKET_DIR}"
}

# Day-2 re-runs must not silently reset the gateway's listen port or TLS
# configuration. register-gateway rebuilds the managed gateway.env block
# WHOLESALE from its arguments, and the wizard always passes --listen-addr
# (GATEWAY_PORT is never empty) and a --tls-auto-generate value — so a
# re-run without --listen-port/--tls-* converted a "--listen-port 27017
# --tls-cert/--tls-key" install to port 10260 with a fresh self-signed
# cert, breaking clients with no error. When the operator did not pass the
# flags explicitly, default them from what the previous run persisted
# (GATEWAY_PORT in the per-major state file; TLS keys in the per-major
# gateway.env managed fragment).
default_gateway_settings_from_persisted_state() {
    [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || return 0
    local per_major_dir="/etc/documentdb/local/${PG_VERSION}"

    if [[ "${GATEWAY_PORT_EXPLICIT}" != "true" ]]; then
        local _state _persisted_port=""
        for _state in "${per_major_dir}/setup.conf" "${per_major_dir}/brownfield.conf"; do
            [[ -r "${_state}" ]] || continue
            _persisted_port="$(grep -E '^GATEWAY_PORT=' "${_state}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            [[ -n "${_persisted_port}" ]] && break
        done
        if [[ -n "${_persisted_port}" && "${_persisted_port}" =~ ^[0-9]+$ \
                && "${_persisted_port}" != "${GATEWAY_PORT}" ]]; then
            local _keep_prefix=""
            [[ "${DRY_RUN}" == "true" ]] && _keep_prefix="[dry-run] "
            log_info "${_keep_prefix}Keeping gateway listen port ${_persisted_port} from the previous run (pass --listen-port to change it)."
            GATEWAY_PORT="${_persisted_port}"
        fi
    fi

    # TLS: only when the operator passed nothing at all this run.
    if [[ -z "${TLS_CERT_FILE}" && -z "${TLS_KEY_FILE}" && -z "${TLS_AUTO_GENERATE}" ]]; then
        local _env_file="${per_major_dir}/gateway.env"
        if [[ -r "${_env_file}" ]]; then
            local _p_auto _p_cert _p_key
            _p_auto="$(grep -E '^DOCUMENTDB_TLS_AUTO_GENERATE=' "${_env_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            _p_cert="$(grep -E '^DOCUMENTDB_TLS_CERT_FILE=' "${_env_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            _p_key="$(grep -E '^DOCUMENTDB_TLS_KEY_FILE=' "${_env_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            if [[ -n "${_p_cert}" && -n "${_p_key}" ]]; then
                local _keep_tls_prefix=""
                [[ "${DRY_RUN}" == "true" ]] && _keep_tls_prefix="[dry-run] "
                log_info "${_keep_tls_prefix}Keeping the operator TLS certificate from the previous run: ${_p_cert} (pass --tls-cert/--tls-key or --tls-auto-generate true to change it)."
                TLS_CERT_FILE="${_p_cert}"
                TLS_KEY_FILE="${_p_key}"
                TLS_AUTO_GENERATE="${_p_auto:-false}"
            elif [[ "${_p_auto}" == "true" ]]; then
                TLS_AUTO_GENERATE="${_p_auto}"
            fi
            # A persisted auto-generate=false WITHOUT a persisted cert/key
            # pair (possible from older installs) is deliberately not
            # propagated: forwarding it alone would make the daemon exit 78
            # ("false requires cert and key") in a systemd restart loop.
            # Leaving TLS_AUTO_GENERATE empty falls back to the default
            # (auto-generate true), which keeps the endpoint working.
        fi
    fi
}

ensure_pg_ident_map() {
    # Phase 10 delegation (per packaging-design.md §4.4): the wizard now
    # delegates all hba + ident + role + connection-URL-file work to
    # documentdb-register-gateway, which owns the design-canonical map
    # name "documentdb-gateway-map" and the gateway-side OS user mapping.
    # The wizard's superuser persona is the documentdb-local OS user,
    # and peer auth maps it 1:1 to the documentdb-local PG role created
    # by initdb --username=documentdb-local — no ident map entry needed
    # for that direction. The previous inline map used the wrong name
    # ("documentdb-map") and the wrong OS user ("documentdb"); both are
    # corrected by the delegation.
    if ! command_exists documentdb-register-gateway; then
        log_warn "documentdb-register-gateway is not on PATH; falling back to inline ident-map writing. Install documentdb-postgresql-tools to use the design-canonical delegation path."
        _legacy_ensure_pg_ident_map
        return $?
    fi

    # Preserve a previous run's listen port / TLS choice unless the
    # operator explicitly overrides them this run (see the helper's
    # comment for why a bare re-run must not reset them).
    default_gateway_settings_from_persisted_state

    # On Debian brownfield, the HBA/
    # ident files live at /etc/postgresql/<V>/<C>/, NOT under the data
    # directory. Passing --pgdata "${LIVE_DATA_DIR}" makes register-gateway
    # look for /var/lib/postgresql/<V>/<C>/pg_hba.conf which doesn't exist
    # on Debian — the call aborts before any registration completes.
    # Greenfield is unaffected because the private data dir DOES contain
    # hba/ident there.
    local -a rg_args=()
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        # Brownfield: let register-gateway re-resolve the canonical paths
        # for the named distro cluster (it has its own Debian/RHEL layout
        # logic in resolve_cluster_paths). Pass --state-mode brownfield
        # so register-gateway writes brownfield.conf (no greenfield-PG-service
        # trigger) instead of setup.conf. Without --state-mode the tool
        # would write setup.conf, which would activate
        # documentdb-postgresql@N.service against the adopted PG, violating
        # The design's brownfield isolation.
        rg_args+=(--target-postgres-instance "${TARGET_CLUSTER}" --state-mode brownfield)
    else
        # Greenfield: the private per-major data dir is the canonical
        # location for hba/ident (initdb places them there).
        # Also pass --pg-version
        # explicitly. Before this fix, register-gateway saw PG_VERSION=""
        # and silently skipped role creation, secret file, env fragment,
        # and state recording. register-gateway has its own
        # PGDATA-derivation fallback, but passing explicitly is more
        # robust and doesn't depend on the PG_VERSION file being readable.
        rg_args+=(--pgdata "${LIVE_DATA_DIR}" --pg-version "${PG_VERSION}" --state-mode greenfield)
    fi
    # In brownfield mode we deliberately do NOT forward --socket-dir/--pg-port.
    # By this point prepare_brownfield_instance HAS overridden PG_SOCKET_DIR /
    # PG_PORT to the adopted instance's verified endpoint (the same values
    # apply_managed_postgres_settings forwards to documentdb-tune), but explicit
    # overrides here would suppress register-gateway's own canonical resolution
    # from --target-postgres-instance (resolve_cluster_paths owns the
    # Debian/RHEL layout logic, hba/ident paths included) — one authoritative
    # resolver is safer than two. For brownfield, let register-gateway resolve
    # everything from --target-postgres-instance.
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        rg_args+=(--pg-owner "${PG_OWNER}" --yes)
    else
        rg_args+=(
            --socket-dir "${PG_SOCKET_DIR}"
            --pg-port "${PG_PORT}"
            --pg-owner "${PG_OWNER}"
            --yes
        )
    fi
    # The per-major gateway-local@N.service
    # only loads its EnvironmentFile (per-major gateway.env); it does NOT
    # load SetupConfiguration.json. So the operator's --listen-port has to
    # land in the per-major env file. Thread it through register-gateway.
    if [[ -n "${GATEWAY_PORT}" ]]; then
        rg_args+=(--listen-addr ":${GATEWAY_PORT}")
    fi
    # Standalone defaults to TLS auto-gen per design §4.3 — UNLESS the
    # operator explicitly passed --tls-cert/--tls-key (in which case
    # validate_required_arguments already pinned TLS_AUTO_GENERATE=false)
    # or explicitly passed --tls-auto-generate true|false. The default
    # path is unchanged: auto-generate=true so a fresh install gets a
    # working TLS endpoint without operator intervention.
    if [[ -n "${TLS_CERT_FILE}" && -n "${TLS_KEY_FILE}" ]]; then
        rg_args+=(--tls-cert "${TLS_CERT_FILE}" --tls-key "${TLS_KEY_FILE}")
    fi
    if [[ -n "${TLS_AUTO_GENERATE}" ]]; then
        rg_args+=(--tls-auto-generate "${TLS_AUTO_GENERATE}")
    else
        rg_args+=(--tls-auto-generate true)
    fi
    if [[ "${VERBOSE}" == "true" ]]; then
        rg_args+=(--verbose)
    fi
    log_info "Delegating pg_hba.conf / pg_ident.conf / gateway role / connection-URL file to documentdb-register-gateway."
    # The previous version invoked
    # register-gateway through confirm_or_apply, which streams stdout/stderr
    # to the terminal but does not retain a captured buffer. When the
    # delegated tool fails, the operator sees the wizard's
    # "see above for details" but the most recent line on screen may be
    # truncated by terminal scrollback (or by `tail` consumers). Capture
    # the full delegated output and re-emit it on failure with a clear
    # leading marker so the actual error is unmissable in any output sink.
    # Capture the CONTENT of the managed hba/ident blocks BEFORE invoking
    # register-gateway so we can tell whether register-gateway actually changed
    # them — not merely whether the markers were already present. Comparing the
    # extracted block content (rather than mere marker presence, or a whole-file
    # md5 that churns because prepend_with_managed_block adds a trailing newline
    # each run) means an upgrade or parameter change that rewrites the block with
    # DIFFERENT content still triggers the reload it needs, while a truly
    # idempotent re-run correctly skips it.
    local _hba_before="" _ident_before=""
    if [[ -r "${LIVE_HBA_FILE}" ]]; then
        _hba_before="$(extract_managed_block_content "${LIVE_HBA_FILE}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}")"
    fi
    if [[ -r "${LIVE_IDENT_FILE}" ]]; then
        _ident_before="$(extract_managed_block_content "${LIVE_IDENT_FILE}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}")"
    fi
    local rg_log
    create_temp_file rg_log
    if ! confirm_or_apply "Run documentdb-register-gateway --yes against ${LIVE_DATA_DIR}" \
            _run_register_gateway_capturing "${rg_log}" "${rg_args[@]}"; then
        echo "" >&2
        echo "==== documentdb-register-gateway FAILED — full output below ====" >&2
        cat "${rg_log}" >&2
        echo "==== end of documentdb-register-gateway output ====" >&2
        die "documentdb-register-gateway failed; see above for details."
    fi
    # Compare the managed-block content after register-gateway ran. If both
    # blocks are byte-identical to what was there before, the run was a no-op
    # and the live PostgreSQL already has these rules loaded — skip the reload.
    # Otherwise (block newly added, or content rewritten by an upgrade / param
    # change) a reload is required to activate the new hba/ident rules.
    local _hba_after="" _ident_after=""
    if [[ -r "${LIVE_HBA_FILE}" ]]; then
        _hba_after="$(extract_managed_block_content "${LIVE_HBA_FILE}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}")"
    fi
    if [[ -r "${LIVE_IDENT_FILE}" ]]; then
        _ident_after="$(extract_managed_block_content "${LIVE_IDENT_FILE}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}")"
    fi
    if [[ "${_hba_before}" == "${_hba_after}" && "${_ident_before}" == "${_ident_after}" ]]; then
        log_verbose "pg_hba/pg_ident managed blocks unchanged by register-gateway; skipping reload-required exit."
        PG_RELOAD_CHANGED=false
    else
        PG_RELOAD_CHANGED=true
    fi
}

# Helper: run register-gateway and tee its combined output to ${log_file}
# So the wizard can re-emit it on failure.
_run_register_gateway_capturing() {
    local log_file="$1"; shift
    DOCUMENTDB_REGISTER_GATEWAY_QUIET=1 documentdb-register-gateway "$@" 2>&1 | tee "${log_file}"
    # Preserve register-gateway's exit code (not tee's).
    return "${PIPESTATUS[0]}"
}

# Inline fallback (Phase 10 escape hatch). Kept for dev environments where
# documentdb-register-gateway is not installed. The map name and OS users
# used here intentionally match the pre-Phase-10 behavior; this path is
# deprecated and will be removed once tools is hard-Depends across all
# packaging variants.
_legacy_ensure_pg_ident_map() {
    local ident_file="${LIVE_IDENT_FILE}"
    local unsafe_legacy_map_line="documentdb-map   documentdb   all"
    local map_line=""
    local temp_file=""
    local desired_block=""
    local existing_block=""
    local changed=false
    local -a map_lines=(
        "documentdb-map   documentdb   documentdb"
        "documentdb-map   documentdb   +documentdb_readonly_role"
        "documentdb-map   documentdb   +documentdb_readwrite_role"
        "documentdb-map   documentdb   +documentdb_admin_role"
        "documentdb-map   documentdb-gateway   documentdb-gateway"
        "documentdb-map   documentdb-gateway   +documentdb_readonly_role"
        "documentdb-map   documentdb-gateway   +documentdb_readwrite_role"
        "documentdb-map   documentdb-gateway   +documentdb_admin_role"
        # The wizard's own greenfield superuser persona. The fallback hba
        # rule is `local all all peer map=documentdb-map` (first match
        # wins), so EVERY local peer connection must resolve through this
        # map — including the wizard connecting as documentdb-local right
        # after first start. Without this identity entry the greenfield
        # fallback locked itself out: wait_for_postgres failed auth for
        # 60s and died with a misleading "did not become ready" error.
        "documentdb-map   documentdb-local   documentdb-local"
    )

    [[ -f "${ident_file}" ]] || die "PostgreSQL ident file does not exist: ${ident_file}"

    # The legacy unsafe `documentdb-map documentdb all` line was historically
    # added by older documentdb-setup versions and lives outside any managed
    # block. Strip it so the managed block becomes the sole source of truth
    # for the map; the strip is a no-op once the upgrade has been done.
    if grep -Fqx "${unsafe_legacy_map_line}" "${ident_file}" 2>/dev/null; then
        create_temp_in_dir temp_file "$(dirname "${ident_file}")"
        grep -Fvx "${unsafe_legacy_map_line}" "${ident_file}" > "${temp_file}" || true
        preserve_file_metadata "${ident_file}" "${temp_file}"
        mv "${temp_file}" "${ident_file}"
        changed=true
    fi

    # Build the desired managed block content (newline-joined map lines) and
    # compare against any existing managed block in the file. Any drift --
    # including a missing block, an outdated block, or the previous
    # marker-less appended-line layout removed above -- triggers a rewrite.
    # Wrapping the entries in start/end markers is what lets `apt purge` /
    # `dnf remove` cleanly strip them later via cleanup_managed_blocks in the
    # maintainer scripts; without the markers the entries would survive
    # uninstall and silently mutate an adopted cluster's pg_ident.conf.
    desired_block="$(printf '%s\n' "${map_lines[@]}")"
    desired_block="${desired_block%$'\n'}"
    existing_block="$(extract_managed_block_content "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}")"
    if [[ "${existing_block}" != "${desired_block}" ]]; then
        log_verbose "Updating pg_ident.conf managed block for documentdb peer authentication."
        rewrite_with_managed_block "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}" "${desired_block}"
        changed=true
    fi

    # Defensive: the loop below also strips any stale duplicate map lines
    # that survived outside the managed block (e.g. an admin manually
    # copy-pasted them at some point). The managed block already provides
    # the entries; any duplicate outside the block is now redundant.
    for map_line in "${map_lines[@]}"; do
        if has_line_outside_managed_block "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}" "${map_line}"; then
            create_temp_in_dir temp_file "$(dirname "${ident_file}")"
            grep -Fvx "${map_line}" "${ident_file}" > "${temp_file}" || true
            preserve_file_metadata "${ident_file}" "${temp_file}"
            mv "${temp_file}" "${ident_file}"
            # Re-establish the managed block after stripping the duplicate so
            # the map entries inside the block are not collateral damage.
            rewrite_with_managed_block "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}" "${desired_block}"
            changed=true
        fi
    done

    if [[ "${changed}" == "true" ]]; then
        PG_RELOAD_CHANGED=true
    fi
}

# Helpers used by confirm_or_apply for the greenfield initdb path.
# Separated so the consent prompt covers the whole logical step rather than
# individual mkdir/chown calls.
_greenfield_create_data_dir() {
    # The script-level `umask 077` (line 17) makes `mkdir -p ${DATA_DIR}`
    # create every intermediate dir mode 0700 owned by root. The data
    # dir itself is chown'd to documentdb-local + chmod'd 0700 below, but
    # the PER-MAJOR PARENT (/var/lib/documentdb-local/N) stays mode 0700
    # root-owned. When the wizard then `runuser`s to documentdb-local to
    # run initdb, the unprivileged documentdb-local process cannot
    # traverse that parent (no `x` bit for it) and initdb fails with
    # "could not access directory ${DATA_DIR}: Permission denied".
    #
    # On a real bare-metal install the parent dir is already created by
    # the documentdb-N package's tmpfiles.d, owned by documentdb-local —
    # so the bug only surfaces when the data dir is non-default OR the
    # tmpfiles.d entry hasn't run yet (typical for `--data-dir`
    # overrides and for fresh container installs where systemd is
    # unavailable to run systemd-tmpfiles).
    #
    # Use `install -d` (which ignores umask and lets us pin mode +
    # owner up front) for the per-major parent, then mkdir -p the data
    # dir itself. Install -d is idempotent so re-running the wizard is
    # safe.
    install -d -m 0755 -o documentdb-local -g documentdb-local \
        "$(dirname "${DATA_DIR}")"
    mkdir -p "${DATA_DIR}"
    chown -R documentdb-local:documentdb-local "${DATA_DIR}"
    chmod 700 "${DATA_DIR}"
    ensure_socket_dir_writable
}

_greenfield_run_initdb() {
    run_as_user documentdb-local \
        "${INITDB}" \
        --pgdata="${DATA_DIR}" \
        --username=documentdb-local \
        --auth-local=peer \
        --auth-host=scram-sha-256 \
        --encoding=UTF8
}

# Brownfield: skip initdb, resolve the live PostgreSQL instance the operator
# pointed us at via --target-postgres-instance N/C, set the wizard's
# LIVE_DATA_DIR / LIVE_CONFIG_FILE / LIVE_HBA_FILE / LIVE_IDENT_FILE from
# what PG itself reports.
#
# The wizard never runs initdb here, never chowns the data dir, and never
# starts/stops the system PostgreSQL service. It only writes managed blocks
# inside config files (delegated to documentdb-tune /
# documentdb-register-gateway) and creates the extension + admin user.
# The package-managed stand-alone gateway workflow requires PostgreSQL 16+
# because the gateway authenticates each client's data pool AS that client's
# role over the local socket with an empty password, relying on pg_ident.conf
# '+group' membership (a PostgreSQL 16 feature) to map the gateway OS user to the
# member role. On PG<=15 that mapping never matches and there is no password
# fallback, so authenticated per-user data operations cannot work. PostgreSQL 15
# stays supported for extension-only use. Fails on a KNOWN major < 16; a
# non-numeric/unknown major is a no-op here (register-gateway's own gate — which
# also cross-checks the live server version — is the backstop).
enforce_gateway_pg_major_supported() {
    local major="$1"
    [[ "${major}" =~ ^[0-9]+$ ]] || return 0
    if (( major < 16 )); then
        die "The DocumentDB stand-alone gateway workflow requires PostgreSQL 16 or newer (target major ${major}). The gateway maps its OS user to per-user database roles via pg_ident.conf group membership ('+role'), a PostgreSQL 16 feature, and SCRAM-authenticated users have no password for a password-based fallback. PostgreSQL ${major} is still supported for extension-only use (install postgresql-${major}-documentdb and CREATE EXTENSION documentdb)."
    fi
}

prepare_brownfield_instance() {
    [[ -n "${TARGET_CLUSTER}" ]] || die "prepare_brownfield_instance called without --target-postgres-instance."

    # Strict VERSION/NAME validation. Without this, --target-postgres-instance
    # 18 (no slash) would slip through and produce a broken
    # postgresql@18-18.service Requires= in the brownfield drop-in (the
    # cluster_name fallback to "main" only kicks in for empty-after-slash,
    # not no-slash-at-all, because both ${TARGET_CLUSTER%%/*} and
    # ${TARGET_CLUSTER#*/} return the whole string when there is no slash).
    if [[ "${TARGET_CLUSTER}" != */* ]]; then
        die "--target-postgres-instance must be VERSION/NAME (e.g., 18/main); got ${TARGET_CLUSTER}."
    fi

    local target_pg_version="${TARGET_CLUSTER%%/*}"
    local target_cluster_name="${TARGET_CLUSTER#*/}"
    [[ -n "${target_cluster_name}" ]] || target_cluster_name="main"
    [[ "${target_pg_version}" =~ ^[0-9]+$ ]] || die "--target-postgres-instance must be VERSION/NAME (e.g., 18/main); got ${TARGET_CLUSTER}."
    # Cluster names are PostgreSQL identifiers per Debian's postgresql-common:
    # the first character may be alphanumeric, then any of letters / digits /
    # underscore / dash. Reject anything else so it can't escape into systemd
    # unit names or shell args. Matches pg_createcluster's own constraint —
    # don't be stricter than the underlying tool, or operators with valid
    # existing clusters like "1replica" can't adopt them.
    [[ "${target_cluster_name}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] \
        || die "--target-postgres-instance cluster name must match [A-Za-z0-9][A-Za-z0-9_-]*; got '${target_cluster_name}'."

    log_info "Brownfield adoption: targeting PostgreSQL instance ${target_pg_version}/${target_cluster_name}."

    # Pin wizard state to the targeted PG version (overrides auto-detect).
    PG_VERSION="${target_pg_version}"

    # The stand-alone gateway workflow requires PostgreSQL 16+ (see
    # enforce_gateway_pg_major_supported). Reject a PG<=15 adoption now — before
    # documentdb-tune, hba/ident writes, or role creation mutate the instance.
    enforce_gateway_pg_major_supported "${PG_VERSION}"

    # Re-resolve PG binaries for the targeted major; die if the matching
    # postgresql-N package isn't installed.
    set_postgres_binary_paths "${PG_VERSION}" \
        || die "PostgreSQL ${PG_VERSION} binaries not found. Install postgresql-${PG_VERSION} first."

    # On Debian, refuse early when
    # the named cluster's config directory is absent. Without this, a typo
    # in --target-postgres-instance silently falls through to port 5432,
    # connects to whatever cluster is bound there, mutates THAT cluster's
    # config, and writes a systemd drop-in pointing at a non-existent
    # postgresql@<V>-<typo>.service. The result is an unbootable
    # documentdb-local@N.target on the wrong PG. RHEL has only one
    # implicit cluster per major so the analogous check is on
    # /var/lib/pgsql/<V>/data.
    if [[ -d "/etc/postgresql/${PG_VERSION}" ]]; then
        if [[ ! -d "/etc/postgresql/${PG_VERSION}/${target_cluster_name}" ]]; then
            local known_clusters
            known_clusters="$(ls -1 "/etc/postgresql/${PG_VERSION}" 2>/dev/null | tr '\n' ' ' || true)"
            die "Brownfield: PostgreSQL ${PG_VERSION} cluster '${target_cluster_name}' not found at /etc/postgresql/${PG_VERSION}/${target_cluster_name}. Known clusters for major ${PG_VERSION}: ${known_clusters:-(none)}."
        fi
    elif [[ -d "/var/lib/pgsql/${PG_VERSION}" ]]; then
        if [[ ! -d "/var/lib/pgsql/${PG_VERSION}/data" ]]; then
            die "Brownfield: PostgreSQL ${PG_VERSION} data directory not found at /var/lib/pgsql/${PG_VERSION}/data. Initialize the instance with 'postgresql-${PG_VERSION}-setup --initdb' before adopting it."
        fi
    fi

    # Resolve config paths from the live instance. We use psql via the
    # standard distro socket directory; the gateway will use its own socket
    # via DOCUMENTDB_PG_URL_FILE later.
    local distro_socket
    if [[ -d /var/run/postgresql ]]; then
        distro_socket="/var/run/postgresql"
    elif [[ -d /run/postgresql ]]; then
        distro_socket="/run/postgresql"
    else
        die "Cannot find the system PostgreSQL socket directory (/var/run/postgresql or /run/postgresql)."
    fi

    # Discover the live instance's port (defaults: 5432 unless the operator
    # overrode it via --pg-port). For multi-cluster Debian setups, the port
    # is in /etc/postgresql/N/C/postgresql.conf.
    if [[ "${PG_PORT_EXPLICIT}" != "true" ]]; then
        # PG_PORT currently holds the GREENFIELD per-major default (9700+N),
        # computed in parse_arguments as soon as PG_VERSION is known. That
        # value is meaningless for an adopted distro instance, and because it
        # is never empty it also defeated the `[[ -n "${PG_PORT}" ]] ||
        # PG_PORT="5432"` fallback that used to sit at the end of this block:
        # the fallback could not fire, so on RHEL/Fedora (no /etc/postgresql
        # tree to discover from) EVERY brownfield adoption tried to reach the
        # adopted server on 9700+N and died at the SHOW below with a
        # misleading "Is the instance running?". Same outcome on Debian
        # whenever the cluster's postgresql.conf is unreadable.
        #
        # Discard it and resolve the port from the adopted instance's own
        # config, falling back to the PostgreSQL default.
        local discovered_port=""
        local candidate_conf
        for candidate_conf in "/etc/postgresql/${PG_VERSION}/${target_cluster_name}/postgresql.conf" \
                              "/var/lib/pgsql/${PG_VERSION}/data/postgresql.conf"; do
            [[ -r "${candidate_conf}" ]] || continue
            discovered_port="$(awk -F= '/^[[:space:]]*port[[:space:]]*=/{gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]#].*/, "", $2); print $2; exit}' "${candidate_conf}")"
            [[ "${discovered_port}" =~ ^[0-9]+$ ]] && break
            discovered_port=""
        done
        if [[ -n "${discovered_port}" ]]; then
            PG_PORT="${discovered_port}"
            log_verbose "Brownfield: discovered PostgreSQL port ${PG_PORT} from ${candidate_conf}."
        else
            PG_PORT="5432"
            log_verbose "Brownfield: no port found in the adopted instance's postgresql.conf; assuming the PostgreSQL default ${PG_PORT} (override with --pg-port)."
        fi
    fi

    # One psql round-trip for all four paths. Four separate connections
    # added ~0.5s of connect overhead to every brownfield run, and only the
    # first query carried a die — the other three silenced stderr, so under
    # set -e a mid-sequence failure exited with no message at all. psql
    # executes each -c separately and -tA prints one line per result.
    local -a adopted_paths=()
    mapfile -t adopted_paths < <(
        run_as_user postgres "${PSQL}" -h "${distro_socket}" -p "${PG_PORT}" -d postgres -X -tA -v ON_ERROR_STOP=1 \
            -c "SHOW data_directory;" -c "SHOW config_file;" \
            -c "SHOW hba_file;" -c "SHOW ident_file;" 2>/dev/null
    )
    [[ "${#adopted_paths[@]}" -eq 4 ]] \
        || die "Cannot reach PostgreSQL ${PG_VERSION} at ${distro_socket}:${PG_PORT}. Is the instance running?"
    LIVE_DATA_DIR="$(trim_whitespace "${adopted_paths[0]}")"
    LIVE_CONFIG_FILE="$(trim_whitespace "${adopted_paths[1]}")"
    LIVE_HBA_FILE="$(trim_whitespace "${adopted_paths[2]}")"
    LIVE_IDENT_FILE="$(trim_whitespace "${adopted_paths[3]}")"
    DATA_DIR="${LIVE_DATA_DIR}"
    # The wizard's downstream calls
    # (register-gateway, gateway-admin, psql ops) all consult PG_SOCKET_DIR.
    # In brownfield we MUST use the adopted system PG's socket dir, not
    # the per-major appliance socket dir (which doesn't exist when the
    # appliance PG isn't running). Override PG_SOCKET_DIR explicitly here.
    PG_SOCKET_DIR="${distro_socket}"

    # Even with the early Debian
    # cluster-dir check, the operator may have pointed --pg-port at the wrong
    # cluster's port (or the named cluster's port file was unreadable so we
    # fell back to 5432). After the live SHOW config_file query returns,
    # cross-check that the running instance's config_file actually lives
    # under the named cluster's config dir. Without this verification, the
    # wizard would mutate cluster X's pg_hba.conf while writing a drop-in
    # that wires the gateway to postgresql@<V>-<named>.service for cluster Y.
    if [[ -d "/etc/postgresql/${PG_VERSION}/${target_cluster_name}" ]]; then
        local expected_config_dir="/etc/postgresql/${PG_VERSION}/${target_cluster_name}"
        case "${LIVE_CONFIG_FILE}" in
            "${expected_config_dir}/"*) ;;
            *)
                die "Brownfield: the live PostgreSQL ${PG_VERSION} instance at port ${PG_PORT} uses config_file=${LIVE_CONFIG_FILE}, which is NOT under ${expected_config_dir}/. Refusing to adopt the wrong cluster. Use --pg-port to target the correct cluster, or correct --target-postgres-instance."
                ;;
        esac
    fi

    # packaging-design.md §4.4 Safety Properties: "Warn loudly when adopting
    # a `postgres`-owned PostgreSQL instance (vs. An empty one we'd init
    # ourselves), explain implications, require confirmation. Don't refuse —
    # the user installed `documentdb`; that's the consent." We emit an
    # explicit warning so an interactive operator pauses to read it; the
    # subsequent per-step confirm_or_apply prompts still gate each invasive
    # change. In --yes mode the operator has already given upfront consent
    # (CI / scripted install), so we log loudly and proceed.
    local live_owner_uid live_owner
    live_owner_uid="$(stat -c '%u' "${LIVE_DATA_DIR}" 2>/dev/null || true)"
    live_owner="$(stat -c '%U' "${LIVE_DATA_DIR}" 2>/dev/null || true)"
    if [[ -n "${live_owner_uid}" && "${live_owner_uid}" -ne 0 ]]; then
        log_warn "Adopting an existing PostgreSQL instance owned by OS user '${live_owner:-uid ${live_owner_uid}}' (data_directory ${LIVE_DATA_DIR})."
        log_warn "  This wizard will write managed blocks to that instance's postgresql.conf, pg_hba.conf, and pg_ident.conf,"
        log_warn "  create the documentdb-gateway PG role, and install a systemd drop-in that ties documentdb-gateway-local@${PG_VERSION}.service"
        log_warn "  to the adopted PG service. All changes are reversible via 'documentdb-setup --restore' or 'apt purge documentdb-${PG_VERSION}'."
        log_warn "  Existing PostgreSQL data, users, and application schemas are preserved; only managed-block edits and a few new role grants are added."
        if [[ "${YES}" != "true" ]]; then
            local reply=""
            printf 'Adopt this PostgreSQL instance and continue? [y/N] ' >&2
            IFS= read -r reply || reply=""
            case "${reply}" in
                y|Y|yes|YES) ;;
                *) die "Aborted at brownfield-adoption confirmation. Re-run with --yes to skip this prompt." ;;
            esac
        else
            log_warn "Proceeding non-interactively because --yes was given."
        fi
    fi

    # Brownfield's PG runs under the distro's "postgres" OS user; that's
    # who we connect as for CREATE EXTENSION + admin bootstrap.
    PG_OWNER="postgres"

    log_info "Brownfield instance discovered:"
    log_info "  data_directory: ${LIVE_DATA_DIR}"
    log_info "  config_file:    ${LIVE_CONFIG_FILE}"
    log_info "  hba_file:       ${LIVE_HBA_FILE}"
    log_info "  ident_file:     ${LIVE_IDENT_FILE}"
    log_info "  port:           ${PG_PORT}"
    log_info "  socket dir:     ${distro_socket}"
}

prepare_self_managed_cluster() {
    # Greenfield creates a private PostgreSQL instance of major PG_VERSION and
    # attaches the gateway to it. Reject a PG<=15 target before initdb / tune /
    # any mutation, since the gateway cannot authenticate per-user pools there.
    enforce_gateway_pg_major_supported "${PG_VERSION}"

    local existing_data_version=""
    local current_preload=""
    local merged_preload=""
    local live_listener_pid=""

    PG_OWNER="documentdb-local"
    LIVE_DATA_DIR="${DATA_DIR}"
    LIVE_CONFIG_FILE="${DATA_DIR}/postgresql.conf"
    LIVE_HBA_FILE="${DATA_DIR}/pg_hba.conf"
    LIVE_IDENT_FILE="${DATA_DIR}/pg_ident.conf"

    if [[ -d "${DATA_DIR}" && ! -f "${DATA_DIR}/PG_VERSION" && -n "$(ls -A "${DATA_DIR}" 2>/dev/null || true)" ]]; then
        die "Data directory ${DATA_DIR} exists but is not a valid PostgreSQL cluster."
    fi

    if [[ -f "${DATA_DIR}/PG_VERSION" ]]; then
        existing_data_version="$(head -n 1 "${DATA_DIR}/PG_VERSION" | cut -d'.' -f1)"
        if [[ "${existing_data_version}" != "${PG_VERSION}" ]]; then
            die "Existing data directory ${DATA_DIR} was initialized for PostgreSQL ${existing_data_version}, not ${PG_VERSION}."
        fi
    else
        # packaging-design.md §4.4: private stand-alone instances "never bind
        # to port 5432, even when no system PostgreSQL is running" — the
        # guarantee is that a later `apt install postgresql` (or any service
        # expecting the default port) can never collide with the
        # package-private instance. Enforced only on the CREATE-new-cluster
        # branch (and mirrored in the --dry-run preview): brownfield
        # legitimately adopts 5432, and an already-initialized data dir above
        # must stay re-runnable regardless of its recorded port — refusing
        # here would brick day-2 re-runs of an existing install.
        if [[ "${PG_PORT}" == "5432" ]]; then
            die "--pg-port 5432 is not allowed for a new package-private PostgreSQL instance: the design reserves the default PostgreSQL port for system instances so they can never collide with this one (packaging-design.md §4.4). Choose another port (default: $(documentdb_default_pg_port "${PG_VERSION}")), or adopt an existing 5432 instance with --target-postgres-instance."
        fi

        live_listener_pid="$(find_listener_pid "${PG_PORT}")"
        if [[ -n "${live_listener_pid}" ]]; then
            if ! listener_looks_like_postgres "${live_listener_pid}" "${PG_PORT}"; then
                # Classification FAILED. If the pid is the unknown-owner
                # placeholder, do not assert "a non-PostgreSQL process" —
                # nothing established that, and in this greenfield branch
                # DATA_DIR is by definition not yet an initialized cluster, so
                # postmaster_pid_owns_port could not resolve it either. Report
                # what is actually true and name the remedy.
                #
                # This check must come AFTER the classifier, not before it: on
                # a systemd host listener_looks_like_postgres resolves the same
                # placeholder from its active-unit fallback, and pre-empting
                # that produced a spurious "install lsof or iproute2" for a
                # condition lsof would not have fixed.
                if [[ "${live_listener_pid}" == "1" ]] && ! pid1_is_postgres; then
                    die_unknown_listener_owner "${PG_PORT}" postgres
                fi
                die "Port ${PG_PORT} is in use by a non-PostgreSQL process."
            fi
            die "Port ${PG_PORT} is already in use by PostgreSQL, but ${DATA_DIR} is not an initialized DocumentDB data directory. Use --data-dir for the running cluster, use --pg-port for a new cluster, or stop the existing PostgreSQL process."
        fi

        confirm_or_apply "Create per-major data directory ${DATA_DIR} owned by documentdb-local:documentdb-local" \
            _greenfield_create_data_dir
        confirm_or_apply "Initialize PostgreSQL ${PG_VERSION} cluster in ${DATA_DIR} (initdb --username=documentdb-local)" \
            _greenfield_run_initdb
    fi

    live_listener_pid="$(find_listener_pid "${PG_PORT}")"
    if [[ -n "${live_listener_pid}" ]]; then
        resolve_live_cluster_metadata "${PG_PORT}"
        current_preload="${LIVE_PRELOAD_LIBRARIES}"
    else
        current_preload="$(read_shared_preload_libraries_from_file "${LIVE_CONFIG_FILE}")"
    fi

    # apply_managed_postgres_settings (postgresql.conf)
    # may be called now because writing to a stopped PG instance's
    # postgresql.conf is safe. But hba/ident/role/conn-file delegation
    # to documentdb-register-gateway must wait until after PG is started,
    # because register-gateway connects to the live instance to create
    # the gateway PG role and verify the extension. The wizard's main
    # now calls register_gateway_after_pg_running after
    # start_or_restart_postgres for this reason.
    merged_preload="$(merge_shared_preload_libraries "${current_preload}")"
    if [[ "${current_preload}" != "${merged_preload}" ]]; then
        PG_CONFIG_CHANGED=true
    fi

    apply_managed_postgres_settings "${LIVE_CONFIG_FILE}" "${LIVE_HBA_FILE}" "${merged_preload}" "off"
}

# Invoked AFTER start_or_restart_postgres so that
# documentdb-register-gateway can connect to the live PG instance. Also
# passes the PG owner (documentdb-local for greenfield, postgres for
# brownfield) so register-gateway connects as the right OS user.
register_gateway_after_pg_running() {
    ensure_pg_ident_map
}

wait_for_postgres() {
    local attempt=""
    for attempt in $(seq 1 60); do
        if run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -qAt -v ON_ERROR_STOP=1 -c "SELECT 1" >/dev/null 2>&1; then
            log_verbose "PostgreSQL became ready on attempt ${attempt}."
            return 0
        fi
        sleep 1
    done

    die "PostgreSQL did not become ready on localhost:${PG_PORT} within 60 seconds."
}

# Reconstruct the operator-supplied flags for the brownfield "restart PG,
# then re-run" handoff. The previous version kept only --admin-user/--yes:
# with --admin-password-file + --yes the printed step-2 command died
# immediately in resolve_password ("--yes was given but no admin password
# source was provided"), and dropped --listen-port/--tls-* flags meant the
# re-run silently reset the gateway port and TLS material (now also
# defended in default_gateway_settings_from_persisted_state, but the
# printed command should still reflect what the operator asked for).
build_rerun_suffix() {
    local suffix=""
    [[ -n "${USERNAME}" ]] && suffix+=" --admin-user ${USERNAME}"
    if [[ -n "${PASSWORD_FILE}" ]]; then
        suffix+=" --admin-password-file ${PASSWORD_FILE}"
    elif [[ "${PASSWORD_FROM_STDIN}" == "true" ]]; then
        suffix+=" --admin-password-stdin"
    fi
    [[ "${GATEWAY_PORT_EXPLICIT}" == "true" ]] && suffix+=" --listen-port ${GATEWAY_PORT}"
    if [[ -n "${TLS_CERT_FILE}" && -n "${TLS_KEY_FILE}" ]]; then
        suffix+=" --tls-cert ${TLS_CERT_FILE} --tls-key ${TLS_KEY_FILE}"
    elif [[ -n "${TLS_AUTO_GENERATE}" ]]; then
        suffix+=" --tls-auto-generate ${TLS_AUTO_GENERATE}"
    fi
    [[ "${YES}" == "true" ]] && suffix+=" --yes"
    printf '%s' "${suffix}"
}

start_or_restart_postgres() {
    # Brownfield: never touch the system PostgreSQL service. We print the
    # required reload/restart command and rely on the operator to execute
    # it once they've inspected the config block we wrote.
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        # Resolve the adopted PG unit via the shared helper so an empty cluster
        # name (e.g. "18/") is normalized to "main" instead of producing a
        # broken postgresql@18-.service; Debian vs RHEL layout is handled there.
        local reload_hint=""
        reload_hint="sudo systemctl reload $(resolve_brownfield_pg_service_unit)"
        if [[ "${PG_CONFIG_CHANGED}" == "true" ]]; then
            # pg_documentdb is a
            # shared_preload_libraries extension — it won't load until the
            # postmaster restarts. We wrote shared_preload_libraries via
            # documentdb-tune, but the postmaster is still the OLD one.
            # If we proceed to CREATE EXTENSION documentdb here, it FAILS
            # with "extension documentdb must be loaded via shared_preload_libraries".
            # The operator is left with a half-configured install
            # (managed blocks in hba/ident/conf, gateway role, drop-in)
            # but no extension, no admin user, and no working gateway.
            # Stop here and tell the operator to restart PG + re-run.
            log_warn "Brownfield mode: PostgreSQL must be restarted to pick up shared_preload_libraries changes."
            log_warn "    Run: ${reload_hint/reload/restart}"
            log_warn ""
            log_warn "documentdb-setup is exiting BEFORE running CREATE EXTENSION because"
            log_warn "pg_documentdb is a preload library and will not load until the"
            log_warn "postmaster has restarted. Re-run this command after PostgreSQL has"
            log_warn "been restarted; the second run will detect that the managed blocks"
            log_warn "are already in place and proceed to CREATE EXTENSION + admin bootstrap."
            log_warn ""
            log_warn "Steps:"
            log_warn "  1. ${reload_hint/reload/restart}"
            # Reconstruct a suggested re-run command using the original
            # operator-supplied flags. YES is the literal string "true" or
            # "false" (set in parse_arguments), NOT empty/non-empty — so
            # use a value check, not ${YES:+...}.
            local rerun_suffix=""
            rerun_suffix="$(build_rerun_suffix)"
            log_warn "  2. sudo documentdb-setup --target-postgres-instance ${TARGET_CLUSTER}${rerun_suffix}"
            if [[ "${PASSWORD_FROM_STDIN}" == "true" ]]; then
                log_warn "     (pipe the admin password to step 2 again, e.g.: printf %s \"\$PW\" | sudo documentdb-setup ...)"
            fi
            exit 0
        elif [[ "${PG_RELOAD_CHANGED}" == "true" ]]; then
            # The prior
            # implementation only LOGGED a reload hint and then
            # continued into create_required_extensions_and_users +
            # start_gateway. The gateway authenticates as the
            # documentdb-gateway PG role via the new pg_hba.conf entry
            # we just wrote — but until PG reloads, that entry is not
            # active, so the gateway cannot connect. We have already
            # mutated pg_hba/pg_ident, so the operator has implicitly
            # consented to those changes; reload is non-disruptive
            # (in-flight queries are not interrupted) and applies the
            # rules we wrote. Use confirm_or_apply so --yes/--dry-run
            # gates still work and the operator can refuse.
            # Same shared resolver as the reload_hint above, so the empty-cluster
            # ("18/") normalization to "main" applies here too.
            local pg_unit_name=""
            pg_unit_name="$(resolve_brownfield_pg_service_unit)"
            if has_systemd_unit_file "${pg_unit_name}"; then
                confirm_or_apply "Reload ${pg_unit_name} to pick up hba/ident changes (non-disruptive)" \
                    systemctl reload "${pg_unit_name}"
            else
                # No systemd / unit not installed (manual pg_ctl
                # installs). Fall back to exit-and-rerun symmetry with
                # the restart-required path: print the hint, exit 0,
                # and let the operator reload + re-run.
                log_warn "Brownfield mode: PostgreSQL must be reloaded to pick up hba/ident changes."
                log_warn "    Run: ${reload_hint}"
                log_warn ""
                log_warn "documentdb-setup is exiting BEFORE starting the gateway because"
                log_warn "the new pg_hba.conf/pg_ident.conf rules are not active yet;"
                log_warn "the gateway would fail to authenticate as the documentdb-gateway"
                log_warn "PG role. Re-run this command after PostgreSQL has been reloaded."
                log_warn ""
                local rerun_suffix=""
                rerun_suffix="$(build_rerun_suffix)"
                log_warn "  1. ${reload_hint}"
                log_warn "  2. sudo documentdb-setup --target-postgres-instance ${TARGET_CLUSTER}${rerun_suffix}"
                if [[ "${PASSWORD_FROM_STDIN}" == "true" ]]; then
                    log_warn "     (pipe the admin password to step 2 again, e.g.: printf %s \"\$PW\" | sudo documentdb-setup ...)"
                fi
                exit 0
            fi
        fi
        wait_for_postgres
        return 0
    fi

    log_info "Starting the self-managed PostgreSQL instance in ${DATA_DIR} (per-major templated unit)."
    ensure_socket_dir_writable

    local pg_unit="documentdb-postgresql@${PG_VERSION}.service"

    # Per design §4.4, the stand-alone package exposes a per-major
    # templated PG unit (documentdb-postgresql@N.service) wired via the
    # per-major target documentdb-local@N.target. We always prefer it
    # when systemd is available and the unit file is shipped.
    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && has_systemd_unit_file "${pg_unit}"; then
        # Record HOW PostgreSQL is actually managed, at the decision point.
        # print_completion_message reads this instead of re-deriving it —
        # re-derivation at print time has drifted from this branch three
        # times in this file's history.
        PG_STARTED_VIA="systemd"
        confirm_or_apply "Enable ${pg_unit} (per-major templated PG service)" \
            systemctl enable "${pg_unit}" >/dev/null
        if systemctl is-active --quiet "${pg_unit}"; then
            if [[ "${PG_CONFIG_CHANGED}" == "true" ]]; then
                confirm_or_apply "Restart ${pg_unit} to apply shared_preload_libraries changes" \
                    systemctl restart "${pg_unit}"
            elif [[ "${PG_RELOAD_CHANGED}" == "true" ]]; then
                confirm_or_apply "Reload ${pg_unit} to apply hba/ident changes" \
                    systemctl reload-or-restart "${pg_unit}"
            fi
        else
            confirm_or_apply "Start ${pg_unit}" \
                systemctl start "${pg_unit}"
        fi
    else
        # Dev / non-systemd fallback: drive pg_ctl directly. Same OS user
        # as the templated unit so the data directory ownership matches.
        PG_STARTED_VIA="pg_ctl"
        if run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" status >/dev/null 2>&1; then
            if [[ "${PG_CONFIG_CHANGED}" == "true" ]]; then
                log_info "Configuration changed; restarting PostgreSQL to apply new settings."
                run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" -w restart
            elif [[ "${PG_RELOAD_CHANGED}" == "true" ]]; then
                log_info "Authentication mapping changed; reloading PostgreSQL configuration."
                run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" reload
            fi
        else
            run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" -l "${DATA_DIR}/pglog.log" -w start
        fi
    fi

    wait_for_postgres
}

reload_self_managed_postgres_auth_mapping() {
    [[ "${PG_RELOAD_CHANGED}" == "true" ]] || return 0

    log_info "Authentication mapping changed; reloading PostgreSQL configuration."
    local pg_unit="documentdb-postgresql@${PG_VERSION}.service"
    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && has_systemd_unit_file "${pg_unit}" \
            && systemctl is-active --quiet "${pg_unit}"; then
        confirm_or_apply "Reload ${pg_unit} to apply hba/ident changes" \
            systemctl reload-or-restart "${pg_unit}"
    else
        run_as_user documentdb-local "${PG_CTL}" -D "${DATA_DIR}" reload
    fi
    PG_RELOAD_CHANGED=false
}

create_required_extensions_and_users() {
    log_info "Creating required extensions and roles."

    confirm_or_apply "Run CREATE EXTENSION documentdb CASCADE in the postgres database" \
        _create_documentdb_extension_inline

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        confirm_or_apply "Run CREATE EXTENSION documentdb_extended_rum CASCADE in the postgres database" \
            _create_extended_rum_extension_inline
    fi

    if run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -tA -v ON_ERROR_STOP=1 -v role_name="${USERNAME}" <<'SQL' | grep -q '^1$'; then
SELECT 1 FROM pg_roles WHERE rolname = :'role_name';
SQL
        # The prior implementation
        # short-circuited here without applying the operator's new
        # password. After a `--restore + re-setup --admin-password-stdin
        # <new-pw>`, mongosh login with new-pw failed silently because
        # the wizard never updated the password. Fix: if the operator
        # provided a fresh password, push it through documentdb_api.update_user.
        # resolve_password guarantees PASSWORD is non-empty on every apply
        # path (it dies otherwise), so no "leave credentials unchanged"
        # branch exists: a re-run always offers the password reset (gated
        # by confirm_or_apply / --yes like every other invasive step).
        log_info "User ${USERNAME} already exists; resetting password via documentdb_api.update_user()."
        confirm_or_apply "Reset password for existing admin user '${USERNAME}'" \
            reset_documentdb_user_password "${PG_OWNER}" "${PG_PORT}" "${USERNAME}" "${PASSWORD}"
        return 0
    fi

    confirm_or_apply "Bootstrap first admin user '${USERNAME}' via documentdb_api.create_user()" \
        create_documentdb_user "${PG_OWNER}" "${PG_PORT}" "${USERNAME}" "${PASSWORD}"
}

# Companion to create_documentdb_user, used when the user already exists
# And the operator supplied a fresh password.
reset_documentdb_user_password() {
    local pg_owner="$1"
    local pg_port="$2"
    local username="$3"
    local password="$4"
    local bson_file
    local pwfile
    # Pass the password to jq via a chmod 600 temp file read with --rawfile
    # instead of --arg: --arg would place the cleartext password on jq's
    # command line, where it is visible in ps / /proc/<pid>/cmdline for the
    # lifetime of the process. This mirrors create_documentdb_user.
    create_temp_file pwfile
    printf '%s' "${password}" > "${pwfile}"
    chmod 600 "${pwfile}"
    create_temp_file bson_file
    jq -cn \
        --arg user "${username}" \
        --rawfile pwd "${pwfile}" \
        '{updateUser: $user, pwd: $pwd}' > "${bson_file}"
    rm -f "${pwfile}"
    chown "${pg_owner}" "${bson_file}" 2>/dev/null || true
    run_as_user "${pg_owner}" env "BSON_FILE=${bson_file}" \
        "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${pg_port}" \
        -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
-- Suppress statement logging so the password embedded in the BSON payload is
-- not written to the PostgreSQL log (log_statement / log_min_duration_statement
-- / log_min_error_statement). Mirrors documentdb-gateway-admin.sh.
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_error_statement = 'panic';
\set bson_arg `cat "$BSON_FILE"`
SELECT documentdb_api.update_user(:'bson_arg'::documentdb_core.bson);
SQL
}

# documentdb-register-gateway runs
# BEFORE CREATE EXTENSION on the greenfield path, so its IF EXISTS GRANT of
# documentdb_admin_role / documentdb_readwrite_role / documentdb_readonly_role
# to the gateway PG role is a silent no-op (the group roles do not exist
# yet). After CREATE EXTENSION creates the groups, nothing re-runs the
# GRANT and the gateway then panics on first start with PG error 42501
# (insufficient_privilege at aclchk.c).
#
# Fix: re-run the grants here, AFTER CREATE EXTENSION. Idempotent and a
# no-op on re-runs because GRANT-to-existing-membership succeeds silently.
# Wrapped in confirm_or_apply so --dry-run and the interactive consent
# gate stay consistent with every other invasive step in the wizard.
grant_gateway_role_memberships() {
    confirm_or_apply "GRANT documentdb_admin_role + readwrite + readonly to the documentdb-gateway PG role (required after CREATE EXTENSION; first start otherwise fails with code=42501)" \
        _grant_gateway_role_memberships_inline
}

_grant_gateway_role_memberships_inline() {
    run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
DO $$
DECLARE
    grp text;
BEGIN
    -- Only grant if both the group and gateway role exist; first dev
    -- environments without the gateway runtime package skip cleanly.
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'documentdb-gateway') THEN
        RAISE NOTICE 'documentdb-gateway role not present; skipping group grants (install documentdb-gateway package + run documentdb-register-gateway first).';
        RETURN;
    END IF;

    FOREACH grp IN ARRAY ARRAY['documentdb_admin_role','documentdb_readwrite_role','documentdb_readonly_role']
    LOOP
        IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = grp) THEN
            EXECUTE format('GRANT %I TO %I', grp, 'documentdb-gateway');
        ELSE
            RAISE NOTICE 'Skipping GRANT % - role does not exist yet (CREATE EXTENSION documentdb did not run).', grp;
        END IF;
    END LOOP;
END
$$;
SQL
}

# Helpers used by confirm_or_apply so CREATE EXTENSION steps go through
# the consent gate. Heredoc-style SQL invocations can't be passed
# verbatim as "$@" args, so they live in tiny wrappers.
_create_documentdb_extension_inline() {
    run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS documentdb CASCADE;
-- Idempotently upgrade the in-database extension to the installed default
-- version. On a first install this is a no-op; on a re-run after a package
-- upgrade (which replaces the .so + SQL upgrade scripts but leaves the
-- in-database version stale) this runs the shipped documentdb--X--Y.sql
-- migrations so the running extension matches the installed files.
-- Release discipline: under ON_ERROR_STOP=1 this hard-fails if a package
-- ever advances the extension's default_version without shipping the
-- contiguous documentdb--X--Y.sql upgrade path ("extension has no update
-- path"). Every release must ship the matching upgrade script.
ALTER EXTENSION documentdb UPDATE;
SQL
}

_create_extended_rum_extension_inline() {
    run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" -d postgres -X -v ON_ERROR_STOP=1 <<'SQL'
CREATE EXTENSION IF NOT EXISTS documentdb_extended_rum CASCADE;
ALTER EXTENSION documentdb_extended_rum UPDATE;
SQL
}

update_gateway_configuration() {
    # On per-major Workflow C installs the canonical config source is
    # the per-major /etc/documentdb/local/N/gateway.env (loaded by the
    # systemd unit and the /usr/bin/documentdb-gateway wrapper). The
    # singleton JSON at /etc/documentdb/gateway/SetupConfiguration.json
    # is a transitional compat shim per design §4.3 and MUST NOT be
    # rewritten with per-major-specific PostgresPort/GatewayListenPort/
    # PostgresHostName values, because on multi-major hosts the LAST
    # wizard to run would clobber the singleton with its own ports,
    # leaving earlier majors' gateways unable to bind. Stamp the JSON
    # only for non-per-major (Workflow B) flows.
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ \
            && -f "/etc/documentdb/local/${PG_VERSION}/gateway.env" ]]; then
        log_verbose "Skipping update of singleton SetupConfiguration.json on per-major install; env file is authoritative."
        # Defensive cleanup: strip stale per-major connection fields
        # from the singleton JSON. A prior wizard run for a different
        # major may have left them set, which would leak into Workflow B
        # callers or into the daemon's JSON-then-env precedence merge.
        if command_exists jq && [[ -f "${CONFIG_FILE}" ]]; then
            local cleaned_tmp=""
            create_temp_in_dir cleaned_tmp "$(dirname "${CONFIG_FILE}")"
            if jq 'del(.PostgresPort, .GatewayListenPort, .PostgresHostName, .PostgresSystemUser, .PostgresDataUser, .PostgresDataUserPassword)' \
                    "${CONFIG_FILE}" > "${cleaned_tmp}" 2>/dev/null; then
                preserve_file_metadata "${CONFIG_FILE}" "${cleaned_tmp}"
                mv "${cleaned_tmp}" "${CONFIG_FILE}"
                log_verbose "Stripped per-major connection fields from singleton SetupConfiguration.json."
            fi
        fi
        return 0
    fi
    log_info "Updating gateway configuration at ${CONFIG_FILE}."
    update_json_file "${CONFIG_FILE}"
}

wait_for_gateway_ready() {
    # Caller passes the
    # systemd unit name that was actually started (per-major templated
    # unit, non-templated, or the empty string for the nohup fallback)
    # so the failure-hint journalctl command points at the right unit.
    # Previously this was hardcoded to "documentdb-gateway", which is
    # the WRONG unit when start_gateway selected
    # documentdb-gateway-local@N.service.
    local running_unit="${1:-}"
    local attempt=""
    for attempt in $(seq 1 60); do
        if timeout 2 bash -c "echo >/dev/tcp/127.0.0.1/${GATEWAY_PORT}" >/dev/null 2>&1; then
            log_verbose "Gateway became ready on attempt ${attempt}."
            return 0
        fi
        sleep 1
    done

    local hint=""
    if [[ -n "${running_unit}" ]]; then
        hint="Check logs: journalctl -u ${running_unit} --no-pager -n 20"
    else
        hint="Check logs at /var/lib/documentdb-gateway/gateway.log"
    fi
    die "The gateway did not become ready on localhost:${GATEWAY_PORT} within 60 seconds. ${hint}"
}

stop_gateway_process() {
    local pid="$1"
    local port="$2"

    if [[ -z "${pid}" || ! "${pid}" =~ ^[0-9]+$ ]] || (( 10#${pid} <= 1 )); then
        log_warn "Refusing to signal PID '${pid}' for port ${port}: owning process ID is not safely resolved."
        return 1
    fi

    kill "${pid}"
    if wait_for_listener_to_clear "${port}" 30; then
        return 0
    fi

    log_warn "Process ${pid} did not stop after SIGTERM; sending SIGKILL."
    kill -KILL "${pid}" 2>/dev/null || true
    if ! wait_for_listener_to_clear "${port}" 10; then
        log_warn "Process ${pid} did not stop even after SIGKILL."
        return 1
    fi
}

verify_gateway_unit_active() {
    # After a systemd start/restart, confirm the unit actually activated.
    # A unit whose ConditionPathExists gate is unmet (e.g. the per-major
    # gateway.env was never written because documentdb-register-gateway did not
    # run — the _legacy_ensure_pg_ident_map fallback path) is SKIPPED by systemd
    # with an exit-success, so `systemctl start` returns 0 while the gateway
    # never launches. Without this check the wizard would then block in
    # wait_for_gateway_ready for 60s and die with a misleading "did not become
    # ready" timeout that hides the real cause. Skip in dry-run (nothing was
    # actually started).
    local gw_unit="$1"
    [[ "${DRY_RUN}" == "true" ]] && return 0
    systemctl is-active --quiet "${gw_unit}" && return 0

    local env_hint=""
    if [[ "${gw_unit}" == documentdb-gateway-local@* ]]; then
        env_hint=" This usually means the per-major connection file /etc/documentdb/local/${PG_VERSION}/gateway.env is missing, so the unit's ConditionPathExists gate skipped the start; run 'documentdb-register-gateway' (from the documentdb-postgresql-tools package) to write it, then retry."
    fi
    die "The gateway unit ${gw_unit} is not active after 'systemctl start' (or the start step was skipped / answered 'dry-run').${env_hint} Check: journalctl -u ${gw_unit} --no-pager -n 20."
}

start_gateway() {
    local existing_gateway_pid=""

    # Per design §4.4, the per-major templated gateway unit is the public
    # day-2 surface. We prefer it whenever a PG_VERSION is known and the
    # unit file is shipped.
    local gw_unit=""
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        gw_unit="documentdb-gateway-local@${PG_VERSION}.service"
    fi
    # Fallback to the non-templated unit if the per-major template isn't
    # available (Workflow B / pre-Phase-10 installs).
    if [[ -z "${gw_unit}" ]] || ! has_systemd_unit_file "${gw_unit}"; then
        gw_unit="documentdb-gateway.service"
    fi

    if [[ "${NO_ENABLE}" == "true" ]]; then
        # The operator asked us not to (re)enable the gateway. But if a
        # previously running gateway was torn down by Requires= dependency
        # propagation when we restarted PostgreSQL above, restore it so
        # --no-enable does not turn into "stop the gateway as a side effect."
        if [[ "${GATEWAY_WAS_ACTIVE}" == "true" ]] \
                && [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] \
                && has_systemd_unit_file "${gw_unit}" \
                && ! systemctl is-active --quiet "${gw_unit}"; then
            log_info "Restoring previously running gateway after PostgreSQL restart (--no-enable preserves prior state)."
            systemctl start "${gw_unit}"
            verify_gateway_unit_active "${gw_unit}"
            wait_for_gateway_ready "${gw_unit}"
            GW_STARTED_VIA="systemd"
        else
            log_info "Skipping gateway startup because --no-enable was requested."
        fi
        return 0
    fi

    if has_systemd_unit_file "${gw_unit}"; then
        # If a manually-started gateway is occupying the port, stop it before
        # handing control to systemd to avoid a port conflict.
        existing_gateway_pid="$(find_listener_pid "${GATEWAY_PORT}")"
        if [[ -n "${existing_gateway_pid}" ]]; then
            if ! systemctl is-active --quiet "${gw_unit}"; then
                [[ "${existing_gateway_pid}" != "1" ]] || die_unknown_listener_owner "${GATEWAY_PORT}"
                # CLASSIFY before signalling. find_listener_pid now resolves a
                # REAL pid on no-ss/lsof hosts, and preflight's gateway check
                # ran long before this (PostgreSQL was restarted in between), so
                # a foreign process that bound GATEWAY_PORT since then must not
                # be SIGKILLed as "the manual gateway". The nohup branch below
                # already classifies; this one must too.
                if ! listener_looks_like_gateway "${existing_gateway_pid}" "${GATEWAY_PORT}"; then
                    die "Gateway port ${GATEWAY_PORT} is in use by a non-gateway process (pid ${existing_gateway_pid}); refusing to stop it for the systemd takeover. Use --gateway-port for a different port, or stop that process yourself."
                fi
                # Listener exists, is our gateway, but systemd doesn't own it —
                # stop the manual process so the unit can take over.
                log_info "Stopping manually started gateway (pid ${existing_gateway_pid}) before systemd takeover."
                if ! stop_gateway_process "${existing_gateway_pid}" "${GATEWAY_PORT}"; then
                    die "Gateway port ${GATEWAY_PORT} is still in use after stopping process ${existing_gateway_pid}."
                fi
            fi
        fi

        log_info "Starting the gateway with systemd (${gw_unit})."
        confirm_or_apply "Enable ${gw_unit}" systemctl enable "${gw_unit}" >/dev/null
        if systemctl is-active --quiet "${gw_unit}"; then
            confirm_or_apply "Restart ${gw_unit}" systemctl restart "${gw_unit}"
        else
            confirm_or_apply "Start ${gw_unit}" systemctl start "${gw_unit}"
        fi
        verify_gateway_unit_active "${gw_unit}"
        wait_for_gateway_ready "${gw_unit}"
        GW_STARTED_VIA="systemd"
        # systemd owns the gateway from here, so any nohup record for this port
        # is obsolete. Leaving it would let a later fallback read a PID systemd
        # has since replaced — and within one boot /run does not clear it for
        # us. The reader's identity check would usually reject a recycled PID,
        # but on a multi-major host it could recycle onto ANOTHER gateway,
        # which is the collateral kill this whole mechanism replaced.
        rm -f "$(nohup_gateway_pidfile "${GATEWAY_PORT}")" 2>/dev/null || true
        return 0
    fi

    existing_gateway_pid="$(find_listener_pid "${GATEWAY_PORT}")"
    if [[ -n "${existing_gateway_pid}" ]]; then
        if [[ "${existing_gateway_pid}" == "1" ]]; then
            # Placeholder PID: a listener exists but the host cannot map it to
            # a process (no ss/lsof visibility — the environment this nohup
            # fallback serves). Recover the owner from the PER-PORT record the
            # fallback writes at launch, and stop exactly that process.
            #
            # This previously stopped gateways BY NAME with a host-wide
            # `pgrep -f`, which was wrong in three ways: it signalled every
            # gateway on the box, so a re-run for one PostgreSQL major killed
            # another major's healthy gateway and never restarted it; it passed
            # THIS port to stop_gateway_process, so PIDs processed while the
            # port was still held could never satisfy the wait and escalated
            # to SIGKILL; and the pattern also matched the
            # `runuser -u documentdb-gateway --` wrapper this script itself
            # uses, so it could kill a wrapper without freeing the port.
            local recorded_gw_pid=""
            # No 2>/dev/null: the reader logs WHY it rejected a record (stale
            # boot, recycled PID, not the port owner) to stderr, and that
            # rationale should reach the operator who is about to see a
            # fail-closed die. The pid itself comes via stdout ("" on reject).
            recorded_gw_pid="$(nohup_gateway_pid_for_port "${GATEWAY_PORT}" || true)"
            [[ -n "${recorded_gw_pid}" ]] || die_unknown_listener_owner "${GATEWAY_PORT}"

            log_info "Restarting the manually managed gateway on port ${GATEWAY_PORT} (listener PID not identifiable; using the recorded PID ${recorded_gw_pid})."
            if ! stop_gateway_process "${recorded_gw_pid}" "${GATEWAY_PORT}"; then
                die "Gateway port ${GATEWAY_PORT} is still in use after stopping process ${recorded_gw_pid}."
            fi
            # The process the record named is gone; drop the record NOW so a
            # failure between here and the relaunch (which would overwrite
            # it) cannot leave a stale entry for a pid the kernel is free to
            # recycle — the reader's port cross-check is the backstop for
            # that, not the primary defence.
            rm -f "$(nohup_gateway_pidfile "${GATEWAY_PORT}")" 2>/dev/null || true
        else
            if ! listener_looks_like_gateway "${existing_gateway_pid}" "${GATEWAY_PORT}"; then
                die "Port ${GATEWAY_PORT} is already in use by a non-gateway process."
            fi

            log_info "Restarting the manually managed gateway process on port ${GATEWAY_PORT}."
            if ! stop_gateway_process "${existing_gateway_pid}" "${GATEWAY_PORT}"; then
                die "Gateway port ${GATEWAY_PORT} is still in use after stopping process ${existing_gateway_pid}."
            fi
            # Same lifecycle rule as the placeholder branch: the port's
            # process is stopped, so any record for this port is now stale.
            rm -f "$(nohup_gateway_pidfile "${GATEWAY_PORT}")" 2>/dev/null || true
        fi
    else
        # The nohup fallback is a
        # convenience for containers and dev environments that lack
        # systemd, but a production host that silently took this path
        # would never restart the gateway on reboot. Warn loudly so the
        # operator knows the design's day-2 commands (systemctl restart /
        # status / stop) won't work for this install.
        log_warn ""
        log_warn "================================================================"
        log_warn "  Falling back to nohup (no working systemd detected)."
        log_warn "  The gateway will run only until reboot or process kill."
        log_warn "  Production hosts MUST have systemd so the per-major"
        log_warn "  documentdb-local@${PG_VERSION}.target can manage the lifecycle."
        log_warn "  This mode is intended for containers and ephemeral dev hosts."
        log_warn "================================================================"
        log_warn ""
        log_info "Starting the gateway without systemd."
    fi

    local escaped_binary escaped_config
    escaped_binary="$(printf '%q' "${GATEWAY_BINARY}")"
    escaped_config="$(printf '%q' "${CONFIG_FILE}")"

    # Source the per-major env file written by documentdb-register-gateway
    # BEFORE launching the gateway binary so DOCUMENTDB_PG_URL_FILE
    # (which pins the gateway to its dedicated 'documentdb-gateway' PG
    # role via the ident map) wins over the JSON's
    # PostgresDataUser=documentdb-local. The systemd
    # documentdb-gateway-local@N.service unit loads this env file via
    # `EnvironmentFile=-` automatically; the nohup fallback path used
    # here (when systemd is unavailable, e.g. inside a Docker container)
    # has no such mechanism, so we splice it in manually.
    #
    # Without this, the gateway tries to connect as documentdb-local
    # (from the JSON's PostgresDataUser) but its peer-auth OS identity
    # is documentdb-gateway, and the ident map only authorizes
    # documentdb-gateway → (documentdb-gateway + docdb_*_role groups),
    # NOT documentdb-gateway → documentdb-local. The connection then
    # fails with `peer authentication failed for user "documentdb-local"`
    # and the gateway pool spins in a retry loop until the wizard's
    # 60s readiness wait expires.
    local per_major_env=""
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        per_major_env="/etc/documentdb/local/${PG_VERSION}/gateway.env"
    fi
    local env_source_clause=""
    if [[ -n "${per_major_env}" && -r "${per_major_env}" ]]; then
        # shellcheck disable=SC1090,SC2016
        env_source_clause="set -a && . $(printf '%q' "${per_major_env}") && set +a && "
    fi

    # GATEWAY_BINARY is normally the packaged wrapper
    # (/usr/bin/documentdb-gateway). The env_source_clause above sources this
    # env file into the launched process, and the wrapper rejects an
    # unsupported inline DOCUMENTDB_PG_URL it finds in that inherited
    # environment. The repo-build fallback from resolve_gateway_binary
    # (dev-from-source only, when the package is not installed) execs the raw
    # daemon directly and does not enforce that rejection; this is acceptable
    # because the daemon ignores the inline form and no supported flow writes
    # it into gateway.env.
    # Record the launched PID in a PER-PORT file so a later re-run can find
    # THIS gateway on a host where ss/lsof cannot report socket owners. Without
    # a record the only way back from a port to a process is a host-wide
    # process-name match, which also finds other majors' gateways.
    #
    # $! is the daemon's own PID: the wrapper drops privileges with runuser
    # only when it starts as root, and here it is already running as
    # documentdb-gateway, so it takes its `exec "${DAEMON}"` path in place.
    # The `\$!` must stay escaped — it has to expand in the launched shell,
    # not in the wizard.
    local gw_pidfile escaped_pidfile
    gw_pidfile="$(nohup_gateway_pidfile "${GATEWAY_PORT}")"
    escaped_pidfile="$(printf '%q' "${gw_pidfile}")"
    # The record lives under /run. On systemd hosts that is tmpfs, emptied on
    # boot; in a plain Docker container /run is ordinary container storage and
    # SURVIVES a container restart while pids reset — so boot-scoping is NOT a
    # defence exactly where this fallback operates. The real defences are the
    # reader's pid_listens_on_port cross-check (a recycled pid does not hold
    # this port) and the lifecycle rm at every stop/restore/reset site;
    # gateway_exe_matches is the belt to those braces.
    install -d -m 0750 -o documentdb-gateway -g documentdb-gateway \
        "$(dirname "${gw_pidfile}")" 2>/dev/null || true
    #
    # The nohup and the `echo $!` are BRACE-GROUPED. Without the braces, `&`
    # binds to the whole `cd ... && ... nohup ...` AND-list, so the shell
    # backgrounds that entire list and `$!` is the PID of the intermediate
    # subshell — a bash process, not the daemon. The reader's identity check
    # then rejects it and every no-systemd day-2 re-run fails closed with the
    # very "already in use by a non-gateway process (pid 1)" error this is
    # meant to prevent. Verified: ungrouped records `bash -lc cd ... && nohup
    # ...`, grouped records the daemon itself.
    #
    # `|| true` keeps the launch's exit status unconditionally 0, as it was
    # before the record existed. Otherwise a failed write (missing or
    # read-only /run) would abort the wizard under `set -e` AFTER the gateway
    # is already running; a missing record instead makes the next re-run fail
    # closed with an actionable message.
    #
    # The pidfile write is BRACE-GROUPED with its own `2>/dev/null`:
    # redirections apply left-to-right, so in the ungrouped
    # `> pidfile 2>/dev/null` form a failure to OPEN the pidfile printed
    # "No such file or directory" to the operator's terminal before stderr
    # was ever redirected (verified). Grouping routes the open error through
    # the group's stderr, making record failures genuinely silent.
    #
    # The record is THREE fields: "PID STARTTIME BOOT_ID" (see the format note
    # in documentdb-tools-lib.sh). STARTTIME (/proc/PID/stat field 22, robustly
    # parsed after the last ')') lets the reader detect a recycled PID WITHOUT
    # CAP_SYS_PTRACE — which is precisely the container where the fd-scan
    # cross-check is blind; BOOT_ID rejects a record carried across a host
    # reboot. Both are computed INSIDE the gateway-user child group so the file
    # is written once, by its owner, in one operation — a later root-side
    # rewrite would change ownership and the next gateway-user truncate would
    # EACCES into the silent `|| true`, leaving no record. The fields are
    # POSITIONAL, so BOOT_ID is nested INSIDE the STARTTIME expansion
    # (${_gws:+ $_gws${_gwb:+ $_gwb}}): if the daemon dies before the stat read,
    # STARTTIME is empty and BOOT_ID is suppressed WITH it — otherwise the
    # always-readable boot_id would land in the STARTTIME slot and the record
    # would be the malformed "PID BOOT_ID". Result is exactly one of "PID",
    # "PID STARTTIME", or "PID STARTTIME BOOT_ID"; the reader honours all three.
    run_as_user_shell documentdb-gateway \
        "cd /var/lib/documentdb-gateway && ${env_source_clause}{ nohup ${escaped_binary} ${escaped_config} > /var/lib/documentdb-gateway/gateway.log 2>&1 & { _gwp=\$!; _gws=\$(awk '{n=split(\$0,a,\")\"); split(a[n],f); print f[20]}' /proc/\$_gwp/stat 2>/dev/null | tr -dc '0-9'); _gwb=\$(tr -d '[:space:]' < /proc/sys/kernel/random/boot_id 2>/dev/null); printf '%s' \"\$_gwp\${_gws:+ \$_gws\${_gwb:+ \$_gwb}}\" > ${escaped_pidfile}; } 2>/dev/null || true; }"
    GW_STARTED_VIA="nohup"
    # nohup path has no systemd unit; empty argument switches the hint
    # to the log file path instead of journalctl.
    wait_for_gateway_ready ""
}

load_sample_data_if_requested() {
    local -a init_args=()

    if [[ "${LOAD_SAMPLE_DATA}" != "true" ]]; then
        return 0
    fi

    # preflight_validation already died unless the sample-data dir, the
    # init script and mongosh were all present, so no re-check here.
    log_info "Loading packaged sample data from ${SAMPLE_DATA_DIR}."
    init_args=(
        --port "${GATEWAY_PORT}"
        --username "${USERNAME}"
        --data-path "${SAMPLE_DATA_DIR}"
    )
    if [[ "${VERBOSE}" == "true" ]]; then
        init_args+=(--verbose)
    fi

    DOCUMENTDB_PASSWORD="${PASSWORD}" \
        "${INIT_DATA_SCRIPT}" "${init_args[@]}"
}

# The wizard previously
# enabled the individual templated services
# (documentdb-postgresql@N.service, documentdb-gateway-local@N.service)
# but never enabled documentdb-local@N.target itself. Because the
# services have WantedBy=documentdb-local@%i.target, `systemctl enable`
# on the service only creates a symlink in the target .wants/
# directory — it does NOT enable the target itself. So at boot, the
# target never activates and the services it pulls in do not start.
# After a successful setup the services run (because the wizard
# started them transiently), but reboot loses the state.
#
# Fix: enable the per-major target so it activates at boot via its
# own WantedBy=multi-user.target, which transitively pulls in the
# PG service and gateway-local service via Wants= / After=. When the
# documentdb meta package wrapper alias documentdb-local.target exists
# (paved-road install for the public alias major), prefer that so
# day-2 systemctl commands match what the operator sees in the
# completion message.
ensure_target_enabled_at_boot() {
    [[ "${NO_ENABLE}" == "true" ]] && return 0
    [[ "${HAS_WORKING_SYSTEMD}" != "true" ]] && return 0
    [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || return 0

    local per_major_target="documentdb-local@${PG_VERSION}.target"
    has_systemd_unit_file "${per_major_target}" || return 0

    local enable_target="${per_major_target}"
    if [[ "${PG_VERSION}" == "${PUBLIC_ALIAS_PG_MAJOR}" ]] \
            && has_systemd_unit_file "documentdb-local.target"; then
        enable_target="documentdb-local.target"
    fi

    if ! systemctl is-enabled --quiet "${enable_target}" 2>/dev/null; then
        confirm_or_apply "Enable ${enable_target} at boot (per design §4.4)" \
            systemctl enable "${enable_target}" >/dev/null
    else
        log_verbose "${enable_target} already enabled at boot; no change."
    fi

    # The per-major services have already been started directly by
    # start_or_restart_postgres / start_gateway above. The target itself
    # is still "inactive" because nothing requested it. Activating the
    # target now makes systemctl restart/stop/status on the target
    # behave as the print_completion_message and docs claim — without
    # this step `systemctl restart documentdb-local.target` is a no-op
    # (you can only restart what is active).
    if ! systemctl is-active --quiet "${enable_target}" 2>/dev/null; then
        confirm_or_apply "Start ${enable_target} so day-2 commands operate on the target" \
            systemctl start "${enable_target}" >/dev/null
    fi
}

print_completion_message() {
    local preferred_target="documentdb-local.target"
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] \
            && [[ "${PG_VERSION}" != "${PUBLIC_ALIAS_PG_MAJOR}" ]]; then
        preferred_target="documentdb-local@${PG_VERSION}.target"
    fi

    if [[ "${NO_ENABLE}" == "true" ]]; then
        log_success "DocumentDB PostgreSQL setup is complete."
        echo "Start the gateway manually when ready:"
        if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] \
                && [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] \
                && has_systemd_unit_file "documentdb-local@${PG_VERSION}.target"; then
            echo "  sudo systemctl enable --now ${preferred_target}"
        elif [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] \
                && [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] \
                && has_systemd_unit_file "documentdb-gateway-local@${PG_VERSION}.service"; then
            echo "  sudo systemctl enable --now documentdb-gateway-local@${PG_VERSION}.service"
        elif [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && has_systemd_unit_file "documentdb-gateway.service"; then
            echo "  sudo systemctl enable --now documentdb-gateway.service"
        else
            echo "  sudo -u documentdb-gateway env DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/${PG_VERSION}/gateway/pg-url ${GATEWAY_BINARY} run"
        fi
        return 0
    fi

    local connect_host="localhost:${GATEWAY_PORT}"
    local connect_opts="tls=true&tlsAllowInvalidCertificates=true"
    local connect_uri
    # Build URI in parts to avoid credential-pattern false positives in secret scanners.
    # Wrap the mongodb:// URI in single quotes so a copy-paste of this
    # line into a shell preserves the `&` literally (otherwise the shell
    # backgrounds mongosh at the `&` and the rest becomes a separate
    # command). Single-quote choice also matches the documentation in
    # packaging-design.md §5 ("After any workflow"), which uses the
    # quoted form in its mongosh examples.
    # The URI had no database segment, so a
    # newbie running `db.coll.insertOne(...)` operated on the default `test`
    # DB silently. Make the example explicit by including /test in the path
    # and pointing out how to switch DBs.
    connect_uri="mongosh 'mongodb://"
    connect_uri+="${USERNAME}:<your-password>@${connect_host}/mydb?${connect_opts}'"
    log_success "DocumentDB is ready."
    echo "Connect with:"
    echo "  ${connect_uri}"
    echo "  Replace <your-password> with the password you provided."
    echo "  Replace mydb with any DB name; a fresh DB is created on the first insert."
    if ! command_exists mongosh; then
        echo "  Note: mongosh is not installed on this host; install it to run the command above."
    fi
    echo ""

    # Important paths stanza — anchor the operator so they can find
    # logs, certs, and the data directory without grepping the source.
    # Per-major (greenfield) and brownfield differ on a couple of these
    # so we branch.
    local pg_unit="documentdb-postgresql@${PG_VERSION}.service"
    # Mirror start_gateway's unit resolution, including its fallback to the
    # non-templated unit. Hardcoding the per-major template here made a
    # Workflow B / pre-Phase-10 install (where only documentdb-gateway.service
    # is shipped) report as unmanaged: systemd was in fact running the gateway,
    # but the hints named a template that does not exist, concluded "not
    # systemd-managed", and printed a log path that is never written on the
    # systemd path.
    local gw_unit="documentdb-gateway-local@${PG_VERSION}.service"
    if [[ -z "${PG_VERSION}" ]] || ! [[ "${PG_VERSION}" =~ ^[0-9]+$ ]] \
            || ! has_systemd_unit_file "${gw_unit}"; then
        gw_unit="documentdb-gateway.service"
    fi
    local data_dir_display="${DATA_DIR}"
    local tls_dir_display="/var/lib/documentdb-local/${PG_VERSION}/gateway/tls"
    local pg_log_hint
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        # Brownfield: PostgreSQL is the adopted system service; its log
        # location is whatever that service configured. Don't claim to
        # know where it is — point the operator at the journal.
        pg_log_hint="journalctl -u $(resolve_brownfield_pg_service_unit 2>/dev/null || echo 'postgresql@'${PG_VERSION}'-main.service')"
    else
        # Greenfield: we own the PG service. Its stderr is captured by
        # systemd journal (no -l file written; see
        # documentdb_postgresql_service.sh::start_postgres).
        pg_log_hint="journalctl -u ${pg_unit}"
    fi
    # These hints must describe how the services were ACTUALLY started, and
    # that decision is not `HAS_WORKING_SYSTEMD` alone — start_postgres and
    # start_gateway both additionally require the unit file to be installed
    # (has_systemd_unit_file), and fall back to pg_ctl / nohup when it is not.
    # Branching on the flag alone was right for the no-systemd container but
    # still wrong for a dev-from-source run on a systemd host, where the units
    # are not installed: the wizard starts via pg_ctl and nohup and then prints
    # `journalctl -u ...` for units that do not exist. Mirror the real
    # predicate instead.
    local pg_systemd_managed="false" gw_systemd_managed="false"
    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && has_systemd_unit_file "${pg_unit}"; then
        pg_systemd_managed="true"
    fi
    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] && has_systemd_unit_file "${gw_unit}"; then
        gw_systemd_managed="true"
    fi
    # RECORDED truth beats derivation: start_or_restart_postgres and
    # start_gateway set PG_STARTED_VIA / GW_STARTED_VIA at their actual
    # branch points, so when a start ran this run, print from what it DID.
    # The derivation above remains the initializer for paths that never
    # reach a start site (e.g. early NO_ENABLE returns).
    case "${PG_STARTED_VIA:-}" in
        systemd) pg_systemd_managed="true" ;;
        pg_ctl)  pg_systemd_managed="false" ;;
    esac
    case "${GW_STARTED_VIA:-}" in
        systemd) gw_systemd_managed="true" ;;
        nohup)   gw_systemd_managed="false" ;;
    esac
    # Brownfield PostgreSQL is the operator's own system service, which exists
    # independently of our unit files, so the journal hint stays correct there.
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        pg_systemd_managed="${HAS_WORKING_SYSTEMD}"
    fi

    if [[ "${pg_systemd_managed}" != "true" ]]; then
        if [[ -z "${TARGET_CLUSTER}" ]]; then
            pg_log_hint="${DATA_DIR}/pglog.log"
        else
            pg_log_hint="the adopted PostgreSQL instance's configured log"
        fi
    fi

    local gw_log_hint="journalctl -u ${gw_unit}"
    [[ "${gw_systemd_managed}" == "true" ]] || gw_log_hint="/var/lib/documentdb-gateway/gateway.log"

    echo "Important paths:"
    echo "  PG data dir:    ${data_dir_display}"
    echo "  PG logs:        ${pg_log_hint}"
    echo "  Gateway logs:   ${gw_log_hint}"
    echo "  TLS cert/key:   ${tls_dir_display}/{cert.pem,pkey.pem}"
    echo "  Connection URL: /var/lib/documentdb-local/${PG_VERSION}/gateway/pg-url"
    echo "  State file:     /etc/documentdb/local/${PG_VERSION}/$(if [[ -n "${TARGET_CLUSTER}" ]]; then echo brownfield.conf; else echo setup.conf; fi)"
    echo ""

    echo "Day-2 commands:"
    # Recommend the umbrella target ONLY when it exists AND covers both
    # components; otherwise per-component truth. The old single-line form
    # printed `systemctl restart ${preferred_target}` whenever EITHER
    # component was systemd-managed — naming a target that may not exist
    # (Workflow B ships only documentdb-gateway.service) and, in a mixed
    # systemd-PG/nohup-gateway state, silently skipping the component the
    # log hint two lines up correctly points at gateway.log.
    local _tgt_ok="false"
    if [[ "${HAS_WORKING_SYSTEMD}" == "true" ]] \
            && has_systemd_unit_file "${preferred_target}"; then
        _tgt_ok="true"
    fi
    if [[ "${pg_systemd_managed}" == "true" && "${gw_systemd_managed}" == "true" \
            && "${_tgt_ok}" == "true" ]]; then
        echo "  Restart:    sudo systemctl restart ${preferred_target}"
        echo "  Status:     sudo systemctl status ${preferred_target}"
    else
        if [[ "${pg_systemd_managed}" == "true" ]]; then
            # Brownfield PG is the OPERATOR's service, not our greenfield
            # template — name the adopted unit, exactly as the log hint above
            # does. Printing documentdb-postgresql@N.service here told a
            # brownfield operator to restart a unit that does not run (and may
            # not exist for) their adopted cluster.
            local _pg_restart_unit="${pg_unit}"
            if [[ -n "${TARGET_CLUSTER}" ]]; then
                _pg_restart_unit="$(resolve_brownfield_pg_service_unit 2>/dev/null || echo "postgresql@${PG_VERSION}-main.service")"
            fi
            echo "  Restart PG: sudo systemctl restart ${_pg_restart_unit}"
        fi
        if [[ "${gw_systemd_managed}" == "true" ]]; then
            echo "  Restart GW: sudo systemctl restart ${gw_unit}"
        fi
        if [[ "${pg_systemd_managed}" != "true" || "${gw_systemd_managed}" != "true" ]]; then
            # At least one component has no unit managing it, so a wizard
            # re-run is its restart path. Name the flags: a BARE re-run
            # prompts for an admin username that defaults to "admin" and then
            # creates or resets that account, so following a plain "re-run
            # documentdb-setup" hint can silently mint a second
            # full-privilege admin.
            echo "  Restart:    re-run sudo documentdb-setup with the SAME --admin-user"
            echo "              and --admin-password-file you used for this install"
            echo "              (restarts any non-systemd component; a bare re-run"
            echo "               would prompt for an admin name and could create"
            echo "               another account)"
        fi
    fi
    echo "  Health:     sudo documentdb-setup --status"
    echo "  Add user:   sudo documentdb-gateway-admin create-user --username <NAME> --password-file <FILE>"
    echo "  Undo setup: sudo documentdb-setup --restore"
    echo "  Full wipe:  sudo documentdb-local-reset --pg-version ${PG_VERSION} --confirm-destroy"
}

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --username|--admin-user)
                [[ $# -ge 2 ]] || die "--admin-user requires a value."
                USERNAME="$2"
                shift 2
                ;;
            --password-file|--admin-password-file)
                [[ $# -ge 2 ]] || die "--admin-password-file requires a value."
                PASSWORD_FILE="$2"
                shift 2
                ;;
            --admin-password-stdin)
                PASSWORD_FROM_STDIN=true
                shift
                ;;
            --tls-cert)
                [[ $# -ge 2 ]] || die "--tls-cert requires a path."
                TLS_CERT_FILE="$2"
                shift 2
                ;;
            --tls-key)
                [[ $# -ge 2 ]] || die "--tls-key requires a path."
                TLS_KEY_FILE="$2"
                shift 2
                ;;
            --tls-auto-generate)
                [[ $# -ge 2 ]] || die "--tls-auto-generate requires a value (true|false)."
                case "$2" in
                    true|false)
                        TLS_AUTO_GENERATE="$2"
                        ;;
                    *)
                        die "--tls-auto-generate must be true or false (got '$2')."
                        ;;
                esac
                shift 2
                ;;
            --pg-version)
                [[ $# -ge 2 ]] || die "--pg-version requires a value."
                PG_VERSION="$2"
                PG_VERSION_EXPLICIT=true
                shift 2
                ;;
            --pg-port)
                [[ $# -ge 2 ]] || die "--pg-port requires a value."
                PG_PORT="$2"
                PG_PORT_EXPLICIT=true
                shift 2
                ;;
            --gateway-port|--listen-port)
                [[ $# -ge 2 ]] || die "--listen-port requires a value."
                GATEWAY_PORT="$2"
                GATEWAY_PORT_EXPLICIT=true
                shift 2
                ;;
            --data-dir)
                [[ $# -ge 2 ]] || die "--data-dir requires a value."
                DATA_DIR="$2"
                DATA_DIR_EXPLICIT=true
                shift 2
                ;;
            --use-new-postgres-instance|--use-private-cluster)
                # --use-private-cluster is a deprecated alias for the
                # design-canonical --use-new-postgres-instance flag.
                USE_PRIVATE_CLUSTER=true
                shift
                ;;
            --target-postgres-instance|--target-cluster)
                # --target-cluster is a deprecated alias for the
                # design-canonical --target-postgres-instance flag.
                [[ $# -ge 2 ]] || die "$1 requires a value."
                TARGET_CLUSTER="$2"
                shift 2
                ;;
            --yes)
                YES=true
                shift
                ;;
            --dry-run)
                DRY_RUN=true
                shift
                ;;
            --restore)
                RESTORE=true
                shift
                ;;
            --print-config)
                PRINT_CONFIG=true
                shift
                ;;
            --status)
                STATUS_ONLY=true
                shift
                ;;
            --no-enable)
                NO_ENABLE=true
                shift
                ;;
            --skip-init-data)
                LOAD_SAMPLE_DATA=false
                shift
                ;;
            --load-sample-data)
                LOAD_SAMPLE_DATA=true
                shift
                ;;
            --verbose)
                VERBOSE=true
                shift
                ;;
            -h|--help)
                usage
                exit 0
                ;;
            *)
                die "Unknown argument: $1"
                ;;
        esac
    done

    # Default PG port: 9700 + PG_VERSION (per-major). When PG_VERSION is
    # unknown at parse time, leave PG_PORT empty so the post-detect
    # recompute path (resolve_runtime_paths) fills it in after
    # detect_postgres_installation populates PG_VERSION. If detection
    # also fails, parse_arguments-time has no defensible value to use
    # — 9712 is a legacy magic number that does NOT match the design's
    # per-major promise and silently confused dry-run output.
    # Fall back to the
    # DEFAULT_PG_PORT sentinel ONLY so existing
    # `[[ PG_PORT == DEFAULT_PG_PORT ]]` checks still recognize the
    # value as "unchanged from default" and recompute it correctly
    # once PG_VERSION is known. The dry-run preview already handles
    # the "still <auto-detect>" case.
    # If PG_VERSION is still
    # empty after parse_arguments but --target-postgres-instance N/C was
    # given, derive PG_VERSION from the cluster identifier here so the
    # per-major port and data-dir defaults below resolve correctly. This
    # matches what print_config does later; doing it up front means
    # parse_arguments never falls through to the DEFAULT_PG_PORT=0
    # sentinel for a brownfield install whose major is encoded in
    # TARGET_CLUSTER. Without this hoist, the range-validation below
    # rejects the sentinel because 0 is < 1.
    if [[ -z "${PG_VERSION}" && -n "${TARGET_CLUSTER}" ]]; then
        local _derived_major="${TARGET_CLUSTER%%/*}"
        if [[ "${_derived_major}" =~ ^[0-9]+$ ]]; then
            PG_VERSION="${_derived_major}"
        fi
    fi
    if [[ -z "${PG_PORT}" ]]; then
        if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
            PG_PORT="$(documentdb_default_pg_port "${PG_VERSION}")"
        else
            PG_PORT="${DEFAULT_PG_PORT}"
        fi
    fi

    # Default data directory: per-major path if PG_VERSION is known
    if [[ -z "${DATA_DIR}" ]]; then
        if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
            DATA_DIR="/var/lib/documentdb-local/${PG_VERSION}/data"
        else
            DATA_DIR="${DEFAULT_DATA_DIR}"
        fi
    fi

    [[ "${PG_PORT}" =~ ^[0-9]+$ ]] || die "--pg-port must be numeric."
    [[ "${GATEWAY_PORT}" =~ ^[0-9]+$ ]] || die "--listen-port must be numeric."

    # `--tls-auto-generate false` without an operator cert/key is a
    # combination the gateway daemon hard-rejects at startup (exit 78 in a
    # systemd restart loop) — but only AFTER the wizard has already mutated
    # PostgreSQL state, surfacing ~60s later as a generic readiness
    # failure. Pure argument validation, so reject it here (before any
    # root check) with the actual reason.
    if [[ "${TLS_AUTO_GENERATE}" == "false" && ( -z "${TLS_CERT_FILE}" || -z "${TLS_KEY_FILE}" ) ]]; then
        die "--tls-auto-generate false requires --tls-cert and --tls-key (the gateway cannot serve TLS without either an auto-generated or an operator-supplied certificate). To keep a previous run's TLS settings, re-run without any TLS flags."
    fi
    # Skip the strict 1..65535 range check when PG_PORT is still the
    # sentinel — that means PG_VERSION couldn't be resolved at parse time
    # and resolve_runtime_paths will recompute the per-major port after
    # detect_postgres_installation. preflight_validation also requires
    # the extension control file, so an install with no resolvable
    # PG_VERSION will fail there with a clear error before we ever try
    # to bind to the sentinel port.
    if [[ "${PG_PORT}" != "${DEFAULT_PG_PORT}" ]] && (( PG_PORT < 1 || PG_PORT > 65535 )); then
        die "--pg-port must be between 1 and 65535."
    fi
    if (( GATEWAY_PORT < 1 || GATEWAY_PORT > 65535 )); then
        die "--listen-port must be between 1 and 65535."
    fi
    if [[ "${PG_PORT}" != "${DEFAULT_PG_PORT}" ]] && (( PG_PORT < 1024 )); then
        log_warn "Port ${PG_PORT} is a privileged port; non-root services may fail to bind."
    fi
    if (( GATEWAY_PORT < 1024 )); then
        log_warn "Port ${GATEWAY_PORT} is a privileged port; non-root services may fail to bind."
    fi
}

# --print-config: report the resolved per-major configuration the
# wizard would apply, without performing any side effects. Differs from
# --dry-run in that it focuses on the *output config* (paths, ports,
# templated-unit names) rather than enumerating *invasive steps*. Both
# are read-only and exit 0.
print_config() {
    # For brownfield, derive PG version from --target-postgres-instance
    # so the report shows the right templated unit names even when the
    # local PG binaries are not installed.
    if [[ -z "${PG_VERSION}" && -n "${TARGET_CLUSTER}" ]]; then
        PG_VERSION="${TARGET_CLUSTER%%/*}"
    fi
    # Try to detect PG so the report reflects what apply would actually
    # use. detect_postgres_installation is non-mutating (just reads
    # /usr/lib/postgresql/*/bin and /usr/pgsql-*/bin) so it does not
    # need root.
    if [[ -z "${PG_VERSION}" ]]; then
        detect_postgres_installation 2>/dev/null || true
    fi
    # Reapply the per-major default overrides; same logic as
    # resolve_runtime_paths but inlined so we don't drag in
    # require_root via preflight.
    if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        if [[ "${PG_PORT_EXPLICIT}" != "true" ]] \
                && { [[ -z "${PG_PORT}" ]] || [[ "${PG_PORT}" == "${DEFAULT_PG_PORT}" ]]; }; then
            PG_PORT="$(documentdb_default_pg_port "${PG_VERSION}")"
        fi
        if [[ "${DATA_DIR_EXPLICIT}" != "true" ]] \
                && { [[ -z "${DATA_DIR}" ]] || [[ "${DATA_DIR}" == "${DEFAULT_DATA_DIR}" ]]; }; then
            DATA_DIR="/var/lib/documentdb-local/${PG_VERSION}/data"
        fi
        PG_SOCKET_DIR="/run/documentdb-local/${PG_VERSION}/postgresql"
    fi

    local v="${PG_VERSION:-<auto-detect-at-apply-time>}"
    local mode="GREENFIELD"
    local preferred_target="documentdb-local.target"
    local public_alias_value="documentdb-local.target -> documentdb-local@${PUBLIC_ALIAS_PG_MAJOR}.target"
    [[ -n "${TARGET_CLUSTER}" ]] && mode="BROWNFIELD (${TARGET_CLUSTER})"
    if [[ "${v}" =~ ^[0-9]+$ ]] && [[ "${v}" != "${PUBLIC_ALIAS_PG_MAJOR}" ]]; then
        preferred_target="documentdb-local@${v}.target"
    fi

    cat <<REPORT
documentdb-setup: resolved configuration

mode:                          ${mode}
PG version:                    ${v}
PG port:                       ${PG_PORT}
PG socket dir:                 ${PG_SOCKET_DIR}
PG data dir (greenfield):      ${DATA_DIR}
gateway port:                  ${GATEWAY_PORT}
admin user:                    ${USERNAME:-<unset>}

per-major systemd units:
  preferred day-2 target:      ${preferred_target}
  target:                      documentdb-local@${v}.target
  PG service (greenfield):     documentdb-postgresql@${v}.service
  gateway service:             documentdb-gateway-local@${v}.service
public alias:                  ${public_alias_value}

per-major state files:
  greenfield setup state:      /etc/documentdb/local/${v}/setup.conf
  brownfield setup state:      /etc/documentdb/local/${v}/brownfield.conf
  gateway env fragment:        /etc/documentdb/local/${v}/gateway.env
  connection URL file:         /var/lib/documentdb-local/${v}/gateway/pg-url

delegated tools:
  postgresql.conf writer:      documentdb-tune (--yes)
  hba/ident/role writer:       documentdb-register-gateway (--yes --pg-owner ${PG_OWNER:-documentdb-local})
REPORT
}

# --status: report the current per-major installation state. Read-only:
# does not modify anything, does not call register-gateway, does not
# initdb. Exit 0 if a healthy install is found, non-zero otherwise so
# scripts can gate on it.
status_only() {
    local v="${PG_VERSION:-}"
    if [[ -z "${v}" ]]; then
        detect_postgres_installation 2>/dev/null || true
        v="${PG_VERSION:-}"
    fi
    if [[ -z "${v}" || ! "${v}" =~ ^[0-9]+$ ]]; then
        cat <<'EOF'
documentdb-setup status: no PostgreSQL installation detected.
EOF
        return 1
    fi

    local state_file="/etc/documentdb/local/${v}/setup.conf"
    local brownfield_file="/etc/documentdb/local/${v}/brownfield.conf"
    local pg_unit="documentdb-postgresql@${v}.service"
    local gw_unit="documentdb-gateway-local@${v}.service"
    local connection_file="/var/lib/documentdb-local/${v}/gateway/pg-url"
    local mode="<not configured>"
    local pg_active="inactive"
    local gw_active="inactive"
    local listening_port="<not listening>"

    if [[ -f "${state_file}" ]]; then
        mode="greenfield"
    elif [[ -f "${brownfield_file}" ]]; then
        mode="brownfield"
    fi

    # --status must read the persisted
    # GATEWAY_PORT from the per-major state file before probing the
    # listener. The previous implementation always probed ${GATEWAY_PORT}
    # from the CLI default (10260), so installs created with --listen-port
    # were reported as "not listening" even when healthy. Both setup.conf
    # (greenfield) and brownfield.conf persist GATEWAY_PORT.
    local persisted_state_file=""
    if [[ -f "${state_file}" ]]; then
        persisted_state_file="${state_file}"
    elif [[ -f "${brownfield_file}" ]]; then
        persisted_state_file="${brownfield_file}"
    fi
    local effective_gateway_port="${GATEWAY_PORT}"
    if [[ -n "${persisted_state_file}" ]]; then
        local persisted_port
        persisted_port="$(grep -E '^GATEWAY_PORT=' "${persisted_state_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        if [[ -n "${persisted_port}" && "${persisted_port}" =~ ^[0-9]+$ ]]; then
            effective_gateway_port="${persisted_port}"
        fi
    fi

    #
    #  1. Suppress "Host is down" noise from systemctl on hosts without systemd.
    #  2. /proc/net/tcp fallback when ss is absent.
    #  3. Detect a nohup-launched gateway (the wizard's fallback when
    #  systemd is missing) so --status doesn't false-negative.
    local has_systemd=0
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        has_systemd=1
    fi
    if [[ "${has_systemd}" == "1" ]]; then
        systemctl is-active --quiet "${pg_unit}" 2>/dev/null && pg_active="active"
        systemctl is-active --quiet "${gw_unit}" 2>/dev/null && gw_active="active"
    fi

    # Listener probe: prefer ss, fall back to /proc/net/tcp.
    local port_hex
    port_hex="$(printf '%04X' "${effective_gateway_port}" 2>/dev/null || echo 0000)"
    if command -v ss >/dev/null 2>&1; then
        if ss -tlnH "sport = :${effective_gateway_port}" 2>/dev/null | grep -q LISTEN; then
            listening_port="${effective_gateway_port}"
        else
            listening_port="<not listening on ${effective_gateway_port}>"
        fi
    elif [[ -r /proc/net/tcp ]]; then
        if awk -v p="${port_hex}" 'NR>1 && $4=="0A" && toupper($2) ~ p"$" {found=1} END{exit !found}' /proc/net/tcp 2>/dev/null \
                || awk -v p="${port_hex}" 'NR>1 && $4=="0A" && toupper($2) ~ p"$" {found=1} END{exit !found}' /proc/net/tcp6 2>/dev/null; then
            listening_port="${effective_gateway_port}"
        else
            listening_port="<not listening on ${effective_gateway_port}>"
        fi
    else
        listening_port="<unable to probe listeners (install iproute2)>"
    fi

    # If listener is up but systemctl said inactive, the wizard most
    # likely fell back to nohup mode (no systemd). Reflect that
    # accurately instead of a false "inactive".
    if [[ "${listening_port}" == "${effective_gateway_port}" && "${gw_active}" == "inactive" ]]; then
        gw_active="active (nohup; no systemd)"
    fi
    if [[ "${listening_port}" == "${effective_gateway_port}" && "${pg_active}" == "inactive" && "${has_systemd}" == "0" ]]; then
        # Probe PG socket as a proxy when systemd is absent.
        local pg_socket="/run/documentdb-local/${v}/postgresql"
        # Resolve the port in two steps: `cut` exits 0 even when grep found
        # nothing, so an inline `... | cut ... || documentdb_default_pg_port`
        # never runs the fallback — the -S probe then tested the literal
        # path ".s.PGSQL." and reported a running PG as inactive.
        local probe_port
        probe_port="$(grep -E '^PG_PORT=' "${persisted_state_file:-/dev/null}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        [[ -n "${probe_port}" ]] || probe_port="$(documentdb_default_pg_port "${v}")"
        if [[ -S "${pg_socket}/.s.PGSQL.${probe_port}" ]]; then
            pg_active="active (nohup; no systemd)"
        fi
    fi

    cat <<EOF
documentdb-setup status (PG ${v}):

mode:                          ${mode}
state file:                    ${state_file}
brownfield state file:         ${brownfield_file}
connection URL file:           ${connection_file}
${pg_unit}: ${pg_active}
${gw_unit}: ${gw_active}
gateway listener:              ${listening_port}
EOF

    # The design doc (§5 line 284)
    # promises "--status … exit 0 if a healthy install is found", and
    # the function docstring says the same. The prior implementation
    # exited 0 whenever the state file existed, regardless of service
    # state or listener — so CI scripts that gated on `documentdb-setup
    # --status` would treat a stopped/broken install as healthy. The
    # contract is stricter than that:
    #  1. State file present (already required), AND
    #  2. Gateway service active, AND
    #  3. Effective gateway port has a listener.
    # PG service health is required only in greenfield mode — brownfield
    # adopts an externally-managed PG instance that is not under our
    # systemd unit, so we cannot reliably probe it via systemctl.
    if [[ "${mode}" == "<not configured>" ]]; then
        return 1
    fi
    if [[ "${gw_active}" != "active" && "${gw_active}" != active* ]]; then
        return 1
    fi
    if [[ "${listening_port}" != "${effective_gateway_port}" ]]; then
        return 1
    fi
    if [[ "${mode}" == "greenfield" && "${pg_active}" != "active" && "${pg_active}" != active* ]]; then
        return 1
    fi
    return 0
}

# Probe whether the documentdb extension is available for PostgreSQL major $1
# (the postgresql-N-documentdb package ships documentdb.control into the
# major's sharedir). Used so brownfield adoption is only ever offered for
# clusters that can actually become a DocumentDB instance.
_major_has_documentdb_extension() {
    local ver="$1"
    local bindir sharedir
    while IFS= read -r bindir; do
        [[ -x "${bindir}/pg_config" ]] || continue
        sharedir="$("${bindir}/pg_config" --sharedir 2>/dev/null || true)"
        [[ -n "${sharedir}" ]] || continue
        [[ -f "${sharedir}/extension/documentdb.control" ]] && return 0
    done < <(documentdb_pg_bindir_candidates "${ver}")
    return 1
}

# Interactive setup-mode selection. When the operator runs `documentdb-setup`
# on a terminal without choosing a mode (neither --use-new-postgres-instance
# nor --target-postgres-instance) and one or more adoptable system PostgreSQL
# instances exist, offer to adopt one (brownfield) instead of silently creating
# a second, private instance (greenfield). This is the interactive counterpart
# to the flag-driven selection in packaging-design.md §4.4 / §5; it removes the
# beginner surprise of ending up with an extra PostgreSQL instance on a host
# that already runs one. Enumeration uses Debian/Ubuntu's pg_lsclusters (the
# same V/C identifier --target-postgres-instance consumes); on hosts without
# pg_lsclusters (e.g. RHEL) greenfield stays the default and brownfield remains
# flag-driven. No-op under --yes / --dry-run / when a mode flag was passed, so
# CI and scripted installs are unaffected.
maybe_prompt_setup_mode() {
    [[ "${YES}" == "true" ]] && return 0
    [[ "${DRY_RUN}" == "true" ]] && return 0
    [[ "${USE_PRIVATE_CLUSTER}" == "true" ]] && return 0
    # An explicit --pg-version signals a deliberate major choice; don't offer to
    # adopt a possibly different-major cluster (prepare_brownfield_instance would
    # override the requested version).
    [[ "${PG_VERSION_EXPLICIT}" == "true" ]] && return 0
    [[ -n "${TARGET_CLUSTER}" ]] && return 0
    [[ -t 0 && -t 2 ]] || return 0
    command_exists pg_lsclusters || return 0

    # pg_lsclusters -h prints headerless rows: "Ver Cluster Port Status Owner ...".
    # Keep only clusters whose major has the documentdb extension available.
    local -a candidates=()
    local line ver name status
    while IFS= read -r line; do
        [[ -n "${line}" ]] || continue
        ver="$(awk '{print $1}' <<<"${line}")"
        name="$(awk '{print $2}' <<<"${line}")"
        status="$(awk '{print $4}' <<<"${line}")"
        [[ "${ver}" =~ ^[0-9]+$ ]] || continue
        # Only offer clusters that are actually adoptable: a name that passes
        # prepare_brownfield_instance's validation, a running ("online")
        # instance (brownfield adoption queries the live server), and a major
        # that ships the documentdb extension.
        [[ "${name}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || continue
        [[ "${status}" == "online" ]] || continue
        _major_has_documentdb_extension "${ver}" || continue
        candidates+=("${ver}/${name}|${status}")
    done < <(pg_lsclusters -h 2>/dev/null || true)

    (( ${#candidates[@]} > 0 )) || return 0

    echo "" >&2
    echo "[documentdb-setup] Found existing PostgreSQL instance(s) that can host DocumentDB:" >&2
    local entry idx=1
    for entry in "${candidates[@]}"; do
        echo "    [${idx}] ${entry%%|*}  (status: ${entry#*|})" >&2
        idx=$(( idx + 1 ))
    done
    echo "[documentdb-setup] Choose how to set up DocumentDB:" >&2
    echo "    [n] Create a NEW private PostgreSQL instance (recommended: isolated, its own port and data dir)" >&2
    echo "    [1-${#candidates[@]}] ADOPT that instance (modifies its postgresql.conf/pg_hba.conf/pg_ident.conf; backups + per-step consent)" >&2

    local reply=""
    while true; do
        printf '%s' "[documentdb-setup] Setup mode [n/1-${#candidates[@]}] (default: n): " >&2
        reply=""
        read -r reply || reply="n"
        reply="${reply:-n}"
        case "${reply}" in
            n|N|new|NEW)
                log_info "Setup mode: NEW private PostgreSQL instance (greenfield)."
                return 0
                ;;
            *)
                if [[ "${reply}" =~ ^[0-9]+$ ]] && (( reply >= 1 && reply <= ${#candidates[@]} )); then
                    local chosen="${candidates[$(( reply - 1 ))]}"
                    TARGET_CLUSTER="${chosen%%|*}"
                    log_info "Setup mode: ADOPT existing PostgreSQL instance ${TARGET_CLUSTER} (brownfield)."
                    return 0
                fi
                echo "[documentdb-setup] Please enter 'n' or a number between 1 and ${#candidates[@]}." >&2
                ;;
        esac
    done
}

main() {
    parse_arguments "$@"

    # Surface deprecation warnings as early as possible so they appear
    # even in --dry-run / --print-config / --status read-only paths.
    # These don't fail the run — they just inform the operator that the
    # input they used is on a deprecation path.
    if [[ -n "${DOCUMENTDB_PASSWORD:-}" && -z "${PASSWORD_FILE}" \
            && "${PASSWORD_FROM_STDIN}" != "true" ]]; then
        log_warn "DOCUMENTDB_PASSWORD environment variable is deprecated; it leaks via /proc/<pid>/environ. Use --admin-password-file <FILE> (mode 0600) or pipe the password via --admin-password-stdin instead."
    fi

    # Read-only operational flags: print-config + status. Both exit
    # before preflight_validation and before any side effect.
    if [[ "${PRINT_CONFIG}" == "true" ]]; then
        print_config
        exit 0
    fi
    if [[ "${STATUS_ONLY}" == "true" ]]; then
        status_only
        exit $?
    fi

    # If --admin-user wasn't supplied AND --restore is not the action,
    # prompt on a TTY with a sensible default. This lets newbies just
    # run `sudo documentdb-setup` and answer two prompts (user, password)
    # rather than reading the help to discover the flag is required.
    # Non-TTY callers (CI, unattended) still hit the usage+exit branch.
    if [[ -z "${USERNAME}" && "${RESTORE}" != "true" ]]; then
        # --dry-run needs no real username — it only appears in the preview
        # text — so default it instead of prompting or erroring. This used
        # to fall into the non-interactive error branch below, which told an
        # operator sitting at a real TTY that "no TTY [is] available".
        if [[ "${DRY_RUN}" == "true" ]]; then
            USERNAME="admin"
        elif [[ -t 0 && -t 2 && "${YES}" != "true" \
                && "${PRINT_CONFIG}" != "true" && "${STATUS_ONLY}" != "true" ]]; then
            local admin_default="admin"
            local admin_reply=""
            printf '%s' "[documentdb-setup] Admin username [${admin_default}]: " >&2
            read -r admin_reply
            USERNAME="${admin_reply:-${admin_default}}"
            # Reject obvious typos / shell weirdness before we go further.
            # The DocumentDB user-management API constrains usernames to a
            # similar shape; surface here rather than at the SQL layer
            # after we've already done invasive setup.
            if ! [[ "${USERNAME}" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
                die "Admin username '${USERNAME}' is invalid. Use letters, digits, '_' or '-' (must start with a letter or '_')."
            fi
            # Same gateway reserved-prefix policy as the flag path above:
            # catch it at the prompt rather than after a full install.
            if declare -F documentdb_validate_gateway_username >/dev/null 2>&1; then
                documentdb_validate_gateway_username "${USERNAME}" \
                    || die "Admin username '${USERNAME}' is rejected by the gateway's reserved-prefix policy (see above). Re-run and choose another name."
            fi
        else
            echo "error: --admin-user is required for non-interactive setup (running without a usable TTY, or with --yes/--print-config/--status, so the wizard cannot prompt for it). Pass --admin-user NAME." >&2
            usage
            exit 1
        fi
    fi

    # Handle --restore early: strip all managed blocks, remove state, exit.
    # Under --dry-run every mutation below is replaced by a "[dry-run]
    # Would ..." log line — the restore preview must never tear anything
    # down (help text promises "Preview changes without writing").
    # With an explicit --pg-version N, restore is scoped to that major
    # only; without one it sweeps every major (confirmed first when more
    # than one is found).
    if [[ "${RESTORE}" == "true" ]]; then
        [[ "${DRY_RUN}" == "true" ]] || require_root

        # Strip one managed block from a file, honoring --dry-run.
        _restore_strip_block() {
            local _file="$1" _start="$2" _end="$3"
            [[ -n "${_file}" && -f "${_file}" ]] || return 0
            if [[ "${DRY_RUN}" == "true" ]]; then
                log_info "[dry-run] Would strip managed block from ${_file}"
                return 0
            fi
            local _stripped
            _stripped="$(strip_managed_block "${_file}" "${_start}" "${_end}")"
            printf '%s\n' "${_stripped}" > "${_file}"
            log_info "Stripped managed block from ${_file}"
        }
        # Run a mutating restore step, or under --dry-run only log it.
        _restore_do() {
            local _desc="$1"; shift
            if [[ "${DRY_RUN}" == "true" ]]; then
                log_info "[dry-run] Would ${_desc}"
                return 0
            fi
            "$@"
        }

        # Scope: an explicit --pg-version N restricts the sweep to that
        # major. This matches the wizard's own guidance, which advertises
        # `documentdb-setup --restore` as the way to detach the install
        # just created — on a multi-major host the unscoped sweep would
        # also strip, stop, and de-state every OTHER major's install.
        local restore_scope=""
        if [[ "${PG_VERSION_EXPLICIT}" == "true" ]]; then
            # The scope is expanded into globs and unit names below; a
            # non-numeric value ('*', '17 18') would silently widen the
            # sweep past the confirmation gate or word-split mid-restore.
            [[ "${PG_VERSION}" =~ ^[0-9]+$ ]] \
                || die "--restore --pg-version requires a single numeric PostgreSQL major (got '${PG_VERSION}')."
            restore_scope="${PG_VERSION}"
            log_info "Restoring: removing documentdb-setup managed configuration for PostgreSQL major ${restore_scope}."
        else
            log_info "Restoring: removing all documentdb-setup managed configuration."
            # Enumerate affected majors and confirm before an unscoped
            # multi-major teardown (skipped under --yes / --dry-run).
            local _restore_majors=() _m_conf _m_dir
            for _m_conf in /etc/documentdb/local/*/setup.conf /etc/documentdb/local/*/brownfield.conf; do
                [[ -r "${_m_conf}" ]] || continue
                _m_dir="$(basename "$(dirname "${_m_conf}")")"
                [[ " ${_restore_majors[*]-} " == *" ${_m_dir} "* ]] || _restore_majors+=("${_m_dir}")
            done
            if (( ${#_restore_majors[@]} > 1 )) && [[ "${DRY_RUN}" != "true" && "${YES}" != "true" ]]; then
                log_warn "This will detach DocumentDB from ALL registered PostgreSQL majors: ${_restore_majors[*]}."
                log_warn "Use --pg-version N to restore a single major."
                if [[ -t 0 ]]; then
                    local _restore_reply=""
                    printf '%s' "[documentdb-setup] Continue with the multi-major restore? [y/N]: " >&2
                    read -r _restore_reply
                    case "${_restore_reply}" in
                        y|Y|yes|YES) ;;
                        *) die "Restore cancelled. Re-run with --pg-version N to scope to one major, or --yes to skip this prompt." ;;
                    esac
                else
                    die "Refusing an unscoped multi-major restore without confirmation (no TTY). Re-run with --pg-version N to scope to one major, or --yes to proceed against all majors."
                fi
            fi
        fi

        # The legacy env file predates per-major state; it records the
        # major it was written for. When the restore is scoped, only
        # process it if it matches (a legacy file without a PG_VERSION
        # key is skipped in scoped mode — it cannot be attributed).
        local env_file="${POSTGRES_SERVICE_ENV_FILE}"
        local process_legacy=true
        if [[ -n "${restore_scope}" && -r "${env_file}" ]]; then
            local _legacy_major
            _legacy_major="$(grep -E '^PG_VERSION=' "${env_file}" | head -1 | cut -d= -f2- || true)"
            if [[ "${_legacy_major}" != "${restore_scope}" ]]; then
                process_legacy=false
                log_info "Skipping legacy state ${env_file} (records major '${_legacy_major:-<none>}', restore is scoped to ${restore_scope})."
            fi
        fi
        local legacy_processed=false
        if [[ "${process_legacy}" == "true" && -r "${env_file}" ]]; then
            legacy_processed=true
            local data_dir config_file hba_file ident_file
            data_dir="$(grep -E '^DATA_DIR=' "${env_file}" | head -1 | cut -d= -f2- || true)"
            config_file="$(grep -E '^CONFIG_FILE=' "${env_file}" | head -1 | cut -d= -f2- || true)"
            hba_file="$(grep -E '^HBA_FILE=' "${env_file}" | head -1 | cut -d= -f2- || true)"
            ident_file="$(grep -E '^IDENT_FILE=' "${env_file}" | head -1 | cut -d= -f2- || true)"

            [[ -z "${config_file}" && -n "${data_dir}" ]] && config_file="${data_dir}/postgresql.conf"
            [[ -z "${hba_file}" && -n "${data_dir}" ]] && hba_file="${data_dir}/pg_hba.conf"
            [[ -z "${ident_file}" && -n "${data_dir}" ]] && ident_file="${data_dir}/pg_ident.conf"

            _restore_strip_block "${config_file}" "${POSTGRES_CONF_BLOCK_START}" "${POSTGRES_CONF_BLOCK_END}"
            _restore_strip_block "${config_file}" "${POSTGRES_LISTEN_BLOCK_START}" "${POSTGRES_LISTEN_BLOCK_END}"
            _restore_strip_block "${hba_file}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}"
            _restore_strip_block "${ident_file}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}"

            _restore_do "remove ${env_file}" rm -f "${env_file}"
            [[ "${DRY_RUN}" == "true" ]] || log_info "Removed ${env_file}"
        elif [[ -e "${env_file}" && ! -r "${env_file}" ]]; then
            log_warn "Cannot read legacy state file ${env_file} (run as root for a complete restore/preview); skipping it."
        elif [[ ! -e "${env_file}" ]]; then
            log_info "No legacy state file found at ${env_file}."
        fi

        # Also restore from per-major state files introduced by recent setup
        local per_major_conf per_major_glob="/etc/documentdb/local/*"
        [[ -n "${restore_scope}" ]] && per_major_glob="/etc/documentdb/local/${restore_scope}"
        for per_major_conf in ${per_major_glob}/setup.conf; do
            if [[ -e "${per_major_conf}" && ! -r "${per_major_conf}" ]]; then
                log_warn "Cannot read ${per_major_conf} (run as root for a complete restore/preview); skipping it."
                continue
            fi
            [[ -r "${per_major_conf}" ]] || continue
            log_info "Processing per-major state: ${per_major_conf}"
            local pm_data_dir pm_config pm_hba pm_ident
            pm_data_dir="$(grep -E '^DATA_DIR=' "${per_major_conf}" | head -1 | cut -d= -f2- || true)"
            pm_config="$(grep -E '^CONFIG_FILE=' "${per_major_conf}" | head -1 | cut -d= -f2- || true)"
            pm_hba="$(grep -E '^HBA_FILE=' "${per_major_conf}" | head -1 | cut -d= -f2- || true)"
            pm_ident="$(grep -E '^IDENT_FILE=' "${per_major_conf}" | head -1 | cut -d= -f2- || true)"

            [[ -z "${pm_config}" && -n "${pm_data_dir}" ]] && pm_config="${pm_data_dir}/postgresql.conf"
            [[ -z "${pm_hba}" && -n "${pm_data_dir}" ]] && pm_hba="${pm_data_dir}/pg_hba.conf"
            [[ -z "${pm_ident}" && -n "${pm_data_dir}" ]] && pm_ident="${pm_data_dir}/pg_ident.conf"

            _restore_strip_block "${pm_config}" "${POSTGRES_CONF_BLOCK_START}" "${POSTGRES_CONF_BLOCK_END}"
            _restore_strip_block "${pm_config}" "${POSTGRES_LISTEN_BLOCK_START}" "${POSTGRES_LISTEN_BLOCK_END}"
            _restore_strip_block "${pm_hba}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}"
            _restore_strip_block "${pm_ident}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}"

            # Greenfield --restore must
            # match brownfield --restore in stripping the per-major gateway
            # env fragment and tmpfs URL file. Without this, a re-run of
            # `documentdb-setup --yes` against the same major picks up the
            # stale gateway.env before the new register-gateway invocation
            # overwrites it, and the systemd unit briefly serves the old
            # connection URL.
            local pm_dir pm_major pm_env_file
            pm_dir="$(dirname "${per_major_conf}")"
            pm_major="$(basename "${pm_dir}")"
            pm_env_file="${pm_dir}/gateway.env"
            if [[ -f "${pm_env_file}" ]]; then
                if [[ "${DRY_RUN}" == "true" ]]; then
                    log_info "[dry-run] Would strip managed env block from ${pm_env_file} (and remove the file if nothing else remains)"
                else
                    local stripped_env
                    stripped_env="$(strip_managed_block "${pm_env_file}" \
                        '# >>> documentdb-register-gateway managed env >>>' \
                        '# <<< documentdb-register-gateway managed env <<<')"
                    printf '%s\n' "${stripped_env}" > "${pm_env_file}"
                    if [[ ! -s "${pm_env_file}" ]]; then
                        rm -f "${pm_env_file}"
                        log_info "Removed ${pm_env_file}"
                    else
                        log_info "Stripped managed env block from ${pm_env_file}"
                    fi
                fi
            fi
            if [[ "${pm_major}" =~ ^[0-9]+$ ]]; then
                # Remove pg-url from BOTH legacy (/run/, legacy) and
                # current (/var/lib/) locations for upgrade-safe cleanup.
                _restore_do "remove /run/documentdb-local/${pm_major}/gateway/pg-url and /var/lib/documentdb-local/${pm_major}/gateway/pg-url" \
                    bash -c "rm -f '/run/documentdb-local/${pm_major}/gateway/pg-url' '/var/lib/documentdb-local/${pm_major}/gateway/pg-url' 2>/dev/null || true"
                _restore_do "remove the brownfield gateway drop-in for major ${pm_major}" \
                    remove_brownfield_gateway_dropin "${pm_major}"
            fi

            # Reverse documentdb-tune's changes for this instance, exactly as
            # the brownfield loop below does. Greenfield setup also runs
            # documentdb-tune (with --pgdata against the private data dir),
            # and tune writes its OWN markers that the managed-block sweep
            # above does not touch — without this revert, the retained data
            # directory's postgresql.conf kept tune's shared_preload_libraries
            # block after a "restore", and a later re-adoption of that data
            # dir silently carried the stale settings.
            if command_exists documentdb-tune; then
                local _pm_tune_args=(--restore)
                if [[ "${pm_config}" =~ ^/etc/postgresql/([0-9]+)/([^/]+)/postgresql\.conf$ ]]; then
                    _pm_tune_args+=(--pg-version "${BASH_REMATCH[1]}" --cluster "${BASH_REMATCH[2]}")
                elif [[ -n "${pm_data_dir}" ]]; then
                    _pm_tune_args+=(--pgdata "${pm_data_dir}")
                else
                    _pm_tune_args=()
                fi
                if [[ "${#_pm_tune_args[@]}" -gt 1 ]]; then
                    if [[ "${DRY_RUN}" == "true" ]]; then
                        # Don't invoke tune at all in the preview: its own
                        # root check would fail for a non-root preview and
                        # the swallowed output would surface as a spurious
                        # "did not complete cleanly" warning.
                        log_info "[dry-run] Would revert documentdb-tune changes (documentdb-tune ${_pm_tune_args[*]})."
                    else
                        log_info "Reverting documentdb-tune changes (${_pm_tune_args[*]})."
                        documentdb-tune "${_pm_tune_args[@]}" >/dev/null 2>&1 || log_warn "documentdb-tune --restore did not complete cleanly for ${pm_major}; check the cluster's postgresql.conf manually."
                    fi
                fi
            fi

            _restore_do "remove ${per_major_conf}" rm -f "${per_major_conf}"
            [[ "${DRY_RUN}" == "true" ]] || log_info "Removed ${per_major_conf}"
            [[ "${DRY_RUN}" == "true" ]] || rmdir --ignore-fail-on-non-empty "${pm_dir}" 2>/dev/null || true
        done

        # Brownfield: per-major brownfield.conf state file plus the
        # systemd drop-in that re-points the gateway at the adopted PG
        # service. The drop-in must be removed first so a subsequent
        # `documentdb-setup` (or re-adopt of a different PG) starts from
        # a clean unit-file view.
        local per_major_brownfield
        for per_major_brownfield in ${per_major_glob}/brownfield.conf; do
            if [[ -e "${per_major_brownfield}" && ! -r "${per_major_brownfield}" ]]; then
                log_warn "Cannot read ${per_major_brownfield} (run as root for a complete restore/preview); skipping it."
                continue
            fi
            [[ -r "${per_major_brownfield}" ]] || continue
            log_info "Processing per-major brownfield state: ${per_major_brownfield}"
            local bf_data_dir bf_config bf_hba bf_ident bf_dir bf_major
            bf_data_dir="$(grep -E '^DATA_DIR=' "${per_major_brownfield}" | head -1 | cut -d= -f2- || true)"
            bf_config="$(grep -E '^CONFIG_FILE=' "${per_major_brownfield}" | head -1 | cut -d= -f2- || true)"
            bf_hba="$(grep -E '^HBA_FILE=' "${per_major_brownfield}" | head -1 | cut -d= -f2- || true)"
            bf_ident="$(grep -E '^IDENT_FILE=' "${per_major_brownfield}" | head -1 | cut -d= -f2- || true)"

            [[ -z "${bf_config}" && -n "${bf_data_dir}" ]] && bf_config="${bf_data_dir}/postgresql.conf"
            [[ -z "${bf_hba}" && -n "${bf_data_dir}" ]] && bf_hba="${bf_data_dir}/pg_hba.conf"
            [[ -z "${bf_ident}" && -n "${bf_data_dir}" ]] && bf_ident="${bf_data_dir}/pg_ident.conf"

            _restore_strip_block "${bf_config}" "${POSTGRES_CONF_BLOCK_START}" "${POSTGRES_CONF_BLOCK_END}"
            _restore_strip_block "${bf_config}" "${POSTGRES_LISTEN_BLOCK_START}" "${POSTGRES_LISTEN_BLOCK_END}"
            _restore_strip_block "${bf_hba}" "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}"
            _restore_strip_block "${bf_ident}" "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}"

            bf_dir="$(dirname "${per_major_brownfield}")"
            bf_major="$(basename "${bf_dir}")"
            # Same numeric guard as the greenfield loop: bf_major is
            # interpolated into a bash -c string below, so a non-numeric
            # directory name must never reach it.
            if [[ ! "${bf_major}" =~ ^[0-9]+$ ]]; then
                log_warn "Skipping ${per_major_brownfield}: parent directory '${bf_major}' is not a PostgreSQL major."
                continue
            fi
            _restore_do "remove the brownfield gateway drop-in for major ${bf_major}" \
                remove_brownfield_gateway_dropin "${bf_major}"

            # Reverse documentdb-tune's changes for this instance. The managed-
            # block sweep above strips only the wizard's own pg_hba/pg_ident/
            # listen/conf blocks; documentdb-tune writes its OWN markers — on
            # Debian a per-cluster fragment under /etc/postgresql-common/... Plus
            # a managed include line in the live postgresql.conf, on RHEL a
            # managed block in the data dir's postgresql.conf — which only
            # `documentdb-tune --restore` removes cleanly. Without this, --restore
            # / purge would leave shared_preload_libraries (and the include) live.
            if command_exists documentdb-tune; then
                local _tune_args=(--restore)
                if [[ "${bf_config}" =~ ^/etc/postgresql/([0-9]+)/([^/]+)/postgresql\.conf$ ]]; then
                    _tune_args+=(--pg-version "${BASH_REMATCH[1]}" --cluster "${BASH_REMATCH[2]}")
                elif [[ -n "${bf_data_dir}" ]]; then
                    _tune_args+=(--pgdata "${bf_data_dir}")
                else
                    _tune_args=()
                fi
                if [[ "${#_tune_args[@]}" -gt 1 ]]; then
                    if [[ "${DRY_RUN}" == "true" ]]; then
                        # Log-only in the preview (see the greenfield loop).
                        log_info "[dry-run] Would revert documentdb-tune changes (documentdb-tune ${_tune_args[*]})."
                    else
                        log_info "Reverting documentdb-tune changes (${_tune_args[*]})."
                        documentdb-tune "${_tune_args[@]}" >/dev/null 2>&1 || log_warn "documentdb-tune --restore did not complete cleanly for ${bf_major}; check /etc/postgresql-common/documentdb manually."
                    fi
                fi
            fi

            # --restore must also strip
            # the per-major gateway env fragment and tmpfs URL file. Without
            # this, the package's postrm orphan sweep would be the only path
            # that cleans them up, and a subsequent `documentdb-setup --yes`
            # re-adopt against a different cluster would inherit stale
            # gateway.env content.
            local bf_env_file="${bf_dir}/gateway.env"
            if [[ -f "${bf_env_file}" ]]; then
                if [[ "${DRY_RUN}" == "true" ]]; then
                    log_info "[dry-run] Would strip managed env block from ${bf_env_file} (and remove the file if nothing else remains)"
                else
                    local stripped_env
                    stripped_env="$(strip_managed_block "${bf_env_file}" \
                        '# >>> documentdb-register-gateway managed env >>>' \
                        '# <<< documentdb-register-gateway managed env <<<')"
                    printf '%s\n' "${stripped_env}" > "${bf_env_file}"
                    if [[ ! -s "${bf_env_file}" ]]; then
                        rm -f "${bf_env_file}"
                        log_info "Removed ${bf_env_file}"
                    else
                        log_info "Stripped managed env block from ${bf_env_file}"
                    fi
                fi
            fi
            # Remove pg-url from BOTH legacy (/run/, legacy) and
            # current (/var/lib/) locations for upgrade-safe cleanup.
            _restore_do "remove /run/documentdb-local/${bf_major}/gateway/pg-url and /var/lib/documentdb-local/${bf_major}/gateway/pg-url" \
                bash -c "rm -f '/run/documentdb-local/${bf_major}/gateway/pg-url' '/var/lib/documentdb-local/${bf_major}/gateway/pg-url' 2>/dev/null || true"

            _restore_do "remove ${per_major_brownfield}" rm -f "${per_major_brownfield}"
            [[ "${DRY_RUN}" == "true" ]] || log_info "Removed ${per_major_brownfield}"
            [[ "${DRY_RUN}" == "true" ]] || rmdir --ignore-fail-on-non-empty "${bf_dir}" 2>/dev/null || true
        done

        # Clean up systemd drop-in. Cover both the new templated path
        # (documentdb-postgresql@N.service.d, per-major) and the legacy
        # non-templated path (documentdb-postgresql.service.d) so a host
        # Upgraded from legacy doesn't leak a stale drop-in. An unscoped
        # restore always sweeps the legacy (non-templated) drop-in — it is
        # stale by definition once no legacy env file backs it — while a
        # scoped restore touches it only when it actually processed the
        # matching legacy state.
        if [[ -z "${restore_scope}" || "${legacy_processed}" == "true" ]]; then
            _restore_do "remove /etc/systemd/system/documentdb-postgresql.service.d/datadir.conf" \
                rm -f /etc/systemd/system/documentdb-postgresql.service.d/datadir.conf
            [[ "${DRY_RUN}" == "true" ]] || rmdir --ignore-fail-on-non-empty /etc/systemd/system/documentdb-postgresql.service.d 2>/dev/null || true
        fi
        local templated_drop_in_glob="/etc/systemd/system/documentdb-postgresql@*.service.d"
        [[ -n "${restore_scope}" ]] && templated_drop_in_glob="/etc/systemd/system/documentdb-postgresql@${restore_scope}.service.d"
        for templated_drop_in_dir in ${templated_drop_in_glob}; do
            [[ -d "${templated_drop_in_dir}" ]] || continue
            _restore_do "remove ${templated_drop_in_dir}/datadir.conf" \
                rm -f "${templated_drop_in_dir}/datadir.conf"
            [[ "${DRY_RUN}" == "true" ]] || rmdir --ignore-fail-on-non-empty "${templated_drop_in_dir}" 2>/dev/null || true
        done
        if command -v systemctl >/dev/null 2>&1; then
            [[ "${DRY_RUN}" == "true" ]] || systemctl daemon-reload || true
        fi

        # --restore stripped state but
        # left gateways running on the old port. An operator who then re-runs
        # setup with --listen-port X gets two gateways listening (old on Y,
        # new on X). Clean up here in two steps.
        #
        # Step 1: stop systemd-managed appliance gateways properly. Scoped to
        # appliance targets, so a stand-alone Workflow-B gateway
        # (documentdb-gateway.service) is never touched.
        local _target_unit_glob='documentdb-local@*.target'
        [[ -n "${restore_scope}" ]] && _target_unit_glob="documentdb-local@${restore_scope}.target"
        if command -v systemctl >/dev/null 2>&1; then
            local _t
            for _t in $(systemctl list-units "${_target_unit_glob}" --all --plain --no-legend 2>/dev/null | awk '{print $1}'); do
                _restore_do "stop and disable ${_t}" \
                    bash -c "systemctl stop '${_t}' 2>/dev/null || true; systemctl disable '${_t}' 2>/dev/null || true"
            done
        fi
        # Step 2: kill leftover NON-systemd (nohup) gateway daemon orphans.
        # A systemd-managed gateway — appliance or stand-alone — lives in a
        # *.service cgroup; a nohup orphan does not. Filtering on the cgroup
        # catches the nohup orphans (their cwd is /var/lib/documentdb-gateway,
        # the same as a stand-alone gateway, so cwd cannot distinguish them)
        # while never killing a running systemd-managed gateway.
        _kill_nohup_gateway_orphans() {
            local _signal="$1" _pid _cg _hit=1
            for _pid in $(pgrep -f /usr/lib/documentdb-gateway/documentdb-gateway-daemon 2>/dev/null); do
                _cg="$(cat "/proc/${_pid}/cgroup" 2>/dev/null || true)"
                case "${_cg}" in
                    *documentdb-gateway.service*|*documentdb-gateway-local@*) continue ;;
                esac
                if [[ "${DRY_RUN}" == "true" ]]; then
                    log_info "[dry-run] Would stop orphan (non-systemd) gateway daemon (pid ${_pid})"
                    continue
                fi
                log_info "Stopping orphan (non-systemd) gateway daemon (pid ${_pid})"
                kill "-${_signal}" "${_pid}" 2>/dev/null || true
                # Lifecycle: a killed daemon's per-port record is now stale;
                # remove exactly the record(s) NAMING this pid, so records of
                # gateways this sweep did not touch survive untouched.
                local _rec _rec_pid
                for _rec in /run/documentdb-gateway/gateway-*.pid; do
                    [[ -r "${_rec}" ]] || continue
                    _rec_pid="$(nohup_gateway_record_pid "${_rec}" || true)"
                    if [[ "${_rec_pid}" == "${_pid}" ]]; then
                        rm -f "${_rec}" 2>/dev/null || true
                    fi
                done
                _hit=0
            done
            return "${_hit}"
        }
        # An orphaned nohup gateway cannot be attributed to a specific
        # major (its cwd matches the stand-alone gateway's), so the sweep
        # only runs for an unscoped restore. Records are removed per killed
        # pid above; scoped restores must leave other majors' LIVE gateways
        # and their records alone.
        if [[ -n "${restore_scope}" ]]; then
            log_info "Scoped restore: skipping the non-systemd orphan gateway sweep (orphans cannot be attributed to a single major). Run an unscoped --restore to clean them up."
        elif _kill_nohup_gateway_orphans TERM; then
            sleep 1
            _kill_nohup_gateway_orphans KILL || true
        fi
        # After an UNSCOPED sweep, records whose process is gone are stale and
        # must not survive (a later re-run would signal whatever pid the
        # kernel recycles onto them). But the sweep's pgrep only matches the
        # PACKAGED daemon path — a dev-build gateway (cargo's
        # documentdb_gateway, via the repo-build fallback) survives it, and
        # deleting a SURVIVOR's record would orphan a live gateway from
        # future identification on ptrace-restricted hosts. So: keep records
        # whose pid is still alive and still a gateway; remove the rest.
        # Scoped restores skip this too.
        if [[ -z "${restore_scope}" && "${DRY_RUN}" != "true" ]]; then
            local _bk_rec _bk_pid
            for _bk_rec in /run/documentdb-gateway/gateway-*.pid; do
                [[ -e "${_bk_rec}" ]] || continue
                _bk_pid="$(nohup_gateway_record_pid "${_bk_rec}" || true)"
                if [[ -n "${_bk_pid}" ]] \
                        && kill -0 "${_bk_pid}" 2>/dev/null \
                        && gateway_exe_matches "${_bk_pid}"; then
                    log_info "Keeping ${_bk_rec}: pid ${_bk_pid} is a live gateway the orphan sweep does not cover (non-packaged binary path)."
                    continue
                fi
                rm -f "${_bk_rec}" 2>/dev/null || true
            done
        fi

        if [[ "${DRY_RUN}" == "true" ]]; then
            log_success "Restore dry-run complete. No changes were made. Re-run without --dry-run to apply."
        else
            log_success "Restore complete. Restart PostgreSQL to apply."
        fi
        exit 0
    fi

    # Reject contradictory major selection before any preflight or side effect:
    # --pg-version pins one major while --target-postgres-instance names a
    # cluster of a different one. Brownfield adoption uses the cluster's major
    # regardless (prepare_brownfield_instance re-pins PG_VERSION from
    # TARGET_CLUSTER), so this combination would silently ignore --pg-version
    # and leave preflight-computed state (HAS_EXTENDED_RUM, extension
    # validation) pinned to the wrong major. This mirrors the greenfield
    # mismatch guard in resolve_live_cluster_metadata.
    # Only check targets shaped the way prepare_brownfield_instance accepts them
    # (numeric major / slash / optional valid cluster name); malformed values
    # (no slash, invalid name) fall through so prepare_brownfield_instance emits
    # the single authoritative syntax error instead of a confusing conflict.
    if [[ "${PG_VERSION_EXPLICIT}" == "true" \
            && "${TARGET_CLUSTER}" =~ ^[0-9]+/([A-Za-z0-9][A-Za-z0-9_-]*)?$ ]]; then
        local conflict_major="${TARGET_CLUSTER%%/*}"
        if [[ "${conflict_major}" != "${PG_VERSION}" ]]; then
            die "Conflicting options: --pg-version ${PG_VERSION} does not match --target-postgres-instance ${TARGET_CLUSTER} (major ${conflict_major}). Omit --pg-version, or use --pg-version ${conflict_major}."
        fi
    fi

    # The two mode flags are mutually exclusive: --use-new-postgres-instance
    # forces greenfield while --target-postgres-instance names a cluster to
    # adopt. USE_PRIVATE_CLUSTER is otherwise only consulted to suppress the
    # interactive mode prompt, so without this guard the combination silently
    # ran the brownfield flow and mutated the named system cluster, discarding
    # the explicit "force greenfield" flag.
    if [[ "${USE_PRIVATE_CLUSTER}" == "true" && -n "${TARGET_CLUSTER}" ]]; then
        die "Conflicting options: --use-new-postgres-instance (create a private package-owned instance) and --target-postgres-instance ${TARGET_CLUSTER} (adopt an existing instance) are mutually exclusive. Pass exactly one."
    fi

    # Interactive mode selection: if the operator didn't pick greenfield or
    # brownfield explicitly and an adoptable PostgreSQL instance exists, offer
    # to adopt it instead of silently creating a second private instance.
    # No-op under --yes / --dry-run / when a mode flag was passed.
    maybe_prompt_setup_mode

    # Early dry-run preview: report what the wizard WOULD do without
    # any side effects (including the root check and PG detection).
    # This is intentionally before preflight_validation so a non-root
    # operator can inspect the plan; full validation still runs in the
    # apply path.
    if [[ "${DRY_RUN}" == "true" ]]; then
        # Try to detect PG so the preview shows the actual per-major
        # paths the wizard would compute at apply time. detect_postgres_installation
        # only reads /usr/lib/postgresql/*/bin and /usr/pgsql-*/bin, so
        # it does not need root. Falls through silently if no PG is found
        # — we just show the auto-detect placeholder in that case.
        if [[ -z "${PG_VERSION}" ]]; then
            detect_postgres_installation 2>/dev/null || true
        fi
        # Recompute the per-major defaults the same way resolve_runtime_paths
        # does at apply time. This is what makes the dry-run preview
        # report the same paths the apply path would actually use.
        if [[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
            if [[ "${PG_PORT_EXPLICIT}" != "true" ]] \
                    && { [[ -z "${PG_PORT}" ]] || [[ "${PG_PORT}" == "${DEFAULT_PG_PORT}" ]]; }; then
                PG_PORT="$(documentdb_default_pg_port "${PG_VERSION}")"
            fi
            if [[ "${DATA_DIR_EXPLICIT}" != "true" ]] \
                    && { [[ -z "${DATA_DIR}" ]] || [[ "${DATA_DIR}" == "${DEFAULT_DATA_DIR}" ]]; }; then
                DATA_DIR="/var/lib/documentdb-local/${PG_VERSION}/data"
            fi
            # Mirror preflight's persisted port/TLS preservation so the
            # preview reports the port a bare day-2 re-run would actually
            # keep, not the CLI default. (DATA_DIR is deliberately NOT
            # defaulted from persisted state here: the apply path does not
            # do that either — it resolves the default path and fails
            # closed in validate_live_cluster_paths on a mismatch — and
            # the preview must not show a rosier plan than apply executes.)
            default_gateway_settings_from_persisted_state
        fi

        # For brownfield, derive the effective PG version + cluster name
        # from --target-postgres-instance so the preview shows the right
        # templated-unit names. Greenfield uses the explicit --pg-version
        # or "<auto-detect>" as a placeholder.
        local preview_pg_version="${PG_VERSION:-<auto-detect>}"
        local preview_cluster_name=""
        if [[ -n "${TARGET_CLUSTER}" ]]; then
            preview_pg_version="${TARGET_CLUSTER%%/*}"
            preview_cluster_name="${TARGET_CLUSTER#*/}"
            [[ -n "${preview_cluster_name}" ]] || preview_cluster_name="main"
        fi
        # Reject a known-unsupported major in dry-run too, so the preview never
        # advertises a plan the apply path would refuse. A non-numeric
        # "<auto-detect>" preview version is a no-op (major not yet known).
        enforce_gateway_pg_major_supported "${preview_pg_version}"
        # Same mirroring for the greenfield never-5432 rule enforced on the
        # create-new-cluster branch of prepare_self_managed_cluster: only for
        # a NEW instance (an already-initialized data dir stays re-runnable).
        if [[ -z "${TARGET_CLUSTER}" && "${PG_PORT}" == "5432" \
                && ! -f "${DATA_DIR}/PG_VERSION" ]]; then
            die "--pg-port 5432 is not allowed for a new package-private PostgreSQL instance: the design reserves the default PostgreSQL port for system instances so they can never collide with this one (packaging-design.md §4.4). Choose another port, or adopt an existing 5432 instance with --target-postgres-instance."
        fi
        log_info "[dry-run] documentdb-setup invoked with --dry-run:"
        # Probe existing state so the
        # preview annotates each step with "(no-op: already done)" when
        # appropriate. Saves operators from thinking the wizard would
        # wipe and re-init when it would actually adopt the existing
        # install. Annotations are best-effort — probes that need root
        # are skipped silently.
        local _state_file="/etc/documentdb/local/${preview_pg_version}/setup.conf"
        local _bf_state_file="/etc/documentdb/local/${preview_pg_version}/brownfield.conf"
        local _datadir_ready=false
        local _ext_ready=false
        local _admin_ready=false
        local _gw_url_file="/var/lib/documentdb-local/${preview_pg_version}/gateway/pg-url"
        if [[ -f "${DATA_DIR}/PG_VERSION" ]]; then _datadir_ready=true; fi
        if [[ -f "${_state_file}" || -f "${_bf_state_file}" ]]; then
            # Existing install — best-effort: assume CREATE EXTENSION + admin already done.
            _ext_ready=true
            _admin_ready=true
        fi
        local _datadir_note=""
        local _initdb_note=""
        local _ext_note=""
        local _admin_note=""
        if [[ "${_datadir_ready}" == "true" ]]; then
            _datadir_note=" (no-op: ${DATA_DIR} already initialized)"
            _initdb_note=" (no-op: data dir present)"
        fi
        if [[ "${_ext_ready}" == "true" ]]; then _ext_note=" (likely no-op: install state present)"; fi
        if [[ "${_admin_ready}" == "true" ]]; then _admin_note=" (likely no-op: install state present; existing user would have password reset if --admin-password supplied)"; fi
        if [[ -n "${TARGET_CLUSTER}" ]]; then
            log_info "[dry-run]   mode: BROWNFIELD (adopt ${TARGET_CLUSTER})"
            log_info "[dry-run]   PG port: <discovered from ${preview_pg_version}/${preview_cluster_name}>, gateway port: ${GATEWAY_PORT}"
        else
            log_info "[dry-run]   mode: GREENFIELD (initdb private instance for PG ${preview_pg_version})"
            log_info "[dry-run]   data dir: ${DATA_DIR}"
            log_info "[dry-run]   PG port: ${PG_PORT}, gateway port: ${GATEWAY_PORT}"
        fi
        log_info "[dry-run]   admin user: ${USERNAME}"
        log_info "[dry-run]   side-effect steps that would run (each gated by [y/N/dry-run] when --yes is not set):"
        if [[ -z "${TARGET_CLUSTER}" ]]; then
            log_info "[dry-run]     - Create ${DATA_DIR} owned by documentdb-local:documentdb-local${_datadir_note}"
            log_info "[dry-run]     - initdb --pgdata=${DATA_DIR} --username=documentdb-local${_initdb_note}"
            log_info "[dry-run]     - documentdb-tune --yes  (writes postgresql.conf managed block)"
            log_info "[dry-run]     - systemctl enable documentdb-postgresql@${preview_pg_version}.service"
            log_info "[dry-run]     - systemctl start  documentdb-postgresql@${preview_pg_version}.service"
            log_info "[dry-run]     - documentdb-register-gateway --yes --pg-owner documentdb-local  (writes pg_hba.conf, pg_ident.conf, gateway role, ${_gw_url_file}) — runs AFTER PG is up so psql/CREATE ROLE work"
        else
            log_info "[dry-run]     - documentdb-tune --yes  (writes postgresql.conf managed block)"
            log_info "[dry-run]     - documentdb-register-gateway --yes --pg-owner postgres  (writes pg_hba.conf, pg_ident.conf, gateway role, ${_gw_url_file})"
            log_info "[dry-run]     - Print 'systemctl reload postgresql@${preview_pg_version}-${preview_cluster_name}' for the operator to run"
        fi
        log_info "[dry-run]     - psql: CREATE EXTENSION documentdb CASCADE${_ext_note}"
        log_info "[dry-run]     - psql: bootstrap admin user '${USERNAME}' via documentdb_api.create_user()${_admin_note}"
        log_info "[dry-run]     - systemctl enable documentdb-gateway-local@${preview_pg_version}.service"
        log_info "[dry-run]     - systemctl start  documentdb-gateway-local@${preview_pg_version}.service"
        # Enable per-major
        # target so the stack auto-starts at boot (services have
        # WantedBy=target but the target needs its own enable to land
        # in multi-user.target.wants/).
        log_info "[dry-run]     - systemctl enable documentdb-local@${preview_pg_version}.target  # boot persistence"
        log_info "[dry-run] no side effects performed."
        exit 0
    fi

    # Reject an unsupported PostgreSQL major as early as possible — before
    # preflight_validation runs anything (including validate_required_arguments,
    # which may adjust operator TLS file ownership/permissions). Resolve the
    # major without side effects: the brownfield target, an explicit
    # --pg-version, or a READ-ONLY probe that mirrors detect_postgres_installation's
    # choice — the highest installed major that ships the documentdb extension,
    # else the highest installed major. This probe neither mutates state nor
    # dies; if no PostgreSQL is found the major stays empty (a no-op gate) and
    # preflight_validation surfaces the missing-PostgreSQL error as before. The
    # preflight/greenfield/brownfield gates and register-gateway's live
    # cross-check remain backstops.
    local _early_pg_major=""
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        _early_pg_major="${TARGET_CLUSTER%%/*}"
    elif [[ "${PG_VERSION}" =~ ^[0-9]+$ ]]; then
        _early_pg_major="${PG_VERSION}"
    else
        local _cand _cand_major _cand_share _best_ext="" _best_any=""
        for _cand in /usr/lib/postgresql/*/bin /usr/pgsql-*/bin; do
            [[ -x "${_cand}/pg_config" ]] || continue
            _cand_major="$(basename "$(dirname "${_cand}")" | sed 's/^pgsql-//')"
            [[ "${_cand_major}" =~ ^[0-9]+$ ]] || continue
            if [[ -z "${_best_any}" ]] || (( _cand_major > _best_any )); then
                _best_any="${_cand_major}"
            fi
            _cand_share="$("${_cand}/pg_config" --sharedir 2>/dev/null || true)"
            if [[ -n "${_cand_share}" && -f "${_cand_share}/extension/documentdb.control" ]]; then
                if [[ -z "${_best_ext}" ]] || (( _cand_major > _best_ext )); then
                    _best_ext="${_cand_major}"
                fi
            fi
        done
        _early_pg_major="${_best_ext:-${_best_any}}"
    fi
    enforce_gateway_pg_major_supported "${_early_pg_major}"

    preflight_validation

    log_info "Using PostgreSQL ${PG_VERSION} binaries in ${PG_BIN_DIR}."
    log_info "Using gateway binary ${GATEWAY_BINARY}."
    log_info "Using gateway config ${CONFIG_FILE}."

    # Capture the gateway's pre-run active state so we can preserve it
    # across PG restarts (Requires= dependency propagation can stop the
    # gateway when we run `systemctl restart documentdb-postgresql`, and
    # under --no-enable we would never bring it back).
    capture_gateway_active_state

    # Branch on the design's primary flow selector:
    #  --target-postgres-instance N/C → brownfield (adopt existing PG)
    #  otherwise → greenfield (initdb private PG)
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        prepare_brownfield_instance
        # Brownfield: only delegate config writes; do NOT activate our
        # per-major templated PG service (the operator owns the system PG
        # service lifecycle, per design §4.4). The adopted PG is already
        # running, so register-gateway's psql/CREATE ROLE call works
        # right after the config writes.
        # On Debian, documentdb-tune
        # writes shared_preload_libraries to the per-cluster fragment at
        # /etc/postgresql-common/documentdb/N/C/documentdb.conf via the
        # include_if_exists mechanism, NOT into the live postgresql.conf.
        # So reading LIVE_CONFIG_FILE (the main postgresql.conf) for SPL
        # never sees our value — every rerun thinks SPL still needs
        # updating, flips PG_CONFIG_CHANGED=true, and the wizard hits
        # the restart-required exit guard in start_or_restart_postgres
        # AGAIN, even though the operator restarted PG already. Result:
        # infinite "restart and re-run" loop.
        #
        # Ground truth is whatever the LIVE PostgreSQL has loaded.
        # SHOW shared_preload_libraries returns that. Compare against the
        # merged value to decide whether a restart is still pending.
        # The ground truth for whether a restart is still pending is whatever the
        # LIVE postmaster has actually loaded — NOT what is on disk. On Debian,
        # documentdb-tune writes shared_preload_libraries (and the pg_cron GUCs)
        # into the per-cluster fragment under
        # /etc/postgresql-common/documentdb/N/C/documentdb.conf via
        # include_if_exists, never into LIVE_CONFIG_FILE, so the on-disk
        # postgresql.conf (and its mtime) never reflects our changes. Gating the
        # restart decision on an on-disk comparison would therefore both
        # (a) loop forever in the fragment case (the file always looks
        # un-applied) and (b) MISS the rerun-after-write case in the direct-edit
        # (--pgdata) layout — a prior run wrote the config but the operator has
        # not restarted yet, so the on-disk file already matches while the
        # running postmaster is still stale, and the wizard would fall through to
        # CREATE EXTENSION against an unrestarted postmaster. Query the running
        # postmaster directly instead and force a restart whenever it is missing
        # a required preload library or is not yet running pg_cron in
        # background-worker mode.
        local current_preload merged_preload live_preload
        current_preload="$(read_shared_preload_libraries_from_file "${LIVE_CONFIG_FILE}")"
        merged_preload="$(merge_shared_preload_libraries "${current_preload}")"
        live_preload="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" \
            -d postgres -X -tA -v ON_ERROR_STOP=1 \
            -c "SHOW shared_preload_libraries;" 2>/dev/null | tr -d '[:space:]' || true)"

        local need_restart=false
        # Mirror merge_shared_preload_libraries' required set, including
        # pg_documentdb_extended_rum when HAS_EXTENDED_RUM=true (its _PG_init
        # errors unless loaded via shared_preload_libraries).
        local -a required_live_libs=(pg_cron pg_documentdb_core pg_documentdb)
        if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
            required_live_libs+=(pg_documentdb_extended_rum)
        fi
        if [[ -z "${live_preload}" ]]; then
            # The adopted postmaster reports no shared_preload_libraries (a
            # vanilla first-time adoption) or its state could not be read; in
            # either case we cannot prove our libraries are active, so a restart
            # is required once apply_managed_postgres_settings writes them.
            need_restart=true
            log_verbose "Live PostgreSQL reports no shared_preload_libraries; forcing a restart to apply the managed configuration."
        else
            # live_preload is the comma-joined SHOW output with whitespace
            # stripped, so match on comma boundaries: a bare substring test
            # ("*pg_documentdb*") would wrongly consider pg_documentdb present
            # when only pg_documentdb_core is loaded.
            local lib
            for lib in "${required_live_libs[@]}"; do
                case ",${live_preload}," in
                    *",${lib},"*) ;;
                    *)
                        need_restart=true
                        log_verbose "Live PostgreSQL is missing required preload library ${lib}; forcing a restart to apply the managed configuration."
                        break
                        ;;
                esac
            done
        fi

        # With every required library confirmed loaded, the restart-only
        # (PGC_POSTMASTER) GUCs that documentdb-tune writes must ALSO be live in
        # the running postmaster. documentdb-tune writes them into the Debian
        # per-cluster fragment (not LIVE_CONFIG_FILE), so neither the mtime check
        # in apply_managed_postgres_settings nor an on-disk comparison observes a
        # stale value, yet the wizard depends on each at runtime:
        #  cron.use_background_workers=on -> pg_cron runs jobs in background
        #  workers; otherwise it dials cron.host over TCP, which the hardened
        #  pg_hba rejects, so build_index_concurrently never runs and the
        #  gateway's createIndexes wait loop hangs forever.
        #  cron.database_name=postgres -> scheduled jobs run in the database
        #  where documentdb-setup creates the extension; a stale value runs
        #  them against the wrong database (same hang).
        #  documentdb.enableBackgroundWorker=on -> the documentdb background
        #  worker actually starts.
        #  documentdb.rum_library_load_option -> the extended RUM index handler
        #  loads (only written when HAS_EXTENDED_RUM=true; reached only once
        #  pg_documentdb_extended_rum is confirmed loaded above).
        # The owning library is loaded (checked above), so SHOW returns a value;
        # an empty result means the value could not be read, which we leave to the
        # library check rather than risk a restart loop (matching the loop-safe
        # treatment of an unreadable live_preload). Booleans render as on/off, but
        # synonyms are tolerated so a representation quirk cannot wedge a loop.
        if [[ "${need_restart}" != "true" ]]; then
            local guc_spec guc_name guc_rest guc_expected guc_is_bool live_guc
            local -a managed_restart_gucs=(
                "cron.use_background_workers|on|1"
                "cron.database_name|postgres|0"
                "documentdb.enableBackgroundWorker|on|1"
            )
            if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
                managed_restart_gucs+=("documentdb.rum_library_load_option|require_documentdb_extended_rum|0")
            fi
            for guc_spec in "${managed_restart_gucs[@]}"; do
                guc_name="${guc_spec%%|*}"
                guc_rest="${guc_spec#*|}"
                guc_expected="${guc_rest%%|*}"
                guc_is_bool="${guc_rest#*|}"
                live_guc="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${PG_SOCKET_DIR}" -p "${PG_PORT}" \
                    -d postgres -X -tA -v ON_ERROR_STOP=1 \
                    -c "SHOW ${guc_name};" 2>/dev/null | tr -d '[:space:]' || true)"
                [[ -z "${live_guc}" ]] && continue
                if [[ "${guc_is_bool}" == "1" ]]; then
                    case "${live_guc,,}" in
                        on|true|yes|1) live_guc="on" ;;
                        off|false|no|0) live_guc="off" ;;
                    esac
                fi
                if [[ "${live_guc}" != "${guc_expected}" ]]; then
                    need_restart=true
                    log_verbose "Live PostgreSQL has ${guc_name}=${live_guc} (expected ${guc_expected}); forcing a restart to apply the managed configuration."
                    break
                fi
            done
        fi
        if [[ "${need_restart}" == "true" ]]; then
            PG_CONFIG_CHANGED=true
        fi

        apply_managed_postgres_settings "${LIVE_CONFIG_FILE}" "${LIVE_HBA_FILE}" "${merged_preload}" ""
        ensure_pg_ident_map
        persist_brownfield_state
    else
        prepare_self_managed_cluster
        # Persist the self-managed PG service state and drop-in BEFORE
        # starting PostgreSQL so the systemd unit's ConditionPathExists
        # is satisfied and `systemctl enable` will auto-start the
        # instance on reboot.
        sync_self_managed_postgres_service_state
    fi

    start_or_restart_postgres

    # Greenfield must call register-gateway AFTER PG
    # is started, because the tool connects via psql to create the
    # gateway role and verify the extension. Brownfield already ran this
    # above (its PG is the long-running system instance).
    if [[ -z "${TARGET_CLUSTER}" ]]; then
        register_gateway_after_pg_running
        reload_self_managed_postgres_auth_mapping
    fi

    create_required_extensions_and_users
    grant_gateway_role_memberships
    update_gateway_configuration
    start_gateway
    load_sample_data_if_requested
    ensure_target_enabled_at_boot
    print_completion_message
}

main "$@"
