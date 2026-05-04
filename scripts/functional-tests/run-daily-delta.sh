#!/bin/bash
# Run the daily full-suite delta report.
#
# Runs the broader upstream suite from the current pinned image WITHOUT
# allow-list filtering, then compares results to allowlist.yml to produce
# a delta report showing:
#   - allow-listed tests that failed
#   - outside-allow-list tests that passed (promotion candidates)
#   - outside-allow-list tests that still do not pass (visibility only)
#
# Usage:
#   ./scripts/functional-tests/run-daily-delta.sh [--connection-string <url>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG_DIR="$REPO_ROOT/test-config/functional-tests"
IMAGE_YML="$CONFIG_DIR/image.yml"
ALLOWLIST_YML="$CONFIG_DIR/allowlist.yml"
GATE_TOOL="$SCRIPT_DIR/functional_gate.py"
RESULTS_DIR="$REPO_ROOT/.test-results/functional-tests-daily"

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

for f in "$IMAGE_YML" "$ALLOWLIST_YML"; do
    if [ ! -f "$f" ]; then
        echo "Required file not found: $f"
        exit 1
    fi
done

IMAGE=$(python3 -c "import yaml; print(yaml.safe_load(open('$IMAGE_YML'))['image'])")
CONNECTION_STRING="${CONNECTION_STRING:-mongodb://docdb_admin:Admin100@host.docker.internal:10260/?tls=true&tlsAllowInvalidCertificates=true}"

mkdir -p "$RESULTS_DIR"

echo "Daily functional-test delta run"
echo ""
echo "Image: $IMAGE"
echo "Connection: $CONNECTION_STRING"
echo ""

# Run the full suite WITHOUT allow-list filtering
docker run --rm --network host \
    -v "$RESULTS_DIR:/results" \
    "$IMAGE" \
    documentdb_tests/compatibility/tests \
    --engine-name documentdb \
    --connection-string "$CONNECTION_STRING" \
    -n auto \
    --json-report --json-report-file=/results/report.json \
    --junitxml=/results/results.xml \
    -v \
    || true  # Don't fail on test failures; we analyze the report

echo ""

if [ ! -f "$RESULTS_DIR/report.json" ]; then
    echo "No report.json produced. Test execution may have failed before producing results."
    exit 1
fi

# Summarize the delta
python3 "$GATE_TOOL" \
    --image "$IMAGE_YML" \
    --allowlist "$ALLOWLIST_YML" \
    summarize-daily \
    --report "$RESULTS_DIR/report.json" \
    --output-dir "$RESULTS_DIR"

DAILY_EXIT=$?

echo ""
echo "Result artifacts:"
echo "  $RESULTS_DIR/report.json"
echo "  $RESULTS_DIR/results.xml"
echo "  $RESULTS_DIR/daily-summary.md"
echo "  $RESULTS_DIR/daily-summary.json"
if [ -f "$RESULTS_DIR/promotion-candidates.yml" ]; then
    echo "  $RESULTS_DIR/promotion-candidates.yml"
fi

exit $DAILY_EXIT
