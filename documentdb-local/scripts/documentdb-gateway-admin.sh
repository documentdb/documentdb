#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-gateway-admin — user/role management subcommands for the
# DocumentDB gateway. Also used by the dev wrapper as
# "documentdb-gateway admin <cmd>".
#
# Subcommands:
#  create-user Create a DocumentDB user
#  drop-user Drop a DocumentDB user
#  list-users List DocumentDB users
#  reset-password Reset a user's password
#  check Verify the gateway can connect and extension is loaded

set -euo pipefail
umask 077

readonly PROG="documentdb-gateway-admin"

# Temp file tracking for cleanup on exit
_TEMP_FILES=()
_cleanup_temp_files() { rm -f "${_TEMP_FILES[@]}" 2>/dev/null || true; }
trap _cleanup_temp_files EXIT

# ── Defaults ────────────────────────────────────────────────────────
USERNAME=""
PASSWORD_FILE=""
PASSWORD_FROM_STDIN=false
RESOLVED_PASSWORD_FILE=""
SOCKET_DIR=""
PG_PORT=""
# Empty until parse/auto-detect resolve it; the "postgres" fallback is
# applied LAST (end of auto_detect_connection), not here. Seeding
# "postgres" up front made the default indistinguishable from an
# explicit --pg-owner, which killed the legacy-host fallback below
# ([[ -n $PG_OWNER ]] could never be false) and let state files clobber
# an operator-supplied value.
PG_OWNER=""
PG_OWNER_EXPLICIT=false
# The admin tool previously hardcoded
# `-d postgres` everywhere, so even when CREATE EXTENSION documentdb ran
# in a different database (perfectly valid setup), create-user /
# drop-user / list-users / reset-password silently targeted the wrong DB.
# --target-db lets the operator point at the actual DocumentDB database.
# Default stays "postgres" (matches the typical Workflow B / Workflow C
# install path and the design's §5 examples).
TARGET_DB="postgres"
TARGET_DB_EXPLICIT=false
VERBOSE=false
YES=false
DRY_RUN=false

# ── Helpers ─────────────────────────────────────────────────────────

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }
log_verbose() { if [[ "${VERBOSE}" == "true" ]]; then echo "[${PROG}] $*" >&2; fi; }

# Source the shared tools library for the PostgreSQL bin-directory candidate
# helper (documentdb_pg_bindir_candidates), so find_psql shares one Debian/RHEL
# layout list with documentdb-tune / documentdb-register-gateway / documentdb-
# setup instead of hardcoding it. The library ships beside this script in a dev
# checkout and at /usr/share/documentdb/scripts/ from the documentdb-postgresql-
# tools package (both files ship together). Sourced after die is defined so a
# missing library fails with a clear message; the only helper used here
# (documentdb_pg_bindir_candidates) is a pure printf that needs no host hooks.
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

# Try to auto-detect socket dir and port from appliance state files.
# Falls back to system PG defaults if no appliance state found.
auto_detect_connection() {
    # When the operator already
    # supplied explicit --pg-port AND --socket-dir, they have
    # disambiguated the target themselves. Skip the ambiguity check
    # entirely — otherwise admin commands on multi-instance hosts fail
    # with a confusing "Re-run with --pg-port and --socket-dir" message
    # even though the operator already passed those flags.
    #
    # Do NOT skip state recovery entirely, though: the multi-instance
    # ambiguity error below prescribes exactly this re-run, and a bare
    # early return dropped PG_OWNER/TARGET_DB on the floor — PG_OWNER
    # then defaulted to "postgres" in main(), which cannot even traverse
    # a greenfield socket dir (0750 documentdb-local:documentdb-gateway),
    # and a persisted non-default TARGET_DB silently fell back to
    # "postgres". Recover both from the unique state file whose PG_PORT
    # matches the explicit --pg-port; if none or several match, keep the
    # operator's explicit flags and the existing defaults.
    if [[ -n "${PG_PORT}" && -n "${SOCKET_DIR}" ]]; then
        local _match_file="" _match_count=0 _cand _cand_port
        for _cand in /etc/documentdb/local/*/setup.conf \
                     /etc/documentdb/local/*/brownfield.conf; do
            [[ -r "${_cand}" ]] || continue
            _cand_port="$(grep -E '^PG_PORT=' "${_cand}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            if [[ -n "${_cand_port}" && "${_cand_port}" == "${PG_PORT}" ]]; then
                _match_file="${_cand}"
                _match_count=$((_match_count + 1))
            fi
        done
        if [[ "${_match_count}" -eq 1 ]]; then
            if [[ "${PG_OWNER_EXPLICIT}" != "true" ]]; then
                local _match_owner
                _match_owner="$(grep -E '^PG_OWNER=' "${_match_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
                [[ -n "${_match_owner}" ]] && PG_OWNER="${_match_owner}"
            fi
            if [[ "${TARGET_DB_EXPLICIT}" != "true" ]]; then
                local _match_db
                _match_db="$(grep -E '^TARGET_DB=' "${_match_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
                [[ -n "${_match_db}" ]] && TARGET_DB="${_match_db}"
            fi
            log_verbose "Recovered PG_OWNER/TARGET_DB from ${_match_file} (matched explicit --pg-port ${PG_PORT})."
        fi
        return 0
    fi

    # Per-major state files. Brownfield
    # state is in brownfield.conf, not setup.conf — iterate both so day-2
    # admin ops work after a brownfield documentdb-setup. The legacy
    # /etc/documentdb/documentdb-postgresql.env is also consulted for
    # back-compat with pre-Phase-10 installs.
    #
    # Collect ALL viable state files
    # first; on a multi-major host (supported per packaging-design.md
    # §4.4 "Co-installable across majors") the previous "return on first
    # match" silently picked whichever sorted first in the glob. Now we
    # refuse with a clear "specify --pg-version" error so the operator
    # is forced to disambiguate.
    local -a state_files=()
    local state_file
    for state_file in /etc/documentdb/local/*/setup.conf \
                      /etc/documentdb/local/*/brownfield.conf \
                      /etc/documentdb/documentdb-postgresql.env; do
        if [[ -r "${state_file}" ]]; then
            # Only consider files that actually carry the detection signal.
            # The per-major files record PG_PORT directly. The legacy file
            # never does — persist_self_managed_postgres_state writes only
            # DOCUMENTDB_MANAGED_POSTGRES/PG_VERSION/DATA_DIR/CONFIG_FILE/
            # HBA_FILE/IDENT_FILE there — so requiring PG_PORT excluded it
            # unconditionally and the advertised back-compat was dead code:
            # on a genuine pre-per-major host (which by construction has no
            # setup.conf) state_files came back empty and we silently fell
            # through to PG_PORT=5432 / /var/run/postgresql, i.e. some
            # unrelated system PostgreSQL rather than the appliance cluster.
            # Accept it on PG_VERSION instead and recover the port from the
            # postgresql.conf it points at (documentdb-setup pins
            # "port = <PG_PORT>" inside its managed block there).
            if [[ "${state_file}" == "/etc/documentdb/documentdb-postgresql.env" ]]; then
                if grep -qE '^PG_VERSION=' "${state_file}" 2>/dev/null; then
                    state_files+=("${state_file}")
                fi
            elif grep -qE '^PG_PORT=' "${state_file}" 2>/dev/null; then
                state_files+=("${state_file}")
            fi
        fi
    done

    # Distinct registered instances: dedup by (PG_VERSION, CLUSTER_NAME)
    # so two clusters on the same major (e.g., 18/main and 18/analytics)
    # are NOT collapsed into one. Collapsing by PG_VERSION only let the
    # script silently pick state_files[0] when two clusters shared a major.
    #
    # The legacy
    # /etc/documentdb/documentdb-postgresql.env has no CLUSTER_NAME (pre-
    # Phase-10 format), so naively it would form its own instance_key
    # and trigger false ambiguity. But it describes the SAME instance as
    # the matching per-major setup.conf. Resolve this by ignoring the
    # legacy file in the dedup count whenever a setup.conf or
    # brownfield.conf for the same major already exists.
    local -a per_major_keys=()
    local sf maj cluster instance_key
    # First pass: collect per-major (non-legacy) instance keys.
    for sf in "${state_files[@]}"; do
        [[ "${sf}" == "/etc/documentdb/documentdb-postgresql.env" ]] && continue
        maj="$(grep -E '^PG_VERSION=' "${sf}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        [[ -z "${maj}" ]] && continue
        cluster="$(grep -E '^CLUSTER_NAME=' "${sf}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        [[ -z "${cluster}" ]] && cluster="<unset>"
        per_major_keys+=("${maj}/${cluster}")
    done
    # Second pass: collapse the legacy file with same-major per-major
    # state, otherwise count it as its own instance.
    local -a distinct_instances=()
    local -a distinct_details=()
    for sf in "${state_files[@]}"; do
        maj="$(grep -E '^PG_VERSION=' "${sf}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        [[ -z "${maj}" ]] && continue
        if [[ "${sf}" == "/etc/documentdb/documentdb-postgresql.env" ]]; then
            # Skip if any per-major state for this major already covers it.
            local k covered=false
            for k in "${per_major_keys[@]}"; do
                [[ "${k}" == "${maj}/"* ]] && { covered=true; break; }
            done
            [[ "${covered}" == "true" ]] && continue
            cluster="<legacy>"
        else
            cluster="$(grep -E '^CLUSTER_NAME=' "${sf}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            [[ -z "${cluster}" ]] && cluster="<unset>"
        fi
        instance_key="${maj}/${cluster}"
        local seen=false
        local m
        for m in "${distinct_instances[@]}"; do
            [[ "${m}" == "${instance_key}" ]] && { seen=true; break; }
        done
        if [[ "${seen}" != "true" ]]; then
            distinct_instances+=("${instance_key}")
            # Record actionable per-instance detail for the ambiguity
            # message: the port and socket dir the operator would need to
            # pass. Socket derivation mirrors the single-instance path
            # below (greenfield per-major runtime dir vs. distro dir).
            local _d_port _d_mode _d_socket
            _d_port="$(grep -E '^PG_PORT=' "${sf}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            _d_mode="$(grep -E '^DOCUMENTDB_MODE=' "${sf}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
            if [[ "${_d_mode}" == "brownfield" ]]; then
                _d_socket="/var/run/postgresql"
                [[ -d /var/run/postgresql ]] || { [[ -d /run/postgresql ]] && _d_socket="/run/postgresql"; }
            elif [[ "${sf}" == "/etc/documentdb/documentdb-postgresql.env" ]]; then
                # The legacy env file records neither PG_PORT nor PG_OWNER;
                # port/socket live in the managed block of the CONFIG_FILE it
                # points at, and legacy appliance clusters run as OS user
                # "documentdb". The explicit-flags recovery scan below cannot
                # match this instance (no PG_PORT key), so spell out
                # --pg-owner here instead of promising auto-recovery.
                distinct_details+=("${instance_key}: derive --pg-port/--socket-dir from the managed block of the CONFIG_FILE in ${sf}, and pass --pg-owner documentdb")
                continue
            else
                _d_socket="/run/documentdb-local/${maj}/postgresql"
            fi
            distinct_details+=("${instance_key}: --pg-port ${_d_port:-<unknown>} --socket-dir ${_d_socket}")
        fi
    done

    if (( ${#distinct_instances[@]} > 1 )); then
        echo "${PROG}: multiple PostgreSQL instances are registered on this host:" >&2
        for m in "${distinct_details[@]}"; do
            echo "  - ${m}" >&2
        done
        die "Auto-detect cannot pick one safely. Re-run with the listed --pg-port and --socket-dir values (plus --target-db if needed) to target a specific instance explicitly; for per-major instances, PG_OWNER and TARGET_DB are then recovered from that instance's state automatically (a <legacy> instance also needs --pg-owner as listed above)."
    fi

    if (( ${#state_files[@]} == 0 )); then
        # No appliance state found — use system PG defaults
        [[ -z "${PG_PORT}" ]] && PG_PORT="5432"
        [[ -z "${SOCKET_DIR}" ]] && SOCKET_DIR="/var/run/postgresql"
        return 0
    fi

    # Exactly one distinct major. Use the first state file with PG_PORT.
    state_file="${state_files[0]}"
    # Initialize both: detected_socket is only conditionally assigned below
    # (no PG_VERSION in the state file, or brownfield with neither
    # /var/run/postgresql nor /run/postgresql present), and this script runs
    # under `set -u` — a bare `local detected_socket` leaves it unset, so the
    # unguarded expansion further down aborted every subcommand with a raw
    # "detected_socket: unbound variable" instead of connecting or failing
    # with a usable message.
    local detected_port="" detected_socket=""
    local is_legacy_state=false
    [[ "${state_file}" == "/etc/documentdb/documentdb-postgresql.env" ]] && is_legacy_state=true

    detected_port="$(grep -E '^PG_PORT=' "${state_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"

    local detected_ver
    detected_ver="$(grep -E '^PG_VERSION=' "${state_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
    local mode_marker
    mode_marker="$(grep -E '^DOCUMENTDB_MODE=' "${state_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"

    if [[ "${is_legacy_state}" == "true" ]]; then
        # Legacy /etc/documentdb/documentdb-postgresql.env records neither
        # PG_PORT nor the socket directory nor PG_OWNER. It does record
        # CONFIG_FILE, and documentdb-setup pins BOTH "port = <PG_PORT>" and
        # "unix_socket_directories = '<dir>'" inside that file's managed
        # block, so recover both from there. Deriving only the port is not
        # enough: a pre-per-major host's socket lives at /run/documentdb/
        # postgresql (documentdb_postgresql_service.sh's LEGACY_RUN_DIR), not
        # under the per-major /run/documentdb-local/ tree, so guessing the
        # appliance path just moves the failure from "wrong server" to
        # "no such file or directory".
        local detected_config
        detected_config="$(grep -E '^CONFIG_FILE=' "${state_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        if [[ -n "${detected_config}" && -r "${detected_config}" ]]; then
            detected_port="$(grep -E "^[[:space:]]*port[[:space:]]*=" "${detected_config}" 2>/dev/null \
                | tail -1 | sed -E "s/^[[:space:]]*port[[:space:]]*=[[:space:]]*'?([0-9]+)'?.*/\1/" || true)"
            # sed leaves the line untouched when it does not match; keep
            # only a clean integer so a malformed value cannot reach libpq.
            [[ "${detected_port}" =~ ^[0-9]+$ ]] || detected_port=""
            detected_socket="$(grep -E "^[[:space:]]*unix_socket_directories[[:space:]]*=" "${detected_config}" 2>/dev/null \
                | tail -1 | sed -E "s/^[[:space:]]*unix_socket_directories[[:space:]]*=[[:space:]]*'?([^',[:space:]]+)'?.*/\1/" || true)"
            [[ "${detected_socket}" == /* ]] || detected_socket=""
        fi
        # Legacy appliance clusters run as the "documentdb" OS user (the
        # legacy env file records no PG_OWNER key to detect it from).
        [[ "${PG_OWNER_EXPLICIT}" == "true" ]] || PG_OWNER="documentdb"
    elif [[ -n "${detected_ver}" ]]; then
        if [[ "${mode_marker}" == "brownfield" ]]; then
            # Brownfield: adopted system PG, use the distro socket dir.
            if [[ -d /var/run/postgresql ]]; then
                detected_socket="/var/run/postgresql"
            elif [[ -d /run/postgresql ]]; then
                detected_socket="/run/postgresql"
            fi
        else
            detected_socket="/run/documentdb-local/${detected_ver}/postgresql"
            [[ -d "${detected_socket}" ]] || detected_socket="/run/documentdb-local/postgresql"
        fi
    fi

    # Apply everything we resolved. This used to sit inside an
    # `if [[ -n "${detected_port}" ]]` block, so whenever the port could not
    # be determined the socket dir, owner and target DB were silently dropped
    # too -- and the fallback below then pointed the whole command at the
    # distro's own PostgreSQL on 5432.
    [[ -z "${SOCKET_DIR}" && -n "${detected_socket}" ]] && SOCKET_DIR="${detected_socket}"
    # An explicit --pg-owner wins over the state file, same contract as
    # --target-db below; without the guard the detected value silently
    # clobbered the operator's flag.
    if [[ "${PG_OWNER_EXPLICIT}" != "true" ]]; then
        local detected_owner
        detected_owner="$(grep -E '^PG_OWNER=' "${state_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        [[ -n "${detected_owner}" ]] && PG_OWNER="${detected_owner}"
    fi
    # If the operator installed the extension into a non-default database via
    # `documentdb-register-gateway --target-db <NAME>`, that value is
    # persisted in the state file. Pick it up so day-2 create-user /
    # drop-user / list-users target the right DB automatically. An explicit
    # --target-db on the gateway-admin command line still wins.
    if [[ "${TARGET_DB_EXPLICIT}" != "true" ]]; then
        local detected_db
        detected_db="$(grep -E '^TARGET_DB=' "${state_file}" 2>/dev/null | head -1 | cut -d= -f2- || true)"
        if [[ -n "${detected_db}" ]]; then
            TARGET_DB="${detected_db}"
        fi
    fi

    if [[ -n "${detected_port}" ]]; then
        [[ -z "${PG_PORT}" ]] && PG_PORT="${detected_port}"
        return 0
    fi

    # Fail closed. We found appliance state
    # for this host but could not work out which port its PostgreSQL is on --
    # typically a stale legacy env file left behind by
    # `documentdb-local-reset` whose CONFIG_FILE now points into a deleted
    # data directory. Defaulting to 5432 / /var/run/postgresql here silently
    # retargeted every subcommand at the distro's own PostgreSQL, so a
    # `drop-user --yes` ran against a completely different server. Refuse and
    # make the operator name the target.
    local missing_flags="--pg-port and --socket-dir"
    if [[ -n "${PG_PORT}" ]]; then
        # The operator already named the port; only the socket dir is
        # unresolved. Telling them to re-pass a flag they already passed
        # reads as a broken tool.
        missing_flags="--socket-dir (your explicit --pg-port ${PG_PORT} is fine, but the socket directory cannot be guessed safely)"
    fi
    die "Found DocumentDB state in ${state_file} but could not determine the PostgreSQL instance it points at (no PG_PORT key, and its CONFIG_FILE is missing or unreadable). This usually means the state file is stale — e.g. left over after 'documentdb-local-reset'. Re-run with explicit ${missing_flags} to target a specific instance, or remove the stale state file."
}

usage() {
    cat <<'EOF'
Usage: documentdb-gateway-admin <command> [OPTIONS]

User and role management for DocumentDB.

Commands:
  create-user       Create a DocumentDB user
  drop-user         Drop a DocumentDB user
  list-users        List DocumentDB users
  reset-password    Reset a user's password
  check             Verify connectivity and extension status

Common options:
  --username NAME         User name (required for create/drop/reset)
  --password-file FILE    Password file (one of: --password-file, --password-stdin;
                          required for create-user and reset-password)
  --password-stdin        Read the password from stdin (single line). Best
                          practice for piping a secret without touching disk:
                            printf '%s' "$PW" | sudo documentdb-gateway-admin \
                              reset-password --username admin --password-stdin
                          Refuses on a TTY; mutually exclusive with --password-file.
  --socket-dir DIR        Unix socket directory (default: auto-detected from
                          the installed DocumentDB state; /var/run/postgresql
                          when no DocumentDB state exists on the host)
  --pg-port PORT          PostgreSQL port (default: auto-detected from the
                          installed DocumentDB state; 5432 when none exists)
  --pg-owner USER         PostgreSQL cluster owner OS user (default: auto-
                          detected from the installed DocumentDB state;
                          postgres when none exists)
  --target-db NAME        PostgreSQL database with the extension (default: postgres)
  --roles JSON            (create-user only) JSON array of {role, db} objects.
                          Default: [{"role":"readWriteAnyDatabase","db":"admin"},
                                    {"role":"clusterAdmin","db":"admin"}]
                          Examples:
                            --roles '[{"role":"readAnyDatabase","db":"admin"}]'  # read-only
                            --roles '[{"role":"readWrite","db":"mydb"}]'         # scoped RW
  --verbose               Show detailed output
  --dry-run               Preview create-user/drop-user/reset-password without
                          making any changes
  --yes                   Non-interactive: skip drop-user confirmation prompt
  -h, --help              Show this help message

Output options for list-users:
  Default                 Pretty-printed table (USER  DB  ROLES) via jq
  LIST_USERS_RAW=1 env    Print the raw BSONHEX from documentdb_api.users_info()
                          (the previous default; preserve for scripts)
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

find_psql() {
    # Discover every installed PostgreSQL major (Debian /usr/lib/postgresql/N/bin
    # and RHEL /usr/pgsql-N/bin), highest major first, then resolve each major's
    # psql through the shared documentdb_pg_bindir_candidates helper so the
    # Debian/RHEL layout list is single-sourced with the other CLIs (no hardcoded
    # 15-18 list that would omit newer majors). Fall back to psql on PATH.
    local bindir major p
    local -a majors=()
    for bindir in /usr/lib/postgresql/*/bin /usr/pgsql-*/bin; do
        [[ -d "${bindir}" ]] || continue
        major="${bindir%/bin}"
        major="${major##*/}"
        major="${major#pgsql-}"
        [[ "${major}" =~ ^[0-9]+$ ]] && majors+=("${major}")
    done
    for major in $(printf '%s\n' "${majors[@]+"${majors[@]}"}" | sort -rn -u); do
        while IFS= read -r p; do
            if [[ -x "${p}/psql" ]]; then
                printf '%s' "${p}/psql"
                return 0
            fi
        done < <(documentdb_pg_bindir_candidates "${major}")
    done
    command -v psql 2>/dev/null || die "psql not found."
}

# Materializes the password into a file on disk and sets the global
# `RESOLVED_PASSWORD_FILE` to that path. The caller passes that path
# to jq's `--rawfile` (which only reads from a real file). Resolution:
#
#  * `--password-file FILE` → use the operator-supplied file verbatim
#  * `--password-stdin` → read one line from stdin, write to a
#  tmpfile registered for trap cleanup
#  * neither → die with usage
#
# `--password-file` and `--password-stdin` are mutually exclusive — an
# operator who set both has ambiguous intent and we refuse rather than
# pick one silently. The stdin path refuses on a TTY so an operator who
# typed the flag by mistake gets a clear message instead of a hung
# `read` waiting for them to paste a password without echo.
#
# Mirrors the `--admin-password-stdin` pattern in documentdb-setup so
# operators have one consistent secret-piping idiom across all the
# DocumentDB tools.
resolve_password_to_file() {
    if [[ -n "${PASSWORD_FILE}" && "${PASSWORD_FROM_STDIN}" == "true" ]]; then
        die "--password-file and --password-stdin are mutually exclusive."
    fi

    if [[ -n "${PASSWORD_FILE}" ]]; then
        [[ -r "${PASSWORD_FILE}" ]] || die "Password file not readable: ${PASSWORD_FILE}"
        # Warn if the operator's file is world-readable; we honor it
        # but flag the risk in the same way documentdb-setup does.
        local file_perms
        file_perms="$(stat -c '%a' "${PASSWORD_FILE}" 2>/dev/null || true)"
        if [[ -n "${file_perms}" && "${file_perms}" != "600" && "${file_perms}" != "400" ]]; then
            log "WARNING: Password file ${PASSWORD_FILE} has permissions ${file_perms} (recommended: 0600)."
        fi
        # Echo "secret" > pwfile adds a
        # trailing newline that gets stored verbatim as part of the
        # password. Client login then fails with a server error (Invalid
        # key) — and the user has no idea why. Materialize the
        # password into a tmpfile with exactly one trailing newline
        # stripped (the common shell-redirection artifact). A genuinely
        # newline-suffixed password is still expressable via stdin or
        # --password-stdin with an explicit \n.
        local stripped
        stripped="$(mktemp)" || die "Cannot create temp file."
        _TEMP_FILES+=("${stripped}")
        chmod 600 "${stripped}"
        # Read whole file; strip single trailing \n if present.
        local raw
        raw="$(cat "${PASSWORD_FILE}")"
        # bash command substitution already strips trailing newlines, so
        # `raw` lost ALL trailing newlines. Writing it back without a
        # trailing newline yields a clean password value.
        printf '%s' "${raw}" > "${stripped}"
        # Warn if the original file ended with multiple newlines (likely
        # an editor artifact) so the operator can fix the source file.
        local file_size raw_len
        file_size="$(stat -c '%s' "${PASSWORD_FILE}" 2>/dev/null || echo 0)"
        raw_len=${#raw}
        if (( file_size > raw_len + 1 )); then
            log "WARNING: ${PASSWORD_FILE} ends with $((file_size - raw_len)) trailing newline/whitespace bytes; using the stripped value. Use printf %s \"\$PW\" > file or --password-stdin to avoid this."
        fi
        if [[ -n "${PG_OWNER}" ]] && id -u "${PG_OWNER}" >/dev/null 2>&1; then
            chown "${PG_OWNER}" "${stripped}" 2>/dev/null || true
        fi
        RESOLVED_PASSWORD_FILE="${stripped}"
        return 0
    fi

    if [[ "${PASSWORD_FROM_STDIN}" == "true" ]]; then
        if [[ -t 0 ]]; then
            die "--password-stdin requires the password on stdin (e.g. 'printf %s \"\$PW\" | documentdb-gateway-admin ... --password-stdin'). Stdin is a TTY."
        fi
        local tmp line=""
        tmp="$(mktemp)" || die "Cannot create temp file for stdin password."
        _TEMP_FILES+=("${tmp}")
        chmod 600 "${tmp}"
        # Read a single line preserving leading/trailing whitespace
        # except the trailing newline. Tolerate the no-trailing-newline
        # case from `printf '%s' "$PW" |` style invocations.
        IFS= read -r line || true
        printf '%s' "${line}" > "${tmp}"
        # If the caller's PG_OWNER differs from the current user, make
        # sure the run_as_user'd psql process can read the file.
        if [[ -n "${PG_OWNER}" ]] && id -u "${PG_OWNER}" >/dev/null 2>&1; then
            chown "${PG_OWNER}" "${tmp}" 2>/dev/null || true
        fi
        RESOLVED_PASSWORD_FILE="${tmp}"
        return 0
    fi

    die "A password is required. Pass --password-file <FILE> or --password-stdin."
}

# ── Subcommands ─────────────────────────────────────────────────────

cmd_create_user() {
    [[ -n "${USERNAME}" ]] || die "--username is required."
    # Refuse a name the gateway blocks at authentication rather than
    # creating a role that reports success and then fails every login with
    # "Username is invalid" (the gateway blocks the documentdb / citus / pg /
    # internal_role prefixes). Checked before the dry-run branch so a preview
    # surfaces the same rejection an apply would.
    if declare -F documentdb_validate_gateway_username >/dev/null 2>&1; then
        documentdb_validate_gateway_username "${USERNAME}" \
            || die "Refusing to create user '${USERNAME}' (see above)."
    fi
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[dry-run] would create DocumentDB user '${USERNAME}' in database '${TARGET_DB}' (no changes made)."
        return 0
    fi
    resolve_password_to_file

    local psql_bin user_bson_file
    psql_bin="$(find_psql)"

    user_bson_file="$(mktemp)"
    _TEMP_FILES+=("${user_bson_file}")
    chmod 600 "${user_bson_file}"

    # Previously the role list was
    # hardcoded to [readWriteAnyDatabase, clusterAdmin]. Operators who
    # wanted a read-only user got full RW + admin instead. --roles takes
    # a JSON array (BSON-shape) and validated by jq before submission.
    # Default preserves the prior behavior so existing scripts work.
    # NOTE: avoid putting `}` directly in ${ROLES_JSON:-...} default
    # because bash parses the first `}` as the closing of the parameter
    # expansion and leaves the rest as literal text → garbled JSON.
    # Build the default in a separate step instead.
    local roles_json
    if [[ -n "${ROLES_JSON:-}" ]]; then
        roles_json="${ROLES_JSON}"
    else
        roles_json='[{"role":"readWriteAnyDatabase","db":"admin"},{"role":"clusterAdmin","db":"admin"}]'
    fi
    if ! echo "${roles_json}" | jq -e 'type=="array" and (all(.[]?; type=="object" and has("role") and has("db")))' >/dev/null 2>&1; then
        die "--roles must be a JSON array of {role:..., db:...} objects. Got: ${roles_json}"
    fi

    jq -cn \
        --arg user "${USERNAME}" \
        --rawfile pwd "${RESOLVED_PASSWORD_FILE}" \
        --argjson roles "${roles_json}" \
        '{createUser: $user, pwd: $pwd, roles: $roles, "$db": "admin"}' \
        > "${user_bson_file}"

    chown "${PG_OWNER}" "${user_bson_file}" 2>/dev/null || true

    run_as_user "${PG_OWNER}" env "USER_BSON_FILE=${user_bson_file}" \
        "${psql_bin}" -h "${SOCKET_DIR}" -p "${PG_PORT}" -d "${TARGET_DB}" \
        -X -v ON_ERROR_STOP=1 <<'SQL'
-- Suppress statement logging so the password embedded in the BSON payload
-- is not written to the PostgreSQL log (log_statement/log_min_duration).
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_error_statement = 'panic';
\set user_bson `cat "$USER_BSON_FILE"`
SELECT documentdb_api.create_user(:'user_bson'::documentdb_core.bson);
SQL

    rm -f "${user_bson_file}"
    log "User '${USERNAME}' created with roles: ${roles_json}"
}

cmd_drop_user() {
    [[ -n "${USERNAME}" ]] || die "--username is required."

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[dry-run] would drop DocumentDB user '${USERNAME}' from database '${TARGET_DB}' (no changes made)."
        return 0
    fi

    # Drop-user is destructive and
    # previously ran without confirmation, inconsistent with restore/
    # reset-password. Require --yes or interactive [y/N].
    if [[ "${YES:-false}" != "true" ]]; then
        if [[ -t 0 ]]; then
            printf "Drop DocumentDB user '%s' from database '%s'? [y/N] " "${USERNAME}" "${TARGET_DB}" >&2
            local reply=""
            read -r reply || true
            case "${reply}" in
                y|Y|yes|YES) ;;
                *) die "Aborted by user." ;;
            esac
        else
            die "Non-interactive drop-user requires --yes (would delete user '${USERNAME}')."
        fi
    fi

    local psql_bin drop_bson_file
    psql_bin="$(find_psql)"

    drop_bson_file="$(mktemp)"
    _TEMP_FILES+=("${drop_bson_file}")
    chmod 600 "${drop_bson_file}"

    jq -cn --arg user "${USERNAME}" '{dropUser: $user, "$db": "admin"}' > "${drop_bson_file}"
    chown "${PG_OWNER}" "${drop_bson_file}" 2>/dev/null || true

    run_as_user "${PG_OWNER}" env "BSON_FILE=${drop_bson_file}" \
        "${psql_bin}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
        -d "${TARGET_DB}" -X -v ON_ERROR_STOP=1 <<'SQL'
\set bson_arg `cat "$BSON_FILE"`
SELECT documentdb_api.drop_user(:'bson_arg'::documentdb_core.bson);
SQL

    rm -f "${drop_bson_file}"
    log "User '${USERNAME}' dropped."
}

cmd_list_users() {
    local psql_bin
    psql_bin="$(find_psql)"

    # The prior implementation returned
    # the raw BSONHEX representation (~3 KB unreadable hex). Convert to
    # extended JSON via documentdb_core.bson_to_json_string and then
    # pretty-print with jq when present. --raw preserves the original
    # behavior for scripts that prefer hex.
    if [[ "${LIST_USERS_RAW:-0}" == "1" ]]; then
        run_as_user "${PG_OWNER}" "${psql_bin}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d "${TARGET_DB}" -X -v ON_ERROR_STOP=1 \
            -c "SELECT documentdb_api.users_info('{\"usersInfo\": 1, \"\$db\": \"admin\"}'::documentdb_core.bson);"
        return $?
    fi

    # Capture stdout ONLY for the JSON. psql emits NOTICE/WARNING lines on
    # stderr (common for extension functions); folding them into ${json} via
    # 2>&1 would corrupt the document and make the jq parse below fail on an
    # otherwise-successful query. Let stderr flow to the caller's terminal so
    # real errors stay visible, and rely on the non-zero exit (ON_ERROR_STOP=1)
    # to detect failure.
    local json
    if ! json="$(run_as_user "${PG_OWNER}" "${psql_bin}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d "${TARGET_DB}" -X -tA -v ON_ERROR_STOP=1 \
            -c "SELECT documentdb_core.bson_to_json_string(documentdb_api.users_info('{\"usersInfo\": 1, \"\$db\": \"admin\"}'::documentdb_core.bson));")"; then
        die "Failed to query users_info."
    fi

    if command -v jq >/dev/null 2>&1; then
        # Render a compact, human-readable table: user, db, roles.
        # Fall back to the full JSON if jq cannot understand the shape
        # (e.g. an extended-JSON $-prefixed value confused the path).
        if echo "${json}" | jq -er '.users[]? | "\(.user)\t\(.db)\t\(.roles|map("\(.role)@\(.db)")|join(","))"' >/dev/null 2>&1; then
            local rows
            rows="$(echo "${json}" | jq -r '.users[] | "\(.user)\t\(.db)\t\(.roles|map("\(.role)@\(.db)")|join(","))"')"
            if command -v column >/dev/null 2>&1; then
                { printf 'USER\tDB\tROLES\n'; echo "${rows}"; } | column -t -s $'\t'
            else
                # No `column` (bsdmainutils) → use awk to compute widths
                { printf 'USER\tDB\tROLES\n'; echo "${rows}"; } | \
                    awk -F'\t' '
                        { for (i=1;i<=NF;i++) { if (length($i)>w[i]) w[i]=length($i); rows[NR,i]=$i } nfmax=NF; n=NR }
                        END {
                            for (r=1;r<=n;r++) {
                                for (i=1;i<=nfmax;i++) printf "%-*s  ", w[i], rows[r,i]
                                printf "\n"
                            }
                        }'
            fi
        else
            echo "${json}" | jq .
        fi
    else
        # No jq → still emit JSON (much better than BSONHEX) with a hint.
        echo "${json}"
        log "Install jq for a pretty table view; or pass LIST_USERS_RAW=1 for raw BSONHEX."
    fi
}

cmd_reset_password() {
    [[ -n "${USERNAME}" ]] || die "--username is required."
    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[dry-run] would reset the password for DocumentDB user '${USERNAME}' in database '${TARGET_DB}' (no changes made)."
        return 0
    fi
    resolve_password_to_file

    local psql_bin update_bson_file
    psql_bin="$(find_psql)"

    # The prior implementation issued
    # ALTER USER unconditionally; PG returned "role does not exist" but
    # ON_ERROR_STOP=1 + psql produced a non-zero rc that we then turned
    # into rc=0 by accident (no error trap in cmd_reset_password). Pre-
    # check with the documentdb-side users_info so we can:
    #  1. Exit non-zero with a clean tool-level message, AND
    #  2. Avoid invoking ALTER USER as the gateway role (since we go
    #  through the extension API anyway via update_user).
    local exists_check exists_err_file
    exists_err_file="$(mktemp)"
    _TEMP_FILES+=("${exists_err_file}")
    # Capture stderr to a separate file rather than merging it (2>&1) into the
    # probed value: a benign stderr line (e.g. a sudo/runuser "could not change
    # directory to /root" warning) would otherwise pollute exists_check so the
    # strict `!= "1"` check below falsely reports a present user as missing.
    if ! exists_check="$(run_as_user "${PG_OWNER}" "${psql_bin}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d "${TARGET_DB}" -X -tA -v ON_ERROR_STOP=1 \
            -v username="${USERNAME}" <<'SQL' 2>"${exists_err_file}"
SELECT 1 FROM pg_roles WHERE rolname = :'username';
SQL
)"; then
        die "Cannot probe PostgreSQL roles: $(cat "${exists_err_file}")"
    fi
    if [[ "${exists_check}" != "1" ]]; then
        die "User '${USERNAME}' does not exist in database '${TARGET_DB}'. List existing users with: documentdb-gateway-admin list-users"
    fi

    update_bson_file="$(mktemp)"
    _TEMP_FILES+=("${update_bson_file}")
    chmod 600 "${update_bson_file}"

    jq -cn \
        --arg user "${USERNAME}" \
        --rawfile pwd "${RESOLVED_PASSWORD_FILE}" \
        '{updateUser: $user, pwd: $pwd, "$db": "admin"}' > "${update_bson_file}"

    chown "${PG_OWNER}" "${update_bson_file}" 2>/dev/null || true

    if ! run_as_user "${PG_OWNER}" env "BSON_FILE=${update_bson_file}" \
            "${psql_bin}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d "${TARGET_DB}" -X -v ON_ERROR_STOP=1 <<'SQL'
-- Suppress statement logging so the password embedded in the BSON payload
-- is not written to the PostgreSQL log (log_statement/log_min_duration).
SET log_statement = 'none';
SET log_min_duration_statement = -1;
SET log_min_error_statement = 'panic';
\set bson_arg `cat "$BSON_FILE"`
SELECT documentdb_api.update_user(:'bson_arg'::documentdb_core.bson);
SQL
    then
        rm -f "${update_bson_file}"
        die "Password reset for '${USERNAME}' failed; see PostgreSQL output above."
    fi

    rm -f "${update_bson_file}"
    log "Password reset for user '${USERNAME}'."
}

cmd_check() {
    local psql_bin ext_check
    psql_bin="$(find_psql)"

    log "Checking PostgreSQL connectivity..."
    if ! run_as_user "${PG_OWNER}" "${psql_bin}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
            -d "${TARGET_DB}" -X -tA -c "SELECT 1;" >/dev/null 2>&1; then
        die "Cannot connect to PostgreSQL at ${SOCKET_DIR}:${PG_PORT}."
    fi
    log "PostgreSQL connectivity: OK"

    log "Checking DocumentDB extension..."
    ext_check="$(run_as_user "${PG_OWNER}" "${psql_bin}" -h "${SOCKET_DIR}" -p "${PG_PORT}" \
        -d "${TARGET_DB}" -X -tA -c "SELECT 1 FROM pg_extension WHERE extname = 'documentdb';" 2>/dev/null || true)"

    if [[ "${ext_check}" == "1" ]]; then
        log "DocumentDB extension: loaded"
    else
        log "DocumentDB extension: NOT loaded (run CREATE EXTENSION documentdb CASCADE;)"
    fi
}

# ── Argument parsing ────────────────────────────────────────────────

parse_admin_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --username)
                [[ $# -ge 2 ]] || die "--username requires a value."
                USERNAME="$2"; shift 2 ;;
            --password-file)
                [[ $# -ge 2 ]] || die "--password-file requires a value."
                PASSWORD_FILE="$2"; shift 2 ;;
            --password-stdin)
                PASSWORD_FROM_STDIN=true
                shift ;;
            --socket-dir)
                [[ $# -ge 2 ]] || die "--socket-dir requires a value."
                SOCKET_DIR="$2"; shift 2 ;;
            --pg-port)
                [[ $# -ge 2 ]] || die "--pg-port requires a value."
                PG_PORT="$2"; shift 2 ;;
            --pg-owner)
                [[ $# -ge 2 ]] || die "--pg-owner requires a value."
                PG_OWNER="$2"
                PG_OWNER_EXPLICIT=true
                shift 2 ;;
            --target-db)
                # Which PostgreSQL database the documentdb extension was
                # created in. Default: postgres. Threaded into every
                # psql -d call below so admin operations land in the
                # Actual DocumentDB database.
                # Track
                # explicit-set so auto_detect doesn't override an
                # operator-supplied value with state-file contents.
                [[ $# -ge 2 ]] || die "--target-db requires a value."
                if ! [[ "$2" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
                    die "--target-db must be a PostgreSQL identifier (got '$2')."
                fi
                TARGET_DB="$2"
                TARGET_DB_EXPLICIT=true
                shift 2 ;;
            --verbose) VERBOSE=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --yes) YES=true; shift ;;
            --roles)
                # Allow operators to
                # supply a custom roles JSON for create-user. Example:
                #  --roles '[{"role":"readAnyDatabase","db":"admin"}]'
                [[ $# -ge 2 ]] || die "--roles requires a JSON value."
                ROLES_JSON="$2"; shift 2 ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done
}

# ── Dispatch (called from documentdb-gateway wrapper) ───────────────

# The first argument is the subcommand (create-user, drop-user, etc.)
# Remaining arguments are parsed as options.
main() {
    if [[ $# -lt 1 ]]; then
        usage
        exit 1
    fi

    local subcmd="$1"; shift
    parse_admin_args "$@"

    # Auto-detect connection params from appliance state if not explicitly set
    auto_detect_connection
    # Final fallback, applied after every auto_detect_connection exit path
    # (explicit-flags early return, no-state default, state-derived): a
    # plain system PostgreSQL runs as "postgres". State files and the
    # legacy-host branch normally resolve PG_OWNER before this fires.
    [[ -n "${PG_OWNER}" ]] || PG_OWNER="postgres"

    log_verbose "subcommand: ${subcmd}"
    log_verbose "connection: db=${TARGET_DB} socket=${SOCKET_DIR} port=${PG_PORT} pg-owner=${PG_OWNER}"

    case "${subcmd}" in
        create-user)     cmd_create_user ;;
        drop-user)       cmd_drop_user ;;
        list-users)      cmd_list_users ;;
        reset-password)  cmd_reset_password ;;
        check)           cmd_check ;;
        -h|--help)       usage; exit 0 ;;
        *)               die "Unknown admin command: ${subcmd}" ;;
    esac
}

main "$@"
