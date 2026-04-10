#!/usr/bin/env bash

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "${script_dir}/../.." && pwd)"

function show_help {
    cat <<EOF
Usage: $0 [run|build|test|logs|down] [options]

Description:
  Build documentdb-local, then run the functional test stack with Docker Compose.

Commands:
  run                  Build packages if needed, build the local image, then run tests
  build                Build packages if needed, then build the documentdb-local image only
  test                 Run tests against the already-built documentdb-local image
  logs                 Show Docker Compose logs for the local stack
  down                 Stop and remove the local stack

Options:
  --os <value>         Package OS for packaging/build_packages.sh (default: deb13)
  --pg <value>         PostgreSQL version (default: 17)
  --output-dir <dir>   Package output dir relative to the repo root (default: downloaded-artifacts)
  --base-image <img>   Base image for Dockerfile_gateway (default: debian:trixie-slim)
  --username <value>   DocumentDB username (default: docdb_user)
  --password <value>   DocumentDB password (default: DocDB_local)
  --host-port <value>  Host port to publish DocumentDB on (default: 10260)
  --scope <value>      Test scope to run: smoke or full (default: smoke)
  --documentdb-image <img>
                       Local image tag for the built documentdb-local image
  --test-image <img>   Functional test image reference or local image ID
                       (default: pinned digest in GitHub Actions, otherwise
                       ghcr.io/documentdb/functional-tests:latest)
  --results-dir <dir>  Results directory (default: <repo>/functional-test-results)
  --pytest-args <arg>  Extra pytest arguments, passed through to the test container
  --exclude-deselect-file
                       Run the full suite without applying deselect.list
  --skip-package-build Reuse an existing package in --output-dir
  -h, --help           Show this help text
EOF
    exit 0
}

command="run"
package_os="deb13"
pg_version="17"
package_output_dir="downloaded-artifacts"
base_image="debian:trixie-slim"
docdb_username="docdb_user"
docdb_password="DocDB_local"
docdb_host_port="10260"
documentdb_image="documentdb-local-functional:local"
default_test_image="ghcr.io/documentdb/functional-tests:latest"
test_image_pin_file="${TEST_IMAGE_PIN_FILE:-${script_dir}/test-image-pin.txt}"
test_image="${TEST_IMAGE:-}"
results_dir="${repo_root}/functional-test-results"
test_scope="smoke"
compose_config_path="${script_dir}/docker-compose.yml"
compose_project_name="${COMPOSE_PROJECT_NAME:-documentdb-functional-tests}"
exclude_deselect_file=false
pytest_extra_args=""
skip_package_build=false

if [[ $# -gt 0 && "$1" != -* ]]; then
    command="$1"
    shift
fi

function is_known_option {
    case "$1" in
        --os|--pg|--output-dir|--base-image|--username|--password|--host-port|--scope|--documentdb-image|--test-image|--results-dir|--pytest-args|--exclude-deselect-file|--skip-package-build|-h|--help)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

function require_option_value {
    local flag="$1"
    local value="${2-}"

    if is_known_option "${value}"; then
        echo "Missing value for ${flag}" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --os)
            shift
            require_option_value "--os" "${1-}"
            package_os="$1"
            ;;
        --pg)
            shift
            require_option_value "--pg" "${1-}"
            pg_version="$1"
            ;;
        --output-dir)
            shift
            require_option_value "--output-dir" "${1-}"
            package_output_dir="$1"
            ;;
        --base-image)
            shift
            require_option_value "--base-image" "${1-}"
            base_image="$1"
            ;;
        --username)
            shift
            require_option_value "--username" "${1-}"
            docdb_username="$1"
            ;;
        --password)
            shift
            require_option_value "--password" "${1-}"
            docdb_password="$1"
            ;;
        --host-port)
            shift
            require_option_value "--host-port" "${1-}"
            docdb_host_port="$1"
            ;;
        --scope)
            shift
            require_option_value "--scope" "${1-}"
            test_scope="$1"
            ;;
        --documentdb-image)
            shift
            require_option_value "--documentdb-image" "${1-}"
            documentdb_image="$1"
            ;;
        --test-image)
            shift
            require_option_value "--test-image" "${1-}"
            test_image="$1"
            ;;
        --results-dir)
            shift
            require_option_value "--results-dir" "${1-}"
            results_dir="$1"
            ;;
        --pytest-args)
            shift
            require_option_value "--pytest-args" "${1-}"
            pytest_extra_args="$1"
            ;;
        --exclude-deselect-file)
            exclude_deselect_file=true
            ;;
        --skip-package-build)
            skip_package_build=true
            ;;
        -h|--help)
            show_help
            ;;
        *)
            echo "Unknown argument: $1"
            show_help
            exit 1
            ;;
    esac
    shift
done

function require_docker_compose {
    docker compose version > /dev/null
}

function read_pinned_test_image {
    bash "${script_dir}/read_pin.sh" "${test_image_pin_file}"
}

function resolve_default_test_image {
    if [[ -n "${test_image}" ]]; then
        return 0
    fi

    if [[ "${GITHUB_ACTIONS:-}" == "true" ]]; then
        if test_image="$(read_pinned_test_image)"; then
            return 0
        fi

        echo "No pinned functional test image found in ${test_image_pin_file}." >&2
        echo "Set TEST_IMAGE/--test-image or update the pin file." >&2
        exit 1
    fi

    test_image="${default_test_image}"
}

function build_packages {
    "${repo_root}/packaging/build_packages.sh" \
        --os "${package_os}" \
        --pg "${pg_version}" \
        --output-dir "${package_output_dir}"
}

function resolve_deb_package {
    local abs_output_dir="${repo_root}/${package_output_dir}"
    local package_path

    if [[ ! -d "${abs_output_dir}" ]]; then
        echo "No Debian package found in ${abs_output_dir}. Run '$0 build' first, remove --skip-package-build, or point --output-dir at a directory containing a built package." >&2
        exit 1
    fi

    package_path="$(find "${abs_output_dir}" -maxdepth 1 -type f -name '*.deb' ! -name '*dbgsym*' | sort | head -n 1)"
    if [[ -z "${package_path}" ]]; then
        echo "No Debian package found in ${abs_output_dir}. Run '$0 build' first, remove --skip-package-build, or point --output-dir at a directory containing a built package." >&2
        exit 1
    fi

    if [[ "${package_path}" != "${repo_root}/"* ]]; then
        echo "Package path must stay under the repository root: ${package_path}" >&2
        exit 1
    fi

    echo "${package_path#${repo_root}/}"
}

function resolve_deb_package_for_maintenance {
    local abs_output_dir="${repo_root}/${package_output_dir}"
    local package_path

    if [[ ! -d "${abs_output_dir}" ]]; then
        echo "${package_output_dir}/placeholder-documentdb.deb"
        return 0
    fi

    package_path="$(find "${abs_output_dir}" -maxdepth 1 -type f -name '*.deb' ! -name '*dbgsym*' | sort | head -n 1 || true)"
    if [[ -z "${package_path}" ]]; then
        echo "${package_output_dir}/placeholder-documentdb.deb"
        return 0
    fi

    if [[ "${package_path}" != "${repo_root}/"* ]]; then
        echo "Package path must stay under the repository root: ${package_path}" >&2
        exit 1
    fi

    echo "${package_path#${repo_root}/}"
}

function prepare_results_dir {
    mkdir -p "${results_dir}"
    results_dir="$(cd "${results_dir}" && pwd)"
    rm -f "${results_dir}/functional-report.json" "${results_dir}/functional-results.xml"
    chmod 0777 "${results_dir}"
}

function export_compose_env {
    local deb_package_rel_path="$1"

    export BASE_IMAGE="${base_image}"
    export DEB_PACKAGE_REL_PATH="${deb_package_rel_path}"
    export DOCDB_HOST_PORT="${docdb_host_port}"
    export DOCDB_PASSWORD="${docdb_password}"
    export DOCDB_USERNAME="${docdb_username}"
    export DOCUMENTDB_IMAGE="${documentdb_image}"
    export PG_VERSION="${pg_version}"
    if [[ "${exclude_deselect_file}" == true ]]; then
        export TEST_DESELECT_FILE=""
    else
        export TEST_DESELECT_FILE="${TEST_DESELECT_FILE-/workspace/scripts/functional_tests/deselect.list}"
    fi
    export TEST_SCOPE="${test_scope}"
    export TEST_IMAGE="${test_image}"
    export PYTEST_EXTRA_ARGS="${pytest_extra_args}"
    export TEST_RESULTS_DIR="${results_dir}"
}

function validate_scope {
    case "${test_scope}" in
        smoke|full)
            ;;
        *)
            echo "Invalid --scope value: ${test_scope}. Allowed values are 'smoke' and 'full'." >&2
            exit 1
            ;;
    esac
}

function ensure_test_image_available {
    if docker image inspect "${test_image}" > /dev/null 2>&1; then
        return 0
    fi

    docker pull "${test_image}"
}

function maybe_build_packages {
    if [[ "${skip_package_build}" != true ]]; then
        build_packages
    fi
}

function prepare_compose_environment {
    local prepare_results="${1:-false}"
    local deb_package_rel_path

    if [[ "${prepare_results}" == true ]]; then
        prepare_results_dir
    fi

    deb_package_rel_path="$(resolve_deb_package)"
    export_compose_env "${deb_package_rel_path}"
}

function prepare_maintenance_environment {
    local prepare_results="${1:-false}"
    local deb_package_rel_path

    if [[ "${prepare_results}" == true ]]; then
        prepare_results_dir
    fi

    deb_package_rel_path="$(resolve_deb_package_for_maintenance)"
    export_compose_env "${deb_package_rel_path}"
}

function build_stack_image {
    maybe_build_packages
    prepare_compose_environment false
    docker compose -f "${compose_config_path}" -p "${compose_project_name}" build documentdb-local
}

function start_documentdb_service {
    docker compose -f "${compose_config_path}" -p "${compose_project_name}" up -d --no-build documentdb-local
}

function wait_for_documentdb_service {
    local container_id
    local status
    local attempt

    container_id="$(docker compose -f "${compose_config_path}" -p "${compose_project_name}" ps -q documentdb-local)"
    if [[ -z "${container_id}" ]]; then
        echo "Could not find a documentdb-local container for project ${compose_project_name}" >&2
        exit 1
    fi

    for attempt in $(seq 1 60); do
        status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "${container_id}" 2>/dev/null || true)"
        case "${status}" in
            healthy)
                return 0
                ;;
            unhealthy|exited|dead)
                echo "documentdb-local became unhealthy while waiting for readiness." >&2
                docker logs "${container_id}" >&2 || true
                exit 1
                ;;
        esac
        sleep 2
    done

    echo "Timed out waiting for documentdb-local to become healthy." >&2
    docker logs "${container_id}" >&2 || true
    exit 1
}

function run_test_service {
    local status

    ensure_test_image_available
    # `docker compose run --no-deps` skips depends_on handling, so readiness is
    # enforced explicitly here before the test container starts.
    start_documentdb_service
    wait_for_documentdb_service

    if docker compose -f "${compose_config_path}" -p "${compose_project_name}" run --rm --no-deps functional-tests; then
        status=0
    else
        status=$?
    fi

    echo "Functional test results are in ${results_dir}"
    echo "Use '$0 logs' to inspect the stack or '$0 down' to remove it."
    return "${status}"
}

function run_stack {
    build_stack_image
    prepare_compose_environment true
    run_test_service
}

function test_stack {
    prepare_maintenance_environment true
    run_test_service
}

function show_logs {
    prepare_maintenance_environment
    docker compose -f "${compose_config_path}" -p "${compose_project_name}" logs
}

function tear_down_stack {
    prepare_maintenance_environment
    docker compose -f "${compose_config_path}" -p "${compose_project_name}" down --volumes --remove-orphans
}

require_docker_compose
validate_scope
resolve_default_test_image

case "${command}" in
    run)
        run_stack
        ;;
    build)
        build_stack_image
        ;;
    test)
        test_stack
        ;;
    logs)
        show_logs
        ;;
    down)
        tear_down_stack
        ;;
    *)
        echo "Unknown command: ${command}"
        show_help
        exit 1
        ;;
esac
