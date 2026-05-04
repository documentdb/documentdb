#!/bin/bash
# Run the full functional-test allow-list gate locally.
#
# Reads image.yml and allowlist.yml, pulls the pinned upstream image,
# mounts the allow-list plugin, and runs only allow-listed tests.
#
# Usage:
#   ./scripts/functional-tests/run-allowlist.sh [--connection-string <url>]
#
# Environment:
#   CONNECTION_STRING  Override the default connection string.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG_DIR="$REPO_ROOT/test-config/functional-tests"
IMAGE_YML="$CONFIG_DIR/image.yml"
ALLOWLIST_YML="$CONFIG_DIR/allowlist.yml"
PLUGIN="$SCRIPT_DIR/conftest_allowlist.py"
GATE_TOOL="$SCRIPT_DIR/functional_gate.py"
RESULTS_DIR="$REPO_ROOT/.test-results/functional-tests"

# Parse args
while [[ $# -gt 0 ]]; do
    case "$1" in
        --connection-string) CONNECTION_STRING="$2"; shift 2 ;;
        --help)
            echo "Usage: $0 [--connection-string <url>]"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

# Validate prerequisites
for f in "$IMAGE_YML" "$ALLOWLIST_YML" "$PLUGIN"; do
    if [ ! -f "$f" ]; then
        echo "Required file not found: $f"
        exit 1
    fi
done

if ! command -v docker &>/dev/null; then
    echo "Docker is required but not found in PATH."
    exit 1
fi

# Read image from image.yml
IMAGE=$(python3 -c "import yaml; print(yaml.safe_load(open('$IMAGE_YML'))['image'])")
CONNECTION_STRING="${CONNECTION_STRING:-mongodb://docdb_admin:Admin100@host.docker.internal:10260/?tls=true&tlsAllowInvalidCertificates=true}"

mkdir -p "$RESULTS_DIR"

echo "Functional test allow-list gate"
echo ""
echo "Image:"
echo "  $IMAGE"
echo ""
echo "Connection:"
echo "  $CONNECTION_STRING"
echo ""
echo "Allow-list:"
echo "  $ALLOWLIST_YML"
echo ""

# Run tests
docker run --rm --network host \
    -v "$ALLOWLIST_YML:/allowlist.yml:ro" \
    -v "$PLUGIN:/extra/conftest_allowlist.py:ro" \
    -v "$RESULTS_DIR:/results" \
    -e "PYTHONPATH=/extra" \
    "$IMAGE" \
    documentdb_tests/compatibility/tests \
    -p conftest_allowlist \
    --allowlist /allowlist.yml \
    --engine-name documentdb \
    --connection-string "$CONNECTION_STRING" \
    -m "not no_parallel" \
    -n 4 \
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

# Run gate summarization
if [ -f "$RESULTS_DIR/report.json" ]; then
    echo ""
    python3 "$GATE_TOOL" \
        --image "$IMAGE_YML" \
        --allowlist "$ALLOWLIST_YML" \
        summarize-gate \
        --report "$RESULTS_DIR/report.json" \
        --output-dir "$RESULTS_DIR"
    GATE_EXIT=$?
else
    echo ""
    echo "No report.json found. Test execution may have failed before producing results."
    GATE_EXIT=1
fi

exit $GATE_EXIT
