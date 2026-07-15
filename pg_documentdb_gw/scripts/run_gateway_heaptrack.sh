#!/usr/bin/env bash
#
# Build the DocumentDB gateway with the `profiling` profile and run it under
# heaptrack for heap-allocation profiling.
#
set -euo pipefail

# Resolve the directory this script lives in so it works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# The gateway cargo workspace root is the parent of this scripts/ directory.
# Build and run from there so cargo resolves the workspace and its target dir.
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
MANIFEST_PATH="$WORKSPACE_ROOT/Cargo.toml"
if [[ ! -f "$MANIFEST_PATH" ]]; then
    echo "error: could not find gateway Cargo.toml at $MANIFEST_PATH" >&2
    exit 1
fi
cd "$WORKSPACE_ROOT"

BIN_NAME="documentdb_gateway"

# Resolve the workspace target directory (honors CARGO_TARGET_DIR / config
# overrides); fall back to the default <workspace>/target layout.
TARGET_DIR="$(cargo metadata --no-deps --format-version 1 --manifest-path "$MANIFEST_PATH" 2>/dev/null \
    | python3 -c 'import sys, json; print(json.load(sys.stdin)["target_directory"])' 2>/dev/null || true)"
if [[ -z "$TARGET_DIR" ]]; then
    TARGET_DIR="$WORKSPACE_ROOT/target"
fi
BIN_PATH="${TARGET_DIR}/profiling/${BIN_NAME}"

# Postgres user to connect as for this heaptrack run only. The gateway has no
# dedicated "user" env var; the only override hook is DOCUMENTDB_PG_URL_FILE,
# so we point it at a private file containing a connection URL that pins the
# user while keeping the gateway's default host/port/database.
PG_USER="docdb_admin"
PG_HOST="localhost"
PG_PORT="9712"
PG_DB="postgres"

if ! command -v heaptrack >/dev/null 2>&1; then
    echo "error: heaptrack is not installed or not on PATH" >&2
    exit 1
fi

# Create a private (0600) URL file and ensure it's cleaned up on exit.
PG_URL_FILE="$(mktemp "${TMPDIR:-/tmp}/documentdb_gw_pg_url.XXXXXX")"
chmod 600 "$PG_URL_FILE"
trap 'rm -f "$PG_URL_FILE"' EXIT
printf 'postgresql://%s@%s:%s/%s\n' "$PG_USER" "$PG_HOST" "$PG_PORT" "$PG_DB" > "$PG_URL_FILE"
export DOCUMENTDB_PG_URL_FILE="$PG_URL_FILE"

echo "==> Building ${BIN_NAME} with the 'profiling' profile..."
cargo build --profile profiling -p "${BIN_NAME}" --manifest-path "$MANIFEST_PATH"

if [[ ! -x "$BIN_PATH" ]]; then
    echo "error: built binary not found at $BIN_PATH" >&2
    exit 1
fi

echo "==> Running ${BIN_NAME} under heaptrack (postgres user: ${PG_USER})..."
# Not using `exec` here so the EXIT trap still runs to remove the URL file
# after heaptrack (and the gateway) exit.
heaptrack "${BIN_PATH}" "$@"
