#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-tune — apply or remove the recommended DocumentDB postgresql.conf
# settings for one PostgreSQL cluster.
#
# On Debian/Ubuntu this writes a per-cluster config file at
# /etc/postgresql-common/documentdb/<version>/<cluster>/documentdb.conf
# which is picked up via the createcluster.d include_if_exists hook.
#
# On RHEL (or when --pgdata is given) it edits the cluster's
# postgresql.conf directly using managed blocks.

set -euo pipefail
umask 077

readonly PROG="documentdb-tune"
# Managed block markers — intentionally match documentdb-setup.sh for backward
# compatibility with existing postrm cleanup scripts.
readonly MANAGED_BLOCK_START="# >>> documentdb-setup managed configuration >>>"
readonly MANAGED_BLOCK_END="# <<< documentdb-setup managed configuration <<<"

# ── Defaults ────────────────────────────────────────────────────────
PG_VERSION=""
CLUSTER_NAME=""
PGDATA=""
SOCKET_DIR_OVERRIDE=""   # explicit Unix socket dir for the localhost-conn GUC
PG_PORT_OVERRIDE=""      # explicit port for the localhost-conn GUC
ACTION="apply"      # apply | restore | print
DRY_RUN=false
YES=false
VERBOSE=false
TOAST_COMPRESSION_REQUESTED=""  # explicit --toast-compression choice
TOAST_COMPRESSION=""            # resolved value; "" leaves the setting alone

# Resolved at runtime
CONFIG_TARGET=""
IS_DEBIAN=false
HAS_EXTENDED_RUM=false
PG_SHAREDIR=""
DEBIAN_LIVE_PG_CONF=""

# ── Helpers ─────────────────────────────────────────────────────────

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }
log_verbose() { [[ "${VERBOSE}" == "true" ]] && echo "[${PROG}] $*" >&2; return 0; }

# Track all temp files in a global array and clean them up on any exit path.
# Mirrors documentdb-register-gateway.sh: a bare RETURN trap with an
# interpolated path is both injection-prone (a --pgdata containing a single
# quote breaks out of the trap string) and leak-prone (RETURN does not fire if
# the process is killed mid-function). A single EXIT/INT/TERM trap over a global
# array avoids per-path interpolation entirely and fires on signals too.
TEMP_FILES=()

cleanup_temp_files() {
    local f
    for f in "${TEMP_FILES[@]:-}"; do
        if [[ -n "${f}" && -e "${f}" ]]; then
            rm -f "${f}" 2>/dev/null || true
        fi
    done
    TEMP_FILES=()
}
trap cleanup_temp_files EXIT
trap 'cleanup_temp_files; exit 130' INT
trap 'cleanup_temp_files; exit 143' TERM

# Create a temp file in the target file's directory (so the eventual mv is an
# atomic same-filesystem rename) and register it for cleanup. The caller passes
# the variable name; the temp path is assigned to that variable via printf -v,
# so the path is never interpolated into a trap or other shell string.
create_temp_in_dir() {
    local var_name="$1"
    local target_dir="$2"
    local tmp_path
    tmp_path="$(mktemp "${target_dir}/.documentdb-tune.XXXXXX")" \
        || die "Failed to create temp file in ${target_dir}."
    TEMP_FILES+=("${tmp_path}")
    printf -v "${var_name}" '%s' "${tmp_path}"
}

# Tools that printed
# "sudo systemctl restart postgresql@N-main" gave no fallback on hosts
# without systemd (containers, minimal installs). Detect a working
# systemd PID-1 and print the platform-correct command; fall back to
# pg_ctlcluster (Debian) or pg_ctl (RHEL) when systemd is unavailable.
# has_working_systemd comes from documentdb-tools-lib.sh (sourced below).

usage() {
    cat <<'EOF'
Usage: documentdb-tune [OPTIONS]

Apply or remove the recommended DocumentDB postgresql.conf settings for a
PostgreSQL cluster.

Options:
  --pg-version N    PostgreSQL major version (required unless --pgdata is given)
  --cluster C       Cluster name (Debian/Ubuntu, default: "main")
  --pgdata DIR      PostgreSQL data directory (overrides --pg-version/--cluster)
  --socket-dir DIR  Absolute Unix socket directory used to route the extension's
                    internal (localhost) connections; overrides the value read
                    from the cluster config. No whitespace, single quotes, or
                    backslashes.
  --port PORT       Port used to route the extension's internal connections
                    (1-65535); overrides the value read from the cluster config.
  --toast-compression MODE
                    Compression used for out-of-line (TOAST) values:
                    "lz4" (default, faster decompression for large documents),
                    "pglz", or "default" to leave the server's own setting
                    alone. Applies to newly written values only. Also settable
                    via the DOCUMENTDB_TOAST_COMPRESSION environment variable.
                    Instance-wide: on a shared cluster this changes the
                    default for EVERY database, not just DocumentDB's; use
                    "default" there if others must keep the server's setting.
  --yes             Apply changes without prompting
  --dry-run         Show what would change without writing
  --restore         Remove the managed config block
  --print           Print the recommended config snippet to stdout and exit
  --verbose         Show detailed output
  -h, --help        Show this help message
EOF
}

# ── Managed-block helpers (shared) ──────────────────────────────────
#
# The managed-block / config-mutation primitives and shared_preload_libraries
# helpers are single-sourced from
# documentdb-tools-lib.sh so documentdb-tune and documentdb-register-gateway
# cannot drift. The library lives beside this script in a dev checkout and at
# /usr/share/documentdb/scripts/ when installed from the
# documentdb-postgresql-tools package. Die / log_verbose / create_temp_in_dir
# (defined above) and HAS_EXTENDED_RUM (set by detect_extended_rum) satisfy the
# library's host contract.
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

# ── Config generation ───────────────────────────────────────────────

build_config_block() {
    local merged_preload="$1"
    local block=""

    block="shared_preload_libraries = '${merged_preload}'"
    block+=$'\n'"cron.database_name = 'postgres'"
    # Run pg_cron jobs in background workers rather than via a libpq client
    # connection. documentdb-setup installs a hardened pg_hba.conf that only
    # admits the documentdb-gateway role (peer + ident map) on the local
    # socket and requires scram-sha-256 over TCP, so pg_cron's default client
    # mode (cron.use_background_workers = off, which dials cron.host=localhost
    # over TCP) cannot authenticate and every scheduled job fails with
    # "connection failed". That silently breaks index creation: createIndexes
    # enqueues the build and the documentdb_api_internal.build_index_concurrently
    # pg_cron job that actually builds it never runs, so the gateway polls for a
    # completion that never arrives and the command hangs. Background-worker mode
    # runs the jobs in-process with no connection or authentication, which is the
    # correct model for the self-contained stand-alone cluster. (Requires a
    # restart to take effect, which documentdb-setup performs after tuning.)
    block+=$'\n'"cron.use_background_workers = on"
    block+=$'\n'"documentdb.enableBackgroundWorker = true"
    block+=$'\n'"documentdb.enableBackgroundWorkerJobs = true"
    block+=$'\n'"documentdb.indexBuildsScheduledOnBgWorker = false"
    block+=$'\n'"documentdb.localhost_connection_string = '$(resolve_localhost_connection)'"

    # Empty means the operator asked us to leave the server's own setting alone,
    # or the build has no lz4 support.
    if [[ -n "${TOAST_COMPRESSION}" ]]; then
        block+=$'\n'"default_toast_compression = '${TOAST_COMPRESSION}'"
    fi

    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        block+=$'\n'"documentdb.rum_library_load_option = 'require_documentdb_extended_rum'"
        block+=$'\n'"documentdb.alternate_index_handler_name = 'extended_rum'"
    fi

    printf '%s' "${block}"
}

# ── Distro / path resolution ───────────────────────────────────────

detect_distro() {
    IS_DEBIAN=false
    if [[ -f /etc/debian_version ]] || command -v dpkg >/dev/null 2>&1; then
        IS_DEBIAN=true
    fi
}

resolve_pg_sharedir() {
    PG_SHAREDIR=""
    local d pg_config
    while IFS= read -r d; do
        pg_config="${d}/pg_config"
        if [[ -x "${pg_config}" ]]; then
            PG_SHAREDIR="$("${pg_config}" --sharedir 2>/dev/null || true)"
            return 0
        fi
    done < <(documentdb_pg_bindir_candidates "${PG_VERSION}")
}

resolve_config_target() {
    if [[ -n "${PGDATA}" ]]; then
        # A mistyped --pgdata must not silently fabricate a cluster: the
        # apply path creates the parent directory and touches a fresh
        # postgresql.conf, then reports success against a path no PostgreSQL
        # instance ever reads. For apply, require the directory to already
        # look like a PostgreSQL cluster: an initialized data dir carries
        # PG_VERSION (written by initdb, so the greenfield wizard's
        # freshly-initdb'd dir passes), and a bare postgresql.conf is
        # accepted for config-only layouts (dev/test fixtures).
        # --print never reads or writes the target, and --restore against a
        # missing dir must stay the clean "Nothing to restore" no-op it has
        # always been (documentdb-setup --restore after documentdb-local-reset
        # legitimately hits a deleted data dir) — only apply can fabricate.
        if [[ "${ACTION}" == "apply" \
              && ! -f "${PGDATA}/PG_VERSION" \
              && ! -f "${PGDATA}/postgresql.conf" ]]; then
            die "--pgdata '${PGDATA}' does not look like a PostgreSQL data directory (no PG_VERSION or postgresql.conf found there). Check the path for typos; refusing to fabricate a new postgresql.conf."
        fi
        CONFIG_TARGET="${PGDATA}/postgresql.conf"
        return 0
    fi

    if [[ "${IS_DEBIAN}" == "true" ]]; then
        # Debian/Ubuntu: write a separate per-instance file that the
        # createcluster.d hook's include_if_exists picks up. The hook
        # references documentdb.conf (PostgreSQL only loads .conf files
        # via include_dir; the .sample example in
        # /usr/share/doc/documentdb-postgresql-tools/examples/ follows the
        # PostgreSQL .sample convention). Per packaging-design.md §4.2.
        CONFIG_TARGET="$(documentdb_tune_fragment_path "${PG_VERSION}" "${CLUSTER_NAME}")"
        # Track the live instance's postgresql.conf so that, on existing
        # clusters that pre-date the hook, we can add the include line
        # ourselves; otherwise the fragment would be silently unused.
        DEBIAN_LIVE_PG_CONF="/etc/postgresql/${PG_VERSION}/${CLUSTER_NAME}/postgresql.conf"
        return 0
    fi

    # RHEL: edit the cluster's postgresql.conf directly.
    local rhel_data="/var/lib/pgsql/${PG_VERSION}/data"
    if [[ -d "${rhel_data}" ]]; then
        CONFIG_TARGET="${rhel_data}/postgresql.conf"
        return 0
    fi

    # --print only emits the recommended snippet to stdout and never reads or
    # writes a target (do_print tolerates an empty CONFIG_TARGET), so a missing
    # or uninitialised data directory must not be fatal for it — e.g. previewing
    # the recommended settings on a host where PostgreSQL is not yet installed.
    # Mutating actions (apply/restore) still require a resolvable target.
    if [[ "${ACTION}" == "print" ]]; then
        CONFIG_TARGET=""
        return 0
    fi

    die "Cannot resolve config file. Use --pgdata to specify the data directory."
}

# Debian-only: on existing clusters created before documentdb-postgresql-tools
# was installed, the createcluster.d hook never ran, so the live cluster's
# postgresql.conf has no include_if_exists line pointing at our fragment.
# documentdb-tune --apply must add that line so the fragment is actually
# loaded; otherwise the operator silently writes /etc/postgresql-common/...
# but PG never reads it. The line is wrapped in our managed-block markers
# so --restore strips it cleanly.
# True (0) when the Debian live postgresql.conf already contains the managed
# include line, or when there is no live conf to add it to (nothing to repair).
# False (1) only when a live conf exists but is missing the include line -- the
# one case do_apply must fall through to the write path to repair.
debian_include_line_satisfied() {
    [[ -n "${DEBIAN_LIVE_PG_CONF}" && -f "${DEBIAN_LIVE_PG_CONF}" ]] || return 0
    # Derive from CONFIG_TARGET (the managed fragment) so this stays byte-identical
    # to the line ensure_debian_include_line writes AND to the value the
    # unhandled-include guard exempts (_config_declares_unhandled_include). On the
    # Debian split-layout CONFIG_TARGET is exactly this fragment path.
    local include_line="include_if_exists = '${CONFIG_TARGET}'"
    # An unanchored fixed-string probe also matched COMMENTED-OUT copies of
    # the line ("# include_if_exists = ..."), wrongly reporting the include
    # satisfied and leaving the managed fragment silently unread. Iterate the
    # fixed-string matches (no regex-escaping of the path needed) and accept
    # only a line whose first non-whitespace content IS the include line —
    # leading whitespace is allowed, a comment marker is not.
    local line stripped
    while IFS= read -r line; do
        stripped="${line#"${line%%[![:space:]]*}"}"
        if [[ "${stripped}" == "${include_line}"* ]]; then
            return 0
        fi
    done < <(grep -F "${include_line}" "${DEBIAN_LIVE_PG_CONF}" 2>/dev/null)
    return 1
}

ensure_debian_include_line() {
    [[ "${IS_DEBIAN}" == "true" ]] || return 0
    [[ -n "${DEBIAN_LIVE_PG_CONF}" && -f "${DEBIAN_LIVE_PG_CONF}" ]] || return 0

    local include_marker_start="# >>> documentdb-tune managed include >>>"
    local include_marker_end="# <<< documentdb-tune managed include <<<"
    # Derive from CONFIG_TARGET (the managed fragment) so the written line stays
    # byte-identical to debian_include_line_satisfied's probe AND to the value the
    # unhandled-include guard exempts. On the Debian split-layout CONFIG_TARGET is
    # exactly this fragment path.
    local include_line="include_if_exists = '${CONFIG_TARGET}'"

    # Fail closed on a torn/unbalanced managed include block (e.g. a manual
    # edit dropped one marker) before the idempotency short-circuit below, so
    # the corruption is reported here rather than only surfacing at a later
    # --restore.
    assert_managed_markers_balanced "${DEBIAN_LIVE_PG_CONF}" \
        "${include_marker_start}" "${include_marker_end}"

    # Skip if the hook (or a prior tune run) already added the include.
    if debian_include_line_satisfied; then
        log_verbose "Include line already present in ${DEBIAN_LIVE_PG_CONF}; nothing to do."
        return 0
    fi

    # Match the §7 contract that
    # every config-edit path refuses to mutate files containing markers from
    # a tool we don't recognize. The fragment-write path at line ~405 already
    # calls check_foreign_markers; the live-conf append path was missing it.
    check_foreign_markers "${DEBIAN_LIVE_PG_CONF}"

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "[dry-run] would append managed include block to ${DEBIAN_LIVE_PG_CONF}:"
        printf '  %s\n  %s\n  %s\n' "${include_marker_start}" "${include_line}" "${include_marker_end}"
        return 0
    fi

    log "Appending managed include block to ${DEBIAN_LIVE_PG_CONF}."
    backup_file "${DEBIAN_LIVE_PG_CONF}"
    # Write the include block through the atomic managed-block helper (temp
    # file in the same directory + rename) rather than a direct '>>' append:
    # a torn/partial append into the live postgresql.conf could leave an
    # unterminated include_if_exists line that prevents PostgreSQL from
    # starting. rewrite_with_managed_block also makes this idempotent.
    rewrite_with_managed_block "${DEBIAN_LIVE_PG_CONF}" \
        "${include_marker_start}" "${include_marker_end}" "${include_line}"
}

# ── Actions ─────────────────────────────────────────────────────────

# Debian: the per-instance fragment is included AFTER postgresql.conf and its
# conf.d drop-ins (via include_if_exists), so its shared_preload_libraries wins
# over those. Its value must therefore be the operator's EFFECTIVE
# shared_preload_libraries (so nothing declared in conf.d is dropped) plus the
# documentdb libraries. We compute that effective value using PostgreSQL's
# LAST-assignment-wins precedence (not a union) across the standard Debian
# layout (postgresql.conf + its conf.d drop-in directory), so a later file that
# replaces or clears the value is honored rather than resurrecting libraries the
# operator removed. An empty '' assignment is an authoritative clear (distinct
# from "not set"). Non-standard include layouts (a renamed include_dir or
# explicit include/include_dir directives) are out of scope — this is still
# strictly better than the previous postgresql.conf-only read.
#
# Sources, in PostgreSQL read order (all read BEFORE our fragment):
#   1. the live postgresql.conf
#   2. every *.conf drop-in under the cluster's conf.d include directory
#
# postgresql.auto.conf (ALTER SYSTEM) is read LAST — AFTER our fragment — so it
# overrides the fragment outright; folding its value in cannot help. Warn
# whenever it declares shared_preload_libraries (even an empty clear), since
# that silently keeps the documentdb libraries from loading until it is fixed.
#
# The prior fragment value (passed as $1) is intentionally NOT folded in on this
# path: the fragment is recomputed from the operator's live sources each run, so
# trusting its previous value would resurrect libraries the operator has since
# removed.

# _spl_assigned_in_file <file>: true when <file> has an uncommented
# shared_preload_libraries assignment (even an empty one). Lets the caller
# distinguish "set to ''" (a clear) from "not set", which
# read_shared_preload_libraries_from_file cannot (both return empty).
_spl_assigned_in_file() {
    local f="$1"
    [[ -f "${f}" ]] || return 1
    # Match PostgreSQL's postgresql.conf syntax like _read_scalar_guc_from_file:
    # GUC names are case-INsensitive and the "=" between name and value is
    # OPTIONAL (whitespace also separates them), so "SHARED_PRELOAD_LIBRARIES
    # 'x'" is an assignment too. The (=|space) boundary keeps a longer
    # parameter that merely starts with the key from matching.
    grep -Eiq '^[[:space:]]*shared_preload_libraries([[:space:]]*=|[[:space:]])' "${f}"
}

# _read_scalar_guc_from_file <key> <file>: print the last uncommented value of a
# scalar GUC assignment, honoring PostgreSQL's inline-comment and quoting rules.
# Empty when unset. Matches PostgreSQL's postgresql.conf syntax: parameter names
# are case-INsensitive and the "=" between name and value is OPTIONAL (a space
# also separates them). A word boundary after the key (an "=", or whitespace)
# prevents a key from matching a longer parameter that merely starts with it.
_read_scalar_guc_from_file() {
    local key="$1" config_path="$2" value=""
    [[ -f "${config_path}" ]] || return 0
    value="$(
        awk -v key="${key}" '
            BEGIN {
                lkey = tolower(key); klen = length(key)
                gsub(/[.\\*+?^${}()|[\]]/, "\\\\&", lkey)   # escape regex metachars in the dynamic match
            }
            /^[[:space:]]*#/ { next }
            tolower($0) ~ ("^[[:space:]]*" lkey "([[:space:]]*=|[[:space:]])") {
                v = $0
                sub(/^[[:space:]]*/, "", v)          # drop leading whitespace
                v = substr(v, klen + 1)               # drop the key name (any case, exact length)
                sub(/^[[:space:]]*=?[[:space:]]*/, "", v)   # drop the optional "=" and surrounding whitespace
                if (v ~ /^\047/) { if (match(v, /^\047[^\047]*\047/)) v = substr(v, RSTART, RLENGTH) }
                else if (v ~ /^"/) { if (match(v, /^"[^"]*"/)) v = substr(v, RSTART, RLENGTH) }
                else { sub(/[[:space:]]*#.*$/, "", v) }
                gsub(/[[:space:]]+$/, "", v)
                print v
            }
        ' "${config_path}" | tail -n 1
    )"
    strip_wrapping_quotes "${value}"
}

# _scalar_guc_assigned_in_file <key> <file>: return 0 if <key> is assigned
# (uncommented, to ANY value including empty) in <file>, else 1. Uses the same
# case-insensitive, optional-"=" match as _read_scalar_guc_from_file so the two
# agree on what counts as an assignment. Unlike _read_scalar_guc_from_file
# (which returns an empty string for BOTH "unset" and "set empty"), this
# distinguishes the two, which is needed to tell "unix_socket_directories unset
# -> use the compiled-in default" apart from "unix_socket_directories = '' ->
# Unix sockets disabled".
_scalar_guc_assigned_in_file() {
    local key="$1" file="$2"
    [[ -f "${file}" ]] || return 1
    awk -v key="${key}" '
        BEGIN {
            lkey = tolower(key)
            gsub(/[.\\*+?^${}()|[\]]/, "\\\\&", lkey)   # escape regex metachars in the dynamic match
        }
        /^[[:space:]]*#/ { next }
        tolower($0) ~ ("^[[:space:]]*" lkey "([[:space:]]*=|[[:space:]])") { found = 1 }
        END { exit(found ? 0 : 1) }
    ' "${file}"
}

# _debian_live_config_files: print the Debian split-layout config files in the
# order PostgreSQL reads them — the live postgresql.conf first, then
# conf.d/*.conf — one path per line. Empty when not on the Debian split-layout
# (non-Debian, or an explicit --pgdata).
#
# PostgreSQL's include_dir reads *.conf in C-locale (byte) order, ignores names
# beginning with '.' (hidden files), and follows symlinks (it fopen()s each
# entry). Mirror all three (-L follows symlinks, -type f then matches a symlink
# to a regular file; ! -name '.*' skips hidden files; LC_ALL=C sort gives byte
# order) so the last-wins tie-break agrees with PG regardless of LC_COLLATE.
_debian_live_config_files() {
    [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]] || return 0
    [[ -n "${DEBIAN_LIVE_PG_CONF}" && -f "${DEBIAN_LIVE_PG_CONF}" ]] && printf '%s\n' "${DEBIAN_LIVE_PG_CONF}"
    local confd="/etc/postgresql/${PG_VERSION}/${CLUSTER_NAME}/conf.d"
    if [[ -d "${confd}" ]]; then
        find -L "${confd}" -maxdepth 1 -type f -name '*.conf' ! -name '.*' 2>/dev/null | LC_ALL=C sort
    fi
}

# _read_effective_scalar_guc_debian <key>: resolve the last-assignment-wins value
# of a scalar GUC across the Debian live config files (postgresql.conf + conf.d),
# mirroring PostgreSQL's read order. Empty when unset or not on Debian.
_read_effective_scalar_guc_debian() {
    local key="$1" effective="" src val
    local -a ordered=()
    local f
    while IFS= read -r f; do
        ordered+=("${f}")
    done < <(_debian_live_config_files)
    for src in "${ordered[@]+"${ordered[@]}"}"; do
        val="$(_read_scalar_guc_from_file "${key}" "${src}")"
        [[ -n "${val}" ]] && effective="${val}"
    done
    printf '%s' "${effective}"
}

# _read_effective_scalar_guc <key>: last-assignment-wins value of a scalar GUC
# across the target's config files INCLUDING postgresql.auto.conf, which
# PostgreSQL reads LAST — so an ALTER SYSTEM override of e.g. port or
# unix_socket_directories is honored (mirrors the auto.conf awareness the
# preload check already has). Empty when unset.
_read_effective_scalar_guc() {
    local key="$1" val="" autoconf auto_val
    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
        val="$(_read_effective_scalar_guc_debian "${key}")"
    elif [[ -n "${CONFIG_TARGET}" && -f "${CONFIG_TARGET}" ]]; then
        val="$(_read_scalar_guc_from_file "${key}" "${CONFIG_TARGET}")"
    fi
    autoconf="$(_cluster_autoconf_path)"
    if [[ -n "${autoconf}" && -f "${autoconf}" ]]; then
        auto_val="$(_read_scalar_guc_from_file "${key}" "${autoconf}")"
        [[ -n "${auto_val}" ]] && val="${auto_val}"
    fi
    printf '%s' "${val}"
}

# _effective_config_files: print, one per line, the config files this resolver
# reads for the target instance in PostgreSQL's read order — the Debian live
# config files (postgresql.conf + conf.d) or the single CONFIG_TARGET, followed
# by postgresql.auto.conf (which PostgreSQL reads last). Shared by the
# disabled-socket and unhandled-include checks so they walk exactly the files
# the scalar value reader consults.
_effective_config_files() {
    local autoconf
    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
        _debian_live_config_files
    elif [[ -n "${CONFIG_TARGET}" && -f "${CONFIG_TARGET}" ]]; then
        printf '%s\n' "${CONFIG_TARGET}"
    fi
    autoconf="$(_cluster_autoconf_path)"
    [[ -n "${autoconf}" && -f "${autoconf}" ]] && printf '%s\n' "${autoconf}"
    return 0
}

# _unix_socket_dirs_disabled: return 0 if unix_socket_directories is effectively
# assigned an EMPTY value (Unix sockets turned OFF) by the LAST file that
# assigns it in the target's read order (config files, then
# postgresql.auto.conf, which PostgreSQL reads last). Returns 1 when the GUC is
# unset (relying on the compiled-in default socket dir) or assigned a non-empty
# path. This lets the caller tell "unset -> use the distro default socket dir"
# apart from "explicitly disabled -> fail, because documentdb's local peer auth
# needs a Unix socket". _read_effective_scalar_guc cannot make this distinction
# because it ignores empty assignments (it tracks the last NON-EMPTY value).
_unix_socket_dirs_disabled() {
    local key='unix_socket_directories' last="" f val
    while IFS= read -r f; do
        if _scalar_guc_assigned_in_file "${key}" "${f}"; then
            last="${f}"
        fi
    done < <(_effective_config_files)
    [[ -n "${last}" ]] || return 1
    val="$(_read_scalar_guc_from_file "${key}" "${last}")"
    [[ -z "$(trim_whitespace "${val}")" ]]
}

# _config_declares_unhandled_include: return 0 if the target config declares an
# active include directive whose target this resolver does NOT read, so a port /
# unix_socket_directories set there would be silently missed. We read
# postgresql.conf, the Debian conf.d directory (the standard
# `include_dir = 'conf.d'`), and postgresql.auto.conf; anything else — an
# `include`/`include_if_exists` of an arbitrary file, or an `include_dir` of a
# non-conf.d directory — is unresolved. Commented directives are ignored.
# `include_dir` is recognised distinctly from `include` via the same word
# boundary the scalar reader uses. Used to fail closed (or warn) rather than
# emit a possibly-wrong localhost route from a partially-read config. Also fails
# closed when active content follows the exempted conf.d include_dir: PostgreSQL
# reads conf.d inline at that point and then continues the root file, so a later
# root assignment overrides conf.d — an ordering the root-then-conf.d resolver
# does not model (the standard Debian layout has include_dir as the last active
# line, so this never fires there). The tune-managed include_if_exists is exempt
# from that trailing check because tune appends it after conf.d yet it only
# pulls in the documentdb fragment (no port / unix_socket_directories), so it
# does not change resolution and must not break idempotent reruns.
_config_declares_unhandled_include() {
    # scan_mode selects strictness (default: full):
    #   full    — flag ANY unhandled include or ANY active content after the
    #             exempted conf.d include (used when tune resolves the port /
    #             socket route from the config, i.e. no --socket-dir/--port).
    #   preload — flag only the hazards that corrupt tune's OWN ordered
    #             shared_preload_libraries fold and data_directory resolution:
    #             a non-exempt include (whose file is never walked) or a
    #             shared_preload_libraries / data_directory assignment placed
    #             AFTER the conf.d include (mis-ordered by the root-then-conf.d
    #             walk). A benign trailing GUC (e.g. work_mem) is allowed
    #             through, since the connection route is already pinned by the
    #             overrides. Used by enforce_config_includes_resolved for the
    #             Debian split-layout when both overrides are supplied.
    local scan_mode="${1:-full}"
    local f root=""
    # The conf.d exemption is valid ONLY for `include_dir = 'conf.d'` declared in
    # the ROOT Debian postgresql.conf, whose relative conf.d is exactly the
    # directory _debian_live_config_files walks. It applies only in the Debian
    # split-layout (IS_DEBIAN, no --pgdata). Everywhere else it must fail closed:
    # under --pgdata / RHEL we do not walk conf.d at all, and a NESTED
    # `include_dir = 'conf.d'` inside a conf.d/*.conf file resolves to
    # conf.d/conf.d (relative to that file), which we do not walk either.
    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" && -n "${DEBIAN_LIVE_PG_CONF:-}" ]]; then
        root="${DEBIAN_LIVE_PG_CONF}"
    fi
    while IFS= read -r f; do
        [[ -f "${f}" ]] || continue
        local exempt_confd=0
        if [[ -n "${root}" && "${f}" == "${root}" ]]; then
            exempt_confd=1
        fi
        if awk -v exempt_confd="${exempt_confd}" -v mgmt_frag="${CONFIG_TARGET:-}" -v scan_mode="${scan_mode}" '
            /^[[:space:]]*#/ { next }
            {
                # line_is_exempt marks lines that are themselves the exempted
                # conf.d include or the tune-managed include, so the trailing-
                # content check at the end of this block does not flag them.
                line_is_exempt = 0
                l = tolower($0)
                if (l ~ /^[[:space:]]*include(_if_exists)?([[:space:]]*=|[[:space:]])/) {
                    # Exempt the tune-managed include_if_exists, which points at
                    # the managed fragment (CONFIG_TARGET). On Debian tune writes
                    # that include into the root postgresql.conf; the fragment
                    # holds only the documentdb GUCs (no port /
                    # unix_socket_directories, no nested includes), so it does not
                    # affect resolution and flagging it would break idempotency
                    # on every rerun. Any OTHER include / include_if_exists is
                    # unresolved and fails closed.
                    v = $0
                    sub(/^[[:space:]]*/, "", v)
                    sub(/^[A-Za-z_]+/, "", v)                     # drop the directive name (include / include_if_exists, any case)
                    sub(/^[[:space:]]*=?[[:space:]]*/, "", v)     # drop the optional "=" and whitespace
                    if (v ~ /^\047/) { if (match(v, /^\047[^\047]*\047/)) v = substr(v, RSTART + 1, RLENGTH - 2) }
                    else if (v ~ /^"/) { if (match(v, /^"[^"]*"/)) v = substr(v, RSTART + 1, RLENGTH - 2) }
                    else { sub(/[[:space:]#].*$/, "", v) }        # unquoted: strip trailing whitespace/comment
                    gsub(/[[:space:]]+$/, "", v)
                    if (mgmt_frag != "" && v == mgmt_frag) { line_is_exempt = 1 } else { bad = 1 }
                } else if (l ~ /^[[:space:]]*include_dir([[:space:]]*=|[[:space:]])/) {
                    # Extract the include_dir value and exempt ONLY the standard
                    # Debian conf.d directory, and ONLY when this is the root
                    # postgresql.conf we walk conf.d for (exempt_confd). A
                    # substring test would wrongly exempt e.g. "conf.d2"; the
                    # value is a filesystem path, so compare it case-sensitively.
                    v = $0
                    sub(/^[[:space:]]*/, "", v)
                    v = substr(v, length("include_dir") + 1)     # drop the directive name (any case)
                    sub(/^[[:space:]]*=?[[:space:]]*/, "", v)     # drop the optional "=" and whitespace
                    if (v ~ /^\047/) { if (match(v, /^\047[^\047]*\047/)) v = substr(v, RSTART + 1, RLENGTH - 2) }
                    else if (v ~ /^"/) { if (match(v, /^"[^"]*"/)) v = substr(v, RSTART + 1, RLENGTH - 2) }
                    else { sub(/[[:space:]#].*$/, "", v) }        # unquoted: strip trailing whitespace/comment
                    gsub(/[[:space:]]+$/, "", v)
                    sub(/\/+$/, "", v)                            # tolerate a trailing slash
                    if (exempt_confd == 1 && v == "conf.d") { confd_ok = 1; line_is_exempt = 1 } else { bad = 1 }
                }
                # Any ACTIVE (non-comment, non-blank) line AFTER the exempted
                # conf.d include that is NOT itself exempt (the conf.d include or
                # the tune-managed include) means PostgreSQL — which reads conf.d
                # INLINE and then continues this root file — would apply a root
                # assignment that overrides conf.d, an ordering the whole-root-
                # then-conf.d resolver does not model. Fail closed. The tune-
                # managed include_if_exists is exempt because on Debian it is
                # appended AFTER conf.d yet only pulls in the documentdb fragment
                # (no port / unix_socket_directories / nested include), so it does
                # not change resolution; flagging it would break idempotency on
                # every rerun. Standard Debian has include_dir as the last active
                # line, so this never fires there.
                if (confd_ok && $0 !~ /^[[:space:]]*$/ && !line_is_exempt) {
                    if (scan_mode == "preload") {
                        # The connection route is pinned by --socket-dir/--port,
                        # so a benign trailing GUC (e.g. work_mem) after conf.d
                        # is harmless. Only a shared_preload_libraries /
                        # data_directory assignment after the conf.d include
                        # actually mis-orders the ordered fold tune performs, so
                        # flag just those; everything else may proceed.
                        if (l ~ /^[[:space:]]*shared_preload_libraries([[:space:]]*=|[[:space:]])/ ||
                            l ~ /^[[:space:]]*data_directory([[:space:]]*=|[[:space:]])/) { bad = 1 }
                    } else {
                        bad = 1
                    }
                }
            }
            END { exit(bad ? 0 : 1) }
        ' "${f}"; then
            return 0
        fi
    done < <(_effective_config_files)
    return 1
}

# resolve_localhost_connection: print "host=<socketdir> port=<port>" for the
# target instance. The extension makes its internal/admin libpq connections
# using documentdb.localhost_connection_string; without a socket host it
# defaults to host=localhost (TCP) and, with the packaged SCRAM pg_hba, fails
# every internal query with "fe_sendauth: no password supplied". Routing it at
# the Unix socket lets those connections use peer/local auth (no password). The
# socket dir and port are RESOLVED (read), NOT set — tune never changes the
# instance's own listen settings, so a brownfield tune cannot clobber the
# operator's port/socket choice. Explicit --socket-dir/--port (passed by
# documentdb-setup for the greenfield private cluster) win; otherwise read the
# effective values from the target config (including postgresql.auto.conf),
# defaulting to the distro socket dir and port 5432.
resolve_localhost_connection() {
    printf 'host=%s port=%s' "$(_resolve_effective_socket_dir)" "$(_resolve_effective_port)"
}

# _resolve_effective_port / _resolve_effective_socket_dir: the individual reads
# behind resolve_localhost_connection. Kept separate so enforce_localhost_conn_safe
# can validate the resolved values at the top level — a resolved socket dir
# containing whitespace, a single quote, or a backslash cannot be safely embedded
# in the single-quoted libpq connection string ('host=<dir> port=<port>'), so we
# fail closed there.
_resolve_effective_port() {
    local port="${PG_PORT_OVERRIDE}"
    if [[ -z "${port}" ]]; then
        port="$(_read_effective_scalar_guc 'port')"
        [[ -n "${port}" ]] || port="5432"
    fi
    printf '%s' "${port}"
}

_resolve_effective_socket_dir() {
    local sock="${SOCKET_DIR_OVERRIDE}"
    if [[ -z "${sock}" ]]; then
        sock="$(_read_effective_scalar_guc 'unix_socket_directories')"
        # unix_socket_directories may be a comma-separated list; take the first.
        sock="${sock%%,*}"
        sock="$(strip_wrapping_quotes "$(trim_whitespace "${sock}")")"
        if [[ -z "${sock}" ]]; then
            # No socket dir declared: use the distro's compiled default —
            # /var/run/postgresql on Debian/Ubuntu, /run/postgresql on RHEL/PGDG
            # (verified: PG18 `postgres -C unix_socket_directories` reports
            # "/run/postgresql, /tmp" on Rocky 9). Both are the same directory on
            # usr-merged systems, but matching each distro's canonical value
            # avoids relying on the /var/run -> /run symlink.
            if [[ "${IS_DEBIAN}" == "true" ]]; then
                sock="/var/run/postgresql"
            else
                sock="/run/postgresql"
            fi
        fi
    fi
    printf '%s' "${sock}"
}

fold_in_debian_live_preload() {
    local current="$1"
    if [[ "${IS_DEBIAN}" != "true" || -n "${PGDATA}" ]]; then
        printf '%s' "${current}"
        return 0
    fi

    local -a ordered=()
    local f
    while IFS= read -r f; do
        ordered+=("${f}")
    done < <(_debian_live_config_files)

    # Last assignment wins across the ordered sources.
    local effective="" src
    for src in "${ordered[@]+"${ordered[@]}"}"; do
        if _spl_assigned_in_file "${src}"; then
            effective="$(read_shared_preload_libraries_from_file "${src}")"
        fi
    done

    printf '%s' "${effective}"
}

# Resolve the cluster's postgresql.auto.conf path. On the Debian split-layout it
# lives in the DATA dir (not the fragment dir), honoring an explicit
# data_directory declared in postgresql.conf. On the RHEL / --pgdata path the
# managed block is written into the data dir's postgresql.conf (CONFIG_TARGET),
# so auto.conf sits beside it. Empty when it cannot be resolved.
_cluster_autoconf_path() {
    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
        local data_dir="/var/lib/postgresql/${PG_VERSION}/${CLUSTER_NAME}"
        # data_directory may be declared in the live postgresql.conf OR a conf.d
        # drop-in (PostgreSQL reads both); resolve it with the same ordered,
        # last-wins walk used for shared_preload_libraries so the auto.conf path
        # tracks a redirected data directory instead of silently inspecting the
        # wrong postgresql.auto.conf (which would mask an override).
        local declared_dd
        declared_dd="$(_read_effective_scalar_guc_debian data_directory)"
        [[ -n "${declared_dd}" ]] && data_dir="${declared_dd}"
        printf '%s' "${data_dir}/postgresql.auto.conf"
        return 0
    fi
    [[ -n "${CONFIG_TARGET}" ]] || return 0
    printf '%s' "$(dirname "${CONFIG_TARGET}")/postgresql.auto.conf"
}

# _normalize_preload_lib <entry>: reduce a shared_preload_libraries entry to its
# bare library name for comparison — drop any directory or $libdir/ prefix and a
# trailing shared-object suffix — so "$libdir/pg_cron", "pg_cron.so", and
# "pg_cron" all compare equal. PostgreSQL accepts all three forms and loads the
# same library, so treating the qualified forms as "present" avoids a
# false-positive failure below.
_normalize_preload_lib() {
    local lib="$1"
    lib="${lib##*/}"
    lib="${lib%.so}"
    lib="${lib%.dylib}"
    lib="${lib%.dll}"
    printf '%s' "${lib}"
}

# postgresql.auto.conf (ALTER SYSTEM) is read LAST — after the managed fragment
# / managed block — so if it declares shared_preload_libraries it overrides our
# settings. When that override is MISSING a required documentdb library the
# managed config is ineffective and the extension will not load, so exiting 0
# would report a success-shaped broken state to automation. Fail (mode=die, the
# apply path) unless the auto.conf value already contains every required
# library; a preview (mode=warn, --dry-run) warns instead. A no-op when
# auto.conf does not set shared_preload_libraries or already includes all
# required libraries.
enforce_autoconf_preload_not_overriding() {
    local mode="$1"
    local autoconf
    autoconf="$(_cluster_autoconf_path)"
    [[ -n "${autoconf}" ]] || return 0
    _spl_assigned_in_file "${autoconf}" || return 0

    local -a required=("pg_cron" "pg_documentdb_core" "pg_documentdb")
    [[ "${HAS_EXTENDED_RUM}" == "true" ]] && required+=("pg_documentdb_extended_rum")

    local auto_val
    auto_val="$(strip_wrapping_quotes "$(read_shared_preload_libraries_from_file "${autoconf}")")"
    local -a auto_items=()
    IFS=',' read -r -a auto_items <<< "${auto_val}"
    local i
    for i in "${!auto_items[@]}"; do
        auto_items[i]="$(_normalize_preload_lib "$(trim_whitespace "${auto_items[i]}")")"
    done

    local lib missing=""
    for lib in "${required[@]}"; do
        array_contains "${lib}" "${auto_items[@]+"${auto_items[@]}"}" \
            || missing+="${missing:+, }${lib}"
    done
    [[ -n "${missing}" ]] || return 0

    # Suggest a corrected value without a stray leading comma when auto.conf
    # currently clears the setting (auto_val empty).
    local suggested="${auto_val:+${auto_val}, }${missing}"
    local msg="shared_preload_libraries is set in ${autoconf} (via ALTER SYSTEM) and is missing required documentdb libraries: ${missing}. PostgreSQL reads postgresql.auto.conf last, so it overrides the managed documentdb fragment and the documentdb extension will NOT load. Add the documentdb libraries to that setting (ALTER SYSTEM SET shared_preload_libraries = '${suggested}';) or clear it (ALTER SYSTEM RESET shared_preload_libraries;), then restart PostgreSQL."
    if [[ "${mode}" == "die" ]]; then
        die "${msg}"
    else
        echo "[${PROG}] WARNING: ${msg}" >&2
    fi
}

# enforce_unix_sockets_enabled <die|warn>: documentdb routes the extension's
# internal libpq connections over the Unix socket (peer/local auth, no
# password). If Unix sockets are turned OFF (unix_socket_directories = ''), no
# such socket exists and every internal connection would fail, so refuse to emit
# a route to a socket dir PostgreSQL is not listening on: die on apply, warn on
# --dry-run / --print. Skipped when --socket-dir is supplied (that explicit path
# wins over the disabled config). Mirrors enforce_autoconf_preload_not_overriding
# and, like it, runs at the top level so die actually stops the script (a die
# inside the resolve_localhost_connection command substitution would only exit
# the subshell).
enforce_unix_sockets_enabled() {
    local mode="$1"
    [[ -z "${SOCKET_DIR_OVERRIDE}" ]] || return 0
    _unix_socket_dirs_disabled || return 0
    local msg="unix_socket_directories is set empty (Unix sockets are disabled); documentdb requires a local Unix socket for passwordless peer authentication. Set unix_socket_directories to a path (or pass --socket-dir) and retry."
    if [[ "${mode}" == "die" ]]; then
        die "${msg}"
    else
        echo "[${PROG}] WARNING: ${msg}" >&2
    fi
}

# enforce_config_includes_resolved <die|warn>: the port/socket resolver reads
# only postgresql.conf, the Debian conf.d directory, and postgresql.auto.conf.
# If the config pulls in other files via include/include_if_exists/include_dir,
# a port or unix_socket_directories set there is missed and the emitted
# localhost route (and the disabled-socket check) could be wrong. Refuse to
# guess: die on apply, warn on --dry-run / --print. When BOTH --socket-dir and
# --port are supplied the connection route no longer depends on the config, so
# the --pgdata / RHEL path is skipped entirely (documentdb-setup's greenfield
# path); the Debian split-layout instead runs a NARROWED scan (scan_mode=preload)
# that still guards tune's own ordered shared_preload_libraries fold and
# data_directory resolution — a benign trailing GUC after conf.d is allowed, but
# a foreign include, or a shared_preload_libraries / data_directory assignment
# after conf.d, still fails closed. documentdb-setup's brownfield path passes
# both overrides on the adopted (possibly split-layout) cluster, so this is what
# lets an adopted config with ordinary trailing tuning through while keeping the
# preload/data_directory protection. Runs at the top level so die actually stops
# the script.
enforce_config_includes_resolved() {
    local mode="$1"
    local scan_mode="full"
    if [[ -n "${SOCKET_DIR_OVERRIDE}" && -n "${PG_PORT_OVERRIDE}" ]]; then
        # Overrides pin the port/socket route, so tune never resolves the
        # connection from the config. On the --pgdata / RHEL path that fully
        # settles it: shared_preload_libraries is read from the single target
        # file (no ordered conf.d walk) and data_directory is not re-resolved,
        # so there is no include-ORDER hazard for tune's own writes — skip
        # entirely (the deferred hand-edited --pgdata include case is design
        # row m). Only the Debian split-layout folds shared_preload_libraries /
        # data_directory with an ordered root-then-conf.d walk, so keep guarding
        # THOSE against include-order mis-modeling even with the overrides.
        [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]] || return 0
        scan_mode="preload"
    fi
    _config_declares_unhandled_include "${scan_mode}" || return 0
    local msg
    if [[ "${scan_mode}" == "preload" ]]; then
        msg="the target PostgreSQL config declares an include/include_if_exists/include_dir directive, or sets shared_preload_libraries / data_directory after its conf.d include, whose PostgreSQL read order documentdb-tune does not model — so the shared_preload_libraries and data_directory it folds into the managed fragment could be resolved from the wrong precedence. Move that assignment into a conf.d drop-in (or above the conf.d include), or fold the extra include into conf.d, then retry."
    else
        msg="the target PostgreSQL config uses include/include_if_exists/include_dir directives (or has settings after its conf.d include) whose PostgreSQL read order documentdb-tune does not model, so the effective port and unix_socket_directories cannot be resolved reliably from it. Pass --socket-dir and --port explicitly so documentdb.localhost_connection_string routes the extension's internal connections correctly."
    fi
    if [[ "${mode}" == "die" ]]; then
        die "${msg}"
    else
        echo "[${PROG}] WARNING: ${msg}" >&2
    fi
}

# enforce_localhost_conn_safe <die|warn>: documentdb.localhost_connection_string
# is emitted as a single-quoted PostgreSQL GUC wrapping a libpq connection string
# ('host=<dir> port=<port>'). Three resolved-socket-dir characters cannot be
# represented safely and are rejected (verified against libpq/psql):
#   - whitespace:   splits the conninfo (host=/tmp/pg socket -> missing "=" after "socket")
#   - backslash:    libpq treats it as an escape, silently corrupting the path
#                   (host=/tmp/a\b connects to /tmp/ab)
#   - single quote: terminates the outer single-quoted GUC value
# A double quote is fine (libpq accepts it in a host value) and is allowed.
# --socket-dir/--port overrides are validated at parse time against the same set,
# so this only fires for values RESOLVED from the cluster config. Refuse to emit a
# malformed route (die on apply, warn on --print/--dry-run) and point the operator
# at --socket-dir. Runs at the top level so die stops the script.
enforce_localhost_conn_safe() {
    local mode="$1" sock port problem=""
    sock="$(_resolve_effective_socket_dir)"
    port="$(_resolve_effective_port)"
    # shellcheck disable=SC1003  # *'\'* matches a literal backslash in the resolved socket dir; not a single-quote escape
    if [[ "${sock}" == *[[:space:]]* || "${sock}" == *"'"* || "${sock}" == *'\'* ]]; then
        problem="the resolved Unix socket directory (${sock}) contains whitespace, a single quote, or a backslash, which cannot be safely represented in the libpq connection string"
    elif [[ ! "${port}" =~ ^[0-9]+$ ]]; then
        problem="the resolved port (${port}) is not numeric"
    fi
    [[ -n "${problem}" ]] || return 0
    local msg="${problem}; documentdb.localhost_connection_string would be malformed. Pass --socket-dir and --port explicitly (socket paths with spaces or quotes are not supported)."
    if [[ "${mode}" == "die" ]]; then
        die "${msg}"
    else
        echo "[${PROG}] WARNING: ${msg}" >&2
    fi
}

# read_current_shared_preload_libraries: the seed value for
# merge_shared_preload_libraries, read from the operator's config WITHOUT the
# tool's own managed block folded back in.
#
# On the Debian standalone-fragment path CONFIG_TARGET is our own fragment;
# fold_in_debian_live_preload discards that value in favor of the operator's live
# sources, so reading the fragment directly here is harmless (the value is
# ignored downstream).
#
# On the RHEL / --pgdata path CONFIG_TARGET is the live postgresql.conf that ALSO
# holds our managed block. read_shared_preload_libraries_from_file returns the
# LAST (winning) shared_preload_libraries assignment, which is our managed block's
# own value — so reading the file as-is feeds our previous output back into the
# merge. That resurrects a library the operator has since removed and makes a
# re-apply falsely report "already up to date" (the block becomes a fixpoint that
# can never shrink — e.g. it cannot drop pg_documentdb_extended_rum after a move
# to a PostgreSQL major that no longer needs it). Strip our managed block first so
# only the operator's own value is read, mirroring the Debian path's
# operator-live-value-only seeding. strip_managed_block returns the file verbatim
# when no managed block is present, so this is also correct on the first apply,
# and fails closed on a torn/unbalanced block (its die propagates through the
# pipeline under `set -o pipefail`). The stripped text is streamed straight into
# the parser so read-only callers (--print / --dry-run) never write a temp file.
read_current_shared_preload_libraries() {
    [[ -f "${CONFIG_TARGET}" ]] || return 0
    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
        read_shared_preload_libraries_from_file "${CONFIG_TARGET}"
        return 0
    fi
    strip_managed_block "${CONFIG_TARGET}" \
        "${MANAGED_BLOCK_START}" "${MANAGED_BLOCK_END}" \
        | read_shared_preload_libraries_from_stdin
}

do_print() {
    local current_preload="" merged_preload="" block=""

    if [[ -n "${CONFIG_TARGET}" && -f "${CONFIG_TARGET}" ]]; then
        current_preload="$(read_current_shared_preload_libraries)"
    fi

    current_preload="$(fold_in_debian_live_preload "${current_preload}")"
    merged_preload="$(merge_shared_preload_libraries "${current_preload}")"
    block="$(build_config_block "${merged_preload}")"

    enforce_config_includes_resolved warn
    enforce_unix_sockets_enabled warn
    enforce_localhost_conn_safe warn

    printf '%s\n' "${MANAGED_BLOCK_START}"
    printf '%s\n' "${block}"
    printf '%s\n' "${MANAGED_BLOCK_END}"
}

do_apply() {
    local current_preload="" merged_preload="" block=""
    local existing_block=""

    if [[ -f "${CONFIG_TARGET}" ]]; then
        current_preload="$(read_current_shared_preload_libraries)"
    fi

    current_preload="$(fold_in_debian_live_preload "${current_preload}")"
    merged_preload="$(merge_shared_preload_libraries "${current_preload}")"
    block="$(build_config_block "${merged_preload}")"

    # If postgresql.auto.conf (ALTER SYSTEM) overrides shared_preload_libraries
    # away from the required documentdb libraries, the fragment we are about to
    # write is ineffective — fail on apply rather than report a broken success;
    # a --dry-run preview only warns.
    if [[ "${DRY_RUN}" == "true" ]]; then
        enforce_autoconf_preload_not_overriding warn
        enforce_config_includes_resolved warn
        enforce_unix_sockets_enabled warn
        enforce_localhost_conn_safe warn
    else
        enforce_autoconf_preload_not_overriding die
        enforce_config_includes_resolved die
        enforce_unix_sockets_enabled die
        enforce_localhost_conn_safe die
    fi

    if [[ -f "${CONFIG_TARGET}" ]]; then
        local fragment_is_current=false
        if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
            # Debian writes the fragment as the raw block (no managed markers,
            # see the Debian branch below), so compare the whole file content.
            [[ "$(cat "${CONFIG_TARGET}")" == "${block}" ]] && fragment_is_current=true
        else
            # RHEL / --pgdata: the block lives between managed markers in the
            # target config. Fail closed on an unbalanced block before the
            # idempotency short-circuit so a torn block (e.g. the end marker
            # deleted at EOF) is reported rather than silently accepted as
            # "already up to date".
            assert_managed_markers_balanced "${CONFIG_TARGET}" \
                "${MANAGED_BLOCK_START}" "${MANAGED_BLOCK_END}"
            existing_block="$(extract_managed_block_content "${CONFIG_TARGET}" "${MANAGED_BLOCK_START}" "${MANAGED_BLOCK_END}")"
            [[ "${existing_block}" == "${block}" ]] && fragment_is_current=true
        fi
        if [[ "${fragment_is_current}" == "true" ]]; then
            # On Debian a cluster created before the createcluster.d hook can
            # have an up-to-date fragment while its live postgresql.conf is
            # missing the include_if_exists line, silently leaving the tuning
            # unused. In that one case fall through to the normal apply path so
            # the include line is added with the same confirmation, backup, and
            # restart guidance as a fresh write; otherwise there is nothing to do.
            if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]] && ! debian_include_line_satisfied; then
                log_verbose "Fragment is current but the live postgresql.conf is missing the include line; applying to add it."
            else
                log "Config is already up to date: ${CONFIG_TARGET}"
                return 0
            fi
        fi
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Would write managed block to ${CONFIG_TARGET}:"
        printf '%s\n' "${MANAGED_BLOCK_START}"
        printf '%s\n' "${block}"
        printf '%s\n' "${MANAGED_BLOCK_END}"
        return 0
    fi

    if [[ "${YES}" != "true" ]]; then
        echo "${PROG}: about to write DocumentDB config to ${CONFIG_TARGET}"
        printf '%s\n' "${MANAGED_BLOCK_START}"
        printf '%s\n' "${block}"
        printf '%s\n' "${MANAGED_BLOCK_END}"
        if [[ -t 0 ]]; then
            local answer=""
            read -r -p "Proceed? [y/N] " answer || true
            case "${answer}" in
                y|Y|yes|YES) ;;
                *) log "Aborted."; exit 0 ;;
            esac
        else
            die "Non-interactive run requires --yes (refusing to write ${CONFIG_TARGET} without confirmation)."
        fi
    fi

    # Ensure parent directory exists (Debian per-cluster path)
    local parent_dir
    parent_dir="$(dirname "${CONFIG_TARGET}")"
    if [[ ! -d "${parent_dir}" ]]; then
        install -d -m 0755 "${parent_dir}"
    fi

    # Safety: check for foreign markers and back up before writing
    check_foreign_markers "${CONFIG_TARGET}"
    backup_file "${CONFIG_TARGET}"

    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
        # Debian: write the entire per-instance file (not a managed block
        # inside an existing postgresql.conf); the createcluster.d hook
        # brings it in via include_if_exists. For instances that pre-date
        # the hook, we also add the include line to the live cluster's
        # postgresql.conf so the fragment is actually picked up rather
        # than silently ignored.
        # Write atomically: render to a temp file in the same directory, then
        # rename into place, so a crash mid-write cannot leave PostgreSQL
        # reading a truncated include fragment on the next restart/reload.
        local _df_tmp
        create_temp_in_dir _df_tmp "$(dirname "${CONFIG_TARGET}")"
        printf '%s\n' "${block}" > "${_df_tmp}"
        chmod 0644 "${_df_tmp}"
        mv "${_df_tmp}" "${CONFIG_TARGET}"
        ensure_debian_include_line
    else
        # RHEL or --pgdata: managed block inside the existing config file.
        if [[ ! -f "${CONFIG_TARGET}" ]]; then
            touch "${CONFIG_TARGET}"
        fi
        rewrite_with_managed_block "${CONFIG_TARGET}" \
            "${MANAGED_BLOCK_START}" "${MANAGED_BLOCK_END}" "${block}"
    fi

    log "Config written to ${CONFIG_TARGET}"

    if [[ -n "${PG_VERSION}" ]]; then
        if has_working_systemd; then
            if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
                log "Restart the cluster to apply: sudo systemctl restart postgresql@${PG_VERSION}-${CLUSTER_NAME}"
            else
                log "Restart PostgreSQL to apply the new settings (e.g. sudo systemctl restart postgresql-${PG_VERSION})."
            fi
        else
            # No systemd → fall back to pg_ctlcluster / pg_ctl
            if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
                log "Restart the cluster to apply (no systemd detected): sudo pg_ctlcluster ${PG_VERSION} ${CLUSTER_NAME} restart"
            elif [[ -n "${PGDATA}" ]]; then
                # PG bin layout differs between Debian (/usr/lib/postgresql/N/bin)
                # and RHEL family (/usr/pgsql-N/bin). Probe the shared candidate
                # list (Debian-then-RHEL) and fall back to a generic hint if
                # neither is on disk.
                local pg_ctl_path=""
                while IFS= read -r candidate; do
                    if [[ -x "${candidate}/pg_ctl" ]]; then
                        pg_ctl_path="${candidate}/pg_ctl"
                        break
                    fi
                done < <(documentdb_pg_bindir_candidates "${PG_VERSION}")
                if [[ -n "${pg_ctl_path}" ]]; then
                    log "Restart PostgreSQL to apply (no systemd detected): sudo -u postgres ${pg_ctl_path} -D ${PGDATA} restart"
                else
                    log "Restart PostgreSQL to apply (no systemd detected): sudo -u postgres <pg_ctl> -D ${PGDATA} restart"
                fi
            else
                log "Restart PostgreSQL to apply the new settings (your distro's preferred command)."
            fi
        fi
    fi
}

do_restore() {
    # Strip the managed include line from the live Debian postgresql.conf
    # first (no-op if absent / not on Debian / not on an existing cluster).
    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" && -n "${DEBIAN_LIVE_PG_CONF}" && -f "${DEBIAN_LIVE_PG_CONF}" ]]; then
        local include_marker_start="# >>> documentdb-tune managed include >>>"
        local include_marker_end="# <<< documentdb-tune managed include <<<"
        if grep -Fqx "${include_marker_start}" "${DEBIAN_LIVE_PG_CONF}" 2>/dev/null; then
            if [[ "${DRY_RUN}" == "true" ]]; then
                log "[dry-run] would strip managed include block from ${DEBIAN_LIVE_PG_CONF}."
            else
                rewrite_with_managed_block "${DEBIAN_LIVE_PG_CONF}" \
                    "${include_marker_start}" "${include_marker_end}" ""
                log "Managed include block stripped from ${DEBIAN_LIVE_PG_CONF}"
            fi
        fi
    fi

    if [[ ! -f "${CONFIG_TARGET}" ]]; then
        log "Nothing to restore (${CONFIG_TARGET} does not exist)."
        return 0
    fi

    if [[ "${DRY_RUN}" == "true" ]]; then
        log "Would remove managed block from ${CONFIG_TARGET}."
        return 0
    fi

    if [[ "${IS_DEBIAN}" == "true" && -z "${PGDATA}" ]]; then
        # Debian per-instance file: remove the file entirely.
        rm -f "${CONFIG_TARGET}"
        local parent_dir
        parent_dir="$(dirname "${CONFIG_TARGET}")"
        rmdir --ignore-fail-on-non-empty "${parent_dir}" 2>/dev/null || true
        log "Removed ${CONFIG_TARGET}"
    else
        rewrite_with_managed_block "${CONFIG_TARGET}" \
            "${MANAGED_BLOCK_START}" "${MANAGED_BLOCK_END}" ""
        log "Managed block removed from ${CONFIG_TARGET}"
    fi
}

# ── Argument parsing ────────────────────────────────────────────────

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --pg-version)
                [[ $# -ge 2 ]] || die "--pg-version requires a value."
                PG_VERSION="$2"; shift 2 ;;
            --cluster)
                [[ $# -ge 2 ]] || die "--cluster requires a value."
                CLUSTER_NAME="$2"; shift 2 ;;
            --pgdata)
                [[ $# -ge 2 ]] || die "--pgdata requires a value."
                PGDATA="$2"; shift 2 ;;
            --socket-dir)
                [[ $# -ge 2 ]] || die "--socket-dir requires a value."
                [[ -n "$2" ]] || die "--socket-dir must not be empty."
                [[ "$2" == /* ]] || die "--socket-dir must be an absolute path."
                # shellcheck disable=SC1003  # *'\'* matches a literal backslash in --socket-dir; not a single-quote escape
                if [[ "$2" == *"'"* || "$2" == *'\'* || "$2" =~ [[:space:]] ]]; then
                    die "--socket-dir must not contain single quotes, backslashes, or whitespace."
                fi
                SOCKET_DIR_OVERRIDE="$2"; shift 2 ;;
            --port)
                [[ $# -ge 2 ]] || die "--port requires a value."
                [[ "$2" =~ ^[0-9]+$ ]] || die "--port must be a positive integer."
                # 10# forces base-10 so a leading-zero value isn't read as octal.
                if (( 10#$2 < 1 || 10#$2 > 65535 )); then
                    die "--port must be between 1 and 65535 (got '$2')."
                fi
                PG_PORT_OVERRIDE="$2"; shift 2 ;;
            --toast-compression)
                [[ $# -ge 2 ]] || die "--toast-compression requires a value."
                case "$2" in
                    lz4|pglz|default) ;;
                    *) die "--toast-compression must be 'lz4', 'pglz', or 'default' (got '$2')." ;;
                esac
                TOAST_COMPRESSION_REQUESTED="$2"; shift 2 ;;
            --yes) YES=true; shift ;;
            --dry-run) DRY_RUN=true; shift ;;
            --restore) ACTION="restore"; shift ;;
            --print) ACTION="print"; shift ;;
            --verbose) VERBOSE=true; shift ;;
            -h|--help) usage; exit 0 ;;
            *) die "Unknown argument: $1" ;;
        esac
    done

    # Validate
    if [[ -z "${PGDATA}" ]]; then
        if [[ -z "${PG_VERSION}" ]]; then
            if [[ "${ACTION}" == "print" || "${ACTION}" == "apply" || "${ACTION}" == "restore" ]]; then
                die "--pg-version is required (or use --pgdata). Run 'documentdb-tune --help' for usage."
            fi
        fi
        [[ -n "${PG_VERSION}" ]] || { usage; exit 1; }
        [[ "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "--pg-version must be a positive integer."
        [[ -z "${CLUSTER_NAME}" ]] && CLUSTER_NAME="main"
        # Validate the cluster name before it is interpolated into managed
        # file paths (/etc/postgresql-common/documentdb/<V>/<C>/...). Without
        # this a value like '../../..' would allow path traversal. Mirrors
        # the validation in documentdb-register-gateway.sh.
        [[ "${CLUSTER_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "Invalid --cluster '${CLUSTER_NAME}'. Only alphanumerics, hyphens, and underscores are allowed, and the name must not start with a hyphen."
    fi

    # Warn if --cluster is given on RHEL where it has no effect
    if [[ -n "${CLUSTER_NAME}" && "${CLUSTER_NAME}" != "main" ]]; then
        detect_distro
        if [[ "${IS_DEBIAN}" != "true" ]]; then
            log "WARNING: --cluster '${CLUSTER_NAME}' is ignored on RHEL/Fedora (only Debian/Ubuntu uses named clusters). Using default PGDATA path."
        fi
    fi
}

# ── Main ────────────────────────────────────────────────────────────

main() {
    parse_arguments "$@"
    detect_distro

    # Resolve (and, for a mistyped apply --pgdata, reject) the target first
    # so the fabrication guard's die is the only message a typo produces.
    resolve_config_target

    # --pgdata without --pg-version: derive the major from the data dir's
    # PG_VERSION file (PostgreSQL's standard cluster-version marker written by
    # initdb) so extended-RUM detection below still runs. Previously the
    # detection was silently skipped in this mode, so a cluster with
    # documentdb_extended_rum installed was tuned without the RUM GUCs.
    # --restore never consults RUM state, so skip the derivation (and its
    # warning) there.
    if [[ "${ACTION}" != "restore" && -z "${PG_VERSION}" && -n "${PGDATA}" ]]; then
        local derived_pg_version=""
        if [[ -r "${PGDATA}/PG_VERSION" ]]; then
            derived_pg_version="$(head -n 1 "${PGDATA}/PG_VERSION" 2>/dev/null | tr -d '[:space:]' || true)"
        fi
        if [[ "${derived_pg_version}" =~ ^[0-9]+$ ]]; then
            PG_VERSION="${derived_pg_version}"
            log_verbose "Derived PostgreSQL major ${PG_VERSION} from ${PGDATA}/PG_VERSION."
        else
            echo "[${PROG}] WARNING: cannot read a numeric PostgreSQL major from ${PGDATA}/PG_VERSION; extended-RUM detection is skipped (pass --pg-version to enable it)." >&2
        fi
    fi

    if [[ -n "${PG_VERSION}" ]]; then
        resolve_pg_sharedir
        documentdb_detect_extended_rum "${PG_SHAREDIR}"
    fi

    # --restore only strips the managed block, so it never needs a value here.
    if [[ "${ACTION}" != "restore" ]]; then
        documentdb_resolve_toast_compression "${TOAST_COMPRESSION_REQUESTED}" "${PG_VERSION}"
    fi

    case "${ACTION}" in
        print)   do_print ;;
        apply)
            # Require root when writing to system paths, but allow non-root
            # for --pgdata (operator-controlled paths, dev/test).
            if [[ "$(id -u)" -ne 0 && -z "${PGDATA}" ]]; then
                die "Must be run as root (use sudo) to apply changes to system clusters."
            fi
            do_apply ;;
        restore)
            if [[ "$(id -u)" -ne 0 && -z "${PGDATA}" ]]; then
                die "Must be run as root (use sudo) to restore changes to system clusters."
            fi
            do_restore ;;
    esac
}

main "$@"
