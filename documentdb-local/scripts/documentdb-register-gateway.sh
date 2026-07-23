#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-register-gateway — one-shot PostgreSQL-side registration of a
# local DocumentDB gateway against an existing PostgreSQL instance.
#
# This script:
#  1. Verifies the documentdb-gateway runtime package is installed (the
#  gateway OS user must exist before we write ident-map entries for it)
#  2. Writes a managed block to pg_hba.conf (peer auth with ident map)
#  3. Writes a managed block to pg_ident.conf (gateway OS user → DB role map)
#  4. Creates the gateway's PG role if it does not exist
#  5. Writes the gateway's connection URL file (passwordless, local socket)
#  6. Optionally creates the first admin user via the extension-side API
#  7. Records every change for --restore / purge reversal
#
# Does NOT touch postgresql.conf — that is documentdb-tune's job.
# Does NOT start the gateway service — that is the administrator's choice
# after the PostgreSQL instance has been reloaded.

set -euo pipefail
umask 077

readonly PROG="documentdb-register-gateway"
readonly PG_HBA_BLOCK_START="# >>> documentdb-setup managed hba >>>"
readonly PG_HBA_BLOCK_END="# <<< documentdb-setup managed hba <<<"
readonly PG_IDENT_BLOCK_START="# >>> documentdb-setup managed pg_ident >>>"
readonly PG_IDENT_BLOCK_END="# <<< documentdb-setup managed pg_ident <<<"

# OS user/group the gateway runs as
readonly GW_OS_USER="documentdb-gateway"
readonly GW_PG_ROLE="documentdb-gateway"

# ── Defaults ────────────────────────────────────────────────────────
TARGET_CLUSTER=""     # e.g., "17/main"
PG_VERSION=""
TARGET_PG_MAJOR=""    # resolved effective PG major (from PG_VERSION or live SHOW); gates +group vs exact pg_ident entries
CLUSTER_NAME=""
PGDATA=""
SOCKET_DIR=""
PG_PORT=""
PG_OWNER=""           # OS user to run psql as (postgres for brownfield, documentdb-local for greenfield-via-wizard)
ADMIN_USER=""
ADMIN_PASSWORD_FILE=""
# Which PostgreSQL database holds
# the `documentdb` extension is configurable, but the script previously
# hardcoded /postgres in the connection-URL file and in psql -d calls.
# That silently broke any install where the operator put the extension
# in a different database. Default stays "postgres" (matches the typical
# Workflow B install path and the design's §5 step 5 example).
TARGET_DB="postgres"
# See write_gateway_env_fragment.
# These let the caller (typically documentdb-setup) thread the
# operator's listen-port / TLS-auto-gen choice into the per-major
# env file that documentdb-gateway-local@N.service actually reads.
GATEWAY_LISTEN_ADDR=""
GATEWAY_TLS_AUTO_GENERATE=""
# When the wizard (documentdb-setup) is given --tls-cert/--tls-key the
# values are passed through here and recorded in the per-major gateway
# env fragment so the runtime gateway picks them up via
# DOCUMENTDB_TLS_CERT_FILE / DOCUMENTDB_TLS_KEY_FILE. Defaults to empty
# (no override) which is the standalone-default auto-gen behavior.
GATEWAY_TLS_CERT_FILE=""
GATEWAY_TLS_KEY_FILE=""
# The state file's name MATTERS
# because documentdb-postgresql@N.service has ConditionPathExists=
# /etc/documentdb/local/%i/setup.conf — so writing setup.conf in brownfield
# mode (where the wizard is adopting the system PG) makes the greenfield
# templated PG service activatable, violating brownfield isolation. The
# caller can declare the mode explicitly via --state-mode, but if they
# don't AND --target-postgres-instance is given, we auto-default to
# brownfield (a named distro cluster is almost always adopted). The plain
# default stays "greenfield" so direct Workflow B invocations of a private
# greenfield PG via --pgdata still write setup.conf.
STATE_MODE=""
STATE_MODE_EXPLICIT=false
YES=false
DRY_RUN=false
RESTORE=false
VERBOSE=false

# Resolved
HBA_FILE=""
IDENT_FILE=""
SECRET_DIR=""
SECRET_FILE=""
STATE_FILE=""
GATEWAY_ENV_FILE=""
PSQL=""
IS_DEBIAN=false

# The state-file keys this script owns. Everything else in the state file
# belongs to another writer (the documentdb-setup wizard) and must survive
# both record_state's rewrite and do_restore's teardown. Kept as a single
# global so the two stay in lockstep — they diverged once, and a
# do_restore that stripped a key record_state still writes (or vice versa)
# silently corrupts state.
readonly STATE_MANAGED_KEYS_RE='^(HBA_FILE|IDENT_FILE|SECRET_FILE|PG_VERSION|CLUSTER_NAME|PG_PORT|PG_OWNER|DOCUMENTDB_MODE|GATEWAY_ENV_FILE|TARGET_DB)='

# The subset of STATE_MANAGED_KEYS_RE that ONLY this script writes. The
# rest (PG_VERSION, PG_PORT, PG_OWNER, DOCUMENTDB_MODE, HBA_FILE,
# IDENT_FILE) are co-owned: the documentdb-setup wizard writes the same
# keys into the same setup.conf/brownfield.conf, and its consumers still
# need them after our teardown — documentdb_postgresql_service.sh's
# load_config dies without PG_VERSION (while the unit's
# ConditionPathExists on the file still passes), setup.sh's
# brownfield-over-greenfield guard reads DOCUMENTDB_MODE, and
# documentdb-gateway-admin skips any per-major state file lacking
# PG_PORT. strip_managed_state_keys therefore strips only these when the
# wizard co-owns the file.
readonly STATE_EXCLUSIVE_KEYS_RE='^(SECRET_FILE|CLUSTER_NAME|GATEWAY_ENV_FILE|TARGET_DB)='

# The previous prepend/rewrite helpers
# used bare $(mktemp) with explicit rm -f at the end. On set -e failure
# between mktemp and rm -f, role-bearing temp content leaked. Track all temp
# files in a global array and clean them up on any exit path.
TEMP_FILES=()

cleanup_temp_files() {
    local f
    for f in "${TEMP_FILES[@]:-}"; do
        [[ -n "${f}" && -e "${f}" ]] && rm -f "${f}" 2>/dev/null || true
    done
    TEMP_FILES=()
}
trap cleanup_temp_files EXIT
# Ensure a signal between commands actually terminates the script (and fires
# the EXIT trap for cleanup) rather than being swallowed mid PostgreSQL-config
# mutation. Without explicit exits, a bare INT/TERM trap returns control to the
# next statement and the script keeps editing pg_hba/pg_ident/postgresql.conf.
trap 'cleanup_temp_files; exit 130' INT
trap 'cleanup_temp_files; exit 143' TERM

# Create a temp file in the target file's directory (so the eventual mv is an
# atomic same-filesystem rename — bare $(mktemp) lands in /tmp which may be on
# a different fs) and register it for cleanup. Caller passes the variable
# name; the temp path is assigned to that variable.
create_temp_in_dir() {
    local var_name="$1"
    local target_dir="$2"
    local tmp_path
    tmp_path="$(mktemp "${target_dir}/.documentdb-register.XXXXXX")" \
        || die "Failed to create temp file in ${target_dir}."
    TEMP_FILES+=("${tmp_path}")
    printf -v "${var_name}" '%s' "${tmp_path}"
}

# ── Helpers ─────────────────────────────────────────────────────────

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }
log_verbose() { [[ "${VERBOSE}" == "true" ]] && echo "[${PROG}] $*" >&2; return 0; }

usage() {
    cat <<'EOF'
Usage: documentdb-register-gateway [OPTIONS]

One-shot PostgreSQL-side registration of a local DocumentDB gateway against
an existing PostgreSQL instance. Writes pg_hba.conf/pg_ident.conf managed
blocks, creates the gateway PG role, writes the connection URL file, and
optionally bootstraps the first admin user.

If neither --target-postgres-instance nor --pgdata is supplied and there is
exactly one PostgreSQL instance on the host, that instance is auto-detected
and used (the typical Workflow B case — see packaging-design.md §5). When
multiple instances are present, you must name the target explicitly.

Does NOT modify postgresql.conf (use documentdb-tune for that).
Requires the documentdb-gateway package to already be installed (the
gateway OS user is the proof we can map an ident entry to it).

Options:
  --target-postgres-instance V/C
                        Target a specific PostgreSQL instance (e.g., "18/main").
                        Optional when exactly one PG instance exists on the host.
                        When set without --state-mode, the tool defaults to
                        brownfield state mode (writes brownfield.conf rather
                        than setup.conf) because an explicitly-named distro
                        cluster is almost always an adopted brownfield PG.
  --target-cluster V/C  Deprecated alias for --target-postgres-instance
  --pgdata DIR          PostgreSQL data directory (alternative to --target-postgres-instance).
                        Treated as greenfield by default (the data dir is
                        documentdb-N's private dir under the stand-alone wrapper).
  --socket-dir DIR      Unix socket directory for psql connections
  --pg-port PORT        PostgreSQL port for socket connections
  --pg-owner USER       OS user to invoke psql as (default: postgres for
                        distro-managed PG; pass documentdb-local for the
                        stand-alone greenfield instance)
  --state-mode MODE     Override the auto-selected state mode. MODE must be
                        one of: greenfield (writes /etc/documentdb/local/N/setup.conf,
                        which activates documentdb-postgresql@N.service via
                        ConditionPathExists), or brownfield (writes
                        brownfield.conf, which does NOT activate the
                        greenfield PG service so an adopted system PG keeps
                        its own lifecycle). Default: greenfield, unless a
                        target instance is named via
                        --target-postgres-instance OR resolved by the
                        single-instance auto-detect (then brownfield: either
                        way the target is a distro-managed cluster, and
                        setup.conf would wrongly make
                        documentdb-postgresql@N.service activatable
                        against it).
  --pg-version N        PostgreSQL major version of the target instance
                        (optional; auto-derived from --pgdata's PG_VERSION
                        file or --target-postgres-instance, or from the
                        single-instance filesystem auto-detect when neither
                        is given -- only needed as a fallback when none of
                        those can supply it). Used to verify the PostgreSQL
                        16+ prerequisite and to name the per-major
                        units/files.
  --target-db NAME      Database where CREATE EXTENSION documentdb ran
                        (default: postgres). The gateway connection URL and the
                        optional --admin-user bootstrap target this database;
                        set it when the extension lives in a non-default
                        database so registration does not target the wrong DB.
  --admin-user NAME     Bootstrap the first admin user (optional;
                        requires --admin-password-file or
                        --admin-password-stdin)
  --admin-password-file FILE  Password file for --admin-user
  --admin-password-stdin  Read --admin-user password from stdin (one
                        line). Use for piping a secret without
                        materializing a file (pass --yes too, since stdin
                        is the password pipe, not a terminal):
                          printf '%s' "$PW" | sudo documentdb-register-gateway \
                            ... --admin-user admin --admin-password-stdin --yes
  --listen-addr ADDR    Gateway listen address (e.g. ":10260"). Recorded
                        in the per-major gateway.env so the
                        documentdb-gateway-local@N.service unit reads it.
  --tls-cert FILE       PEM certificate path for the gateway listener.
                        Must be paired with --tls-key. Written to the
                        per-major gateway.env as DOCUMENTDB_TLS_CERT_FILE.
  --tls-key FILE        PEM private key path. Pair with --tls-cert.
                        Written as DOCUMENTDB_TLS_KEY_FILE.
  --tls-auto-generate {true|false}
                        Force or disable auto-generated self-signed
                        certificate. Recorded as
                        DOCUMENTDB_TLS_AUTO_GENERATE.
  --yes                 Non-interactive (no prompts)
  --dry-run             Preview changes without writing
  --restore             Remove all managed blocks and revert changes
  --verbose             Show detailed output
  -h, --help            Show this help message
EOF
}

run_as_user() {
    local target_user="$1"; shift
    if command -v runuser >/dev/null 2>&1; then
        runuser -u "${target_user}" -- "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo -u "${target_user}" "$@"
    else
        su -s /bin/bash "${target_user}" -c "$(printf '%q ' "$@")"
    fi
}

# ── Managed-block helpers (shared) ──────────────────────────────────
#
# The managed-block / config-mutation primitives and shared string helpers are
# single-sourced from
# documentdb-tools-lib.sh so documentdb-tune and documentdb-register-gateway
# cannot drift. The library lives beside this script in a dev checkout and at
# /usr/share/documentdb/scripts/ when installed from the
# documentdb-postgresql-tools package. Die / log_verbose / create_temp_in_dir
# (defined above) satisfy the library's host contract. The managed-block
# primitives — including prepend_with_managed_block — are single-sourced from
# the library so documentdb-setup, documentdb-tune and this script cannot drift.
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

# ── Distro / path resolution ───────────────────────────────────────

detect_distro() {
    IS_DEBIAN=false
    if [[ -f /etc/debian_version ]] || command -v dpkg >/dev/null 2>&1; then
        IS_DEBIAN=true
    fi
}

resolve_pg_bindir() {
    local d
    while IFS= read -r d; do
        if [[ -x "${d}/psql" ]]; then
            PSQL="${d}/psql"
            return 0
        fi
    done < <(documentdb_pg_bindir_candidates "${PG_VERSION}")
    die "Cannot find PostgreSQL ${PG_VERSION} client binaries."
}

resolve_cluster_paths() {
    if [[ -n "${PGDATA}" ]]; then
        HBA_FILE="${PGDATA}/pg_hba.conf"
        IDENT_FILE="${PGDATA}/pg_ident.conf"
        # Derive the live port and socket directory from the data directory's
        # own postmaster.pid (line 4 = port, line 5 = socket dir) so that the
        # role/extension/admin psql operations hit the SAME cluster whose
        # pg_hba.conf / pg_ident.conf we are about to edit. Without this, an
        # unset --pg-port fell back to 5432 (see main) and an unset
        # --socket-dir to /var/run/postgresql, so a --pgdata cluster listening
        # elsewhere would have its auth files edited while SQL ran against a
        # different instance on the default socket/port. Explicit --pg-port /
        # --socket-dir always win.
        local _pmpid="${PGDATA}/postmaster.pid"
        if [[ -r "${_pmpid}" ]]; then
            if [[ -z "${PG_PORT}" ]]; then
                local _pm_port
                _pm_port="$(sed -n '4p' "${_pmpid}" 2>/dev/null | tr -dc '0-9')"
                [[ -n "${_pm_port}" ]] && PG_PORT="${_pm_port}"
            fi
            if [[ -z "${SOCKET_DIR}" ]]; then
                local _pm_sock
                _pm_sock="$(sed -n '5p' "${_pmpid}" 2>/dev/null)"
                [[ "${_pm_sock}" == /* ]] && SOCKET_DIR="${_pm_sock}"
            fi
        fi
        # /var/run/postgresql is the convention on both Debian and RHEL
        # packaged PostgreSQL. Operators using a non-default socket dir on a
        # stopped cluster (no postmaster.pid) must still pass --socket-dir.
        [[ -z "${SOCKET_DIR}" ]] && SOCKET_DIR="/var/run/postgresql"
        return 0
    fi

    if [[ "${IS_DEBIAN}" == "true" ]]; then
        local pg_conf_dir="/etc/postgresql/${PG_VERSION}/${CLUSTER_NAME}"
        PGDATA="/var/lib/postgresql/${PG_VERSION}/${CLUSTER_NAME}"
        HBA_FILE="${pg_conf_dir}/pg_hba.conf"
        IDENT_FILE="${pg_conf_dir}/pg_ident.conf"
        [[ -z "${SOCKET_DIR}" ]] && SOCKET_DIR="/var/run/postgresql"
    else
        PGDATA="/var/lib/pgsql/${PG_VERSION}/data"
        HBA_FILE="${PGDATA}/pg_hba.conf"
        IDENT_FILE="${PGDATA}/pg_ident.conf"
        [[ -z "${SOCKET_DIR}" ]] && SOCKET_DIR="/var/run/postgresql"
    fi
    # Explicit return so the function's exit status never reflects the trailing
    # `[[ -z SOCKET_DIR ]] && ...` short-circuit (which returns 1 when
    # SOCKET_DIR is already set, e.g. --socket-dir given with
    # --target-postgres-instance) and trips `set -e` at the call site.
    return 0
}

# Resolve the chosen target cluster's actual TCP port from on-disk config so
# psql ops hit the same cluster whose HBA/ident we just edited. Without this
# the script falls back to 5432 and silently registers against the wrong
# cluster when the operator named one that listens on a non-default port
# (Debian's pg_createcluster auto-assigns 5432, 5433, 5434, ...).
resolve_target_cluster_port() {
    if [[ "${IS_DEBIAN}" == "true" ]]; then
        local debian_conf="/etc/postgresql/${PG_VERSION}/${CLUSTER_NAME}/postgresql.conf"
        if [[ -r "${debian_conf}" ]]; then
            local discovered_port
            discovered_port="$(awk -F= '/^[[:space:]]*port[[:space:]]*=/{gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]#].*/, "", $2); gsub(/[\047"]/, "", $2); if ($2 ~ /^[0-9]+$/) print $2; exit}' "${debian_conf}")"
            if [[ -n "${discovered_port}" ]]; then
                PG_PORT="${discovered_port}"
                log_verbose "Resolved cluster ${PG_VERSION}/${CLUSTER_NAME} port from ${debian_conf}: ${PG_PORT}"
                return 0
            fi
        fi
        # Last resort on Debian: try pg_lsclusters output.
        if command -v pg_lsclusters >/dev/null 2>&1; then
            local lscluster_port
            lscluster_port="$(pg_lsclusters --no-header 2>/dev/null \
                | awk -v v="${PG_VERSION}" -v c="${CLUSTER_NAME}" \
                    '$1==v && $2==c {print $3; exit}')"
            if [[ -n "${lscluster_port}" && "${lscluster_port}" =~ ^[0-9]+$ ]]; then
                PG_PORT="${lscluster_port}"
                log_verbose "Resolved cluster ${PG_VERSION}/${CLUSTER_NAME} port from pg_lsclusters: ${PG_PORT}"
                return 0
            fi
        fi
    else
        # RHEL/Fedora: PGDG's systemd unit and conf put port in
        # /var/lib/pgsql/<V>/data/postgresql.conf.
        local rhel_conf="/var/lib/pgsql/${PG_VERSION}/data/postgresql.conf"
        if [[ -r "${rhel_conf}" ]]; then
            local discovered_port
            discovered_port="$(awk -F= '/^[[:space:]]*port[[:space:]]*=/{gsub(/^[[:space:]]+/, "", $2); gsub(/[[:space:]#].*/, "", $2); gsub(/[\047"]/, "", $2); if ($2 ~ /^[0-9]+$/) print $2; exit}' "${rhel_conf}")"
            if [[ -n "${discovered_port}" ]]; then
                PG_PORT="${discovered_port}"
                log_verbose "Resolved cluster ${PG_VERSION} port from ${rhel_conf}: ${PG_PORT}"
                return 0
            fi
        fi
    fi
    # Caller falls back to 5432; this is fine when the cluster's config is
    # unreadable (e.g. running as a non-root operator before sudo).
    return 0
}

# ── HBA block ───────────────────────────────────────────────────────

build_hba_block() {
    # Scope the peer + ident-map rule to the database users the gateway is
    # actually allowed to assume (per the ident map: the gateway PG role
    # itself + the three documentdb_*_role groups). Without this scoping
    # the previous "local all all peer map=documentdb-gateway-map" rule
    # was a first-match catch-all that locked out any other local OS
    # user (postgres, documentdb-local) trying peer auth because their
    # ident map entry doesn't exist.
    cat <<EOF
local   all   "${GW_PG_ROLE}",+documentdb_admin_role,+documentdb_readwrite_role,+documentdb_readonly_role   peer   map=documentdb-gateway-map
EOF
}

# ── Ident map block ─────────────────────────────────────────────────

# Resolve the effective PostgreSQL major into TARGET_PG_MAJOR for the version
# gate below (enforce_gateway_pg_major_supported). The gateway's package-managed
# peer + pg_ident.conf group-membership registration requires PostgreSQL 16+, so
# we must know the major before mutating anything.
#
# Cross-check the asserted major (from --pg-version / --target-postgres-instance
# / PGDATA/PG_VERSION) against the live server_version_num when the instance is
# reachable, and prefer the LIVE value — a stale or mistyped asserted major must
# not let a PG15 server slip past the gate. A hard disagreement is fatal: the
# config we are about to write would otherwise target a different cluster.
resolve_target_pg_major() {
    TARGET_PG_MAJOR=""
    local asserted=""
    [[ "${PG_VERSION}" =~ ^[0-9]+$ ]] && asserted="${PG_VERSION}"

    local live="" vnum=""
    if [[ -n "${PSQL}" && -n "${SOCKET_DIR}" && -n "${PG_PORT}" ]]; then
        # Probe the target database (the one the rest of do_setup connects to),
        # falling back to 'postgres'. server_version_num is available from any
        # database, and probing TARGET_DB gives the cross-check the same
        # reachability as the operations that follow.
        vnum="$(run_as_user "${PG_OWNER:-postgres}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d "${TARGET_DB:-postgres}" -X -tA -c 'SHOW server_version_num;' 2>/dev/null | tr -d '[:space:]' || true)"
        [[ "${vnum}" =~ ^[0-9]+$ ]] && live=$(( vnum / 10000 ))
    fi

    if [[ -n "${asserted}" && -n "${live}" && "${asserted}" != "${live}" ]]; then
        die "PostgreSQL major mismatch: asserted major ${asserted} but the live server at ${SOCKET_DIR}:${PG_PORT} reports major ${live}. Refusing to write gateway configuration that would target the wrong cluster; re-check --pg-version / --target-postgres-instance / --pg-port."
    fi

    # Prefer the authoritative live value; fall back to the asserted major.
    TARGET_PG_MAJOR="${live:-${asserted}}"
}

# The gateway opens a per-authenticated-user PostgreSQL connection AS that user's
# role with an EMPTY password (SCRAM verifies the client at the wire level, then
# the data pool connects over the local socket — see documentdb_gateway_core
# auth.rs allocate_data_pool("")). It therefore relies on peer auth plus a
# pg_ident.conf map that turns the gateway OS user into the requested member role
# via '+group' membership. That '+group' matching in the pg_ident.conf DB-user
# field was introduced in PostgreSQL 16; on PG<=15 it silently never matches and
# there is no password for a scram-sha-256 fallback, so authenticated per-user
# data operations cannot work. Refuse to register rather than write a config that
# starts but fails on the first authenticated query.
#
# PostgreSQL 15 stays fully supported for extension-only use (CREATE EXTENSION
# documentdb + SQL); only this package-managed local-gateway registration needs
# 16+. --restore dispatches to do_restore and never reaches this gate.
enforce_gateway_pg_major_supported() {
    if [[ -n "${TARGET_PG_MAJOR}" ]]; then
        if (( TARGET_PG_MAJOR < 16 )); then
            die "The DocumentDB gateway's package-managed peer/pg_ident registration requires PostgreSQL 16 or newer (detected major ${TARGET_PG_MAJOR}). It maps the gateway OS user to per-user database roles via pg_ident.conf group membership ('+role'), a PostgreSQL 16 feature, and SCRAM-authenticated users have no password for a password-based fallback. PostgreSQL ${TARGET_PG_MAJOR} is still supported for extension-only use (CREATE EXTENSION documentdb)."
        fi
        return 0
    fi
    # Unknown major: fail closed on a real apply (never write a config we cannot
    # verify is PG16+); a --dry-run preview may proceed with a warning.
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "WARNING: could not determine the target PostgreSQL major version; the gateway requires PostgreSQL 16+. This preview assumes a supported major."
        return 0
    fi
    die "Could not determine the target PostgreSQL major version, which is required to verify the gateway's PostgreSQL 16+ prerequisite. Pass --pg-version N (with --pgdata) or --target-postgres-instance N/cluster, or ensure the instance is reachable."
}

build_ident_block() {
    # The gateway's SYSTEM/auth connection pools connect AS the documentdb-gateway
    # role (the exact one-to-one mapping below), but each authenticated client's
    # DATA pool connects AS that client's own role with an empty password, so the
    # '+group' entries are required to let the gateway OS user assume member roles
    # via peer auth. This needs PostgreSQL 16+; enforce_gateway_pg_major_supported
    # guarantees we only reach here on a supported major.
    local -a map_lines=(
        "documentdb-gateway-map   ${GW_OS_USER}   ${GW_PG_ROLE}"
        "documentdb-gateway-map   ${GW_OS_USER}   +documentdb_admin_role"
        "documentdb-gateway-map   ${GW_OS_USER}   +documentdb_readwrite_role"
        "documentdb-gateway-map   ${GW_OS_USER}   +documentdb_readonly_role"
        "documentdb-gateway-map   documentdb-local   +documentdb_admin_role"
        "documentdb-gateway-map   documentdb-local   +documentdb_readwrite_role"
        "documentdb-gateway-map   documentdb-local   +documentdb_readonly_role"
    )
    # The extension's internal/admin libpq connections dial the local socket
    # with peer auth AS the PostgreSQL server's OS user, so that user must be
    # able to assume the documentdb role groups. Greenfield runs PostgreSQL as
    # documentdb-local (already mapped above); brownfield adopts a distro cluster
    # that runs as PG_OWNER (e.g. postgres), which otherwise has no ident map and
    # fails peer auth. Add PG_OWNER's group maps, de-duplicating when it is
    # already documentdb-local.
    if [[ -n "${PG_OWNER}" && "${PG_OWNER}" != "documentdb-local" ]]; then
        map_lines+=(
            "documentdb-gateway-map   ${PG_OWNER}   +documentdb_admin_role"
            "documentdb-gateway-map   ${PG_OWNER}   +documentdb_readwrite_role"
            "documentdb-gateway-map   ${PG_OWNER}   +documentdb_readonly_role"
        )
    fi
    printf '%s\n' "${map_lines[@]}"
}

# ── Safety helpers ───────────────────────────────────────────────────

# ── Actions ─────────────────────────────────────────────────────────

do_setup() {
    [[ -f "${HBA_FILE}" ]] || die "pg_hba.conf not found: ${HBA_FILE}"
    [[ -f "${IDENT_FILE}" ]] || die "pg_ident.conf not found: ${IDENT_FILE}"

    # Gateway OS user prereq is already verified by check_gateway_prereq
    # in main before any I/O. This duplicate check is belt-and-suspenders
    # for any future direct caller of do_setup that bypasses main. It is
    # skipped for --dry-run because a preview must work before the gateway
    # package (and its OS user) is installed — matching the main guard.
    [[ "${DRY_RUN}" == "true" ]] || check_gateway_prereq

    # Resolve the target PostgreSQL major and enforce the gateway's PostgreSQL
    # 16+ prerequisite BEFORE building or previewing any managed block, so a PG15
    # target is rejected before mutation (and before a dry-run advertises a plan
    # that could never work).
    resolve_target_pg_major
    enforce_gateway_pg_major_supported

    local hba_block ident_block
    hba_block="$(build_hba_block)"
    ident_block="$(build_ident_block)"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Would write managed HBA block to ${HBA_FILE}:"
        printf '%s\n' "${PG_HBA_BLOCK_START}"
        printf '%s\n' "${hba_block}"
        printf '%s\n' "${PG_HBA_BLOCK_END}"
        echo ""
        log "Would write managed ident block to ${IDENT_FILE}:"
        printf '%s\n' "${PG_IDENT_BLOCK_START}"
        printf '%s\n' "${ident_block}"
        printf '%s\n' "${PG_IDENT_BLOCK_END}"
        if [[ -n "${PSQL}" && -n "${SOCKET_DIR}" && -n "${PG_PORT}" ]]; then
            log "Would verify the live PostgreSQL config paths via psql at ${SOCKET_DIR}:${PG_PORT} as OS user ${PG_OWNER:-postgres}."
            log "Would create or refresh gateway PG role '${GW_PG_ROLE}'."
        fi
        if [[ -n "${SECRET_DIR}" ]]; then
            log "Would write connection URL file to ${SECRET_FILE}."
        fi
        if [[ -n "${ADMIN_USER}" && -n "${ADMIN_PASSWORD_FILE}" ]]; then
            log "Would create admin user '${ADMIN_USER}' in database '${TARGET_DB}'."
        fi
        if [[ -n "${STATE_FILE}" ]]; then
            log "Would record restore state in ${STATE_FILE}."
        fi
        if [[ -n "${GATEWAY_ENV_FILE}" ]]; then
            log "Would write gateway environment fragment to ${GATEWAY_ENV_FILE}."
        fi
        return 0
    fi

    if [[ "${YES}" != "true" ]]; then
        echo "${PROG}: about to modify:"
        echo "  ${HBA_FILE} — peer auth with ident map"
        echo "  ${IDENT_FILE} — gateway OS user → DB role map"
        if [[ -n "${ADMIN_USER}" ]]; then
            echo "  Create PG role '${GW_PG_ROLE}' and admin user '${ADMIN_USER}'"
        fi
        if [[ -t 0 ]]; then
            local answer=""
            read -r -p "Proceed? [y/N] " answer || true
            case "${answer}" in
                y|Y|yes|YES) ;;
                *) log "Aborted."; exit 0 ;;
            esac
        else
            die "Non-interactive run requires --yes (refusing to modify PostgreSQL auth config without confirmation). When piping a password via --admin-password-stdin, also pass --yes."
        fi
    fi

    # Persist a minimal recovery record
    # BEFORE the first config mutation, not after the whole flow succeeds.
    # The port resolver narrows the
    # 5432-default footgun, but if --pg-port is stale or if the port
    # changed between resolution and connect, role/admin operations could
    # still land on a different cluster than the HBA/ident files we are
    # about to edit. Verify with `SHOW config_file` that the live instance
    # we are connecting to owns the HBA file we are about to mutate. If
    # not, refuse — the operator must reconcile before we mutate anything.
    #
    # MUST run BEFORE write_recovery_marker
    # because verify_psql_connects_to_named_cluster also overrides
    # HBA_FILE/IDENT_FILE with the live SHOW values (operators can set
    # custom hba_file/ident_file). If we wrote the marker first with the
    # default paths and were interrupted before final record_state, the
    # postrm cleanup would target the wrong files and leave the real
    # ones with orphaned managed blocks.
    verify_psql_connects_to_named_cluster

    # Verify the target database itself is reachable BEFORE any mutation, so a
    # mistyped or non-existent --target-db fails cleanly instead of writing
    # HBA/ident blocks and a connection URL the gateway can never use (the soft
    # extension check later swallows connection errors). The database must
    # exist even though the extension may not be loaded yet (the wizard creates
    # the extension next), so this probes connectivity only, not the extension.
    if [[ -n "${PSQL}" && -n "${SOCKET_DIR}" && -n "${PG_PORT}" ]]; then
        if ! run_as_user "${PG_OWNER}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
                -d "${TARGET_DB}" -X -tA -v ON_ERROR_STOP=1 -c "SELECT 1;" >/dev/null 2>&1; then
            die "Cannot connect to target database '${TARGET_DB}' at ${SOCKET_DIR}:${PG_PORT} as ${PG_OWNER}. Verify the database exists and --target-db is correct."
        fi
    fi

    # Persist a minimal recovery record
    # BEFORE the first config mutation, not after the whole flow succeeds.
    # Without this, a SIGTERM (or shellcheck-failed exit) between the HBA
    # write and record_state leaves managed blocks in postgresql config
    # files with no state-file pointer for the package's postrm / %postun
    # to use during cleanup. The package's unconditional orphan sweep only
    # covers gateway.env + the drop-in + the tmpfs URL; HBA/ident blocks
    # would be silently orphaned. Now runs AFTER the live-path verifier
    # so it records the actual paths we're about to mutate.
    write_recovery_marker

    # Write HBA block (prepend for first-match semantics)
    check_foreign_markers "${HBA_FILE}"
    check_foreign_markers "${IDENT_FILE}"
    backup_file "${HBA_FILE}"
    backup_file "${IDENT_FILE}"
    log "Writing managed HBA block to ${HBA_FILE}"
    prepend_with_managed_block "${HBA_FILE}" \
        "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}" "${hba_block}"

    # Write ident map block (ident_block was built above; none of its
    # inputs change in between, and command substitution already stripped
    # trailing newlines).
    log "Writing managed ident block to ${IDENT_FILE}"
    rewrite_with_managed_block "${IDENT_FILE}" \
        "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}" "${ident_block}"

    # Suggest reload (the earlier bug: print pg_ctlcluster / pg_reload_conf
    # fallback when systemd is unavailable so containers and minimal
    # hosts get a working command).
    local has_systemd=0
    if [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1; then
        has_systemd=1
    fi
    if [[ "${IS_DEBIAN}" == "true" && -n "${PG_VERSION}" && -n "${CLUSTER_NAME}" ]]; then
        if [[ "${has_systemd}" == "1" ]]; then
            local reload_cmd="sudo systemctl reload postgresql@${PG_VERSION}-${CLUSTER_NAME}"
        else
            local reload_cmd="sudo pg_ctlcluster ${PG_VERSION} ${CLUSTER_NAME} reload  # (no systemd detected)"
        fi
    else
        if [[ "${has_systemd}" == "1" && -n "${PG_VERSION}" ]]; then
            # RHEL/PGDG systemd unit is postgresql-${PG_VERSION}.service; there
            # is no bare "postgresql" unit, so a plain `reload postgresql`
            # would fail and the freshly written hba/ident blocks would never
            # be reloaded.
            local reload_cmd="sudo systemctl reload postgresql-${PG_VERSION}"
        elif [[ "${has_systemd}" == "1" ]]; then
            local reload_cmd="sudo systemctl reload postgresql"
        else
            local reload_cmd="sudo -u ${PG_OWNER:-postgres} psql -c 'SELECT pg_reload_conf();'  # (no systemd detected)"
        fi
    fi

    # Check if extension is loaded and warn if not. When called by the
    # wizard, we KNOW CREATE EXTENSION is the very next step, so the
    # WARNING is noise that looks like an error. Suppress under
    # the wizard's DOCUMENTDB_REGISTER_GATEWAY_QUIET=1.
    if [[ -n "${PSQL}" && -n "${SOCKET_DIR}" && -n "${PG_PORT}" \
            && "${DOCUMENTDB_REGISTER_GATEWAY_QUIET:-0}" != "1" ]]; then
        local ext_check
        ext_check="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d "${TARGET_DB}" -X -tA -c "SELECT 1 FROM pg_extension WHERE extname = 'documentdb';" 2>/dev/null || true)"
        if [[ "${ext_check}" != "1" ]]; then
            log "WARNING: The DocumentDB extension is not loaded in the '${TARGET_DB}' database."
            log "Run:  sudo -u ${PG_OWNER} psql -d ${TARGET_DB} -c 'CREATE EXTENSION documentdb CASCADE;'"
            log "Then: ${reload_cmd}"
        fi
    fi

    # Create the gateway PG role
    if [[ -n "${PSQL}" && -n "${SOCKET_DIR}" && -n "${PG_PORT}" ]]; then
        create_gateway_role
    fi

    # Write connection URL file (consumed by the gateway via DOCUMENTDB_PG_URL_FILE)
    if [[ -n "${SECRET_DIR}" ]]; then
        write_connection_secret
    fi

    # Optional first-admin user bootstrap (extension-side user-management API)
    # Track success so the
    # completion message below can branch on whether a working admin
    # login actually exists, rather than always printing a happy URI.
    local admin_bootstrap_succeeded=false
    if [[ -n "${ADMIN_USER}" && -n "${ADMIN_PASSWORD_FILE}" ]]; then
        if create_admin_user; then
            admin_bootstrap_succeeded=true
        fi
    fi

    # Record state + gateway env fragment last so --restore knows exactly
    # what was written (state-file contents drive the restore path).
    record_state

    # Print the "Setup complete" message only AFTER all side effects have
    # actually succeeded. Previously this was printed before role creation,
    # connection-file writes, admin bootstrap, and state recording, which
    # made it possible for the operator to see a success message while the
    # gateway still could not start.
    # When this tool is run as a delegated
    # subcommand of documentdb-setup, the wizard is about to handle the
    # "Remaining steps" itself (reload PG, start the gateway, bootstrap
    # admin) — printing them here makes the operator think the wizard
    # stopped mid-flow. The wizard sets DOCUMENTDB_REGISTER_GATEWAY_QUIET=1
    # to suppress the "Remaining steps" block. Standalone invocations
    # (Workflow B) still print the guidance.
    if [[ "${DOCUMENTDB_REGISTER_GATEWAY_QUIET:-0}" == "1" ]]; then
        log "Registration complete; the wizard will reload PG and start the gateway next."
        return 0
    fi
    echo ""
    log "Setup complete. Remaining steps:"
    echo "  1. Reload PostgreSQL: ${reload_cmd}"
    local start_cmd="sudo systemctl enable --now documentdb-gateway"
    if [[ -n "${PG_VERSION}" && "${GATEWAY_ENV_FILE}" == "/etc/documentdb/local/${PG_VERSION}/gateway.env" ]]; then
        start_cmd="sudo systemctl enable --now documentdb-local@${PG_VERSION}.target"
    fi
    echo "  2. Start the gateway: ${start_cmd}"
    # Derive the connect host/port for the printed hints from any operator
    # --listen-addr (GATEWAY_LISTEN_ADDR, e.g. ":10260" or "host:port") so every
    # branch below advertises the port the gateway actually binds rather than the
    # 10260 default. A wildcard/unspecified host is not connectable, so fall back
    # to loopback.
    local connect_host="127.0.0.1"
    local connect_port="10260"
    if [[ -n "${GATEWAY_LISTEN_ADDR:-}" ]]; then
        local _la="${GATEWAY_LISTEN_ADDR}"
        if [[ "${_la}" =~ ^:[0-9]+$ ]]; then
            connect_port="${_la#:}"
        else
            connect_host="${_la%:*}"
            connect_port="${_la##*:}"
        fi
        case "${connect_host}" in
            ""|":"|"0.0.0.0"|"::"|"*") connect_host="127.0.0.1" ;;
        esac
    fi
    # Bracket a bare IPv6 literal so host:port stays unambiguous. The pattern
    # "["*"]" matches an already-bracketed host (literal [... ]) so it is not
    # double-bracketed; quoting the brackets keeps the glob valid for linters.
    if [[ "${connect_host}" == *:* && "${connect_host}" != "["*"]" ]]; then
        connect_host="[${connect_host}]"
    fi
    # Branch on actual admin-bootstrap success — not just whether
    # --admin-user was passed — so the operator never sees a happy connect
    # URI for a login that does not exist.
    if [[ "${admin_bootstrap_succeeded}" == "true" ]]; then
        local connect_opts="tls=true&tlsAllowInvalidCertificates=true"
        local connect_uri
        # Build URI in parts to avoid credential-pattern false positives in secret scanners
        connect_uri="mongosh mongodb://"
        connect_uri+="${ADMIN_USER}@${connect_host}:${connect_port}/?${connect_opts}"
        echo "  3. Connect:           ${connect_uri}"
    elif [[ -n "${ADMIN_USER}" ]]; then
        echo "  3. Admin bootstrap FAILED — see the WARNING above. Create the first admin user manually before connecting:"
        echo "       sudo documentdb-gateway-admin create-user --username ${ADMIN_USER} --password-file <FILE> --pg-owner ${PG_OWNER} --target-db ${TARGET_DB}"
        echo "  4. Then connect with that user via mongosh on ${connect_host}:${connect_port} (tls=true)."
    else
        echo "  3. Bootstrap first admin user (no --admin-user was provided):"
        echo "       sudo documentdb-gateway-admin create-user --username <NAME> --password-file <FILE> --pg-owner ${PG_OWNER} --target-db ${TARGET_DB}"
        echo "  4. Then connect with that user via mongosh on ${connect_host}:${connect_port} (tls=true)."
    fi
}

create_gateway_role() {
    local role_exists
    # Do NOT merge stderr (2>&1) into the captured value: a benign stderr line
    # (e.g. a sudo/runuser "could not change directory to /root" warning) would
    # pollute role_exists so the strict `== "1"` check below fails, triggering a
    # spurious CREATE ROLE that then aborts an idempotent re-run with "role
    # already exists". Let stderr flow to the console; capture stdout only.
    role_exists="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
        -d postgres -X -tA -v ON_ERROR_STOP=1 \
        -c "SELECT 1 FROM pg_roles WHERE rolname = '${GW_PG_ROLE}';")" || \
        die "Cannot connect to PostgreSQL at ${SOCKET_DIR}:${PG_PORT} as OS user ${PG_OWNER} to check for gateway role."

    if [[ "${role_exists}" == "1" ]]; then
        log_verbose "PG role '${GW_PG_ROLE}' already exists."
    else
        log "Creating PG role '${GW_PG_ROLE}'."
        run_as_user "${PG_OWNER}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d postgres -X -v ON_ERROR_STOP=1 \
            -c "CREATE ROLE \"${GW_PG_ROLE}\" LOGIN;" || \
            die "Failed to create PG role '${GW_PG_ROLE}'."
    fi

    # Grant the documentdb_admin/readwrite/readonly group roles to the
    # gateway role so that — at runtime — the gateway's startup query
    # against the documentdb extension's catalog functions does not hit
    # PostgreSQL error 42501 (insufficient_privilege) on a row in
    # aclchk.c. The ident map in pg_ident.conf already allows the
    # gateway OS user to SET ROLE to any of the *_role groups, but
    # the bare gateway role still needs to be a *member* of those
    # groups for inherited ACL purposes (the gateway's pool connects
    # AS documentdb-gateway, then relies on inherited group ACLs to
    # call extension functions owned by the documentdb_admin_role).
    #
    # The group roles are created by CREATE EXTENSION documentdb,
    # which has not necessarily run yet when register-gateway is
    # called from the wizard (CREATE EXTENSION happens AFTER ident
    # registration in the wizard's flow). Use IF EXISTS so this is
    # idempotent both ways: on first run before CREATE EXTENSION,
    # this is a no-op; on the re-run after CREATE EXTENSION (the
    # second wizard invocation typically), the grants land.
    #
    # NOTE: this could be cleaner as a post-CREATE-EXTENSION hook in
    # documentdb-setup, but doing it here means workflow B (BYO PG
    # with documentdb-register-gateway run manually after CREATE
    # EXTENSION) also gets the grants without an extra step.
    for grp in documentdb_admin_role documentdb_readwrite_role documentdb_readonly_role; do
        local grant_result=""
        grant_result="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d "${TARGET_DB}" -X -tA -v ON_ERROR_STOP=0 \
            -c "DO \$\$ BEGIN IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = '${grp}') THEN EXECUTE format('GRANT %I TO %I', '${grp}', '${GW_PG_ROLE}'); END IF; END \$\$;" 2>&1)" || true
        log_verbose "GRANT ${grp} TO ${GW_PG_ROLE}: ${grant_result:-ok}"
    done
}

write_connection_secret() {
    install -d -m 0750 -o root -g "${GW_OS_USER}" "${SECRET_DIR}"
    # libpq-standard URL with host/port carried as query params so the
    # Unix-socket directory path doesn't collide with the URL's literal
    # path separator. Matches the Rust gateway's URL parser
    # (see oss/pg_documentdb_gw/documentdb_gateway_core/src/configuration/setup.rs).
    # Use ${TARGET_DB} (set by --target-db,
    # defaults to "postgres") so the gateway connects to the database where
    # CREATE EXTENSION documentdb actually ran, not the hardcoded postgres.
    # The socket directory is carried as the libpq URI "host" query parameter.
    # Reject characters that would break URI parsing (& starts another param;
    # ? / # are URI delimiters; % begins a percent-escape; whitespace/control
    # chars are invalid) so a malformed --socket-dir cannot produce a URI the
    # gateway's parser would misread. Normal Unix socket directories are clean
    # absolute paths (letters, digits, . _ / + -).
    case "${SOCKET_DIR}" in
        *[!A-Za-z0-9._/+-]*)
            die "Refusing to build a connection URL: --socket-dir '${SOCKET_DIR}' contains characters that are unsafe in a libpq URI host (allowed: letters, digits, and . _ / + -)." ;;
    esac
    local url="postgresql://${GW_PG_ROLE}@/${TARGET_DB}?host=${SOCKET_DIR}&port=${PG_PORT}"
    printf '%s\n' "${url}" > "${SECRET_FILE}"
    chown "root:${GW_OS_USER}" "${SECRET_FILE}"
    chmod 0640 "${SECRET_FILE}"
    log "Connection URL file written to ${SECRET_FILE}"

    # Pre-create the per-major TLS state directory owned by the gateway.
    #
    # The per-major systemd unit (documentdb-gateway-local@N.service)
    # sets `Environment=DOCUMENTDB_TLS_STATE_DIR=${SECRET_DIR}/tls` so
    # the per-major gateway puts its auto-generated cert/key under its
    # own writable tree (matches per-major isolation). The gateway
    # runs as ${GW_OS_USER} and on first start calls
    # `fs::create_dir_all` on the TLS dir.
    #
    # Bug fix: ${SECRET_DIR} above is created mode 0750 root:${GW_OS_USER}
    # so the gateway group has r-x but NOT write on the parent. Without
    # pre-creating tls/, the gateway hits EACCES trying to mkdir it on
    # first start and the per-major service never comes up.
    #
    # Mode 0700 owned outright by the gateway: the cert/key never need
    # to be read by anyone but the gateway itself, and the tight mode
    # mirrors the security posture of the auto-generated material on
    # the Workflow B path (/var/lib/documentdb-gateway/tls is also
    # gateway-owned).
    install -d -m 0700 -o "${GW_OS_USER}" -g "${GW_OS_USER}" "${SECRET_DIR}/tls"
    log "TLS state directory pre-created at ${SECRET_DIR}/tls (gateway-owned, 0700)"
}

create_admin_user() {
    if [[ ! -r "${ADMIN_PASSWORD_FILE}" ]]; then
        die "Admin password file not readable: ${ADMIN_PASSWORD_FILE}"
    fi

    log "Creating admin user '${ADMIN_USER}' in database '${TARGET_DB}'."
    # Delegate to documentdb-gateway-admin create-user if available.
    # --target-db is threaded through so the bootstrap user lands in the
    # same database where the extension was installed.
    # --pg-owner is threaded through so the admin tool connects as the
    # Right OS user. Without
    # --pg-owner, documentdb-gateway-admin defaults to "postgres" and
    # the bootstrap silently fails on private greenfield PG owned by
    # documentdb-local.
    #
    # Return non-zero on
    # bootstrap failure so the caller's "Setup complete" message can
    # branch on success vs. Failure and print the right remediation.
    # Previously the wizard printed a happy connect URI even when the
    # bootstrap had warned-and-continued.
    if command -v documentdb-gateway-admin >/dev/null 2>&1; then
        if ! documentdb-gateway-admin create-user \
            --username "${ADMIN_USER}" \
            --password-file "${ADMIN_PASSWORD_FILE}" \
            --socket-dir "${SOCKET_DIR}" \
            --pg-port "${PG_PORT}" \
            --pg-owner "${PG_OWNER}" \
            --target-db "${TARGET_DB}"; then
            log "WARNING: Failed to create admin user '${ADMIN_USER}'. The gateway will start but no user will be able to connect. Create one manually with: documentdb-gateway-admin create-user --username ${ADMIN_USER} --password-file <file> --pg-owner ${PG_OWNER} --target-db ${TARGET_DB}"
            return 1
        fi
        return 0
    else
        log "documentdb-gateway-admin not found; first admin bootstrap skipped."
        return 1
    fi
}

record_state() {
    if [[ -n "${STATE_FILE}" ]]; then
        install -d -m 0755 "$(dirname "${STATE_FILE}")"
        # Write atomically via
        # tempfile + rename so a SIGTERM mid-write cannot leave a
        # truncated state file that defeats --restore/postrm cleanup.
        # Matches the write_recovery_marker pattern below.
        local tmp
        tmp="$(mktemp "${STATE_FILE}.XXXXXX")" \
            || die "Cannot create state tempfile in $(dirname "${STATE_FILE}"): refusing to leave inconsistent state."

        # Preserve any KEY=VALUE
        # lines in the existing state file that register-gateway does
        # not manage. This is required because in greenfield mode the
        # wizard (documentdb-setup) first writes setup.conf with
        # additional keys (GATEWAY_PORT, DATA_DIR, CONFIG_FILE,
        # DOCUMENTDB_MANAGED_POSTGRES) at the SAME path register-gateway
        # then uses as STATE_FILE. Without preservation, register-gateway
        # would silently drop those keys — breaking documentdb-setup
        # --status (which reads GATEWAY_PORT to know which port to probe
        # for a healthy listener) for any install created with a
        # non-default --listen-port. The preserve list also future-proofs
        # the layout: any new key the wizard adds is kept by default.
        # Also include
        # TARGET_DB in the managed set so we own that field.
        local preserved=""
        if [[ -f "${STATE_FILE}" ]]; then
            preserved="$(grep -Ev "${STATE_MANAGED_KEYS_RE}" "${STATE_FILE}" 2>/dev/null \
                | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
        fi

        {
            if [[ -n "${preserved}" ]]; then
                printf '%s\n' "${preserved}"
            fi
            printf 'HBA_FILE=%s\n' "${HBA_FILE}"
            printf 'IDENT_FILE=%s\n' "${IDENT_FILE}"
            printf 'SECRET_FILE=%s\n' "${SECRET_FILE}"
            printf 'PG_VERSION=%s\n' "${PG_VERSION}"
            printf 'CLUSTER_NAME=%s\n' "${CLUSTER_NAME}"
            # documentdb-gateway-admin's
            # auto_detect_connection reads PG_PORT, PG_OWNER, and
            # DOCUMENTDB_MODE from this state file to dispatch day-2 admin
            # Commands at the right cluster. Previously these were
            # missing from register-gateway's state file (only the wizard
            # wrote them, only in brownfield.conf), so any direct
            # Workflow B install without --pg-port 5432/--pg-owner postgres
            # left admin commands pointed at the wrong target.
            printf 'PG_PORT=%s\n' "${PG_PORT}"
            printf 'PG_OWNER=%s\n' "${PG_OWNER}"
            printf 'DOCUMENTDB_MODE=%s\n' "${STATE_MODE}"
            # GATEWAY_ENV_FILE is chosen
            # at apply-time based on whether documentdb-N is installed
            # (Workflow C → per-major; Workflow B → /etc/documentdb/gateway/).
            # do_restore previously recomputed it from current host
            # state, so if documentdb-N was uninstalled between setup and
            # --restore, the restore stripped the wrong env file. Persist
            # the chosen path so --restore always operates on the file
            # we actually wrote.
            printf 'GATEWAY_ENV_FILE=%s\n' "${GATEWAY_ENV_FILE}"
            # TARGET_DB
            # defaults to "postgres" but operators commonly install the
            # extension in a dedicated database via --target-db. Without
            # persisting it, documentdb-gateway-admin's auto-detect
            # leaves TARGET_DB at "postgres" and day-2 admin commands
            # (create-user, etc.) silently target the wrong DB. Persist
            # so auto-detect picks up the actual extension database.
            printf 'TARGET_DB=%s\n' "${TARGET_DB}"
        } > "${tmp}" || die "Cannot write state contents to ${tmp}."
        # The greenfield setup.conf path is read at unit-start time by
        # documentdb-postgresql@N.service which runs as User=documentdb-local.
        # The brownfield.conf path is only read by --restore tooling as root.
        # Mode 0644 on both is fine because the contents are paths/ports/
        # connection-file pointers, not secrets. (See parallel chmod 0644
        # in documentdb-setup.sh's persist_self_managed_postgres_state.)
        chmod 0644 "${tmp}"
        mv "${tmp}" "${STATE_FILE}" \
            || die "Cannot rename state file into place at ${STATE_FILE}."
    fi
    write_gateway_env_fragment
}

# Persist a minimal recovery marker
# BEFORE the HBA/ident write so that a SIGTERM (or any mid-flow error)
# leaves a state file pointing at the files we are about to touch. The
# package's postrm/%postun loops over per-major state files to recover
# managed blocks; without this pre-write marker, an interrupted setup
# leaks HBA/ident edits with no cleanup path. record_state runs again
# at end-of-setup to update with the SECRET_FILE pointer.
write_recovery_marker() {
    [[ -n "${STATE_FILE}" ]] || return 0
    install -d -m 0755 "$(dirname "${STATE_FILE}")"
    local tmp
    # Treat mktemp failure as fatal. The
    # whole point of this helper is to leave a state-file pointer before we
    # mutate PostgreSQL config; silently returning here would leave the
    # caller about to write HBA/ident edits with no postrm-recoverable
    # pointer. die is correct because this is invoked from do_setup
    # immediately before the first invasive write.
    tmp="$(mktemp "${STATE_FILE}.recovery.XXXXXX")" \
        || die "Cannot create recovery marker at $(dirname "${STATE_FILE}"): refusing to proceed without a postrm-recoverable state pointer."

    #
    # preserve any KEY=VALUE lines in the existing STATE_FILE that the
    # marker does not manage (e.g., GATEWAY_PORT, DATA_DIR, CONFIG_FILE,
    # DOCUMENTDB_MANAGED_POSTGRES written earlier by documentdb-setup in
    # greenfield mode). Without this, a SIGTERM between recovery_marker
    # and record_state would leave a file missing the wizard's keys and
    # break documentdb-setup --status until a successful re-run.
    local managed_keys_re='^(HBA_FILE|IDENT_FILE|PG_VERSION|CLUSTER_NAME|GATEWAY_ENV_FILE)='
    local preserved=""
    if [[ -f "${STATE_FILE}" ]]; then
        preserved="$(grep -Ev "${managed_keys_re}" "${STATE_FILE}" 2>/dev/null \
            | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
    fi

    {
        if [[ -n "${preserved}" ]]; then
            printf '%s\n' "${preserved}"
        fi
        printf 'HBA_FILE=%s\n' "${HBA_FILE}"
        printf 'IDENT_FILE=%s\n' "${IDENT_FILE}"
        printf 'PG_VERSION=%s\n' "${PG_VERSION}"
        printf 'CLUSTER_NAME=%s\n' "${CLUSTER_NAME}"
        # Also persist
        # GATEWAY_ENV_FILE in the recovery marker so a SIGTERM between
        # write_recovery_marker and record_state still gives
        # do_restore the persisted env path. Cost is one printf; the
        # field is unconditionally set in main before do_setup runs.
        printf 'GATEWAY_ENV_FILE=%s\n' "${GATEWAY_ENV_FILE}"
        printf '# Pre-write recovery marker. Updated by record_state() at end-of-setup.\n'
    } > "${tmp}" || die "Cannot write recovery marker contents to ${tmp}."
    # See chmod 0644 rationale in record_state above — setup.conf must
    # be readable by documentdb-local for the per-major systemd unit.
    chmod 0644 "${tmp}"
    mv "${tmp}" "${STATE_FILE}" \
        || die "Cannot rename recovery marker into place at ${STATE_FILE}."
}

# After resolve_target_cluster_port set
# PG_PORT, verify that the cluster `psql` will reach actually owns the
# HBA_FILE we are about to mutate. This catches:
#  - stale operator-supplied --pg-port
#  - cluster restarted on a different port between port-resolution and connect
#  - multiple PG instances bound on overlapping addresses
# If config_file is outside the named cluster's config tree, refuse rather
# than proceed: HBA/ident edits would target one cluster while role/admin
# psql ops target another.
verify_psql_connects_to_named_cluster() {
    # Need a reachable psql endpoint to verify anything.
    [[ -n "${PSQL}" && -n "${SOCKET_DIR}" && -n "${PG_PORT}" ]] || return 0
    # Only meaningful when we know which cluster (named) or data directory
    # (--pgdata) we intend to edit.
    [[ -n "${CLUSTER_NAME}" || -n "${PGDATA}" ]] || return 0

    if [[ -n "${CLUSTER_NAME}" && -n "${PG_VERSION}" ]]; then
        # Named-cluster mode: the live config_file must be under the named
        # cluster's config tree.
        local live_config_file
        live_config_file="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d postgres -X -tA -v ON_ERROR_STOP=1 \
            -c "SHOW config_file;" 2>/dev/null | tr -d '[:space:]' || true)"

        if [[ -z "${live_config_file}" ]]; then
            die "Cannot SHOW config_file on PostgreSQL ${PG_VERSION} via socket ${SOCKET_DIR}:${PG_PORT} as ${PG_OWNER}. Verify the instance is running and the --pg-port is correct."
        fi

        if [[ "${IS_DEBIAN}" == "true" ]]; then
            local expected_dir="/etc/postgresql/${PG_VERSION}/${CLUSTER_NAME}"
            case "${live_config_file}" in
                "${expected_dir}/"*) ;;
                *)
                    die "Cluster identity check failed: the live PostgreSQL instance at ${SOCKET_DIR}:${PG_PORT} uses config_file=${live_config_file}, which is NOT under ${expected_dir}/. Refusing to edit HBA/ident for one cluster while psql ops would hit another. Re-run with the correct --pg-port or --target-postgres-instance."
                    ;;
            esac
        else
            # RHEL/Fedora PGDG: config_file lives under the data directory.
            local expected_data_dir="/var/lib/pgsql/${PG_VERSION}/data"
            case "${live_config_file}" in
                "${expected_data_dir}/"*) ;;
                *)
                    die "Cluster identity check failed: the live PostgreSQL instance at ${SOCKET_DIR}:${PG_PORT} uses config_file=${live_config_file}, which is NOT under ${expected_data_dir}/. Refusing to edit HBA/ident for one cluster while psql ops would hit another. Re-run with the correct --pg-port or --pgdata."
                    ;;
            esac
        fi
    elif [[ -n "${PGDATA}" ]]; then
        # --pgdata mode (no named cluster): the live instance's data_directory
        # must equal the directory whose pg_hba.conf / pg_ident.conf we will
        # edit. This closes the same split-brain gap the named-cluster
        # config_file check closes above — without it, a wrong/default
        # --pg-port could mutate one cluster's auth files while SQL ops hit
        # another instance.
        local live_data_dir want_data_dir
        live_data_dir="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d postgres -X -tA -v ON_ERROR_STOP=1 \
            -c "SHOW data_directory;" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ -z "${live_data_dir}" ]]; then
            die "Cannot SHOW data_directory on PostgreSQL via socket ${SOCKET_DIR}:${PG_PORT} as ${PG_OWNER}. Verify the instance at --pgdata ${PGDATA} is running and reachable (or pass --pg-port / --socket-dir)."
        fi
        want_data_dir="${PGDATA}"
        if command -v realpath >/dev/null 2>&1; then
            live_data_dir="$(realpath -m "${live_data_dir}" 2>/dev/null || printf '%s' "${live_data_dir}")"
            want_data_dir="$(realpath -m "${PGDATA}" 2>/dev/null || printf '%s' "${PGDATA}")"
        fi
        if [[ "${live_data_dir}" != "${want_data_dir}" ]]; then
            die "Cluster identity check failed: the live PostgreSQL instance at ${SOCKET_DIR}:${PG_PORT} has data_directory=${live_data_dir}, which does NOT match --pgdata ${want_data_dir}. Refusing to edit HBA/ident for one cluster while psql ops would hit another. Re-run with the correct --pg-port / --socket-dir."
        fi
    fi

    # Resolve the live hba_file and
    # ident_file from PostgreSQL itself before mutating. Operators can
    # set custom hba_file/ident_file in postgresql.conf — without
    # querying, this tool would silently edit the distro-default paths
    # while the running PG reads its custom files (so the gateway role
    # is never reached).
    local live_hba_file live_ident_file
    live_hba_file="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
        -d postgres -X -tA -v ON_ERROR_STOP=1 \
        -c "SHOW hba_file;" 2>/dev/null | tr -d '[:space:]' || true)"
    live_ident_file="$(run_as_user "${PG_OWNER}" "${PSQL}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
        -d postgres -X -tA -v ON_ERROR_STOP=1 \
        -c "SHOW ident_file;" 2>/dev/null | tr -d '[:space:]' || true)"

    if [[ -n "${live_hba_file}" && "${live_hba_file}" != "${HBA_FILE}" ]]; then
        log "Overriding HBA file from cluster query: ${HBA_FILE} -> ${live_hba_file}"
        HBA_FILE="${live_hba_file}"
    fi
    if [[ -n "${live_ident_file}" && "${live_ident_file}" != "${IDENT_FILE}" ]]; then
        log "Overriding ident file from cluster query: ${IDENT_FILE} -> ${live_ident_file}"
        IDENT_FILE="${live_ident_file}"
    fi

    log_verbose "Cluster identity verified (hba=${HBA_FILE}, ident=${IDENT_FILE})."
}

# Write or refresh a managed block inside the gateway's EnvironmentFile so
# that the systemd unit (documentdb-gateway.service or
# documentdb-gateway-local@.service) automatically picks up the
# connection-URL file we just produced. The block is delimited by the
# same managed-block markers used elsewhere so that --restore and package
# purge can strip it without disturbing administrator-authored lines.
write_gateway_env_fragment() {
    local env_target=""
    if [[ -n "${GATEWAY_ENV_FILE}" ]]; then
        env_target="${GATEWAY_ENV_FILE}"
    else
        env_target="/etc/documentdb/gateway/gateway.env"
    fi
    install -d -m 0755 "$(dirname "${env_target}")"
    # Ensure the file exists so the systemd unit's non-optional
    # EnvironmentFile= form doesn't fail on first install.
    touch "${env_target}"
    # 0640 root:documentdb-gateway, matching what the gateway postinst
    # tells operators to install by hand (and packaging-design.md §4.3).
    # This used to chmod 0644, which silently loosened an operator's 0640
    # on every re-registration; nothing needs world access — systemd reads
    # EnvironmentFile= as root and the wrapper loads it before dropping
    # privileges. Group-read is kept for the gateway user's own tooling;
    # fall back to root-only when the gateway package (and thus the group)
    # is absent, since only root readers exist in that case.
    chmod 0640 "${env_target}"
    chgrp documentdb-gateway "${env_target}" 2>/dev/null || true

    local block_start="# >>> documentdb-register-gateway managed env >>>"
    local block_end="# <<< documentdb-register-gateway managed env <<<"
    # The per-major
    # documentdb-gateway-local@N.service only loads its EnvironmentFile
    # (the per-major gateway.env), NOT the shared SetupConfiguration.json.
    # Before this fix the env fragment only carried DOCUMENTDB_PG_URL_FILE,
    # so any --listen-port the operator set via documentdb-setup was
    # silently ignored when the gateway started. Emit the listen address
    # (and TLS auto-gen marker, if applicable) here too so the per-major
    # standalone gateway picks up the right runtime config.
    # Reject any value containing a newline/CR before writing it into the
    # systemd EnvironmentFile. Parsing is line-based (one KEY=VALUE per line),
    # so a newline embedded in an operator-supplied path (--tls-cert /
    # --tls-key / --listen-addr) or the generated secret path would inject
    # additional env lines. Spaces are safe (systemd takes the rest of the
    # line as the value); only newline/CR can break out of the value.
    local _ef_v
    for _ef_v in "${SECRET_FILE}" "${GATEWAY_LISTEN_ADDR:-}" \
            "${GATEWAY_TLS_AUTO_GENERATE:-}" "${GATEWAY_TLS_CERT_FILE:-}" \
            "${GATEWAY_TLS_KEY_FILE:-}"; do
        case "${_ef_v}" in
            *$'\n'*|*$'\r'*)
                die "Refusing to write a value containing a newline into ${env_target} (would corrupt the EnvironmentFile)." ;;
        esac
    done

    local content
    content="$(printf 'DOCUMENTDB_PG_URL_FILE=%s\n' "${SECRET_FILE}")"
    if [[ -n "${GATEWAY_LISTEN_ADDR:-}" ]]; then
        content+="$(printf '\nDOCUMENTDB_LISTEN_ADDR=%s' "${GATEWAY_LISTEN_ADDR}")"
    fi
    if [[ -n "${GATEWAY_TLS_AUTO_GENERATE:-}" ]]; then
        content+="$(printf '\nDOCUMENTDB_TLS_AUTO_GENERATE=%s' "${GATEWAY_TLS_AUTO_GENERATE}")"
    fi
    # Operator-supplied PEM cert/key — both come from the wizard's
    # --tls-cert/--tls-key pass-through. validate_tls_pair in main
    # ensures the two are set together before we reach this point;
    # nothing useful to write when only one of them slipped through.
    if [[ -n "${GATEWAY_TLS_CERT_FILE:-}" && -n "${GATEWAY_TLS_KEY_FILE:-}" ]]; then
        content+="$(printf '\nDOCUMENTDB_TLS_CERT_FILE=%s' "${GATEWAY_TLS_CERT_FILE}")"
        content+="$(printf '\nDOCUMENTDB_TLS_KEY_FILE=%s' "${GATEWAY_TLS_KEY_FILE}")"
    fi
    rewrite_with_managed_block "${env_target}" "${block_start}" "${block_end}" "${content}"
    log "Gateway env fragment written to ${env_target}"
}

# Tear down this script's half of the state file.
#
# Deleting the whole file (the previous behavior) is wrong whenever
# another writer shares the path. In greenfield the wizard
# (documentdb-setup) owns the SAME /etc/documentdb/local/N/setup.conf and
# stores GATEWAY_PORT/DATA_DIR/CONFIG_FILE there — and, critically,
# documentdb-postgresql@N.service gates on
# ConditionPathExists=/etc/documentdb/local/%i/setup.conf. So
# `documentdb-register-gateway --restore --pg-version N`, documented as
# removing "only the managed gateway registration wiring", silently
# stopped the private PostgreSQL from starting on the next boot and blanked
# `documentdb-setup --status`.
#
# Strip exactly the keys record_state writes and leave every foreign key
# in place — the mirror image of record_state's preserve step. The file is
# removed only when nothing but our own keys was in it (the direct
# Workflow B install, where register-gateway is the sole writer), which
# preserves the old behavior for the case it was actually correct for.
strip_managed_state_keys() {
    [[ -n "${STATE_FILE}" && -f "${STATE_FILE}" ]] || return 0

    # When the documentdb-setup wizard co-owns this file (its
    # DOCUMENTDB_MANAGED_POSTGRES marker is present — greenfield setup.conf
    # or brownfield brownfield.conf), strip only OUR exclusive keys.
    # Stripping the full managed set here used to delete PG_VERSION /
    # DOCUMENTDB_MODE / PG_PORT out from under the wizard's install: the
    # private documentdb-postgresql@N.service kept passing its
    # ConditionPathExists (the file survives, DATA_DIR intact) but its
    # ExecStartPre load_config died on the missing PG_VERSION, so the
    # wizard's PostgreSQL silently stopped starting on the next
    # restart/reboot — and a later brownfield adoption, seeing no
    # DOCUMENTDB_MODE=greenfield, deleted the whole file as "legacy".
    local strip_re="${STATE_MANAGED_KEYS_RE}"
    if grep -qE '^DOCUMENTDB_MANAGED_POSTGRES=' "${STATE_FILE}" 2>/dev/null; then
        strip_re="${STATE_EXCLUSIVE_KEYS_RE}"
    fi

    local remaining
    remaining="$(grep -Ev "${strip_re}" "${STATE_FILE}" 2>/dev/null \
        | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true)"

    if [[ -z "${remaining}" ]]; then
        rm -f "${STATE_FILE}"
        log "State file removed: ${STATE_FILE}"
        return 0
    fi

    # Rewrite atomically so an interrupted restore cannot truncate state
    # another tool is still reading (matches record_state's tempfile+rename).
    local tmp
    tmp="$(mktemp "${STATE_FILE}.XXXXXX")" \
        || die "Cannot create state tempfile in $(dirname "${STATE_FILE}"): refusing to leave inconsistent state."
    printf '%s\n' "${remaining}" > "${tmp}" \
        || die "Cannot write state contents to ${tmp}."
    # Preserve the existing mode rather than assuming 0644: setup.conf is
    # 0644 (read by documentdb-postgresql@N.service as User=documentdb-local)
    # but brownfield.conf is 0600, and mktemp creates 0600.
    chmod --reference="${STATE_FILE}" "${tmp}" 2>/dev/null || chmod 0644 "${tmp}"
    mv "${tmp}" "${STATE_FILE}" \
        || die "Cannot rename state file into place at ${STATE_FILE}."
    log "Gateway registration keys stripped from ${STATE_FILE} (other state preserved)."
}

do_restore() {
    if [[ "${DRY_RUN}" != "true" ]]; then
        log "Restoring: removing managed blocks."
    fi

    # Load every persisted path from the state file before doing any
    # stripping. The previous implementation only loaded GATEWAY_ENV_FILE
    # and trusted runtime path resolution for HBA_FILE / IDENT_FILE /
    # SECRET_FILE. That broke --restore for two real cases:
    #  1. Apply with --pgdata /custom/dir, --restore later with no flags
    #  → runtime autodetect resolves to the default cluster's paths,
    #  leaving the custom cluster's managed blocks behind
    #  2. Apply against /etc/pgsql/<custom>, --restore on a host where
    #  autodetect picks a different PG instance
    # The state file is the source of truth for what we actually wrote;
    # trust it. If any persisted path is missing or unreadable we fall
    # back to the currently-resolved value (set up by main before
    # do_restore is reached) — a no-op for the common case where the
    # paths still match what was written.
    local persisted_env_file=""
    local persisted_hba=""
    local persisted_ident=""
    local persisted_secret=""
    if [[ -n "${STATE_FILE}" && -r "${STATE_FILE}" ]]; then
        persisted_env_file="$(grep -E '^GATEWAY_ENV_FILE=' "${STATE_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        persisted_hba="$(grep -E '^HBA_FILE=' "${STATE_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        persisted_ident="$(grep -E '^IDENT_FILE=' "${STATE_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        persisted_secret="$(grep -E '^SECRET_FILE=' "${STATE_FILE}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        if [[ -n "${persisted_env_file}" ]]; then
            log_verbose "Using persisted GATEWAY_ENV_FILE=${persisted_env_file} from ${STATE_FILE}"
            GATEWAY_ENV_FILE="${persisted_env_file}"
        fi
        if [[ -n "${persisted_hba}" ]]; then
            log_verbose "Using persisted HBA_FILE=${persisted_hba} from ${STATE_FILE}"
            HBA_FILE="${persisted_hba}"
        fi
        if [[ -n "${persisted_ident}" ]]; then
            log_verbose "Using persisted IDENT_FILE=${persisted_ident} from ${STATE_FILE}"
            IDENT_FILE="${persisted_ident}"
        fi
        if [[ -n "${persisted_secret}" ]]; then
            log_verbose "Using persisted SECRET_FILE=${persisted_secret} from ${STATE_FILE}"
            SECRET_FILE="${persisted_secret}"
        fi
    fi

    # Compute the gateway env-file candidates up front so the dry-run preview
    # and the real removal agree on exactly which files are touched.
    # When the state file did not
    # Carry GATEWAY_ENV_FILE (legacy install), strip from BOTH known
    # candidate paths instead of just the runtime-detected one — runtime
    # detection is what was broken originally.
    local env_candidates=()
    if [[ -n "${persisted_env_file}" ]]; then
        env_candidates+=("${persisted_env_file}")
    elif [[ -n "${GATEWAY_ENV_FILE}" ]]; then
        env_candidates+=("${GATEWAY_ENV_FILE}")
        if [[ -n "${PG_VERSION}" ]]; then
            local per_major="/etc/documentdb/local/${PG_VERSION}/gateway.env"
            if [[ "${per_major}" != "${GATEWAY_ENV_FILE}" ]]; then
                env_candidates+=("${per_major}")
            fi
        fi
        if [[ "${GATEWAY_ENV_FILE}" != "/etc/documentdb/gateway/gateway.env" ]]; then
            env_candidates+=("/etc/documentdb/gateway/gateway.env")
        fi
    else
        env_candidates+=("/etc/documentdb/gateway/gateway.env")
        if [[ -n "${PG_VERSION}" ]]; then
            env_candidates+=("/etc/documentdb/local/${PG_VERSION}/gateway.env")
        fi
    fi

    # Legacy /run/ secret path, cleaned in case --restore runs on a host
    # With a legacy install.
    local legacy_secret=""
    if [[ -n "${PG_VERSION}" ]]; then
        legacy_secret="/run/documentdb-local/${PG_VERSION}/gateway/pg-url"
    fi

    # --dry-run must preview only: do_restore is destructive (it strips managed
    # blocks and deletes the secret/state files), so honor the documented
    # preview-only contract and make no changes here.
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[dry-run] would remove the following managed blocks / files:"
        [[ -f "${HBA_FILE}" ]] && log "  - managed HBA block from ${HBA_FILE}"
        [[ -f "${IDENT_FILE}" ]] && log "  - managed ident block from ${IDENT_FILE}"
        [[ -n "${SECRET_FILE}" && -f "${SECRET_FILE}" ]] && log "  - connection URL file ${SECRET_FILE}"
        [[ -n "${legacy_secret}" && -f "${legacy_secret}" ]] && log "  - legacy connection URL file ${legacy_secret}"
        [[ -n "${SECRET_DIR}" && -d "${SECRET_DIR}/tls" ]] && log "  - auto-generated TLS key material ${SECRET_DIR}/tls"
        local _env_preview
        for _env_preview in "${env_candidates[@]}"; do
            [[ -f "${_env_preview}" ]] && log "  - managed env fragment from ${_env_preview}"
        done
        if [[ -n "${STATE_FILE}" && -f "${STATE_FILE}" ]]; then
            # Mirror strip_managed_state_keys' remove-vs-strip decision so the
            # preview never promises a deletion that will not happen.
            local _state_remaining
            _state_remaining="$(grep -Ev "${STATE_MANAGED_KEYS_RE}" "${STATE_FILE}" 2>/dev/null \
                | grep -E '^[A-Za-z_][A-Za-z0-9_]*=' || true)"
            if [[ -z "${_state_remaining}" ]]; then
                log "  - state file ${STATE_FILE}"
            else
                log "  - gateway registration keys from ${STATE_FILE} (other state preserved)"
            fi
        fi
        log "[dry-run] no changes made."
        return 0
    fi

    if [[ -f "${HBA_FILE}" ]]; then
        rewrite_with_managed_block "${HBA_FILE}" \
            "${PG_HBA_BLOCK_START}" "${PG_HBA_BLOCK_END}" ""
        log "Managed HBA block removed from ${HBA_FILE}"
    fi

    if [[ -f "${IDENT_FILE}" ]]; then
        rewrite_with_managed_block "${IDENT_FILE}" \
            "${PG_IDENT_BLOCK_START}" "${PG_IDENT_BLOCK_END}" ""
        log "Managed ident block removed from ${IDENT_FILE}"
    fi

    if [[ -n "${SECRET_FILE}" && -f "${SECRET_FILE}" ]]; then
        rm -f "${SECRET_FILE}"
        log "Connection URL file removed: ${SECRET_FILE}"
    fi
    if [[ -n "${legacy_secret}" && -f "${legacy_secret}" ]]; then
        rm -f "${legacy_secret}"
        log "Legacy connection URL file removed: ${legacy_secret}"
    fi

    # When TLS auto-generation is enabled, the gateway daemon materializes its
    # self-signed serving certificate and private key under ${SECRET_DIR}/tls
    # (DOCUMENTDB_TLS_STATE_DIR; pre-created 0700 documentdb-gateway by
    # do_setup). A full teardown must delete that key material too: once the
    # gateway package (and its sysusers-created documentdb-gateway account) is
    # purged, the orphaned directory survives owned by a bare numeric UID, and
    # any future account that recycles that UID silently inherits read access
    # to pkey.pem. Remove exactly the package-created tls subdirectory, then
    # prune the secret dir only when nothing else (operator files) remains.
    if [[ -n "${SECRET_DIR}" && -d "${SECRET_DIR}/tls" ]]; then
        rm -rf "${SECRET_DIR}/tls"
        log "Auto-generated TLS key material removed: ${SECRET_DIR}/tls"
    fi
    if [[ -n "${SECRET_DIR}" && -d "${SECRET_DIR}" ]]; then
        rmdir --ignore-fail-on-non-empty "${SECRET_DIR}" 2>/dev/null || true
    fi

    # Remove the managed block from the gateway env file(s) (preserving any
    # administrator-authored lines outside the block).
    local env_target
    for env_target in "${env_candidates[@]}"; do
        if [[ -f "${env_target}" ]]; then
            rewrite_with_managed_block "${env_target}" \
                "# >>> documentdb-register-gateway managed env >>>" \
                "# <<< documentdb-register-gateway managed env <<<" ""
            log "Managed env fragment removed from ${env_target}"
        fi
    done

    strip_managed_state_keys

    log "Restore complete. Reload PostgreSQL to apply."
}

# ── Argument parsing ────────────────────────────────────────────────

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --target-postgres-instance|--target-cluster)
                [[ $# -ge 2 ]] || die "$1 requires a value."
                TARGET_CLUSTER="$2"; shift 2 ;;
            --pgdata)
                [[ $# -ge 2 ]] || die "--pgdata requires a value."
                PGDATA="$2"; shift 2 ;;
            --pg-version)
                # When called via
                # --pgdata (e.g. greenfield from the wizard), PG_VERSION
                # was unset and all per-major work — psql resolver,
                # SECRET_DIR, STATE_FILE, GATEWAY_ENV_FILE — was skipped.
                # Accept --pg-version explicitly; also auto-derive from
                # ${PGDATA}/PG_VERSION when only --pgdata is given.
                [[ $# -ge 2 ]] || die "--pg-version requires a value."
                [[ "$2" =~ ^[0-9]+$ ]] || die "--pg-version must be numeric (got '$2')."
                PG_VERSION="$2"; shift 2 ;;
            --socket-dir)
                [[ $# -ge 2 ]] || die "--socket-dir requires a value."
                SOCKET_DIR="$2"; shift 2 ;;
            --pg-port)
                [[ $# -ge 2 ]] || die "--pg-port requires a value."
                # Validate before the value is interpolated into the libpq
                # connection URL (?host=...&port=${PG_PORT}); an unchecked
                # value such as "5432&sslmode=disable" would inject an extra
                # query parameter into the connection-secret file. Bound to 1-5
                # digits (so a >64-bit value cannot overflow the arithmetic
                # range check) and force base-10 (10#) so a decimal port written
                # with a leading zero (e.g. 08) is not misread as octal.
                { [[ "$2" =~ ^[0-9]{1,5}$ ]] && (( 10#$2 >= 1 && 10#$2 <= 65535 )); } \
                    || die "--pg-port must be a port number 1-65535 (got '$2')."
                PG_PORT="$2"; shift 2 ;;
            --pg-owner)
                # OS user to invoke psql as. Defaults to "postgres" which
                # works for distro-managed PG. For the stand-alone
                # greenfield path the wizard passes "documentdb-local"
                # (the OS user that owns the private data dir and is the
                # PG superuser).
                [[ $# -ge 2 ]] || die "--pg-owner requires a value."
                PG_OWNER="$2"; shift 2 ;;
            --admin-user)
                [[ $# -ge 2 ]] || die "--admin-user requires a value."
                ADMIN_USER="$2"; shift 2 ;;
            --admin-password-file)
                [[ $# -ge 2 ]] || die "--admin-password-file requires a value."
                ADMIN_PASSWORD_FILE="$2"; shift 2 ;;
            --admin-password-stdin)
                # CLI-surface parity with documentdb-setup: read one line
                # of password from stdin into a 0600 tempfile and reuse
                # the existing --admin-password-file plumbing. Without
                # this, operators following the design-doc pattern
                # `printf '%s' "$PW" | sudo documentdb-register-gateway
                # ... --admin-password-stdin` hit "Unknown argument" and
                # have to materialize a file by hand.
                if [[ -n "${ADMIN_PASSWORD_FILE}" ]]; then
                    die "--admin-password-stdin is mutually exclusive with --admin-password-file."
                fi
                # Parity with documentdb-gateway-admin --password-stdin: refuse
                # a TTY so the secret is never read from (and echoed on) an
                # interactive terminal. The documented form pipes the password:
                #  printf '%s' "$PW" | sudo documentdb-register-gateway... --admin-password-stdin --yes
                if [[ -t 0 ]]; then
                    die "--admin-password-stdin requires the password on stdin (e.g. 'printf %s \"\$PW\" | documentdb-register-gateway ... --admin-password-stdin --yes'). Stdin is a TTY."
                fi
                local _stdin_pw_file
                _stdin_pw_file="$(mktemp /tmp/documentdb-register-gateway.pwd.XXXXXX)"
                chmod 600 "${_stdin_pw_file}"
                IFS= read -r _stdin_pw_line || true
                printf '%s' "${_stdin_pw_line}" > "${_stdin_pw_file}"
                unset _stdin_pw_line
                ADMIN_PASSWORD_FILE="${_stdin_pw_file}"
                # Track so cleanup_temp_files wipes after use.
                TEMP_FILES+=("${_stdin_pw_file}")
                shift ;;
            --target-db)
                # Which PostgreSQL database the documentdb extension was
                # created in. Default: postgres. Threaded into the gateway
                # connection-URL file and into create-admin-user's
                # delegation to documentdb-gateway-admin. Without this
                # flag the gateway would be silently locked to /postgres
                # regardless of where CREATE EXTENSION actually ran.
                [[ $# -ge 2 ]] || die "--target-db requires a value."
                # PostgreSQL identifier: letters / digits / underscores
                # only (reject anything that could escape into URL or
                # shell). Keep it conservative.
                if ! [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                    die "--target-db must be a PostgreSQL identifier (got '$2')."
                fi
                TARGET_DB="$2"; shift 2 ;;
            --listen-addr)
                # The per-major
                # gateway-local@N.service only loads the per-major env
                # fragment (it does NOT load SetupConfiguration.json),
                # so listen-port settings written there are ignored at
                # runtime. Accept --listen-addr so the wizard can thread
                # the operator's --listen-port through to the env file
                # the unit actually reads.
                [[ $# -ge 2 ]] || die "--listen-addr requires a value (e.g. :10260)."
                # Conservative validation: forms ":<port>" or "<addr>:<port>"
                # with port digits only, addr letters/digits/dots/colons.
                if ! [[ "$2" =~ ^([A-Za-z0-9._:-]*):[0-9]+$ ]]; then
                    die "--listen-addr must be HOST:PORT or :PORT (got '$2')."
                fi
                GATEWAY_LISTEN_ADDR="$2"; shift 2 ;;
            --tls-auto-generate)
                # Mirror of DOCUMENTDB_TLS_AUTO_GENERATE for the per-major
                # env file. Same rationale as --listen-addr.
                [[ $# -ge 2 ]] || die "--tls-auto-generate requires a value (true|false)."
                case "$2" in
                    true|false) GATEWAY_TLS_AUTO_GENERATE="$2"; shift 2 ;;
                    *) die "--tls-auto-generate must be true or false (got '$2')." ;;
                esac
                ;;
            --tls-cert)
                # Pass-through for DOCUMENTDB_TLS_CERT_FILE — see
                # GATEWAY_TLS_CERT_FILE comment above the defaults block.
                # Both --tls-cert and --tls-key must be supplied together;
                # validation is in main after parse_arguments finishes
                # so that --restore (which ignores TLS flags) does not
                # need to set them.
                [[ $# -ge 2 ]] || die "--tls-cert requires a path."
                [[ -r "$2"   ]] || die "--tls-cert path is not readable: $2"
                GATEWAY_TLS_CERT_FILE="$2"; shift 2 ;;
            --tls-key)
                [[ $# -ge 2 ]] || die "--tls-key requires a path."
                [[ -r "$2"   ]] || die "--tls-key path is not readable: $2"
                GATEWAY_TLS_KEY_FILE="$2"; shift 2 ;;
            --state-mode)
                # greenfield (default) → write /etc/documentdb/local/N/setup.conf
                # brownfield → write /etc/documentdb/local/N/brownfield.conf
                # The choice matters because documentdb-postgresql@.service
                # has ConditionPathExists=.../setup.conf — writing setup.conf
                # in brownfield mode would let the greenfield templated PG
                # service activate against the adopted PG, violating the
                # design's brownfield isolation. See packaging-design.md §4.4.
                [[ $# -ge 2 ]] || die "--state-mode requires a value (greenfield|brownfield)."
                case "$2" in
                    greenfield|brownfield)
                        STATE_MODE="$2"
                        STATE_MODE_EXPLICIT=true
                        shift 2
                        ;;
                    *) die "--state-mode must be one of: greenfield, brownfield. Got '$2'." ;;
                esac
                ;;
            --yes) YES=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --restore) RESTORE=true; shift ;;
            --verbose) VERBOSE=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    # Parse target spec "V/C" into PG_VERSION + CLUSTER_NAME.
    # The slash is mandatory, as in documentdb-setup: for a no-slash value
    # like "18", BOTH ${TARGET_CLUSTER%%/*} and ${TARGET_CLUSTER#*/} return
    # the whole string, so CLUSTER_NAME would silently become "18" (the
    # empty-after-slash "main" fallback never fires) and Debian paths would
    # resolve to the nonexistent /etc/postgresql/18/18/ — dying later with a
    # confusing "pg_hba.conf not found" instead of a usable message here.
    if [[ -n "${TARGET_CLUSTER}" ]]; then
        [[ "${TARGET_CLUSTER}" == */* ]] \
            || die "--target-postgres-instance must be VERSION/CLUSTER (e.g., 18/main); got '${TARGET_CLUSTER}'."
        PG_VERSION="${TARGET_CLUSTER%%/*}"
        CLUSTER_NAME="${TARGET_CLUSTER#*/}"
        [[ "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "Invalid --target-postgres-instance format. Use VERSION/CLUSTER (e.g., 18/main)."
        [[ -n "${CLUSTER_NAME}" ]] || CLUSTER_NAME="main"
        [[ "${CLUSTER_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "Invalid cluster name '${CLUSTER_NAME}'. Only alphanumerics, hyphens, and underscores are allowed, and the name must not start with a hyphen."
        # Warn on RHEL where cluster name is not used
        if [[ "${CLUSTER_NAME}" != "main" ]]; then
            detect_distro
            if [[ "${IS_DEBIAN}" != "true" ]]; then
                log "WARNING: Cluster name '${CLUSTER_NAME}' is ignored on RHEL/Fedora. Using default PGDATA path /var/lib/pgsql/${PG_VERSION}/data."
            fi
        fi
    fi

    # When called with --pgdata only
    # (typical greenfield-via-wizard path), PG_VERSION may still be empty
    # after target-cluster parsing. Auto-derive it from
    # ${PGDATA}/PG_VERSION (PostgreSQL's standard cluster-version marker
    # written by initdb) so register-gateway can resolve per-major paths.
    # Without this, the wizard's greenfield call silently skipped psql
    # role creation, the secret file, the env fragment, and state.
    if [[ -z "${PG_VERSION}" && -n "${PGDATA}" && -r "${PGDATA}/PG_VERSION" ]]; then
        local derived_pg_version
        derived_pg_version="$(head -n 1 "${PGDATA}/PG_VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "${derived_pg_version}" =~ ^[0-9]+$ ]]; then
            PG_VERSION="${derived_pg_version}"
            log_verbose "Auto-derived PG_VERSION=${PG_VERSION} from ${PGDATA}/PG_VERSION"
        fi
    fi

    if [[ -z "${PGDATA}" ]]; then
        if [[ -z "${PG_VERSION}" ]]; then
            # packaging-design.md §5 Workflow B step (3): "Auto-detects when
            # there is exactly one PostgreSQL instance on the host (typical
            # case)." If there's more than one, fail loudly so the operator
            # has to pick explicitly — silently choosing one would be a
            # surprising side effect against the wrong instance.
            autodetect_single_pg_instance \
                || die "--target-postgres-instance or --pgdata is required. Run 'documentdb-register-gateway --help' for usage."
        fi
    fi

    if [[ "${RESTORE}" != "true" ]]; then
        if [[ -n "${ADMIN_PASSWORD_FILE}" && -z "${ADMIN_USER}" ]]; then
            die "--admin-user is required when --admin-password-file is set."
        fi

        if [[ -n "${ADMIN_USER}" && -z "${ADMIN_PASSWORD_FILE}" ]]; then
            die "--admin-password-file is required when --admin-user is set."
        fi

        if [[ -z "${ADMIN_USER}" && "${DRY_RUN}" != "true" ]]; then
            log "No --admin-user specified; gateway registration will complete without bootstrapping a first admin user."
        fi
    fi

    # Auto-default --state-mode so an
    # operator who runs `documentdb-register-gateway --target-postgres-instance 18/main`
    # (named distro cluster, the brownfield case) does NOT silently get
    # setup.conf — which would trigger the greenfield PG service template.
    # Explicit --state-mode always wins; otherwise:
    #  - TARGET_CLUSTER set → brownfield. This covers BOTH the operator
    #    naming --target-postgres-instance AND the Workflow B single-instance
    #    auto-detect (autodetect_single_pg_instance fills TARGET_CLUSTER
    #    too). Brownfield is correct for both: the target is a distro-managed
    #    cluster either way, and writing setup.conf would wrongly make
    #    documentdb-postgresql@N.service activatable against it.
    #  - otherwise → greenfield (private PG via --pgdata, the wizard path)
    if [[ "${STATE_MODE_EXPLICIT}" != "true" ]]; then
        if [[ -n "${TARGET_CLUSTER}" ]]; then
            STATE_MODE="brownfield"
            log_verbose "Auto-selected --state-mode brownfield (target instance ${TARGET_CLUSTER} named via --target-postgres-instance or resolved by the single-instance auto-detect)."
        else
            STATE_MODE="greenfield"
            log_verbose "Auto-selected --state-mode greenfield (no target instance named or auto-detected; private cluster via --pgdata)."
        fi
    fi
}

# packaging-design.md §5 Workflow B step (3): when there is exactly one
# PostgreSQL instance on the host, auto-detect it and set PG_VERSION +
# CLUSTER_NAME + TARGET_CLUSTER. Returns 0 if a single instance was
# resolved, 1 otherwise (caller dies with the prereq error). We never pick
# one of several — that would silently mutate the wrong PG.
autodetect_single_pg_instance() {
    detect_distro

    local -a candidates=()

    if [[ "${IS_DEBIAN}" == "true" ]]; then
        # Prefer pg_lsclusters when postgresql-common is installed — it's the
        # canonical source for Debian/Ubuntu PG instance enumeration. Output
        # format: "Ver Cluster Port Status Owner...". We pull lines whose
        # version is purely numeric so the header / blank lines are ignored.
        if command -v pg_lsclusters >/dev/null 2>&1; then
            local line
            while IFS= read -r line; do
                local ver cluster
                ver="$(printf '%s' "${line}" | awk '{print $1}')"
                cluster="$(printf '%s' "${line}" | awk '{print $2}')"
                [[ "${ver}" =~ ^[0-9]+$ ]] || continue
                # Match pg_createcluster's own cluster-name shape (first
                # char may be alphanumeric, not letter-only). Stricter
                # filters would silently skip existing valid clusters
                # like "1replica" from the auto-detect list.
                [[ "${cluster}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || continue
                candidates+=("${ver}/${cluster}")
            done < <(pg_lsclusters --no-header 2>/dev/null || true)
        else
            # postgresql-common absent — enumerate /etc/postgresql/<V>/<C>/
            # directly. Same shape as pg_lsclusters output.
            local etc_dir cluster_dir ver cluster
            for etc_dir in /etc/postgresql/*/; do
                [[ -d "${etc_dir}" ]] || continue
                ver="$(basename "${etc_dir}")"
                [[ "${ver}" =~ ^[0-9]+$ ]] || continue
                for cluster_dir in "${etc_dir}"*/; do
                    [[ -d "${cluster_dir}" ]] || continue
                    cluster="$(basename "${cluster_dir}")"
                    [[ "${cluster}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || continue
                    candidates+=("${ver}/${cluster}")
                done
            done
        fi
    else
        # RHEL/Fedora PGDG layout: /var/lib/pgsql/<V>/data per major.
        local data_dir ver
        for data_dir in /var/lib/pgsql/*/data; do
            [[ -d "${data_dir}" ]] || continue
            ver="$(basename "$(dirname "${data_dir}")")"
            [[ "${ver}" =~ ^[0-9]+$ ]] || continue
            # RHEL has a single implicit cluster per major; convention name
            # is "main" so the downstream code path (which uses CLUSTER_NAME
            # only for messaging on RHEL) stays consistent.
            candidates+=("${ver}/main")
        done
    fi

    if (( ${#candidates[@]} == 0 )); then
        log "Auto-detect: no PostgreSQL instance found. Specify --target-postgres-instance or --pgdata explicitly."
        return 1
    fi

    if (( ${#candidates[@]} > 1 )); then
        log "Auto-detect: multiple PostgreSQL instances found:"
        local c
        for c in "${candidates[@]}"; do
            log "  - ${c}"
        done
        log "Specify --target-postgres-instance VERSION/CLUSTER explicitly."
        return 1
    fi

    TARGET_CLUSTER="${candidates[0]}"
    PG_VERSION="${TARGET_CLUSTER%%/*}"
    CLUSTER_NAME="${TARGET_CLUSTER#*/}"
    log "Auto-detected single PostgreSQL instance: ${TARGET_CLUSTER}"
    return 0
}

# Prerequisite check: the documentdb-gateway runtime package must be
# installed before we can register a PG-side ident map that points at its
# OS user. We detect the package by checking for the OS user (which the
# gateway package's sysusers.d entry creates on install). This makes the
# tools→gateway boundary explicit: this script edits PostgreSQL state on
# behalf of the gateway, but does not itself install the gateway.
check_gateway_prereq() {
    if ! getent passwd "${GW_OS_USER}" >/dev/null 2>&1; then
        die "OS user '${GW_OS_USER}' does not exist. Install the documentdb-gateway package first (e.g., 'sudo apt install documentdb-gateway' or 'sudo dnf install documentdb-gateway'), then re-run this command."
    fi
}

# ── Main ────────────────────────────────────────────────────────────

main() {
    parse_arguments "$@"
    detect_distro
    # --restore only strips managed files/blocks and never uses the gateway OS
    # account, so it must keep working after the gateway package (and its
    # sysusers-created user) has been removed. --dry-run previews changes
    # without writing anything (and must work before the gateway is installed,
    # per the preview-before-install contract), so it likewise must not require
    # the gateway OS user. Only enforce the prerequisite on the real setup path.
    [[ "${RESTORE}" == "true" || "${DRY_RUN}" == "true" ]] || check_gateway_prereq

    # --tls-cert and --tls-key are paired: one without the other is
    # always a wizard bug. Validate here so the failure surfaces before
    # we mutate any PG state. --restore ignores these flags so the
    # check is conditional on at least one being set.
    if [[ -n "${GATEWAY_TLS_CERT_FILE}" || -n "${GATEWAY_TLS_KEY_FILE}" ]]; then
        [[ -n "${GATEWAY_TLS_CERT_FILE}" ]] || die "--tls-key requires --tls-cert to also be set."
        [[ -n "${GATEWAY_TLS_KEY_FILE}"  ]] || die "--tls-cert requires --tls-key to also be set."
        if [[ "${GATEWAY_TLS_AUTO_GENERATE}" == "true" ]]; then
            die "--tls-auto-generate=true cannot be combined with --tls-cert / --tls-key; pick one TLS source."
        fi
    fi

    # --tls-auto-generate false with NO certificate pair leaves the gateway
    # without any TLS source. The daemon hard-rejects that combination only at
    # startup (EX_CONFIG, exit 78) and systemd restart-loops it — fail here at
    # the CLI instead, where the operator can actually see the message. The
    # pair check above already rejects a lone --tls-cert/--tls-key, and
    # --restore ignores TLS flags entirely.
    if [[ "${RESTORE}" != "true" && "${GATEWAY_TLS_AUTO_GENERATE}" == "false" \
          && ( -z "${GATEWAY_TLS_CERT_FILE}" || -z "${GATEWAY_TLS_KEY_FILE}" ) ]]; then
        die "--tls-auto-generate false requires both --tls-cert and --tls-key: with auto-generation disabled the gateway has no certificate source and refuses to start (exit 78, systemd restart loop). Provide the certificate pair, or drop --tls-auto-generate false."
    fi

    # --restore only strips managed blocks from on-disk files and never calls
    # psql, so it must not require the PostgreSQL client binaries. This lets an
    # operator clean up managed blocks after the PostgreSQL package has been
    # removed (but its /etc conffiles still carry our blocks).
    if [[ -n "${PG_VERSION}" && "${RESTORE}" != "true" ]]; then
        resolve_pg_bindir
    fi
    resolve_cluster_paths

    # When --target-postgres-instance
    # or auto-detect names a specific cluster, the script previously fell
    # back to PG_PORT=5432 unless the operator explicitly passed --pg-port.
    # That meant HBA/ident edits went to the named cluster's config files
    # while all subsequent psql ops (role creation, extension check, admin
    # bootstrap) hit whatever cluster was listening on 5432 — a different
    # PostgreSQL instance. Resolve the target's actual port from on-disk
    # config before defaulting, so the file edits and the psql ops target
    # the same cluster.
    if [[ -z "${PG_PORT}" && -n "${PG_VERSION}" ]]; then
        resolve_target_cluster_port
    fi

    # Default socket/port if not set
    [[ -z "${PG_PORT}" ]] && PG_PORT="5432"
    # PG_OWNER defaults to "postgres" (distro-managed PG instances). For
    # stand-alone greenfield, the wizard passes --pg-owner documentdb-local.
    [[ -z "${PG_OWNER}" ]] && PG_OWNER="postgres"

    # Determine secret/state file paths.
    # Track 1 paths (per packaging-design.md §4.4):
    #  /run/documentdb-local/N/gateway/pg-url — connection URL file
    #  /etc/documentdb/local/N/setup.conf — greenfield state
    #  /etc/documentdb/local/N/brownfield.conf — brownfield state (no
    #  ConditionPathExists trigger)
    #  /etc/documentdb/local/N/gateway.env — gateway EnvironmentFile
    #  (per-major, read by
    #  documentdb-gateway-local@N.service)
    #
    # The original design path of
    # /run/documentdb-local/N/gateway/pg-url is on tmpfs, so the file
    # disappears on reboot while /etc/.../gateway.env (which records the
    # path via DOCUMENTDB_PG_URL_FILE) survives. First boot after
    # reboot: gateway starts → reads env → DOCUMENTDB_PG_URL_FILE points
    # to a non-existent file → gateway fails. Move the secret file to
    # the persistent per-major working dir
    # /var/lib/documentdb-local/N/gateway/pg-url (already owned by the
    # standalone package per §4.4, mode 0750 documentdb-gateway). Same
    # access boundary (mode 0640 root:documentdb-gateway) as the
    # original /run/ path, but reboot-safe.
    #
    # The per-major gateway.env path
    # only works when documentdb-N is installed (i.e., Workflow C). For
    # Workflow B (just documentdb-gateway, no documentdb-N) the operator
    # starts the plain `documentdb-gateway.service` unit which reads
    # `/etc/documentdb/gateway/gateway.env`, not the per-major path —
    # so writes to the per-major path silently never reach the gateway.
    # Discriminate by checking whether the per-major systemd template
    # unit file is shipped on this host.
    if [[ -n "${PG_VERSION}" ]]; then
        SECRET_DIR="/var/lib/documentdb-local/${PG_VERSION}/gateway"
        SECRET_FILE="${SECRET_DIR}/pg-url"
        case "${STATE_MODE}" in
            brownfield)
                STATE_FILE="/etc/documentdb/local/${PG_VERSION}/brownfield.conf"
                ;;
            *)
                STATE_FILE="/etc/documentdb/local/${PG_VERSION}/setup.conf"
                ;;
        esac

        # For a teardown, discover which state file actually exists rather
        # than trusting the mode default.
        #
        # STATE_MODE only auto-defaults to brownfield when
        # --target-postgres-instance is given. The documented restore
        # invocation `documentdb-register-gateway --restore --pg-version N`
        # supplies neither that flag nor --pgdata, and because PG_VERSION is
        # already set it also skips autodetect_single_pg_instance -- so
        # TARGET_CLUSTER stayed empty, STATE_MODE fell through to greenfield,
        # and a brownfield install's --restore ran against a setup.conf that
        # does not exist. It then failed OPEN: no persisted paths were loaded,
        # so the HBA/ident rewrites were no-ops against a bogus
        # /etc/postgresql/N//pg_hba.conf (empty CLUSTER_NAME), while the
        # secret file and gateway env fragment -- derived from PG_VERSION
        # alone -- WERE deleted. Net effect: the gateway was broken, the
        # peer-auth ident-map grants for the documentdb-gateway OS user stayed
        # live in the adopted cluster, and the tool printed "Restore complete."
        #
        # Only when the operator did not pin the mode; an explicit
        # --state-mode still wins.
        if [[ "${RESTORE}" == "true" && "${STATE_MODE_EXPLICIT}" != "true" ]]; then
            local _bf_state="/etc/documentdb/local/${PG_VERSION}/brownfield.conf"
            local _gf_state="/etc/documentdb/local/${PG_VERSION}/setup.conf"
            if [[ -r "${_bf_state}" && ! -r "${_gf_state}" ]]; then
                STATE_MODE="brownfield"
                STATE_FILE="${_bf_state}"
                log_verbose "Restore: found brownfield state at ${STATE_FILE}; switching --state-mode to brownfield."
            elif [[ -r "${_gf_state}" && ! -r "${_bf_state}" ]]; then
                # Symmetric fail-open hazard in the other direction: with
                # `--restore --target-postgres-instance N/C` (or when the
                # single-instance auto-detect resolved a target), STATE_MODE
                # auto-defaulted to brownfield — but the install on disk may
                # be greenfield (only setup.conf exists). Without this switch
                # the restore would strip keys against a brownfield.conf that
                # does not exist while leaving setup.conf behind, so
                # ConditionPathExists stays satisfied and
                # documentdb-postgresql@N.service remains activatable after
                # the tool printed "Restore complete."
                STATE_MODE="greenfield"
                STATE_FILE="${_gf_state}"
                log_verbose "Restore: found greenfield state at ${STATE_FILE}; switching --state-mode to greenfield."
            elif [[ -r "${_gf_state}" && -r "${_bf_state}" ]]; then
                # Both present: ambiguous, and picking wrong strips the wrong
                # cluster's config. Make the operator disambiguate.
                die "Both ${_gf_state} and ${_bf_state} exist for PostgreSQL ${PG_VERSION}; cannot tell which install to restore. Re-run with an explicit --state-mode greenfield or --state-mode brownfield."
            fi
        fi
        # Workflow C path (documentdb-N installed) → per-major env file.
        # Workflow B path (just documentdb-gateway) → /etc/documentdb/gateway/gateway.env.
        if [[ -f "/lib/systemd/system/documentdb-gateway-local@.service" ]] \
                || [[ -f "/usr/lib/systemd/system/documentdb-gateway-local@.service" ]]; then
            GATEWAY_ENV_FILE="/etc/documentdb/local/${PG_VERSION}/gateway.env"
        else
            GATEWAY_ENV_FILE="/etc/documentdb/gateway/gateway.env"
            log_verbose "Workflow B detected (per-major gateway-local unit not installed); writing env to ${GATEWAY_ENV_FILE}."
        fi
    fi

    if [[ "${RESTORE}" == "true" ]]; then
        do_restore
    else
        do_setup
    fi
}

main "$@"
