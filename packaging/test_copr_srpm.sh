#!/bin/bash
# Test the Copr SRPM build locally in a Fedora container.
# This replicates the Copr mock chroot environment to catch errors
# before pushing to the remote Copr project.
#
# Usage: ./packaging/test_copr_srpm.sh [--output-dir DIR]

set -euo pipefail

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUTPUT_DIR="${1:+${1#--output-dir=}}"
OUTPUT_DIR="${OUTPUT_DIR:-$script_dir/packaging}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --output-dir)
            shift
            OUTPUT_DIR="$1"
            ;;
        -h|--help)
            echo "Usage: $0 [--output-dir DIR]"
            echo ""
            echo "Test the Copr SRPM build locally using a Fedora container."
            echo ""
            echo "Options:"
            echo "  --output-dir DIR  Directory to place the built SRPM (default: packaging/)"
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

abs_output_dir="$(cd "$script_dir" && mkdir -p "$OUTPUT_DIR" && cd "$OUTPUT_DIR" && pwd)"

echo "=== Testing Copr SRPM build in Fedora container ==="
echo "Source directory: $script_dir"
echo "Output directory: $abs_output_dir"

docker run --rm \
    -v "$script_dir:/src:z" \
    -v "$abs_output_dir:/output:z" \
    fedora:latest \
    bash -c '
        set -euo pipefail
        echo "--- Installing base tools ---"
        dnf install -y rpm-build curl make 2>&1 | tail -1

        cd /src
        echo "--- Running .copr/Makefile srpm target ---"
        make -f .copr/Makefile srpm outdir=/output

        echo ""
        echo "=== SRPM build succeeded ==="
        ls -lh /output/*.src.rpm
    '

echo ""
echo "SRPM available in: $abs_output_dir"
ls -lh "$abs_output_dir"/*.src.rpm 2>/dev/null
