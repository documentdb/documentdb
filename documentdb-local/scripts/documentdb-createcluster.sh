#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-createcluster — Debian/Ubuntu helper that wraps pg_createcluster
# and documentdb-tune to create a DocumentDB-ready PostgreSQL cluster in one
# step.
#
# Usage:
#  documentdb-createcluster N C [--start]
#
# Example (the cluster must not exist yet: pg_createcluster refuses a name
# that is taken, including the "main" the postgresql-N package creates):
#  documentdb-createcluster 17 docdb --start

set -euo pipefail

readonly PROG="documentdb-createcluster"

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }
# stderr: resolve_extra_extension's stdout is captured by command substitution.
warn() { echo "[${PROG}] WARNING: $*" >&2; }

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

usage() {
    cat <<'EOF'
Usage: documentdb-createcluster VERSION CLUSTER [OPTIONS]

Create a PostgreSQL cluster tuned for DocumentDB. Debian/Ubuntu only.

Arguments:
  VERSION    PostgreSQL major version (e.g., 15, 16, 17, 18)
  CLUSTER    Cluster name (e.g., "main")

Options:
  --start    Start the cluster after creating and tuning it, then create the
             DocumentDB extensions in the "postgres" database
  -h, --help Show this help message
EOF
}

# ── Help / usage ────────────────────────────────────────────────────
# Handle help and the no-arguments case BEFORE the environment guards below,
# so that `documentdb-createcluster --help` (and a bare invocation) work on
# every platform — including RHEL, where pg_createcluster is intentionally
# absent and the guard would otherwise abort before usage is ever shown.

if [[ $# -lt 1 ]]; then
    usage
    exit 1
fi

case "$1" in
    -h|--help) usage; exit 0 ;;
esac

# ── Guard: Debian/Ubuntu only ───────────────────────────────────────

if ! command -v pg_createcluster >/dev/null 2>&1; then
    die "pg_createcluster is not available. This tool is for Debian/Ubuntu only. On RHEL, use 'postgresql-N-setup --initdb' followed by 'documentdb-tune --pg-version N --pgdata /var/lib/pgsql/N/data --yes'."
fi

if ! command -v documentdb-tune >/dev/null 2>&1; then
    die "documentdb-tune is not installed. Install the documentdb-postgresql-tools package first."
fi

# Sourced after the help handling and platform guards above so --help and the
# "Debian/Ubuntu only" diagnostic still work when the library is absent.
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

# ── Argument parsing ────────────────────────────────────────────────

PG_VERSION=""
CLUSTER_NAME=""
START=false

[[ $# -ge 2 ]] || die "Both VERSION and CLUSTER arguments are required."

PG_VERSION="$1"
CLUSTER_NAME="$2"
shift 2

while [[ $# -gt 0 ]]; do
    case "$1" in
        --start) START=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "VERSION must be a positive integer."
[[ -n "${CLUSTER_NAME}" ]] || die "CLUSTER name must not be empty."
# Validate before passing to pg_createcluster and documentdb-tune (which
# interpolates it into managed config paths). Restricts to safe characters.
[[ "${CLUSTER_NAME}" =~ ^[A-Za-z0-9][A-Za-z0-9_-]*$ ]] || die "Invalid CLUSTER name '${CLUSTER_NAME}'. Only alphanumerics, hyphens, and underscores are allowed, and the name must not start with a hyphen."

# Only --start needs psql. Guarded after parsing (so START is known) and before
# pg_createcluster (so it fails before creating anything).
if [[ "${START}" == "true" ]] && ! command -v psql >/dev/null 2>&1; then
    die "psql is not available, but --start needs it to create the DocumentDB extensions. Install the PostgreSQL client package (e.g. apt install postgresql-client-${PG_VERSION}), or re-run without --start and create the extensions manually."
fi

# ── Main ────────────────────────────────────────────────────────────

log "Creating PostgreSQL ${PG_VERSION} cluster '${CLUSTER_NAME}'."
pg_createcluster "${PG_VERSION}" "${CLUSTER_NAME}" -- \
    --auth-local=peer \
    --auth-host=scram-sha-256 \
    --encoding=UTF8

log "Tuning cluster for DocumentDB."
# --no-next-steps: this script owns the guidance, in an order that accounts for
# the cluster not being started yet. Tune's own copy lands here, above
# "Start with: ...", pointing at a cluster that is still stopped.
documentdb-tune --pg-version "${PG_VERSION}" --cluster "${CLUSTER_NAME}" --yes --no-next-steps

# Echo the extra extension this host needs, or nothing. Uses the same probe
# documentdb-tune used to pin documentdb.alternate_index_handler_name, so the
# two cannot disagree — and a tuned cluster missing documentdb_extended_rum
# cannot build a new index.
resolve_extra_extension() {
    local sharedir=""

    # Fail OPEN, deliberately: documentdb-tune's resolve_pg_sharedir swallows
    # the identical failure and therefore does not pin the handler, so the
    # cluster we just tuned does not demand extended_rum either. Skipping the
    # extension is consistent, not a silent degradation, and dying here would
    # reject hosts tune handles fine.
    #
    # Invariant: this probe and tune's must agree on any given host.
    if ! sharedir="$(documentdb_pg_sharedir "${PG_VERSION}")"; then
        warn "could not read the PostgreSQL ${PG_VERSION} share directory; treating documentdb_extended_rum as not installed. documentdb-tune probes identically, so it did not pin an alternate index handler either — index creation will use the built-in handler."
        return 0
    fi

    documentdb_detect_extended_rum "${sharedir}"
    if [[ "${HAS_EXTENDED_RUM}" == "true" ]]; then
        printf 'documentdb_extended_rum'
    fi
    return 0
}

# The extension recipe for this cluster, indented two spaces, for embedding in
# guidance and recovery messages. --cluster resolves this cluster's binary,
# socket, and port, so nothing has to be guessed (pg_createcluster does not
# always pick 5432).
extension_recipe() {
    local line=""
    while IFS= read -r line; do
        printf '  %s\n' "${line}"
    done < <(documentdb_create_extension_advice postgres postgres "${EXTRA_EXTENSION}" \
                --cluster "${PG_VERSION}/${CLUSTER_NAME}")
}

create_documentdb_extensions() {
    local extra_extension="$1"

    log "Creating DocumentDB extensions in the 'postgres' database."
    if ! documentdb_create_extension_sql "${extra_extension}" \
            | run_as_user postgres psql --cluster "${PG_VERSION}/${CLUSTER_NAME}" \
                -d postgres -X -v ON_ERROR_STOP=1 -f -; then
        # The cluster is created, tuned, and running; only the DDL is missing,
        # and the statements are idempotent, so the retry is the recipe itself.
        die "failed to create the DocumentDB extensions in the 'postgres' database of cluster ${PG_VERSION}/${CLUSTER_NAME}.
The cluster is created, tuned, and running, so re-running documentdb-createcluster
will refuse it. Fix the error above, then run:
$(extension_recipe)"
    fi
}

EXTRA_EXTENSION="$(resolve_extra_extension)"

# Start and provision in one place, after both definitions above: the DDL needs
# a running server, and pg_documentdb_extended_rum loads only from
# shared_preload_libraries, i.e. only once the tuned cluster has started.
if [[ "${START}" == "true" ]]; then
    log "Starting cluster."
    if ! pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" start; then
        die "cluster ${PG_VERSION}/${CLUSTER_NAME} was created and tuned, but did not start.
Re-running documentdb-createcluster will refuse the existing cluster. Fix the
error above, then run:
  sudo pg_ctlcluster ${PG_VERSION} ${CLUSTER_NAME} start
$(extension_recipe)"
    fi
    create_documentdb_extensions "${EXTRA_EXTENSION}"
fi

log "Done. Cluster ${PG_VERSION}/${CLUSTER_NAME} is ready for DocumentDB."
if [[ "${START}" != "true" ]]; then
    # Order is why this lives here rather than in documentdb-tune:
    # pg_documentdb_extended_rum loads only from shared_preload_libraries, so
    # CREATE EXTENSION cannot run until the cluster is started.
    echo "Start with: sudo pg_ctlcluster ${PG_VERSION} ${CLUSTER_NAME} start"
    echo "Then create the DocumentDB extensions (required before an index can be built):"
    extension_recipe
fi
