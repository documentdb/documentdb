#!/bin/bash
# Run DocumentDB functional tests locally using the pinned upstream image.
#
# Modes:
#   allowlist  Run the required PR-gate allow-list and summarize gate results.
#   single     Run one pytest node ID. Pass the node ID positionally or with --test.
#   smoke      Run upstream smoke tests, excluding no_parallel tests.
#   full       Run the full upstream suite.
#   daily      Run the full upstream suite and summarize daily delta results.
#   bootstrap  Generate an allow-list candidate from tests that pass every run.
#
# Examples:
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh single --test compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_all_documents
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh smoke --workers 4
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh full --workers 4
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh daily --workers 4
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh bootstrap --runs 3 --output allowlist-candidate.yml
#
# Additional pytest arguments can be passed after --.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FUNCTIONAL_TESTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
REPO_ROOT="$(cd "$FUNCTIONAL_TESTS_DIR/../.." && pwd)"

CONFIG_DIR="$FUNCTIONAL_TESTS_DIR/config"
IMAGE_YML="$CONFIG_DIR/image.yml"
ALLOWLIST_YML="$CONFIG_DIR/allowlist.yml"
PLUGIN="$FUNCTIONAL_TESTS_DIR/tools/conftest_allowlist.py"
GATE_TOOL="$FUNCTIONAL_TESTS_DIR/tools/functional_gate.py"

DEFAULT_CONNECTION_STRING="mongodb://docdb_admin:Admin100@host.docker.internal:10260/?tls=true&tlsAllowInvalidCertificates=true"
MODE="${1:-}"
CONNECTION_STRING="${CONNECTION_STRING:-$DEFAULT_CONNECTION_STRING}"
WORKERS=4
RESULTS_DIR=""
TEST_ID=""
RUNS=1
OUTPUT="allowlist-candidate.yml"
PYTEST_ARGS=()

show_help() {
    cat <<EOF
Run DocumentDB functional tests locally using the pinned upstream image.

Usage:
  $0 <mode> [options] [-- <pytest args>]

Modes:
  allowlist  Run the required PR-gate allow-list and summarize gate results.
  single     Run one pytest node ID. Pass the node ID positionally or with --test.
  smoke      Run upstream smoke tests, excluding no_parallel tests.
  full       Run the full upstream suite.
  daily      Run the full upstream suite and summarize daily delta results.
  bootstrap  Generate an allow-list candidate from tests that pass every run.

Examples:
  $0 allowlist
  $0 single compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_all_documents
  $0 single --test compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_all_documents
  $0 smoke --workers 4
  $0 full --workers 4
  $0 daily --workers 4
  $0 bootstrap --runs 3 --output allowlist-candidate.yml

Options:
  --connection-string <url>  Override the DocumentDB connection string.
  --workers <n>              Number of pytest-xdist workers (default: 4).
  --results-dir <path>       Output directory (default: .test-results/functional-tests/<mode>).
  --test <nodeid>            Pytest node ID for single mode.
  --runs <n>                 Number of bootstrap runs (default: 1).
  --output <path>            Bootstrap candidate output path (default: allowlist-candidate.yml).
  --help                     Show this help.
  -- <pytest args>           Extra arguments passed through to pytest.

Environment:
  CONNECTION_STRING          Alternative way to set the connection string.
EOF
}

if [ -z "$MODE" ] || [ "$MODE" = "--help" ] || [ "$MODE" = "-h" ]; then
    show_help
    exit 0
fi

case "$MODE" in
    allowlist|single|smoke|full|daily|bootstrap) shift ;;
    *)
        echo "Unknown mode: $MODE"
        echo ""
        show_help
        exit 1
        ;;
esac

while [[ $# -gt 0 ]]; do
    case "$1" in
        --connection-string) CONNECTION_STRING="$2"; shift 2 ;;
        --workers) WORKERS="$2"; shift 2 ;;
        --results-dir) RESULTS_DIR="$2"; shift 2 ;;
        --test) TEST_ID="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --help|-h)
            show_help
            exit 0
            ;;
        --)
            shift
            PYTEST_ARGS+=("$@")
            break
            ;;
        *)
            if [ "$MODE" = "single" ] && [ -z "$TEST_ID" ]; then
                TEST_ID="$1"
                shift
            else
                echo "Unknown option: $1"
                echo ""
                show_help
                exit 1
            fi
            ;;
    esac
done

if [ ! -f "$IMAGE_YML" ]; then
    echo "Required file not found: $IMAGE_YML"
    exit 1
fi

if [[ "$MODE" == "allowlist" || "$MODE" == "daily" ]]; then
    for f in "$ALLOWLIST_YML" "$GATE_TOOL"; do
        if [ ! -f "$f" ]; then
            echo "Required file not found: $f"
            exit 1
        fi
    done
fi

if [ "$MODE" = "allowlist" ] && [ ! -f "$PLUGIN" ]; then
    echo "Required file not found: $PLUGIN"
    exit 1
fi

if [ "$MODE" = "single" ] && [ -z "$TEST_ID" ]; then
    echo "single mode requires --test <pytest-node-id>"
    exit 1
fi

if [ "$MODE" = "bootstrap" ] && ! [[ "$RUNS" =~ ^[1-9][0-9]*$ ]]; then
    echo "bootstrap --runs must be a positive integer"
    exit 1
fi

if ! command -v docker &>/dev/null; then
    echo "Docker is required but not found in PATH."
    exit 1
fi

if [ -z "$RESULTS_DIR" ]; then
    RESULTS_DIR="$REPO_ROOT/.test-results/functional-tests/$MODE"
fi

IMAGE=$(python3 -c "import yaml; print(yaml.safe_load(open('$IMAGE_YML'))['image'])")
mkdir -p "$RESULTS_DIR"
chmod 777 "$RESULTS_DIR"

echo "DocumentDB functional test runner"
echo ""
echo "Mode:        $MODE"
echo "Image:       $IMAGE"
echo "Connection:  $CONNECTION_STRING"
echo "Workers:     $WORKERS"
echo "Results:     $RESULTS_DIR"
if [ -n "$TEST_ID" ]; then
    echo "Test:        $TEST_ID"
fi
if [ "$MODE" = "bootstrap" ]; then
    echo "Runs:        $RUNS"
    echo "Output:      $OUTPUT"
fi
if [ "${#PYTEST_ARGS[@]}" -gt 0 ]; then
    echo "Extra args:  ${PYTEST_ARGS[*]}"
fi
echo ""

TEST_EXIT=0

case "$MODE" in
    allowlist)
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
            -n "$WORKERS" \
            --json-report --json-report-file=/results/report.json \
            --junitxml=/results/results.xml \
            -v \
            "${PYTEST_ARGS[@]}" \
            || TEST_EXIT=$?

        if [ -f "$RESULTS_DIR/report.json" ]; then
            python3 "$GATE_TOOL" \
                --image "$IMAGE_YML" \
                --allowlist "$ALLOWLIST_YML" \
                summarize-gate \
                --report "$RESULTS_DIR/report.json" \
                --output-dir "$RESULTS_DIR"
            TEST_EXIT=$?
        else
            echo "No report.json produced. Test execution may have failed before producing results."
            TEST_EXIT=1
        fi
        ;;

    single)
        # Allow users to paste allowlist-style short node IDs.
        if [[ "$TEST_ID" == compatibility/* ]]; then
            TEST_ID="documentdb_tests/$TEST_ID"
        fi

        docker run --rm --network host \
            -v "$RESULTS_DIR:/results" \
            "$IMAGE" \
            "$TEST_ID" \
            --engine-name documentdb \
            --connection-string "$CONNECTION_STRING" \
            --json-report --json-report-file=/results/report.json \
            --junitxml=/results/results.xml \
            -v \
            "${PYTEST_ARGS[@]}" \
            || TEST_EXIT=$?
        ;;

    smoke)
        docker run --rm --network host \
            -v "$RESULTS_DIR:/results" \
            "$IMAGE" \
            documentdb_tests/compatibility/tests \
            --engine-name documentdb \
            --connection-string "$CONNECTION_STRING" \
            -m "smoke and not no_parallel" \
            -n "$WORKERS" \
            --json-report --json-report-file=/results/report.json \
            --junitxml=/results/results.xml \
            -v \
            "${PYTEST_ARGS[@]}" \
            || TEST_EXIT=$?
        ;;

    full|daily)
        docker run --rm --network host \
            -v "$RESULTS_DIR:/results" \
            "$IMAGE" \
            documentdb_tests/compatibility/tests \
            --engine-name documentdb \
            --connection-string "$CONNECTION_STRING" \
            -n "$WORKERS" \
            --json-report --json-report-file=/results/report.json \
            --junitxml=/results/results.xml \
            -v \
            "${PYTEST_ARGS[@]}" \
            || TEST_EXIT=$?

        if [ "$MODE" = "daily" ]; then
            TEST_EXIT=0
            if [ -f "$RESULTS_DIR/report.json" ]; then
                python3 "$GATE_TOOL" \
                    --image "$IMAGE_YML" \
                    --allowlist "$ALLOWLIST_YML" \
                    summarize-daily \
                    --report "$RESULTS_DIR/report.json" \
                    --output-dir "$RESULTS_DIR" \
                    || TEST_EXIT=$?
            else
                echo "No report.json produced. Test execution may have failed before producing results."
                TEST_EXIT=1
            fi
        fi
        ;;

    bootstrap)
        ALL_PASSING=""

        for RUN in $(seq 1 "$RUNS"); do
            RUN_DIR="$RESULTS_DIR/run-$RUN"
            mkdir -p "$RUN_DIR"
            chmod 777 "$RUN_DIR"

            echo "=== Bootstrap run $RUN/$RUNS ==="
            docker run --rm --network host \
                -v "$RUN_DIR:/results" \
                "$IMAGE" \
            documentdb_tests/compatibility/tests \
            --engine-name documentdb \
            --connection-string "$CONNECTION_STRING" \
            -n "$WORKERS" \
                --json-report --json-report-file=/results/report.json \
                --junitxml=/results/results.xml \
                -v \
                "${PYTEST_ARGS[@]}" \
                || true

            if [ ! -f "$RUN_DIR/report.json" ]; then
                echo "No report.json produced in bootstrap run $RUN."
                TEST_EXIT=1
                break
            fi

            RUN_PASSING=$(python3 -c "
import json
with open('$RUN_DIR/report.json') as f:
    report = json.load(f)
for test in report.get('tests', []):
    if test.get('outcome') == 'passed':
        print(test['nodeid'].removeprefix('documentdb_tests/'))
" | sort)

            if [ "$RUN" -eq 1 ]; then
                ALL_PASSING="$RUN_PASSING"
            else
                ALL_PASSING=$(comm -12 <(echo "$ALL_PASSING") <(echo "$RUN_PASSING"))
            fi

            echo "Passing in run $RUN: $(echo "$RUN_PASSING" | grep -c '.' || true)"
        done

        if [ "$TEST_EXIT" -eq 0 ]; then
            python3 -c "
import sys
import yaml

tests = sorted(line.strip() for line in sys.stdin if line.strip())
with open('$OUTPUT', 'w') as f:
    yaml.dump({'schema_version': 1, 'tests': tests}, f, default_flow_style=False, width=200)
print(f'Wrote {len(tests)} tests to $OUTPUT')
" <<< "$ALL_PASSING"
        fi
        ;;
esac

echo ""
echo "Test run complete (exit: $TEST_EXIT)"
echo ""
echo "Result artifacts:"
echo "  $RESULTS_DIR/report.json"
echo "  $RESULTS_DIR/results.xml"
if [ -f "$RESULTS_DIR/gate-summary.md" ]; then
    echo "  $RESULTS_DIR/gate-summary.md"
fi
if [ -f "$RESULTS_DIR/daily-summary.md" ]; then
    echo "  $RESULTS_DIR/daily-summary.md"
fi
if [ -f "$RESULTS_DIR/promotion-candidates.yml" ]; then
    echo "  $RESULTS_DIR/promotion-candidates.yml"
fi
if [ "$MODE" = "bootstrap" ] && [ -f "$OUTPUT" ]; then
    echo "  $OUTPUT"
fi

exit "$TEST_EXIT"
