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
# Example:
#  documentdb-createcluster 17 main --start

set -euo pipefail

readonly PROG="documentdb-createcluster"

die() { echo "${PROG}: error: $*" >&2; exit 1; }
log() { echo "[${PROG}] $*"; }

usage() {
    cat <<'EOF'
Usage: documentdb-createcluster VERSION CLUSTER [OPTIONS]

Create a PostgreSQL cluster tuned for DocumentDB. Debian/Ubuntu only.

Arguments:
  VERSION    PostgreSQL major version (e.g., 15, 16, 17, 18)
  CLUSTER    Cluster name (e.g., "main")

Options:
  --start    Start the cluster after creating and tuning it
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

# ── Main ────────────────────────────────────────────────────────────

log "Creating PostgreSQL ${PG_VERSION} cluster '${CLUSTER_NAME}'."
pg_createcluster "${PG_VERSION}" "${CLUSTER_NAME}" -- \
    --auth-local=peer \
    --auth-host=scram-sha-256 \
    --encoding=UTF8

log "Tuning cluster for DocumentDB."
documentdb-tune --pg-version "${PG_VERSION}" --cluster "${CLUSTER_NAME}" --yes

if [[ "${START}" == "true" ]]; then
    log "Starting cluster."
    pg_ctlcluster "${PG_VERSION}" "${CLUSTER_NAME}" start
fi

log "Done. Cluster ${PG_VERSION}/${CLUSTER_NAME} is ready for DocumentDB."
if [[ "${START}" != "true" ]]; then
    echo "Start with: sudo pg_ctlcluster ${PG_VERSION} ${CLUSTER_NAME} start"
fi
