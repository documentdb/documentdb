#!/bin/bash
# Start DocumentDB and the Mongo-compatible gateway for functional testing.
#
# This script wraps the existing build/start scripts to provide a single
# entry point for local development and CI. It waits until the gateway is
# reachable and prints a connection string compatible with upstream
# functional-tests.
#
# Usage:
#   ./scripts/functional-tests/start-documentdb-for-functional-tests.sh [options]
#
# Options:
#   --pg-version <ver>   PostgreSQL major version (default: 17)
#   --port <port>        Gateway port (default: 10260)
#   --data-dir <dir>     PostgreSQL data directory (default: $HOME/.documentdb/functional-test-data)
#   --log-dir <dir>      Log output directory (default: .test-results/functional-tests)
#   --skip-build         Skip building DocumentDB (assume already built)
#   --help               Show this help
#
# The script prints the connection string on stdout when ready.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

PG_VERSION="${PG_VERSION:-17}"
GATEWAY_PORT="${GATEWAY_PORT:-10260}"
PG_PORT="${PG_PORT:-9712}"
DATA_DIR="${DATA_DIR:-$HOME/.documentdb/functional-test-data}"
LOG_DIR="${LOG_DIR:-.test-results/functional-tests}"
SKIP_BUILD="${SKIP_BUILD:-false}"
USERNAME="${DOCUMENTDB_USER:-docdb_admin}"
PASSWORD="${DOCUMENTDB_PASSWORD:-Admin100}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --pg-version) PG_VERSION="$2"; shift 2 ;;
        --port) GATEWAY_PORT="$2"; shift 2 ;;
        --data-dir) DATA_DIR="$2"; shift 2 ;;
        --log-dir) LOG_DIR="$2"; shift 2 ;;
        --skip-build) SKIP_BUILD="true"; shift ;;
        --help)
            head -22 "$0" | tail -19
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

mkdir -p "$LOG_DIR"

echo "Starting DocumentDB for functional testing"
echo "  PG version: $PG_VERSION"
echo "  Gateway port: $GATEWAY_PORT"
echo "  Data dir: $DATA_DIR"
echo "  Log dir: $LOG_DIR"

# Step 1: Build (unless skipped)
if [ "$SKIP_BUILD" != "true" ]; then
    echo ""
    echo "Building DocumentDB..."
    export PG_VERSION_USED="$PG_VERSION"
    "$REPO_ROOT/scripts/build_documentdb_with_scripts.sh" \
        --pg-version "$PG_VERSION" --citus-version 12 \
        > "$LOG_DIR/build.log" 2>&1 || {
        echo "Build failed. See $LOG_DIR/build.log"
        exit 1
    }
    echo "Build complete."
fi

# Step 2: Start PostgreSQL
echo ""
echo "Starting PostgreSQL on port $PG_PORT..."
export PG_VERSION_USED="$PG_VERSION"
"$REPO_ROOT/scripts/start_oss_server.sh" \
    -d "$DATA_DIR" -c -p "$PG_PORT" -g \
    > "$LOG_DIR/start_server.log" 2>&1 &
SERVER_PID=$!

# Wait for PostgreSQL
TIMEOUT=300
ELAPSED=0
while ! pg_isready -h localhost -p "$PG_PORT" > /dev/null 2>&1; do
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "PostgreSQL did not start within ${TIMEOUT}s. See $LOG_DIR/start_server.log"
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo "PostgreSQL is ready on port $PG_PORT."

# Step 3: Start the gateway
echo ""
echo "Starting gateway on port $GATEWAY_PORT..."
"$REPO_ROOT/scripts/build_and_start_gateway.sh" \
    -u "$USERNAME" -p "$PASSWORD" -P "$PG_PORT" \
    > "$LOG_DIR/gateway.log" 2>&1 &
GATEWAY_PID=$!

# Wait for gateway port
ELAPSED=0
while ! nc -z localhost "$GATEWAY_PORT" 2>/dev/null; do
    if [ "$ELAPSED" -ge "$TIMEOUT" ]; then
        echo "Gateway did not start on port $GATEWAY_PORT within ${TIMEOUT}s. See $LOG_DIR/gateway.log"
        exit 1
    fi
    sleep 2
    ELAPSED=$((ELAPSED + 2))
done
echo "Gateway is ready on port $GATEWAY_PORT."

# Print connection string
CONNECTION_STRING="mongodb://${USERNAME}:${PASSWORD}@localhost:${GATEWAY_PORT}/?tls=true&tlsAllowInvalidCertificates=true"
echo ""
echo "DocumentDB is ready for functional testing."
echo "CONNECTION_STRING=$CONNECTION_STRING"

# Write connection string to a file for CI consumption
echo "$CONNECTION_STRING" > "$LOG_DIR/connection-string.txt"
