#!/usr/bin/env bash

set -euo pipefail

results_dir="${TEST_RESULTS_DIR:-/app/.test-results}"
default_deselect_file="/workspace/scripts/functional_tests/deselect.list"
deselect_file="${TEST_DESELECT_FILE-${default_deselect_file}}"
connection_string="${TEST_CONNECTION_STRING:?TEST_CONNECTION_STRING is required}"
test_scope="${TEST_SCOPE:-smoke}"
pytest_extra_args="${PYTEST_EXTRA_ARGS:-}"

mkdir -p "${results_dir}"

args=(
    documentdb_tests/compatibility/tests
    -n
    auto
    --connection-string "${connection_string}"
    --engine-name documentdb
    --json-report
    --json-report-file "${results_dir}/functional-report.json"
    --junitxml "${results_dir}/functional-results.xml"
)

case "${test_scope}" in
    smoke)
        args=( -m smoke "${args[@]}" )
        ;;
    full)
        ;;
    *)
        echo "Unsupported TEST_SCOPE: ${test_scope}. Expected 'smoke' or 'full'." >&2
        exit 1
        ;;
esac

if [[ -n "${deselect_file}" && -f "${deselect_file}" ]]; then
    while IFS= read -r nodeid; do
        args+=( "--deselect=${nodeid}" )
    done < <(
        sed \
            -e 's/[[:space:]]*#.*$//' \
            -e 's/^[[:space:]]*//' \
            -e 's/[[:space:]]*$//' \
            -e '/^[[:space:]]*$/d' \
            "${deselect_file}"
    )
fi

if [[ -n "${pytest_extra_args}" ]]; then
    while IFS= read -r pytest_arg; do
        args+=( "${pytest_arg}" )
    done < <(
        PYTEST_EXTRA_ARGS="${pytest_extra_args}" python3 -c '
import os
import shlex

for item in shlex.split(os.environ["PYTEST_EXTRA_ARGS"]):
    print(item)
'
    )
fi

exec pytest --rootdir documentdb_tests "${args[@]}"
