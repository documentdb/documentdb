#!/bin/bash

set -euo pipefail

readonly LEGACY_ENV_FILE="/etc/documentdb/documentdb-postgresql.env"
readonly LEGACY_RUN_DIR="/run/documentdb/postgresql"

# Per-major mode: when invoked as "documentdb_postgresql_service.sh start 17"
# uses /etc/documentdb/local/17/setup.conf and /var/lib/documentdb-local/17/data.
PG_MAJOR=""
ENV_FILE=""
RUN_DIR=""
PG_OWNER=""

log() {
    echo "[documentdb-postgresql-service] $*"
}

die() {
    echo "[documentdb-postgresql-service] ERROR: $*" >&2
    exit 1
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

run_as_pg_owner() {
    # When invoked from systemd with User=PG_OWNER, we're already the
    # right user and runuser would fail because it requires root. Detect
    # that case and just exec the command directly.
    local current_user
    current_user="$(id -un)"
    if [[ "${current_user}" == "${PG_OWNER}" ]]; then
        "$@"
    elif command_exists runuser; then
        runuser -u "${PG_OWNER}" -- "$@"
    elif command_exists sudo; then
        sudo -u "${PG_OWNER}" "$@"
    else
        local quoted_command=""
        quoted_command="$(printf '%q ' "$@")"
        su -s /bin/bash "${PG_OWNER}" -c "${quoted_command}"
    fi
}

load_config() {
    if [[ ! -r "${ENV_FILE}" ]]; then
        log "No configuration found at ${ENV_FILE}; nothing to do."
        exit 0
    fi

    # Parse the env file safely instead of sourcing it to prevent arbitrary
    # code execution if the file is ever tampered with.
    DOCUMENTDB_MANAGED_POSTGRES="$(grep -E '^DOCUMENTDB_MANAGED_POSTGRES=' "${ENV_FILE}" | head -1 | cut -d= -f2- || true)"
    PG_VERSION="$(grep -E '^PG_VERSION=' "${ENV_FILE}" | head -1 | cut -d= -f2- || true)"
    DATA_DIR="$(grep -E '^DATA_DIR=' "${ENV_FILE}" | head -1 | cut -d= -f2- || true)"

    if [[ "${DOCUMENTDB_MANAGED_POSTGRES:-}" != "true" ]]; then
        log "Managed PostgreSQL is disabled; nothing to do."
        exit 0
    fi

    [[ "${PG_VERSION:-}" =~ ^[0-9]+$ ]] || die "PG_VERSION is missing or invalid in ${ENV_FILE}."
    [[ -n "${DATA_DIR:-}" ]] || die "DATA_DIR is missing from ${ENV_FILE}."
    [[ -d "${DATA_DIR}" ]] || die "Configured PostgreSQL data directory does not exist: ${DATA_DIR}"
}

resolve_pg_ctl() {
    local candidate=""
    local candidates=(
        "/usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl"
        "/usr/pgsql-${PG_VERSION}/bin/pg_ctl"
    )

    for candidate in "${candidates[@]}"; do
        if [[ -x "${candidate}" ]]; then
            printf '%s' "${candidate}"
            return 0
        fi
    done

    die "Unable to find pg_ctl for PostgreSQL ${PG_VERSION}."
}

ensure_runtime_dir() {
    local socket_group="documentdb-gateway"
    local run_parent
    run_parent="$(dirname "${RUN_DIR}")"
    if ! getent group "${socket_group}" >/dev/null 2>&1; then
        socket_group="${PG_OWNER}"
    fi
    install -d -o "${PG_OWNER}" -g "${socket_group}" -m 0750 "${run_parent}"
    install -d -o "${PG_OWNER}" -g "${socket_group}" -m 0750 "${RUN_DIR}"
}

postgres_is_running() {
    run_as_pg_owner "${PG_CTL}" -D "${DATA_DIR}" status >/dev/null 2>&1
}

start_postgres() {
    # ensure_runtime_dir is handled by ExecStartPre=+ prepare-runtime
    # when invoked from systemd; running here too is harmless when invoked
    # outside systemd (legacy non-systemd path).
    if [[ "$(id -u)" -eq 0 ]]; then
        ensure_runtime_dir
    fi

    if postgres_is_running; then
        log "Restarting self-managed PostgreSQL cluster in ${DATA_DIR}."
        run_as_pg_owner "${PG_CTL}" -D "${DATA_DIR}" -w restart
    else
        log "Starting self-managed PostgreSQL cluster in ${DATA_DIR}."
        # Intentionally NOT passing `-l <file>`. With Type=forking under
        # systemd, omitting -l makes the postmaster inherit pg_ctl's
        # stderr (which systemd captures), so all PostgreSQL log lines
        # land in the journal. Operators access them via:
        #
        #  journalctl -u documentdb-postgresql@${PG_MAJOR} (per-major)
        #  journalctl -u documentdb-postgresql (legacy)
        #
        # This avoids three previous foot-guns:
        #  - PG logs were silently written to ${DATA_DIR}/pglog.log,
        #  where operators looking under /var/log/ never found them.
        #  - That file grew unbounded with no log rotation.
        #  - The file was mode 0640 owned by documentdb-local, so
        #  reading it always required sudo even for a quick tail.
        # journald handles rotation, retention, and access control via
        # systemd-journal group membership.
        run_as_pg_owner "${PG_CTL}" -D "${DATA_DIR}" -w start
    fi
}

stop_postgres() {
    if postgres_is_running; then
        log "Stopping self-managed PostgreSQL cluster in ${DATA_DIR}."
        run_as_pg_owner "${PG_CTL}" -D "${DATA_DIR}" -w stop -m fast
    else
        log "Self-managed PostgreSQL cluster is already stopped."
    fi
}

reload_postgres() {
    if postgres_is_running; then
        log "Reloading self-managed PostgreSQL cluster in ${DATA_DIR}."
        run_as_pg_owner "${PG_CTL}" -D "${DATA_DIR}" reload
    else
        die "Cannot reload self-managed PostgreSQL cluster because it is not running."
    fi
}

main() {
    local action="${1:-}"
    PG_MAJOR="${2:-}"

    [[ "${action}" == "start" || "${action}" == "stop" || "${action}" == "reload" || "${action}" == "prepare-runtime" ]] \
        || die "Usage: $0 <start|stop|reload|prepare-runtime> [PG_MAJOR]"

    # Per-major mode (invoked by documentdb-postgresql@N.service)
    if [[ -n "${PG_MAJOR}" ]]; then
        ENV_FILE="/etc/documentdb/local/${PG_MAJOR}/setup.conf"
        RUN_DIR="/run/documentdb-local/${PG_MAJOR}/postgresql"
        PG_OWNER="documentdb-local"
    else
        # Legacy mode (invoked by documentdb-postgresql.service)
        ENV_FILE="${LEGACY_ENV_FILE}"
        RUN_DIR="${LEGACY_RUN_DIR}"
        PG_OWNER="documentdb"
    fi

    # prepare-runtime runs as root from ExecStartPre=+ to create the per-
    # major socket directory before the main ExecStart drops privileges
    # via User=. Start/stop/reload run as PG_OWNER (User= on the unit) so
    # the postmaster lives in the unit's cgroup, which is how systemd tracks
    # it: the unit sets no PIDFile= and relies on Type=forking + GuessMainPID
    # walking the cgroup (see documentdb-postgresql@.service).
    if [[ "${action}" == "prepare-runtime" ]]; then
        [[ "$(id -u)" -eq 0 ]] || die "prepare-runtime must run as root (ExecStartPre=+)."
        load_config
        ensure_runtime_dir
        exit 0
    fi

    load_config
    PG_CTL="$(resolve_pg_ctl)"

    case "${action}" in
        start)
            start_postgres
            ;;
        stop)
            stop_postgres
            ;;
        reload)
            reload_postgres
            ;;
    esac
}

main "$@"
