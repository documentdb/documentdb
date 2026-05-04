#!/bin/bash
# Generate an initial allowlist.yml from tests that pass against DocumentDB.
#
# Runs the pinned upstream image broadly (without --allowlist), collects tests
# with outcome PASS, and outputs a candidate allowlist.yml.
#
# Usage:
#   ./scripts/functional-tests/bootstrap-allowlist.sh [options]
#
# Options:
#   --connection-string <url>  Override default connection string
#   --output <path>            Output file (default: allowlist-candidate.yml)
#   --runs <n>                 Number of repeated runs; only tests passing all runs are included (default: 1)
#   --help                     Show this help

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

CONFIG_DIR="$REPO_ROOT/test-config/functional-tests"
IMAGE_YML="$CONFIG_DIR/image.yml"
GATE_TOOL="$SCRIPT_DIR/functional_gate.py"
RESULTS_DIR="$REPO_ROOT/.test-results/functional-tests-bootstrap"
OUTPUT="allowlist-candidate.yml"
RUNS=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        --connection-string) CONNECTION_STRING="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --help)
            head -15 "$0" | tail -12
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if [ ! -f "$IMAGE_YML" ]; then
    echo "Required file not found: $IMAGE_YML"
    exit 1
fi

IMAGE=$(python3 -c "import yaml; print(yaml.safe_load(open('$IMAGE_YML'))['image'])")
CONNECTION_STRING="${CONNECTION_STRING:-mongodb://docdb_admin:Admin100@host.docker.internal:10260/?tls=true&tlsAllowInvalidCertificates=true}"

echo "Bootstrap allow-list generation"
echo ""
echo "Image: $IMAGE"
echo "Connection: $CONNECTION_STRING"
echo "Runs: $RUNS"
echo ""

# Run the full suite (without allow-list filtering), excluding no_parallel
ALL_PASSING=""

for RUN in $(seq 1 "$RUNS"); do
    RUN_DIR="$RESULTS_DIR/run-$RUN"
    mkdir -p "$RUN_DIR"

    echo "=== Run $RUN/$RUNS ==="
    docker run --rm --network host \
        -v "$RUN_DIR:/results" \
        "$IMAGE" \
        documentdb_tests/compatibility/tests \
        --engine-name documentdb \
        --connection-string "$CONNECTION_STRING" \
        -m "not no_parallel" \
        -n 4 \
        --json-report --json-report-file=/results/report.json \
        -v \
        || true  # Don't fail on test failures

    if [ ! -f "$RUN_DIR/report.json" ]; then
        echo "No report.json produced in run $RUN. Aborting."
        exit 1
    fi

    # Extract passing test IDs
    RUN_PASSING=$(python3 -c "
import json
with open('$RUN_DIR/report.json') as f:
    report = json.load(f)
for t in report.get('tests', []):
    if t.get('outcome') == 'passed':
        print(t['nodeid'])
" | sort)

    if [ "$RUN" -eq 1 ]; then
        ALL_PASSING="$RUN_PASSING"
    else
        # Intersect with previous runs
        ALL_PASSING=$(comm -12 <(echo "$ALL_PASSING") <(echo "$RUN_PASSING"))
    fi
    echo "  Passing in run $RUN: $(echo "$RUN_PASSING" | wc -l | tr -d ' ')"
done

# Generate candidate allowlist.yml
PASSING_COUNT=$(echo "$ALL_PASSING" | grep -c '.' || true)

echo ""
echo "Tests passing all $RUNS run(s): $PASSING_COUNT"
echo ""

python3 -c "
import yaml, sys

tests = [line.strip() for line in sys.stdin if line.strip()]
tests.sort()

data = {
    'schema_version': 1,
    'tests': tests,
}
with open('$OUTPUT', 'w') as f:
    yaml.dump(data, f, default_flow_style=False, width=200)

print(f'Wrote {len(tests)} tests to $OUTPUT')

# Print area summary
areas = {}
for t in tests:
    area = 'unknown'
    for pattern, name in [
        ('commands/find/', 'find'),
        ('commands/insert/', 'insert'),
        ('commands/update/', 'update'),
        ('commands/delete/', 'delete'),
        ('aggregate/', 'aggregate'),
        ('collections/', 'collection_mgmt'),
        ('sessions/', 'sessions'),
        ('indexes/', 'index'),
        ('admin/', 'admin'),
        ('bson_types/', 'bson_types'),
    ]:
        if pattern in t:
            area = name
            break
    areas[area] = areas.get(area, 0) + 1

print()
print('Area summary:')
for area, count in sorted(areas.items(), key=lambda x: -x[1]):
    print(f'  {area}: {count}')
" <<< "$ALL_PASSING"
