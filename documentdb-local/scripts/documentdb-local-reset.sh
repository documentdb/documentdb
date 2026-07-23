#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-local-reset — destructive per-major cluster wipe.
#
# Scope: greenfield (stand-alone-package-owned) installs ONLY. In
# brownfield mode the adopted PostgreSQL instance is the operator's
# property and its managed-block mutations live in the system PG's
# pg_hba.conf / pg_ident.conf / postgresql.conf. This tool refuses to
# touch those — `documentdb-setup --restore` is the correct entry point
# for brownfield because it knows how to strip managed blocks safely.
#
# Usage:
#  documentdb-local-reset --pg-version N --confirm-destroy

set -euo pipefail

readonly PROG="documentdb-local-reset"

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }
# log_warn is part of the host contract for the shared gateway-record reader
# sourced below (nohup_gateway_pid_for_port calls it on a reject); without it
# the reader would abort reset under `set -e` at the moment it warns.
log_warn() { echo "[${PROG}] WARNING: $*" >&2; }

# Source the shared identity primitives (port_listen_inodes,
# pid_listens_on_port, gateway_exe_matches, nohup_gateway_pidfile,
# nohup_gateway_record_pid, nohup_gateway_pid_for_port, proc_starttime,
# current_boot_id, ...) so reset uses the SAME gateway-record reader as
# documentdb-setup — including its recycled-PID/stale-boot guards — instead of
# an inline copy that could drift. documentdb-common (which ships this script)
# hard-depends on documentdb-postgresql-tools (which ships the lib), so it is
# present on every supported install; fail loudly if a --nodeps mutant removed
# it.
_ddb_reset_script_dir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ddb_reset_lib_found=""
for _ddb_cand in "${_ddb_reset_script_dir}/documentdb-tools-lib.sh" \
                 "/usr/share/documentdb/scripts/documentdb-tools-lib.sh"; do
    if [[ -r "${_ddb_cand}" ]]; then
        # shellcheck source=documentdb-tools-lib.sh
        . "${_ddb_cand}"
        _ddb_reset_lib_found="${_ddb_cand}"
        break
    fi
done
[[ -n "${_ddb_reset_lib_found}" ]] \
    || die "cannot locate documentdb-tools-lib.sh (looked beside ${BASH_SOURCE[0]} and in /usr/share/documentdb/scripts). It ships in documentdb-postgresql-tools, a dependency of this package."

usage() {
    cat <<'EOF'
Usage: documentdb-local-reset --pg-version N --confirm-destroy

Destructive wipe of the GREENFIELD DocumentDB Local appliance for a specific
PostgreSQL major version. This stops services, removes the per-major data
directory, gateway state, backups, logs, config, and runtime dirs.
THE DATA IS PERMANENTLY LOST.

Brownfield (adopted PostgreSQL) installs are NOT supported by this tool —
they keep the operator's existing PG service and config files, which this
destructive path is not safe to touch. Use `documentdb-setup --restore`
for brownfield instead; it strips only the package-managed blocks and
leaves the adopted PostgreSQL data, roles, and contents intact.

Options:
  --pg-version N       PostgreSQL major version to reset (required)
  --confirm-destroy    Required safety flag (no default)
  -h, --help           Show this help message
EOF
}

PG_VERSION=""
CONFIRMED=false

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pg-version)
                [[ $# -ge 2 ]] || die "--pg-version requires a value."
                PG_VERSION="$2"; shift 2 ;;
            --confirm-destroy)
                CONFIRMED=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    [[ -n "${PG_VERSION}" ]] || die "--pg-version is required."
    [[ "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "--pg-version must be a positive integer."
    [[ "${CONFIRMED}" == "true" ]] || die "--confirm-destroy is required. This operation is destructive and irreversible."
}

main() {
    parse_arguments "$@"

    if [[ "$(id -u)" -ne 0 ]]; then
        die "Must be run as root."
    fi

    local data_dir="/var/lib/documentdb-local/${PG_VERSION}/data"
    local gw_dir="/var/lib/documentdb-local/${PG_VERSION}/gateway"
    local backup_dir="/var/lib/documentdb-local/${PG_VERSION}/backups"
    local log_dir="/var/log/documentdb-local/${PG_VERSION}"
    local config_dir="/etc/documentdb/local/${PG_VERSION}"
    local run_dir="/run/documentdb-local/${PG_VERSION}"
    local brownfield_marker="/etc/documentdb/local/${PG_VERSION}/brownfield.conf"

    # Refuse to proceed on a
    # brownfield install. The destructive cleanup below only knows about
    # the greenfield layout (per-major /var/lib/documentdb-local/N/...
    # and the package-owned systemd target). On brownfield the gateway
    # is layered on top of an operator-owned PostgreSQL service whose
    # data dir is at /var/lib/postgresql/N/main (Debian/Ubuntu) or
    # /var/lib/pgsql/N/data (RHEL) and whose pg_hba.conf / pg_ident.conf
    # carry the documentdb-setup managed blocks. This tool can neither
    # safely delete that operator-owned data nor strip those managed
    # blocks, so it must hand the operator to `documentdb-setup --restore`
    # which knows how to do the non-destructive restore correctly.
    if [[ -f "${brownfield_marker}" ]]; then
        die "Brownfield install detected at ${brownfield_marker}. This tool only handles greenfield (stand-alone-package-owned) installs. Run 'documentdb-setup --restore' to non-destructively detach the gateway from the adopted PostgreSQL instance, or remove the brownfield marker manually after handling its lifecycle if you truly want to wipe per-major state."
    fi

    # Honor a custom --data-dir recorded at setup time: the wizard writes the
    # resolved DATA_DIR to setup.conf, which may live outside the default
    # /var/lib/documentdb-local/N/data. Read it BEFORE deleting setup.conf (and
    # before the postmaster.pid safety checks / rm -rf below) so a custom data
    # directory is the one actually wiped and "completely reset" stays truthful.
    #
    # FAIL CLOSED on ambiguous state: hosts upgraded from legacy packages can
    # carry a setup.conf that an old brownfield run wrongly wrote — with
    # DATA_DIR pointing at the OPERATOR'S adopted system PostgreSQL data
    # directory and no brownfield.conf marker. Honoring that DATA_DIR blindly
    # would stop and rm -rf the operator's cluster. Every other consumer of
    # this file (read_persisted_managed_data_dir in documentdb-setup,
    # documentdb_postgresql_service.sh) requires DOCUMENTDB_MANAGED_POSTGRES=true
    # before trusting DATA_DIR; do the same here, and refuse outright when the
    # state file explicitly records a non-greenfield mode.
    local setup_conf="${config_dir}/setup.conf"
    # The nohup gateway's per-port record is keyed by GATEWAY_PORT, and the
    # only durable copy of that port lives in this state file — which the
    # cleanup below deletes. Read it FIRST, or the record (and the gateway it
    # names) becomes unfindable the moment config_dir is removed.
    local recorded_gw_port=""
    if [[ -r "${setup_conf}" ]]; then
        recorded_gw_port="$(grep -E '^GATEWAY_PORT=' "${setup_conf}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        [[ "${recorded_gw_port}" =~ ^[0-9]+$ ]] || recorded_gw_port=""
    fi
    if [[ -r "${setup_conf}" ]]; then
        local _recorded_data_dir _recorded_mode _recorded_managed
        _recorded_data_dir="$(grep -E '^DATA_DIR=' "${setup_conf}" | head -1 | cut -d= -f2- || true)"
        _recorded_mode="$(grep -E '^DOCUMENTDB_MODE=' "${setup_conf}" | head -1 | cut -d= -f2- || true)"
        _recorded_managed="$(grep -E '^DOCUMENTDB_MANAGED_POSTGRES=' "${setup_conf}" | head -1 | cut -d= -f2- || true)"
        if [[ -n "${_recorded_mode}" && "${_recorded_mode}" != "greenfield" ]]; then
            die "${setup_conf} records DOCUMENTDB_MODE=${_recorded_mode}, not a greenfield install. Its DATA_DIR may point at an operator-owned PostgreSQL data directory that this tool must not delete. Run 'documentdb-setup --restore' to detach non-destructively instead."
        fi
        if [[ -n "${_recorded_data_dir}" && "${_recorded_data_dir}" != "${data_dir}" ]]; then
            if [[ "${_recorded_managed}" == "true" && "${_recorded_mode}" == "greenfield" ]]; then
                log "Using data directory recorded in ${setup_conf}: ${_recorded_data_dir} (custom --data-dir)."
                data_dir="${_recorded_data_dir}"
            else
                die "${setup_conf} records DATA_DIR=${_recorded_data_dir} but does not mark it as a package-managed greenfield cluster (DOCUMENTDB_MANAGED_POSTGRES=true + DOCUMENTDB_MODE=greenfield). Refusing to delete a data directory this package cannot prove it owns — it may belong to an adopted (operator-owned) PostgreSQL instance from an earlier install. Run 'documentdb-setup --restore' to detach non-destructively, or remove the stale state file manually if you are certain."
            fi
        fi
    fi

    # Stop services
    if command -v systemctl >/dev/null 2>&1; then
        log "Stopping documentdb-local@${PG_VERSION}.target..."
        systemctl stop "documentdb-local@${PG_VERSION}.target" 2>/dev/null || true
        systemctl disable "documentdb-local@${PG_VERSION}.target" 2>/dev/null || true
    fi

    # On a no-systemd host this major's gateway runs under nohup, recorded in
    # /run/documentdb-gateway/gateway-<port>.pid. Reset previously never
    # stopped it — it wiped the gateway's state out from under a running
    # process and left a stale record for a pid the kernel could recycle.
    # Stop it FAIL-SOFT (mirroring documentdb-setup's reader: numeric, >1,
    # alive, and a gateway binary — never signal a pid that fails any check),
    # then remove exactly THIS major's record. Other majors' records are
    # never touched: reset is per-major by contract.
    if [[ -n "${recorded_gw_port}" ]]; then
        local gw_record gw_pid
        gw_record="$(nohup_gateway_pidfile "${recorded_gw_port}")"
        if [[ -r "${gw_record}" ]]; then
            # Identify with the SHARED reader: it validates numeric/alive/
            # gateway-binary AND the recycled-PID / stale-boot guards, so reset
            # can never signal a PID the record no longer legitimately names.
            # "Skip" means skip SIGNALLING, never skip removing THIS major's
            # record. gw_pid is "" on any reject.
            gw_pid="$(nohup_gateway_pid_for_port "${recorded_gw_port}" || true)"
            if [[ -n "${gw_pid}" ]]; then
                log "Stopping nohup gateway for port ${recorded_gw_port} (pid ${gw_pid})..."
                kill "${gw_pid}" 2>/dev/null || true
                sleep 1
                kill -0 "${gw_pid}" 2>/dev/null && { kill -KILL "${gw_pid}" 2>/dev/null || true; }
            else
                log "Not signalling any process for port ${recorded_gw_port}: the recorded PID did not pass identity checks (missing/recycled/foreign). Removing the stale record only."
            fi
            rm -f "${gw_record}" 2>/dev/null || true
        fi
    fi

    # On non-systemd hosts the stop above is a no-op, and even with systemd the
    # stop is best-effort. Try a direct pg_ctl stop as the data-dir owner, then
    # FAIL CLOSED: never rm -rf a data directory whose postmaster is still
    # alive (that would corrupt a live cluster / lose data).
    # Resolve pg_ctl by versioned bindir rather than by PATH. Neither
    # supported distro puts pg_ctl on PATH — Debian/Ubuntu keep it in
    # /usr/lib/postgresql/N/bin and RHEL/PGDG in /usr/pgsql-N/bin — so the
    # previous `command -v pg_ctl` guard never matched and this entire
    # fallback was unreachable: on a non-systemd host the documented
    # automatic stop never ran and reset always died at the postmaster
    # check below telling the operator to stop PostgreSQL by hand. Same
    # candidate list as resolve_pg_ctl in documentdb_postgresql_service.sh;
    # PG_VERSION is already validated as numeric by parse_arguments.
    local _pg_ctl=""
    local _pg_ctl_candidate
    for _pg_ctl_candidate in "/usr/lib/postgresql/${PG_VERSION}/bin/pg_ctl" \
                             "/usr/pgsql-${PG_VERSION}/bin/pg_ctl"; do
        if [[ -x "${_pg_ctl_candidate}" ]]; then
            _pg_ctl="${_pg_ctl_candidate}"
            break
        fi
    done
    # Last resort: honor a PATH-resolvable pg_ctl if one does exist (source
    # builds, unusual layouts).
    if [[ -z "${_pg_ctl}" ]] && command -v pg_ctl >/dev/null 2>&1; then
        _pg_ctl="$(command -v pg_ctl)"
    fi

    if [[ -f "${data_dir}/postmaster.pid" ]] && [[ -n "${_pg_ctl}" ]]; then
        local _dd_owner
        _dd_owner="$(stat -c '%U' "${data_dir}" 2>/dev/null || echo postgres)"
        log "Attempting pg_ctl fast stop for ${data_dir} (as ${_dd_owner}, via ${_pg_ctl})..."
        if command -v runuser >/dev/null 2>&1; then
            runuser -u "${_dd_owner}" -- "${_pg_ctl}" -D "${data_dir}" -m fast stop 2>/dev/null || true
        else
            su -s /bin/sh "${_dd_owner}" -c "'${_pg_ctl}' -D '${data_dir}' -m fast stop" 2>/dev/null || true
        fi
        sleep 1
    elif [[ -f "${data_dir}/postmaster.pid" ]]; then
        log "No pg_ctl found for PostgreSQL ${PG_VERSION}; skipping the direct stop attempt."
    fi
    if [[ -f "${data_dir}/postmaster.pid" ]]; then
        _pm_pid="$(head -n 1 "${data_dir}/postmaster.pid" 2>/dev/null || true)"
        if [[ -n "${_pm_pid}" ]] && kill -0 "${_pm_pid}" 2>/dev/null; then
            die "PostgreSQL still appears to be running for ${data_dir} (pid ${_pm_pid}). Refusing to delete a live data directory. Stop it first (e.g. 'sudo systemctl stop documentdb-local@${PG_VERSION}.target' or 'sudo -u ${_dd_owner:-postgres} pg_ctl -D ${data_dir} stop'), then re-run."
        fi
    fi

    # Remove data
    if [[ -d "${data_dir}" ]]; then
        log "Removing data directory: ${data_dir}"
        rm -rf "${data_dir}"
    fi

    # Remove gateway state
    if [[ -d "${gw_dir}" ]]; then
        log "Removing gateway directory: ${gw_dir}"
        rm -rf "${gw_dir}"
    fi

    # Remove backups
    if [[ -d "${backup_dir}" ]]; then
        log "Removing backups: ${backup_dir}"
        rm -rf "${backup_dir}"
    fi

    # Remove logs
    if [[ -d "${log_dir}" ]]; then
        log "Removing logs: ${log_dir}"
        rm -rf "${log_dir}"
    fi

    # Remove config
    if [[ -d "${config_dir}" ]]; then
        log "Removing config: ${config_dir}"
        rm -rf "${config_dir}"
    fi

    # Remove runtime dir
    if [[ -d "${run_dir}" ]]; then
        rm -rf "${run_dir}"
    fi

    # Clean up empty parent dirs
    rmdir --ignore-fail-on-non-empty /var/lib/documentdb-local/"${PG_VERSION}" 2>/dev/null || true

    if command -v systemctl >/dev/null 2>&1; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    log "Greenfield DocumentDB Local for PostgreSQL ${PG_VERSION} has been completely reset."
}

main "$@"
