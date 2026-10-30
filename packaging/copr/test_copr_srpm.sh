#!/bin/bash
# Test the Copr SRPM build locally in the selected chroot's container.
# This replicates the Copr mock chroot environment to catch errors
# before pushing to the remote Copr project.
#
# Usage: ./packaging/copr/test_copr_srpm.sh [--chroot CHROOT] [--output-dir DIR]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd "$script_dir/../.." && pwd)"
OUTPUT_DIR="$script_dir"
CHROOT="fedora-43-x86_64"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --chroot)
            shift
            CHROOT="$1"
            ;;
        --output-dir)
            shift
            OUTPUT_DIR="$1"
            ;;
        -h|--help)
            echo "Usage: $0 [--chroot CHROOT] [--output-dir DIR]"
            echo ""
            echo "Test the Copr SRPM build locally using the target container."
            echo ""
            echo "Options:"
            echo "  --chroot CHROOT   fedora-43-x86_64 (default), fedora-42-x86_64,"
            echo "                    fedora-45-x86_64, fedora-rawhide-x86_64, epel-9-x86_64"
            echo "  --output-dir DIR  Directory to place the built SRPM (default: packaging/copr/)"
            echo "  -h, --help        Show this help message"
            exit 0
            ;;
        *)
            echo "Unknown argument: $1"
            exit 1
            ;;
    esac
    shift
done

case "$CHROOT" in
    fedora-43-x86_64) IMAGE="fedora:43" ;;
    fedora-42-x86_64) IMAGE="fedora:42" ;;
    fedora-45-x86_64) IMAGE="fedora:45" ;;
    fedora-rawhide-x86_64) IMAGE="fedora:rawhide" ;;
    epel-9-x86_64) IMAGE="rockylinux:9" ;;
    *) echo "Unsupported chroot: $CHROOT" >&2; exit 2 ;;
esac

abs_output_dir="$(cd "$repo_root" && mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"

echo "=== Testing Copr SRPM build: $CHROOT ($IMAGE) ==="
echo "Source directory: $repo_root"
echo "Output directory: $abs_output_dir"

docker run --rm \
    -v "$repo_root:/src:ro" \
    -v "$abs_output_dir:/output:z" \
    -e CHROOT="$CHROOT" \
    "$IMAGE" \
    bash -c '
        set -euo pipefail
        echo "--- Installing base tools ---"
        dnf install -y --allowerasing rpm-build curl make 2>&1 | tail -1
        if [[ "$CHROOT" == epel-9-x86_64 ]]; then
            dnf install -y dnf-plugins-core epel-release
            dnf config-manager --set-enabled crb
        fi

        cd /src
        echo "--- Running .copr/Makefile srpm target ---"
        make -f .copr/Makefile srpm TOPDIR=/tmp/rpmbuild outdir=/output

        echo ""
        echo "=== SRPM build succeeded ==="
        ls -lh /output/*.src.rpm
    '

echo ""
echo "SRPM available in: $abs_output_dir"
ls -lh "$abs_output_dir"/*.src.rpm 2>/dev/null
