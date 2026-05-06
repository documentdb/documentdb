#!/bin/bash
# Run DocumentDB functional tests locally using the pinned upstream image.
#
# Modes:
#   allowlist  Run the required PR-gate allowlist and summarize gate results.
#   single     Run one pytest node ID. Pass the node ID positionally or with --test.
#   smoke      Run upstream smoke tests, excluding no_parallel tests.
#   full       Run the full upstream suite.
#   daily      Run the full upstream suite and summarize daily delta results.
#   bootstrap  Generate an allowlist candidate from tests that pass every run.
#
# Examples:
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh single --test compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_all_documents
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist --build-and-start-documentdb
#   ./documentdb-local/functional-tests/scripts/run-functional-tests.sh allowlist --use-existing-documentdb-image ghcr.io/documentdb/documentdb/documentdb-local:latest
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

MODE="${1:-}"
CONNECTION_STRING_EXPLICIT=false
if [ -n "${CONNECTION_STRING+x}" ]; then
    CONNECTION_STRING_EXPLICIT=true
fi
ENGINE_NAME="${ENGINE_NAME:-documentdb}"
WORKERS=4
RESULTS_DIR=""
TEST_ID=""
RUNS=1
OUTPUT="allowlist-candidate.yml"
BUILD_DOCUMENTDB=false
START_DOCUMENTDB=false
PULL_DOCUMENTDB_IMAGE=false
KEEP_DOCUMENTDB=false
DOCUMENTDB_IMAGE="documentdb-local:functional-tests"
DOCUMENTDB_CONTAINER="documentdb-functional-tests"
DOCUMENTDB_PORT="${DOCUMENTDB_PORT:-10260}"
DOCUMENTDB_USER="${DOCUMENTDB_USER:-docdb_admin}"
DOCUMENTDB_PASSWORD="${DOCUMENTDB_PASSWORD:-Admin100}"
# Local-dev defaults only. Do not use these credentials for deployed environments;
# CI generates per-run credentials in .github/workflows/functional_tests.yml.
DEFAULT_CONNECTION_STRING="mongodb://${DOCUMENTDB_USER}:${DOCUMENTDB_PASSWORD}@host.docker.internal:${DOCUMENTDB_PORT}/?tls=true&tlsAllowInvalidCertificates=true"
CONNECTION_STRING="${CONNECTION_STRING:-$DEFAULT_CONNECTION_STRING}"
PG_VERSION="${PG_VERSION:-17}"
PACKAGE_OS="deb13"
DOCUMENTDB_BUILD_DIR="$REPO_ROOT/.test-results/functional-tests/documentdb-build"
DOCUMENTDB_BASE_IMAGE="debian:trixie-slim"
DOCUMENTDB_READY_TIMEOUT=180
MANAGED_DOCUMENTDB_STARTED=false
PYTEST_ARGS=()
PYTEST_ARGS_PRESENT=false

show_help() {
    cat <<EOF
Run DocumentDB functional tests locally using the pinned upstream image.

Usage:
  $0 <mode> [options] [-- <pytest args>]

Modes:
  allowlist  Run the required PR-gate allowlist and summarize gate results.
  single     Run one pytest node ID. Pass the node ID positionally or with --test.
  smoke      Run upstream smoke tests, excluding no_parallel tests.
  full       Run the full upstream suite.
  daily      Run the full upstream suite and summarize daily delta results.
  bootstrap  Generate an allowlist candidate from tests that pass every run.

Examples:
  $0 allowlist
  $0 single compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_all_documents
  $0 single --test compatibility/tests/core/query-and-write/commands/find/test_find_basic_queries.py::test_find_all_documents
  $0 allowlist --build-and-start-documentdb
  $0 allowlist --use-existing-documentdb-image ghcr.io/documentdb/documentdb/documentdb-local:latest
  $0 smoke --workers 4
  $0 full --workers 4
  $0 daily --workers 4
  $0 bootstrap --runs 3 --output allowlist-candidate.yml

Options:
  --connection-string <url>  Override the DocumentDB connection string, including
                             the managed container connection string.
  --engine-name <name>       Engine name passed to upstream pytest and the
                             allowlist plugin (default: documentdb).
  --workers <n>              Number of pytest-xdist workers (default: 4).
  --results-dir <path>       Output directory (default: .test-results/functional-tests/<mode>).
  --test <nodeid>            Pytest node ID for single mode.
  --runs <n>                 Number of bootstrap runs (default: 1).
  --output <path>            Bootstrap candidate output path (default: allowlist-candidate.yml).
  --build-documentdb         Build the local documentdb-local Docker image before running tests.
  --start-documentdb         Start documentdb-local, wait for readiness, then run tests.
  --build-and-start-documentdb
                             Build, start, wait, and run tests in one command.
  --use-existing-documentdb-image <image>
                             Start a prebuilt image ref without rebuilding; pulls if missing locally.
  --documentdb-image <image> Managed documentdb-local image ref for build/start (default: documentdb-local:functional-tests).
  --documentdb-container <name>
                             Managed container name (default: documentdb-functional-tests).
  --documentdb-port <port>   Managed DocumentDB host port (default: 10260).
  --documentdb-user <user>   Managed DocumentDB username (default: docdb_admin).
  --documentdb-password <pw> Managed DocumentDB password (default: Admin100).
  --pg-version <ver>         PostgreSQL major version for local image builds (default: 17).
  --package-os <os>          Package OS for local image builds (default: deb13).
  --build-dir <path>         Repo-local build artifact directory.
  --base-image <image>       Base image for documentdb-local Docker build (default: debian:trixie-slim).
  --ready-timeout <seconds>  Startup readiness timeout (default: 180).
  --keep-documentdb          Leave the managed container running after tests.
  --help                     Show this help.
  -- <pytest args>           Extra arguments passed through to pytest.

Environment:
  CONNECTION_STRING          Alternative way to set the connection string.
                             Preserved when using managed DocumentDB startup.
EOF
}

repo_relative_path() {
    python3 -c "import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$1" "$2"
}

redact_connection_string() {
    python3 - "$1" <<'PY'
import sys
from urllib.parse import urlsplit

try:
    parsed = urlsplit(sys.argv[1])
    scheme = parsed.scheme or "mongodb"
    host = parsed.hostname
    port = parsed.port
except ValueError:
    print("<redacted>")
    raise SystemExit(0)

if not host:
    print("<redacted>")
    raise SystemExit(0)

if ":" in host and not host.startswith("["):
    host = f"[{host}]"

port_suffix = f":{port}" if port is not None else ""
print(f"{scheme}://{host}{port_suffix}")
PY
}

cleanup_managed_documentdb() {
    local exit_code=$?

    if [ "$MANAGED_DOCUMENTDB_STARTED" = "true" ]; then
        echo ""
        echo "Collecting managed DocumentDB logs:"
        echo "  $RESULTS_DIR/documentdb.log"
        docker logs "$DOCUMENTDB_CONTAINER" > "$RESULTS_DIR/documentdb.log" 2>&1 || true

        if [ "$KEEP_DOCUMENTDB" = "true" ]; then
            echo "Keeping managed DocumentDB container running:"
            echo "  $DOCUMENTDB_CONTAINER"
        else
            echo "Stopping managed DocumentDB container:"
            echo "  $DOCUMENTDB_CONTAINER"
            docker rm -f "$DOCUMENTDB_CONTAINER" >/dev/null 2>&1 || true
        fi
    fi

    exit "$exit_code"
}

build_documentdb_image() {
    case "$PACKAGE_OS" in
        deb*|ubuntu*) ;;
        *)
            echo "--package-os must produce a Debian package for Dockerfile_documentdb_local, got: $PACKAGE_OS"
            exit 1
            ;;
    esac

    mkdir -p "$DOCUMENTDB_BUILD_DIR"
    DOCUMENTDB_BUILD_DIR="$(cd "$DOCUMENTDB_BUILD_DIR" && pwd)"
    case "$DOCUMENTDB_BUILD_DIR/" in
        "$REPO_ROOT"/*) ;;
        *)
            echo "--build-dir must be inside the repository so Docker can copy the built package: $DOCUMENTDB_BUILD_DIR"
            exit 1
            ;;
    esac

    local build_dir_rel
    local packages_dir_rel
    local packages_dir
    local deb_file
    local deb_rel

    build_dir_rel="$(repo_relative_path "$DOCUMENTDB_BUILD_DIR" "$REPO_ROOT")"
    packages_dir_rel="$build_dir_rel/downloaded-artifacts"
    packages_dir="$REPO_ROOT/$packages_dir_rel"

    echo "Building documentdb-local package:"
    echo "  OS:        $PACKAGE_OS"
    echo "  PG:        $PG_VERSION"
    echo "  Output:    $packages_dir"
    rm -rf "$packages_dir"
    mkdir -p "$packages_dir"
    (
        cd "$REPO_ROOT"
        ./packaging/build_packages.sh --os "$PACKAGE_OS" --pg "$PG_VERSION" --output-dir "$packages_dir_rel"
    )

    deb_file="$(find "$packages_dir" -maxdepth 1 -type f -name '*.deb' ! -name '*dbgsym*' | sort | head -1)"
    if [ -z "$deb_file" ]; then
        echo "No non-dbgsym .deb package found in $packages_dir"
        exit 1
    fi
    deb_rel="$(repo_relative_path "$deb_file" "$REPO_ROOT")"

    echo "Building documentdb-local Docker image:"
    echo "  Image:     $DOCUMENTDB_IMAGE"
    echo "  Base:      $DOCUMENTDB_BASE_IMAGE"
    echo "  Package:   $deb_rel"
    (
        cd "$REPO_ROOT"
        docker build \
            --build-arg BASE_IMAGE="$DOCUMENTDB_BASE_IMAGE" \
            --build-arg POSTGRES_VERSION="$PG_VERSION" \
            --build-arg DEB_PACKAGE_REL_PATH="$deb_rel" \
            -t "$DOCUMENTDB_IMAGE" \
            -f packaging/gateway/docker/Dockerfile_documentdb_local .
    )
}

start_managed_documentdb() {
    if ! docker image inspect "$DOCUMENTDB_IMAGE" >/dev/null 2>&1; then
        if [ "$PULL_DOCUMENTDB_IMAGE" = "true" ]; then
            echo "DocumentDB image not found locally; pulling:"
            echo "  $DOCUMENTDB_IMAGE"
            docker pull "$DOCUMENTDB_IMAGE"
        else
            echo "DocumentDB image not found: $DOCUMENTDB_IMAGE"
            echo "Use --build-documentdb, --build-and-start-documentdb, or --use-existing-documentdb-image <image>."
            exit 1
        fi
    fi

    echo "Removing any existing managed DocumentDB container:"
    echo "  $DOCUMENTDB_CONTAINER"
    docker rm -f "$DOCUMENTDB_CONTAINER" >/dev/null 2>&1 || true

    echo "Starting managed DocumentDB container:"
    echo "  Container: $DOCUMENTDB_CONTAINER"
    echo "  Image:     $DOCUMENTDB_IMAGE"
    echo "  Host port: $DOCUMENTDB_PORT"
    docker run -d \
        --name "$DOCUMENTDB_CONTAINER" \
        -p "$DOCUMENTDB_PORT:10260" \
        "$DOCUMENTDB_IMAGE" \
        --username "$DOCUMENTDB_USER" \
        --password "$DOCUMENTDB_PASSWORD" \
        --skip-init-data \
        >/dev/null
    MANAGED_DOCUMENTDB_STARTED=true

    echo "Waiting for DocumentDB readiness log (timeout: ${DOCUMENTDB_READY_TIMEOUT}s)..."
    local elapsed=0
    while ! docker logs "$DOCUMENTDB_CONTAINER" 2>&1 | grep -q "=== DocumentDB is ready ==="; do
        if ! docker ps --format '{{.Names}}' | grep -Fx "$DOCUMENTDB_CONTAINER" >/dev/null; then
            echo "Managed DocumentDB container exited before readiness."
            docker logs "$DOCUMENTDB_CONTAINER" 2>&1 || true
            exit 1
        fi
        if [ "$elapsed" -ge "$DOCUMENTDB_READY_TIMEOUT" ]; then
            echo "DocumentDB did not become ready within ${DOCUMENTDB_READY_TIMEOUT}s."
            docker logs "$DOCUMENTDB_CONTAINER" 2>&1 || true
            exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done

    if [ "$CONNECTION_STRING_EXPLICIT" = "true" ]; then
        echo "Using user-provided DocumentDB connection string."
    else
        CONNECTION_STRING="mongodb://${DOCUMENTDB_USER}:${DOCUMENTDB_PASSWORD}@127.0.0.1:${DOCUMENTDB_PORT}/?tls=true&tlsAllowInvalidCertificates=true"
    fi
    echo "Waiting for DocumentDB host port ${DOCUMENTDB_PORT}..."
    elapsed=0
    while ! timeout 1 bash -c "</dev/tcp/127.0.0.1/${DOCUMENTDB_PORT}" >/dev/null 2>&1; do
        if [ "$elapsed" -ge "$DOCUMENTDB_READY_TIMEOUT" ]; then
            echo "DocumentDB host port ${DOCUMENTDB_PORT} did not become reachable within ${DOCUMENTDB_READY_TIMEOUT}s."
            docker logs "$DOCUMENTDB_CONTAINER" 2>&1 || true
            exit 1
        fi
        sleep 2
        elapsed=$((elapsed + 2))
    done
    echo "Managed DocumentDB is ready."
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
        --connection-string) CONNECTION_STRING="$2"; CONNECTION_STRING_EXPLICIT=true; shift 2 ;;
        --engine-name) ENGINE_NAME="$2"; shift 2 ;;
        --workers) WORKERS="$2"; shift 2 ;;
        --results-dir) RESULTS_DIR="$2"; shift 2 ;;
        --test) TEST_ID="$2"; shift 2 ;;
        --runs) RUNS="$2"; shift 2 ;;
        --output) OUTPUT="$2"; shift 2 ;;
        --build-documentdb) BUILD_DOCUMENTDB=true; shift ;;
        --start-documentdb) START_DOCUMENTDB=true; shift ;;
        --build-and-start-documentdb) BUILD_DOCUMENTDB=true; START_DOCUMENTDB=true; shift ;;
        --use-existing-documentdb-image) DOCUMENTDB_IMAGE="$2"; BUILD_DOCUMENTDB=false; START_DOCUMENTDB=true; PULL_DOCUMENTDB_IMAGE=true; shift 2 ;;
        --documentdb-image) DOCUMENTDB_IMAGE="$2"; shift 2 ;;
        --documentdb-container) DOCUMENTDB_CONTAINER="$2"; shift 2 ;;
        --documentdb-port) DOCUMENTDB_PORT="$2"; shift 2 ;;
        --documentdb-user) DOCUMENTDB_USER="$2"; shift 2 ;;
        --documentdb-password) DOCUMENTDB_PASSWORD="$2"; shift 2 ;;
        --pg-version) PG_VERSION="$2"; shift 2 ;;
        --package-os) PACKAGE_OS="$2"; shift 2 ;;
        --build-dir) DOCUMENTDB_BUILD_DIR="$2"; shift 2 ;;
        --base-image) DOCUMENTDB_BASE_IMAGE="$2"; shift 2 ;;
        --ready-timeout) DOCUMENTDB_READY_TIMEOUT="$2"; shift 2 ;;
        --keep-documentdb) KEEP_DOCUMENTDB=true; shift ;;
        --help|-h)
            show_help
            exit 0
            ;;
        --)
            shift
            if [ "$#" -gt 0 ]; then
                PYTEST_ARGS_PRESENT=true
                PYTEST_ARGS+=("$@")
            fi
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

if ! [[ "$DOCUMENTDB_READY_TIMEOUT" =~ ^[1-9][0-9]*$ ]]; then
    echo "--ready-timeout must be a positive integer"
    exit 1
fi

if ! [[ "$DOCUMENTDB_PORT" =~ ^[1-9][0-9]*$ ]]; then
    echo "--documentdb-port must be a positive integer"
    exit 1
fi

if ! command -v docker &>/dev/null; then
    echo "Docker is required but not found in PATH."
    exit 1
fi

if [ -z "$RESULTS_DIR" ]; then
    RESULTS_DIR="$REPO_ROOT/.test-results/functional-tests/$MODE"
fi

IMAGE=$(python3 -c 'import sys, yaml; print(yaml.safe_load(open(sys.argv[1]))["image"])' "$IMAGE_YML")
mkdir -p "$RESULTS_DIR"
chmod 777 "$RESULTS_DIR"
trap cleanup_managed_documentdb EXIT

if [ "$BUILD_DOCUMENTDB" = "true" ]; then
    build_documentdb_image
fi

if [ "$START_DOCUMENTDB" = "true" ]; then
    start_managed_documentdb
fi

echo "DocumentDB functional test runner"
echo ""
echo "Mode:        $MODE"
echo "Image:       $IMAGE"
echo "Engine:      $ENGINE_NAME"
echo "Connection:  $(redact_connection_string "$CONNECTION_STRING")"
echo "Workers:     $WORKERS"
echo "Results:     $RESULTS_DIR"
if [ "$BUILD_DOCUMENTDB" = "true" ] || [ "$START_DOCUMENTDB" = "true" ]; then
    echo "DocumentDB:"
    echo "  image:     $DOCUMENTDB_IMAGE"
    echo "  container: $DOCUMENTDB_CONTAINER"
    echo "  host port: $DOCUMENTDB_PORT"
fi
if [ -n "$TEST_ID" ]; then
    echo "Test:        $TEST_ID"
fi
if [ "$MODE" = "bootstrap" ]; then
    echo "Runs:        $RUNS"
    echo "Output:      $OUTPUT"
fi
if [ "$PYTEST_ARGS_PRESENT" = "true" ]; then
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
            --engine-name "$ENGINE_NAME" \
            --allowlist-engine-name "$ENGINE_NAME" \
            --connection-string "$CONNECTION_STRING" \
            -m "not no_parallel" \
            -n "$WORKERS" \
            --json-report --json-report-file=/results/report.json \
            --junitxml=/results/results.xml \
            -v \
            ${PYTEST_ARGS[@]+"${PYTEST_ARGS[@]}"} \
            || TEST_EXIT=$?

        if [ -f "$RESULTS_DIR/report.json" ]; then
            SUMMARY_EXIT=0
            if ! python3 "$GATE_TOOL" \
                --image "$IMAGE_YML" \
                --allowlist "$ALLOWLIST_YML" \
                summarize-gate \
                --report "$RESULTS_DIR/report.json" \
                --output-dir "$RESULTS_DIR"; then
                SUMMARY_EXIT=1
            fi
            if [ "$TEST_EXIT" -ne 0 ] || [ "$SUMMARY_EXIT" -ne 0 ]; then
                TEST_EXIT=1
            fi
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
            --engine-name "$ENGINE_NAME" \
            --connection-string "$CONNECTION_STRING" \
            --json-report --json-report-file=/results/report.json \
            --junitxml=/results/results.xml \
            -v \
            ${PYTEST_ARGS[@]+"${PYTEST_ARGS[@]}"} \
            || TEST_EXIT=$?
        ;;

    smoke)
        docker run --rm --network host \
            -v "$RESULTS_DIR:/results" \
            "$IMAGE" \
            documentdb_tests/compatibility/tests \
            --engine-name "$ENGINE_NAME" \
            --connection-string "$CONNECTION_STRING" \
            -m "smoke and not no_parallel" \
            -n "$WORKERS" \
            --json-report --json-report-file=/results/report.json \
            --junitxml=/results/results.xml \
            -v \
            ${PYTEST_ARGS[@]+"${PYTEST_ARGS[@]}"} \
            || TEST_EXIT=$?
        ;;

    full|daily)
        docker run --rm --network host \
            -v "$RESULTS_DIR:/results" \
            "$IMAGE" \
            documentdb_tests/compatibility/tests \
            --engine-name "$ENGINE_NAME" \
            --connection-string "$CONNECTION_STRING" \
            -n "$WORKERS" \
            --json-report --json-report-file=/results/report.json \
            --junitxml=/results/results.xml \
            -v \
            ${PYTEST_ARGS[@]+"${PYTEST_ARGS[@]}"} \
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
                --engine-name "$ENGINE_NAME" \
                --connection-string "$CONNECTION_STRING" \
                -m "not no_parallel" \
                -n "$WORKERS" \
                --json-report --json-report-file=/results/report.json \
                --junitxml=/results/results.xml \
                -v \
                ${PYTEST_ARGS[@]+"${PYTEST_ARGS[@]}"} \
                || true

            if [ ! -f "$RUN_DIR/report.json" ]; then
                echo "No report.json produced in bootstrap run $RUN."
                TEST_EXIT=1
                break
            fi

            RUN_PASSING=$(python3 -c '
import json
import sys

prefix = "documentdb_tests/"
with open(sys.argv[1]) as f:
    report = json.load(f)
for test in report.get("tests", []):
    if test.get("outcome") == "passed":
        nodeid = test["nodeid"]
        if nodeid.startswith(prefix):
            nodeid = nodeid[len(prefix):]
        print(nodeid)
' "$RUN_DIR/report.json" | sort)

            if [ "$RUN" -eq 1 ]; then
                ALL_PASSING="$RUN_PASSING"
            else
                ALL_PASSING=$(comm -12 <(echo "$ALL_PASSING") <(echo "$RUN_PASSING"))
            fi

            echo "Passing in run $RUN: $(echo "$RUN_PASSING" | grep -c '.' || true)"
        done

        if [ "$TEST_EXIT" -eq 0 ]; then
            python3 -c '
import sys
import yaml

output_path = sys.argv[1]
tests = sorted(line.strip() for line in sys.stdin if line.strip())
with open(output_path, "w") as f:
    yaml.dump({"schema_version": 1, "tests": tests}, f, default_flow_style=False, width=200)
print(f"Wrote {len(tests)} tests to {output_path}")
' "$OUTPUT" <<< "$ALL_PASSING"
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
