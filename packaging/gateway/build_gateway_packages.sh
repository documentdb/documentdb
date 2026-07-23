#!/bin/bash

set -euo pipefail

# set script_dir to the root of the repository (3 levels up from packaging/gateway/)
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Function to display help message
function show_help {
    echo "Usage: $0 --os <OS> --pg <PG_VERSION> [--test-clean-install] [--output-dir <DIR>] [-h|--help]"
    echo ""
    echo "Description:"
    echo "  This script builds gateway packages (DEB/RPM) using Docker."
    echo ""
    echo "Mandatory Arguments:"
    echo "  --os                 OS to build packages for. Possible values: [deb11, deb12, deb13, ubuntu22.04, ubuntu24.04, rhel8, rhel9]"
    echo "  --pg                 PG version to build packages for. Possible values: [15, 16, 17, 18]"
    echo ""
    echo "Optional Arguments:"
    echo "  --version            The version of documentdb to build. Examples: [0.100.0, 0.101.0]"
    echo "  --test-clean-install Test installing the packages in a clean Docker container."
    echo "  --output-dir         Relative path from the repo root of the directory where to drop the packages. The directory will be created if it doesn't exist. Default: packaging"
    echo "  -h, --help           Display this help message."
    exit 0
}

# Initialize variables
OS=""
PG=""
DOCUMENTDB_VERSION=""
TEST_CLEAN_INSTALL=false
OUTPUT_DIR="packaging"  # Default value for output directory (relative to script_dir)
PACKAGE_TYPE=""  # Will be set to "deb" or "rpm"

function add_docker_test_capabilities {
    local image="$1"
    local -n args_ref="$2"

    args_ref=()
    if docker run --rm --cap-add=SYS_PTRACE --entrypoint /bin/true "$image" >/dev/null 2>&1; then
        # The cap is grantable, so the real run gets it AND we require the
        # capability-gated guard tests to actually run: GUARD_TESTS_REQUIRED=1
        # turns a guard-test skip into a failure inside the entrypoint, closing
        # the silent-skip blind spot where a green run never executed the guard.
        args_ref+=(--cap-add=SYS_PTRACE --env GUARD_TESTS_REQUIRED=1)
        echo "Clean-install test will run with SYS_PTRACE; capability-gated guard tests are REQUIRED to run (a skip becomes a failure)."
    else
        echo "Warning: Docker refused SYS_PTRACE for $image; capability-gated guard tests may SKIP and will be listed in the run's end-of-run summary." >&2
    fi
}

# Process arguments to convert long options to short ones
while [[ $# -gt 0 ]]; do
    case "$1" in
        --os)
            shift
            case $1 in
                deb11|deb12|deb13|ubuntu22.04|ubuntu24.04)
                    OS=$1
                    PACKAGE_TYPE="deb"
                    ;;
                rhel8|rhel9)
                    OS=$1
                    PACKAGE_TYPE="rpm"
                    ;;
                *)
                    echo "Invalid --os value. Allowed values are [deb11, deb12, deb13, ubuntu22.04, ubuntu24.04, rhel8, rhel9]"
                    exit 1
                    ;;
            esac
            ;;
        --pg)
            shift
            case $1 in
                15|16|17|18)
                    PG=$1
                    ;;
                *)
                    echo "Invalid --pg value. Allowed values are [15, 16, 17, 18]"
                    exit 1
                    ;;
            esac
            ;;
        --version)
            shift
            DOCUMENTDB_VERSION=$1
            ;;
        --test-clean-install)
            TEST_CLEAN_INSTALL=true
            ;;
        --output-dir)
            shift
            OUTPUT_DIR=$1
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

# Check mandatory arguments
if [[ -z "$OS" ]]; then
    echo "Error: --os is required."
    show_help
    exit 1
fi

if [[ -z "$PG" ]]; then
    echo "Error: --pg is required."
    show_help
    exit 1
fi

if [[ -z "$DOCUMENTDB_VERSION" ]]; then
    DOCUMENTDB_VERSION=$(grep -E "^default_version" "$script_dir/pg_documentdb_core/documentdb_core.control" | sed -E "s/.*'([0-9]+\.[0-9]+-[0-9]+)'.*/\1/")
    DOCUMENTDB_VERSION=$(echo "$DOCUMENTDB_VERSION" | sed "s/-/./g")
    echo "DOCUMENTDB_VERSION extracted from control file: $DOCUMENTDB_VERSION"
fi

if [[ -z "$DOCUMENTDB_VERSION" ]]; then
    echo "Error: --version is required and could not be found in the control file."
    show_help
    exit 1
fi

# Validate that DOCUMENTDB_VERSION is a SemVer-compatible string before we
# bake it into Cargo.toml, the deb filename, and the RPM spec. An empty or
# malformed value would otherwise propagate silently into the package
# metadata and cause confusing failures (e.g. rpmbuild rejecting the spec
# late, cargo refusing to compile because the workspace version is empty,
# or operators seeing a literal placeholder in `dpkg -l` output).
if ! [[ "$DOCUMENTDB_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][0-9A-Za-z.-]+)?$ ]]; then
    echo "Error: DOCUMENTDB_VERSION '$DOCUMENTDB_VERSION' is not a valid SemVer-compatible version string." >&2
    echo "Expected: MAJOR.MINOR.PATCH (with optional .N or -PRERELEASE suffix), e.g. 0.113.0 or 1.2.3-rc1." >&2
    exit 1
fi

# Set the appropriate Docker image and configuration based on the OS
DOCKERFILE=""
OS_VERSION_NUMBER=""

if [[ "$PACKAGE_TYPE" == "deb" ]]; then
    case $OS in
        deb11)
            DOCKER_IMAGE="rust:slim-bullseye"
            TEST_DOCKER_IMAGE="debian:bullseye-slim"
            DOCKERFILE="${script_dir}/packaging/gateway/deb/Dockerfile_gateway_deb"
            ;;
        deb12)
            DOCKER_IMAGE="rust:slim-bookworm"
            TEST_DOCKER_IMAGE="debian:bookworm-slim"
            DOCKERFILE="${script_dir}/packaging/gateway/deb/Dockerfile_gateway_deb"
            ;;
        deb13)
            DOCKER_IMAGE="rust:slim-trixie"
            TEST_DOCKER_IMAGE="debian:trixie-slim"
            DOCKERFILE="${script_dir}/packaging/gateway/deb/Dockerfile_gateway_deb"
            ;;
        # Ubuntu images need to install rust manually
        ubuntu22.04)
            DOCKER_IMAGE="ubuntu:22.04"
            TEST_DOCKER_IMAGE="ubuntu:22.04"
            DOCKERFILE="${script_dir}/packaging/gateway/deb/Dockerfile_gateway_ubuntu"
            ;;
        ubuntu24.04)
            DOCKER_IMAGE="ubuntu:24.04"
            TEST_DOCKER_IMAGE="ubuntu:24.04"
            DOCKERFILE="${script_dir}/packaging/gateway/deb/Dockerfile_gateway_ubuntu"
            ;;
    esac
elif [[ "$PACKAGE_TYPE" == "rpm" ]]; then
    case $OS in
        rhel8)
            DOCKER_IMAGE="rockylinux:8"
            TEST_DOCKER_IMAGE="rockylinux:8"
            DOCKERFILE="${script_dir}/packaging/rpm/Dockerfile_gateway_rhel"
            ;;
        rhel9)
            DOCKER_IMAGE="rockylinux:9"
            TEST_DOCKER_IMAGE="rockylinux:9"
            DOCKERFILE="${script_dir}/packaging/rpm/Dockerfile_gateway_rhel"
            ;;
        *)
            echo "Error: Invalid OS specified for RPM build: $OS"
            exit 1
            ;;
    esac
fi

TAG=documentdb-build-packages-$OS-pg$PG:latest

abs_output_dir="$script_dir/$OUTPUT_DIR"

echo "Building $PACKAGE_TYPE packages for OS: $OS, PostgreSQL version: $PG, DOCUMENTDB version: $DOCUMENTDB_VERSION"
echo "Output directory: $abs_output_dir"

# Create the output directory if it doesn't exist
mkdir -p "$abs_output_dir"
chmod 777 "$abs_output_dir"

# Build the Docker image while showing the output to the console
if [[ "$PACKAGE_TYPE" == "deb" ]]; then
    docker build -t "$TAG" -f "$DOCKERFILE" \
        --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
        --build-arg DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" "$script_dir"
    # Run the Docker container to build the packages
    docker run --rm --env OS="$OS" --env DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" -v "$abs_output_dir:/output" "$TAG"
elif [[ "$PACKAGE_TYPE" == "rpm" ]]; then
    # Build the gateway RPM via the rhel-8 / rhel-9 Dockerfile (builds the
    # Rust daemon, stages sources, runs rpmbuild, and copies the .rpm to
    # /output).
    docker build -t "$TAG" -f "$DOCKERFILE" \
        --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
        --build-arg DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" "$script_dir"
    # Run the Docker container to build the packages
    docker run --rm --env DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" -v "$abs_output_dir:/output" "$TAG"
fi

echo "Packages built successfully!!"

if [[ $TEST_CLEAN_INSTALL == true ]]; then
    # The clean-install test installs the full four-package stack and runs
    # documentdb-setup, whose gateway registration requires PostgreSQL 16+.
    # Building the gateway package itself is PG-agnostic, but the full-stack
    # clean-install cannot succeed on PG<16. PostgreSQL 15 is extension-only.
    if (( PG < 16 )); then
        echo "Error: --test-clean-install requires PostgreSQL 16+ (got ${PG}); the clean-install test runs documentdb-setup, which requires PostgreSQL 16+. PostgreSQL 15 is supported for the extension only." >&2
        exit 1
    fi
    echo "Testing clean installation in a Docker container..."

    # ── Build the 'extras' (documentdb-postgresql-tools + documentdb-N
    # standalone + documentdb meta) before invoking the test image. The
    # gateway-test Dockerfiles now install all four packages from
    # packaging-design.md §4 so the test entrypoint can run the full
    # Workflow C path (apt install documentdb → documentdb-setup →
    # systemctl target). Without this build step the docker COPY would
    # fail with "no such file or directory".
    #
    # build_extra_packages.sh is a pure-shell builder (no compilation)
    # so this adds ~5s to the test path. The PG-major and OS-prefix
    # match what build_packages.sh produces so package filenames line
    # up with the COPY paths below.
    echo "Building extras (tools + stand-alone + meta) for test container..."
    # build_extra_packages.sh handles both formats from one invocation: on the
    # rpm path it self-checks for rpmbuild on PATH (CI installs `rpm`) and ignores
    # --os-prefix (that prefix only renames .deb artifacts), so passing
    # PACKAGE_TYPE straight through keeps the two paths from drifting.
    "${script_dir}/packaging/build_extra_packages.sh" \
        --type "$PACKAGE_TYPE" \
        --pg "$PG" \
        --version "$DOCUMENTDB_VERSION" \
        --output-dir "$abs_output_dir" \
        --default-pg-major 18 \
        --os-prefix "$OS"

    if [[ "$PACKAGE_TYPE" == "deb" ]]; then
        deb_package_name=$(ls "$abs_output_dir" | grep -E "${OS}-postgresql-$PG-documentdb_${DOCUMENTDB_VERSION}.*\.deb" | grep -v "dbg" | head -n 1 || true)
        if [[ -z "$deb_package_name" ]]; then
            echo "DocumentDB extension package not found in $abs_output_dir; building it for clean-install validation."
            "${script_dir}/packaging/build_packages.sh" --os "$OS" --pg "$PG" --version "$DOCUMENTDB_VERSION" --output-dir "$OUTPUT_DIR"
        fi

        ls "$abs_output_dir"
        deb_package_name=$(ls "$abs_output_dir" | grep -E "${OS}-postgresql-$PG-documentdb_${DOCUMENTDB_VERSION}.*\.deb" | grep -v "dbg" | head -n 1)
        deb_package_rel_path="$OUTPUT_DIR/$deb_package_name"
        # Pin the exact version this script just built (mirrors the RPM
        # branch below). The previous versionless `ls | head -n 1` picked
        # the LEXICOGRAPHICALLY first match, so a stale lower-version
        # artifact lingering in the output dir (e.g. 0.115.0 beside the
        # freshly built 0.116.0) was silently staged into the test image
        # and failed the install with a version-skew dependency error.
        gateway_package_name=$(ls "$abs_output_dir" | grep -E "^${OS}-documentdb-gateway_${DOCUMENTDB_VERSION}_.*\.deb$" | grep -v "dbg" | head -n 1 || true)
        if [[ -z "$gateway_package_name" ]]; then
            # Fallback for a version mismatch between the gateway and the
            # extension: newest by mtime, never lexicographic order.
            # LC_ALL=C so the decimal epoch from %T@ sorts numerically
            # regardless of the build host's locale decimal separator.
            gateway_package_name=$(find "$abs_output_dir" -maxdepth 1 -name "${OS}-documentdb-gateway_*.deb" ! -name '*dbg*' -printf '%T@ %f\n' 2>/dev/null | LC_ALL=C sort -rn | head -n 1 | cut -d' ' -f2-)
            # Announce the fallback only if it actually found something. The
            # previous form printed "falling back to ... :" with an EMPTY name
            # whenever nothing matched either, so the operator's first
            # diagnostic asserted a success that had not happened, immediately
            # before the error below.
            if [[ -n "$gateway_package_name" ]]; then
                echo "Warning: no gateway .deb at version ${DOCUMENTDB_VERSION}; falling back to newest by mtime: ${gateway_package_name}" >&2
            fi
        fi
        if [[ -z "$gateway_package_name" ]]; then
            # Match the sibling resolvers below: dump the directory so the
            # operator can see what IS there.
            echo "Error: no ${OS}-documentdb-gateway_*.deb found in $abs_output_dir." >&2
            ls "$abs_output_dir" >&2
            exit 1
        fi
        gateway_package_rel_path="$OUTPUT_DIR/$gateway_package_name"

        # Track 1 extras — resolved from the OS-prefixed naming that
        # build_extra_packages.sh applies (matches build-meta-deb.sh
        # and build-standalone-deb.sh). Failing to find either of
        # these means the extras build above silently produced nothing
        # (or used a different naming convention); fail loudly.
        tools_package_name=$(ls "$abs_output_dir" | grep -E "^${OS}-documentdb-postgresql-tools_${DOCUMENTDB_VERSION}_all\.deb$" | head -n 1 || true)
        if [[ -z "$tools_package_name" ]]; then
            echo "Error: documentdb-postgresql-tools .deb not found in $abs_output_dir (looked for ${OS}-documentdb-postgresql-tools_${DOCUMENTDB_VERSION}_all.deb)." >&2
            ls "$abs_output_dir" | sed 's/^/    /' >&2
            exit 1
        fi
        tools_package_rel_path="$OUTPUT_DIR/$tools_package_name"

        standalone_package_name=$(ls "$abs_output_dir" | grep -E "^${OS}-documentdb-${PG}_${DOCUMENTDB_VERSION}_all\.deb$" | head -n 1 || true)
        if [[ -z "$standalone_package_name" ]]; then
            echo "Error: documentdb-${PG} stand-alone .deb not found in $abs_output_dir (looked for ${OS}-documentdb-${PG}_${DOCUMENTDB_VERSION}_all.deb)." >&2
            ls "$abs_output_dir" | sed 's/^/    /' >&2
            exit 1
        fi
        standalone_package_rel_path="$OUTPUT_DIR/$standalone_package_name"

        common_package_name=$(ls "$abs_output_dir" | grep -E "^${OS}-documentdb-common_${DOCUMENTDB_VERSION}_all\.deb$" | head -n 1 || true)
        if [[ -z "$common_package_name" ]]; then
            echo "Error: documentdb-common .deb not found in $abs_output_dir (looked for ${OS}-documentdb-common_${DOCUMENTDB_VERSION}_all.deb)." >&2
            ls "$abs_output_dir" | sed 's/^/    /' >&2
            exit 1
        fi
        common_package_rel_path="$OUTPUT_DIR/$common_package_name"

        echo "Debian package paths passed into Docker build:"
        echo "  extension:  $deb_package_rel_path"
        echo "  gateway:    $gateway_package_rel_path"
        echo "  tools:      $tools_package_rel_path"
        echo "  common:     $common_package_rel_path"
        echo "  standalone: $standalone_package_rel_path"

        # Build the Docker image while showing the output to the console
        docker build -t documentdb-test-gateway-packages:latest -f "${script_dir}/packaging/gateway/test/Dockerfile_deb_gateway_test" \
            --build-arg BASE_IMAGE="$TEST_DOCKER_IMAGE" \
            --build-arg POSTGRES_VERSION="$PG" \
            --build-arg DEB_PACKAGE_REL_PATH="$deb_package_rel_path" \
            --build-arg GATEWAY_PACKAGE_PATH="$gateway_package_rel_path" \
            --build-arg TOOLS_PACKAGE_REL_PATH="$tools_package_rel_path" \
            --build-arg COMMON_PACKAGE_REL_PATH="$common_package_rel_path" \
            --build-arg STANDALONE_PACKAGE_REL_PATH="$standalone_package_rel_path" \
            "$script_dir"
        # Run the Docker container to test the packages
        docker_run_args=()
        add_docker_test_capabilities documentdb-test-gateway-packages:latest docker_run_args
        docker run --rm "${docker_run_args[@]}" documentdb-test-gateway-packages:latest

    elif [[ "$PACKAGE_TYPE" == "rpm" ]]; then
        rpm_package_name=$(ls "$abs_output_dir" | grep -E "${OS}-postgresql${PG}-documentdb-${DOCUMENTDB_VERSION}.*\.(x86_64|aarch64)\.rpm" | head -n 1 || true)
        if [[ -z "$rpm_package_name" ]]; then
            echo "DocumentDB extension RPM package not found in $abs_output_dir; building it for clean-install validation."
            "${script_dir}/packaging/build_packages.sh" --os "$OS" --pg "$PG" --version "$DOCUMENTDB_VERSION" --output-dir "$OUTPUT_DIR"
        fi

        ls "$abs_output_dir"
        rpm_package_name=$(ls "$abs_output_dir" | grep -E "${OS}-postgresql${PG}-documentdb-${DOCUMENTDB_VERSION}.*\.(x86_64|aarch64)\.rpm" | head -n 1)
        rpm_package_rel_path="$OUTPUT_DIR/$rpm_package_name"
        # Pin to the dist tag (.el8/.el9) matching the build OS so that, when
        # both RHEL 8 and RHEL 9 gateway RPMs happen to share the output dir,
        # we do not pick the wrong distro's package. Fall back to the
        # un-qualified match so behavior is unchanged when only one is present.
        gateway_rpm_dist=""
        case "$OS" in
            *8*) gateway_rpm_dist="el8" ;;
            *9*) gateway_rpm_dist="el9" ;;
        esac
        gateway_rpm_package_name=""
        if [[ -n "$gateway_rpm_dist" ]]; then
            gateway_rpm_package_name=$(ls "$abs_output_dir" | grep -E "^documentdb-gateway-${DOCUMENTDB_VERSION}-.*\.${gateway_rpm_dist}\.(x86_64|aarch64)\.rpm$" | head -n 1 || true)
        fi
        if [[ -z "$gateway_rpm_package_name" ]]; then
            gateway_rpm_package_name=$(ls "$abs_output_dir" | grep -E "^documentdb-gateway-${DOCUMENTDB_VERSION}-.*\.(x86_64|aarch64)\.rpm" | head -n 1 || true)
        fi
        if [[ -z "$gateway_rpm_package_name" ]]; then
            echo "Error: Could not find the built gateway RPM package in $abs_output_dir for testing."
            exit 1
        fi
        gateway_rpm_package_rel_path="$OUTPUT_DIR/$gateway_rpm_package_name"

        # Track 1 extras (noarch RPMs produced by build_extra_packages.sh
        # --type rpm above). RPM filenames do NOT carry an OS prefix
        # (unlike the DEBs) so the patterns are simpler.
        tools_rpm_package_name=$(ls "$abs_output_dir" | grep -E "^documentdb-postgresql-tools-${DOCUMENTDB_VERSION}-.*\.noarch\.rpm$" | head -n 1 || true)
        if [[ -z "$tools_rpm_package_name" ]]; then
            echo "Error: documentdb-postgresql-tools RPM not found in $abs_output_dir." >&2
            ls "$abs_output_dir" | sed 's/^/    /' >&2
            exit 1
        fi
        tools_rpm_package_rel_path="$OUTPUT_DIR/$tools_rpm_package_name"

        standalone_rpm_package_name=$(ls "$abs_output_dir" | grep -E "^documentdb-${PG}-${DOCUMENTDB_VERSION}-.*\.noarch\.rpm$" | head -n 1 || true)
        if [[ -z "$standalone_rpm_package_name" ]]; then
            echo "Error: documentdb-${PG} stand-alone RPM not found in $abs_output_dir." >&2
            ls "$abs_output_dir" | sed 's/^/    /' >&2
            exit 1
        fi
        standalone_rpm_package_rel_path="$OUTPUT_DIR/$standalone_rpm_package_name"

        common_rpm_package_name=$(ls "$abs_output_dir" | grep -E "^documentdb-common-${DOCUMENTDB_VERSION}-.*\.noarch\.rpm$" | head -n 1 || true)
        if [[ -z "$common_rpm_package_name" ]]; then
            echo "Error: documentdb-common RPM not found in $abs_output_dir." >&2
            ls "$abs_output_dir" | sed 's/^/    /' >&2
            exit 1
        fi
        common_rpm_package_rel_path="$OUTPUT_DIR/$common_rpm_package_name"

        echo "RPM package paths passed into Docker build:"
        echo "  extension:  $rpm_package_rel_path"
        echo "  gateway:    $gateway_rpm_package_rel_path"
        echo "  tools:      $tools_rpm_package_rel_path"
        echo "  common:     $common_rpm_package_rel_path"
        echo "  standalone: $standalone_rpm_package_rel_path"

        if [[ "$OS" == "rhel8" || "$OS" == "rhel9" ]]; then
            # Single parameterized Dockerfile for both EL families; the EL major
            # is derived from the base image (BASE_IMAGE build-arg, passed below).
            TEST_DOCKERFILE="${script_dir}/packaging/test_packages/Dockerfile-rhel-gateway-test"
        else
            echo "Error: Unknown RPM OS for test Dockerfile: $OS"
            exit 1
        fi

        docker build -t documentdb-test-gateway-rpm-packages:latest -f "$TEST_DOCKERFILE" \
            --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
            --build-arg POSTGRES_VERSION="$PG" \
            --build-arg RPM_PACKAGE_REL_PATH="$rpm_package_rel_path" \
            --build-arg GATEWAY_RPM_PACKAGE_REL_PATH="$gateway_rpm_package_rel_path" \
            --build-arg TOOLS_RPM_PACKAGE_REL_PATH="$tools_rpm_package_rel_path" \
            --build-arg COMMON_RPM_PACKAGE_REL_PATH="$common_rpm_package_rel_path" \
            --build-arg STANDALONE_RPM_PACKAGE_REL_PATH="$standalone_rpm_package_rel_path" \
            "$script_dir"

        docker_run_args=()
        add_docker_test_capabilities documentdb-test-gateway-rpm-packages:latest docker_run_args
        docker run --rm "${docker_run_args[@]}" --env POSTGRES_VERSION="$PG" documentdb-test-gateway-rpm-packages:latest
    fi

    echo "Clean installation test successful!!"
fi

echo "Packages are available in $abs_output_dir"
