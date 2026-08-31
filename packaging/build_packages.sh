#!/bin/bash

set -euo pipefail

# set script_dir to the parent directory of the script
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# Function to display help message
function show_help {
    echo "Usage: $0 --os <OS> --pg <PG_VERSION> [--test-clean-install] [--output-dir <DIR>] [-h|--help]"
    echo ""
    echo "Description:"
    echo "  This script builds extension packages (DEB/RPM) using Docker."
    echo ""
    echo "Mandatory Arguments:"
    echo "  --os                 OS to build packages for. Possible values: [deb11, deb12, ubuntu22.04, ubuntu24.04, ubuntu26.04, rhel8, rhel9]"
    echo "  --pg                 PG version to build packages for. Possible values: [15, 16, 17, 18]"
    echo ""
    echo "Optional Arguments:"
    echo "  --version            The version of documentdb to build. Examples: [0.100.0, 0.101.0]"
    echo "  --test-clean-install Test installing the packages in a clean Docker container."
    echo "  --no-dbgsym          DEB only: skip generation of the -dbgsym debug package. Use where the debug package would be discarded anyway."
    echo "  --output-dir         Relative path from the repo root of the directory where to drop the packages. The directory will be created if it doesn't exist. Default: packaging"
    echo "  -h, --help           Display this help message."
    exit 0
}

# Initialize variables
OS=""
PG=""
DOCUMENTDB_VERSION=""
TEST_CLEAN_INSTALL=false
NO_DBGSYM=false
OUTPUT_DIR="packaging"  # Default value for output directory (relative to script_dir)
PACKAGE_TYPE=""  # Will be set to "deb" or "rpm"

# Process arguments to convert long options to short ones
while [[ $# -gt 0 ]]; do
    case "$1" in
        --os)
            shift
            case $1 in
                deb11|deb12|deb13|ubuntu22.04|ubuntu24.04|ubuntu26.04)
                    OS=$1
                    PACKAGE_TYPE="deb"
                    ;;
                rhel8|rhel9)
                    OS=$1
                    PACKAGE_TYPE="rpm"
                    ;;
                *)
                    echo "Invalid --os value. Allowed values are [deb11, deb12, ubuntu22.04, ubuntu24.04, ubuntu26.04, rhel8, rhel9]"
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
        --no-dbgsym)
            NO_DBGSYM=true
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

# get the version from control file
if [[ -z "$DOCUMENTDB_VERSION" ]]; then
    DOCUMENTDB_VERSION=$(grep -E "^default_version" pg_documentdb_core/documentdb_core.control | sed -E "s/.*'([0-9]+\.[0-9]+-[0-9]+)'.*/\1/")
    DOCUMENTDB_VERSION=$(echo $DOCUMENTDB_VERSION | sed "s/-/./g")
    echo "DOCUMENTDB_VERSION extracted from control file: $DOCUMENTDB_VERSION"
    if [[ -z "$DOCUMENTDB_VERSION" ]]; then
        echo "Error: --version is required and could not be found in the control file."
        show_help
        exit 1
    fi
fi

# Set the appropriate Docker image and configuration based on the OS
DOCKERFILE=""
OS_VERSION_NUMBER=""

if [[ "$PACKAGE_TYPE" == "deb" ]]; then
    DOCKERFILE="${script_dir}/packaging/deb/Dockerfile-deb"
    case $OS in
        deb11)
            DOCKER_IMAGE="debian:bullseye"
            ;;
        deb12)
            DOCKER_IMAGE="debian:bookworm"
            ;;
        deb13)
            DOCKER_IMAGE="debian:trixie"
            ;;
        ubuntu22.04)
            DOCKER_IMAGE="ubuntu:22.04"
            ;;
        ubuntu24.04)
            DOCKER_IMAGE="ubuntu:24.04"
            ;;
        ubuntu26.04)
            DOCKER_IMAGE="ubuntu:26.04"
            ;;
    esac
elif [[ "$PACKAGE_TYPE" == "rpm" ]]; then
    case $OS in
        rhel8)
            DOCKERFILE="${script_dir}/packaging/rpm/rhel-8/Dockerfile-rhel8"
            DOCKER_IMAGE="rockylinux:8"
            ;;
        rhel9)
            DOCKERFILE="${script_dir}/packaging/rpm/rhel-9/Dockerfile-rhel9"
            DOCKER_IMAGE="rockylinux:9"
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

# Build the Docker image while showing the output to the console
if [[ "$PACKAGE_TYPE" == "deb" ]]; then
    # noautodbgsym stops dh_strip from emitting the automatic -dbgsym package.
    # It is the documented spelling of this build option (dh_strip also honours
    # the historical "noddebs" alias). debuild preserves DEB_* variables through
    # its environment sanitizing, so the value set here reaches dh inside the
    # container; an empty value is a no-op.
    DEB_BUILD_OPTIONS_VALUE=""
    if [[ $NO_DBGSYM == true ]]; then
        DEB_BUILD_OPTIONS_VALUE="noautodbgsym"
    fi
    docker build -t "$TAG" -f "$DOCKERFILE" \
        --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
        --build-arg POSTGRES_VERSION="$PG" \
        --build-arg DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" "$script_dir"
    # Run the Docker container to build the packages
    docker run --rm --env OS="$OS" --env POSTGRES_VERSION="$PG" --env DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" --env DEB_BUILD_OPTIONS="$DEB_BUILD_OPTIONS_VALUE" -v "$abs_output_dir:/output" "$TAG"
elif [[ "$PACKAGE_TYPE" == "rpm" ]]; then
    docker build -t "$TAG" -f "$DOCKERFILE" \
        --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
        --build-arg POSTGRES_VERSION="$PG" \
        --build-arg DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" "$script_dir"
    # Run the Docker container to build the packages
    docker run --rm --env OS="$OS" --env POSTGRES_VERSION="$PG" --env DOCUMENTDB_VERSION="$DOCUMENTDB_VERSION" -v "$abs_output_dir:/output" "$TAG"
fi

echo "Packages built successfully!!"

if [[ $TEST_CLEAN_INSTALL == true ]]; then
    echo "Testing clean installation in a Docker container..."

    # The test container is started with --rm, so everything the regression
    # suite writes is destroyed the moment it exits. Bind-mount a directory so
    # the entrypoint can copy the regression diffs and server logs somewhere
    # that outlives it. TEST_ARTIFACTS_DIR overrides the location; otherwise a
    # temporary directory is used and removed again when the tests pass.
    if [[ -n "${TEST_ARTIFACTS_DIR:-}" ]]; then
        mkdir -p "$TEST_ARTIFACTS_DIR"
        test_artifacts_temporary=false
    else
        TEST_ARTIFACTS_DIR="$(mktemp -d)"
        test_artifacts_temporary=true
    fi
    abs_test_artifacts_dir="$(cd "$TEST_ARTIFACTS_DIR" && pwd)"
    test_run_args=(-v "$abs_test_artifacts_dir:/test-artifacts"
                   --env TEST_ARTIFACTS_DIR=/test-artifacts)

    # Boot-relative watermark for tying dmesg records to this run: dmesg stamps
    # each record with seconds since boot, the clock /proc/uptime also reports.
    # Empty on a host without /proc/uptime.
    test_start_uptime=""
    function mark_test_start {
        test_start_uptime="$(cut -d' ' -f1 /proc/uptime 2>/dev/null || true)"
    }

    # Host-side diagnostics for a failed test container. Must never abort part
    # way: the container's own evidence is already in the bind mount waiting to
    # be archived, so every step below degrades instead of failing.
    function report_host_diagnostics {
        local label="$1"
        local dmesg_out="$abs_test_artifacts_dir/dmesg-crash-records.txt"
        local matches="" tarball had_container_artifacts=false
        local crash_pattern raw_dmesg window_start window_note outside uncorrelated window_margin

        # Drop a stale capture from an earlier leg sharing an explicit
        # TEST_ARTIFACTS_DIR before probing what the container left behind.
        rm -f "$dmesg_out" 2>/dev/null || true
        if [[ -n "$(ls -A "$abs_test_artifacts_dir" 2>/dev/null)" ]]; then
            had_container_artifacts=true
        fi

        # A backend SIGSEGV leaves its faulting ip and the object it landed in
        # here, e.g. "segfault at 0 ip ... in documentdb.so[...+0x2a000]", which
        # addr2line resolves without a core dump or debug symbols in the image.
        # Only the host can read it, and -n keeps sudo from prompting on a dev
        # machine. The buffer is host-wide, so it is captured to a scratch file
        # outside the artifacts directory and only the filtered result is ever
        # written where the archive step can see it.
        crash_pattern='segfault|general protection|traps:|out of memory|killed process'
        # Named once so the window and the text describing it cannot drift.
        window_margin=5
        raw_dmesg=""
        # SC2024: only dmesg needs the privilege, and the target is a file we
        # created. The directive must precede the whole compound command here,
        # not the elif.
        # shellcheck disable=SC2024
        if ! raw_dmesg="$(mktemp 2>/dev/null)"; then
            raw_dmesg=""
            echo "Could not create a scratch file for the kernel ring buffer; skipping kernel crash records."
        elif dmesg 2>/dev/null > "$raw_dmesg" || sudo -n dmesg 2>/dev/null > "$raw_dmesg"; then
            # The margin covers sampling and container startup jitter only. It
            # cannot cover suspend: /proc/uptime is CLOCK_BOOTTIME (counts
            # suspended time), printk uses local_clock (does not), so a host
            # that has slept is off by its whole suspend time. CI agents do not
            # suspend; a laptop that has falls through to the uncorrelated
            # branch and says so. awk runs inside the condition so that a
            # failure degrades there too instead of aborting.
            if [[ -n "$test_start_uptime" ]] \
               && grep -qE '^\[[[:space:]]*[0-9]+\.[0-9]+\]' "$raw_dmesg" \
               && window_start="$(awk -v u="$test_start_uptime" -v m="$window_margin" 'BEGIN { s = u - m; printf "%.6f", (s > 0 ? s : 0) }')" \
               && [[ -n "$window_start" ]]; then
                matches="$(awk -v start="$window_start" '
                            match($0, /^\[[[:space:]]*[0-9]+\.[0-9]+\]/) {
                                if (substr($0, RSTART + 1, RLENGTH - 2) + 0 >= start) { print }
                            }' "$raw_dmesg" \
                          | grep -Ei "$crash_pattern" | tail -n 40 || true)"
                if [[ -n "$matches" ]]; then
                    window_note="kernel records from boot second $window_start onward (test container start, less a ${window_margin}s clock margin)"
                    # Log first: this copy survives an unwritable artifacts dir.
                    echo "##[group]Kernel crash records ($window_note)"
                    printf '%s\n' "$matches"
                    echo ""
                    echo "##[endgroup]"
                    printf '%s\n' "$matches" | head -n 3 | while IFS= read -r line; do
                        echo "##vso[task.logissue type=error]kernel: ${line:0:300}"
                    done || true
                    # Must stay a simple command with 2>/dev/null BEFORE the
                    # redirect. A failed redirect on a brace group or subshell
                    # is neither propagated to `if !` nor fatal, and its
                    # standalone $? is still 1, which is why the group form
                    # looks safe and is not; a trailing 2>/dev/null also fails
                    # to suppress the shell's own message for it.
                    if ! printf '# %s\n# Matching: %s\n\n%s\n' \
                            "$window_note" "$crash_pattern" "$matches" \
                            2>/dev/null > "$dmesg_out"; then
                        # ENOSPC opens fine and fails on write; drop the empty file.
                        rm -f "$dmesg_out" 2>/dev/null || true
                        echo "Could not write $dmesg_out; the records above are in this log only."
                        matches=""
                    fi
                else
                    # Do not let "crashed outside the window" read as an all-clear.
                    outside=$(grep -Eci "$crash_pattern" "$raw_dmesg" || true)
                    if [[ "${outside:-0}" -gt 0 ]]; then
                        echo "No kernel crash records inside this run's window (boot second $window_start onward). The buffer holds ${outside} match(es) outside it, which this run cannot claim, so they are not archived."
                    else
                        echo "No kernel-level crash records matched in dmesg (not a hard crash, or the ring buffer already wrapped past it)."
                    fi
                fi
            else
                # No watermark, an unstamped kernel, or no usable awk: show the
                # lines, but never archive or annotate what cannot be tied to
                # this run.
                uncorrelated="$(grep -Ei "$crash_pattern" "$raw_dmesg" | tail -n 40 || true)"
                if [[ -n "$uncorrelated" ]]; then
                    echo "##[group]Kernel crash records, uncorrelated - these cannot be tied to this run, so they are not archived"
                    printf '%s\n' "$uncorrelated"
                    echo ""
                    echo "##[endgroup]"
                else
                    echo "No kernel-level crash records matched in dmesg (not a hard crash, or the ring buffer already wrapped past it)."
                fi
            fi
        else
            echo "dmesg is unavailable here; skipping kernel crash records."
        fi
        if [[ -n "$raw_dmesg" ]]; then
            rm -f "$raw_dmesg" 2>/dev/null || true
        fi

        # artifact.upload is a stdout logging command, so no CI task definition
        # is needed and it is inert text elsewhere, where the tarball just
        # stays on disk at the path printed above. The timestamp+PID suffix
        # keeps a retried run from uploading under the same name.
        if [[ $had_container_artifacts == true || -n "$matches" ]]; then
            tarball="$(dirname "$abs_test_artifacts_dir")/test-diagnostics-${label}-$(date -u +%Y%m%d%H%M%S)-$$.tar.gz"
            if tar -czf "$tarball" -C "$abs_test_artifacts_dir" . 2>/dev/null; then
                echo "Test diagnostics archived at $tarball"
                echo "##vso[artifact.upload artifactname=test-diagnostics-${label}]${tarball}"
            else
                echo "Could not archive $abs_test_artifacts_dir; the files are still there."
            fi
        else
            echo "No test diagnostics worth archiving under $abs_test_artifacts_dir (the container copied nothing out and nothing archivable matched in dmesg)."
        fi
    }

    if [[ "$PACKAGE_TYPE" == "deb" ]]; then
        deb_package_name=$(ls "$abs_output_dir" | grep -E "${OS}-postgresql-$PG-documentdb_${DOCUMENTDB_VERSION}.*\.deb" | grep -v "dbg" | head -n 1)
        deb_package_rel_path="$OUTPUT_DIR/$deb_package_name"

        echo "Debian package path passed into Docker build: $deb_package_rel_path"

        # Build the Docker image while showing the output to the console
    docker build -t documentdb-test-packages:latest -f "${script_dir}/packaging/test_packages/deb/Dockerfile-deb-test" \
            --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
            --build-arg POSTGRES_VERSION="$PG" \
            --build-arg DEB_PACKAGE_REL_PATH="$deb_package_rel_path" "$script_dir"
        # Run the Docker container to test the packages
        mark_test_start
        if ! docker run --rm "${test_run_args[@]}" documentdb-test-packages:latest; then
            report_host_diagnostics "deb-${OS}-pg${PG}"
            exit 1
        fi

    elif [[ "$PACKAGE_TYPE" == "rpm" ]]; then
    rpm_package_name=$(ls "$abs_output_dir" | grep -E "${OS}-postgresql${PG}-documentdb-${DOCUMENTDB_VERSION}.*\.(x86_64|aarch64)\.rpm" | head -n 1)
        if [[ -z "$rpm_package_name" ]]; then
            echo "Error: Could not find the built RPM package in $abs_output_dir for testing."
            exit 1
        fi
        package_rel_path="$OUTPUT_DIR/$rpm_package_name"

        echo "RPM package path passed into Docker build: $package_rel_path"
        
        # Select the correct test Dockerfile for RHEL 8 or RHEL 9
        if [[ "$OS" == "rhel8" ]]; then
            TEST_DOCKERFILE="${script_dir}/packaging/test_packages/rhel-8/Dockerfile-rhel8-test"
        elif [[ "$OS" == "rhel9" ]]; then
            TEST_DOCKERFILE="${script_dir}/packaging/test_packages/rhel-9/Dockerfile-rhel9-test"
        else
            echo "Error: Unknown RPM OS for test Dockerfile: $OS"
            exit 1
        fi
        docker build -t documentdb-test-rpm-packages:latest -f "$TEST_DOCKERFILE" \
            --build-arg BASE_IMAGE="$DOCKER_IMAGE" \
            --build-arg POSTGRES_VERSION="$PG" \
            --build-arg RPM_PACKAGE_REL_PATH="$package_rel_path" "$script_dir"
            
        # Run the Docker container to test the packages
        mark_test_start
        if ! docker run --rm "${test_run_args[@]}" --env POSTGRES_VERSION="$PG" documentdb-test-rpm-packages:latest; then
            report_host_diagnostics "rpm-${OS}-pg${PG}"
            exit 1
        fi
    fi

    # Nothing failed, so the diagnostics directory holds nothing worth keeping.
    if [[ $test_artifacts_temporary == true ]]; then
        rm -rf "$abs_test_artifacts_dir"
    fi

    echo "Clean installation test successful!!"
fi

echo "Packages are available in $abs_output_dir"