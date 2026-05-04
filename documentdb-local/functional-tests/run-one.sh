#!/bin/bash
# Run a single functional test by node ID for failure diagnosis.
#
# Uses the same pinned image and connection settings as the PR gate.
# Does not use or modify the allow-list.
#
# Usage:
#   ./documentdb-local/functional-tests/run-one.sh <pytest-node-id> [--connection-string <url>]
#
# Example:
#   ./documentdb-local/functional-tests/run-one.sh \
#     documentdb_tests/compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_eq

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG_DIR="$SCRIPT_DIR/config"
IMAGE_YML="$CONFIG_DIR/image.yml"
RESULTS_DIR="$REPO_ROOT/.test-results/functional-tests"

if [ $# -lt 1 ] || [ "$1" = "--help" ]; then
    echo "Usage: $0 <pytest-node-id> [--connection-string <url>]"
    echo ""
    echo "Example:"
    echo "  $0 documentdb_tests/.../test_find_basic_queries.py::test_find_eq"
    exit 1
fi

NODE_ID="$1"
shift

while [[ $# -gt 0 ]]; do
    case "$1" in
        --connection-string) CONNECTION_STRING="$2"; shift 2 ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ ! -f "$IMAGE_YML" ]; then
    echo "Required file not found: $IMAGE_YML"
    exit 1
fi

if ! command -v docker &>/dev/null; then
    echo "Docker is required but not found in PATH."
    exit 1
fi

IMAGE=$(python3 -c "import yaml; print(yaml.safe_load(open('$IMAGE_YML'))['image'])")
CONNECTION_STRING="${CONNECTION_STRING:-mongodb://docdb_admin:Admin100@host.docker.internal:10260/?tls=true&tlsAllowInvalidCertificates=true}"

mkdir -p "$RESULTS_DIR"

echo "Running single functional test"
echo ""
echo "Image:"
echo "  $IMAGE"
echo ""
echo "Connection:"
echo "  $CONNECTION_STRING"
echo ""
echo "Test:"
echo "  $NODE_ID"
echo ""

docker run --rm --network host \
    -v "$RESULTS_DIR:/results" \
    "$IMAGE" \
    "$NODE_ID" \
    --engine-name documentdb \
    --connection-string "$CONNECTION_STRING" \
    --json-report --json-report-file=/results/report.json \
    --junitxml=/results/results.xml \
    -v \
    || TEST_EXIT=$?

TEST_EXIT=${TEST_EXIT:-0}

echo ""
echo "Test run complete (exit: $TEST_EXIT)"
echo ""
echo "Result artifacts:"
echo "  $RESULTS_DIR/report.json"
echo "  $RESULTS_DIR/results.xml"

exit $TEST_EXIT
