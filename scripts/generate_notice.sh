#!/bin/bash
# Generate NOTICE file with alphabetically sorted dependencies
# Usage: ./generate_notice.sh -d [project-directory] -o [output_file]

# fail if trying to reference a variable that is not set.
set -u

# exit immediately if a command exits with a non-zero status
set -e

SOURCEDIR=""
NOTICE_FILE=""
help="false"

while getopts "d:o:h" opt; do
  case $opt in
    d) SOURCEDIR="$OPTARG"
    ;;
    o) NOTICE_FILE="$OPTARG"
    ;;
    h) help="true"
    ;;
  esac

  # Assume empty string if it's unset since we cannot reference to
  # an unset variabled due to "set -u".
  case ${OPTARG:-""} in
    -*) echo "Option $opt needs a valid argument. use -h to get help."
    exit 1
    ;;
  esac
done

if [ "$help" == "true" ]; then
    echo "Usage: $0 -d <source_directory> -o <output_file> [-h]"
    echo "  -d <source_directory>   : Directory containing the source code to build and install (defaults to current dir)."
    echo "  -o <output_file>        : Output file for the generated NOTICE (defaults to NOTICE)."
    echo "  -h                      : Display this help message."
    exit 0
fi

if [ "$SOURCEDIR" == "" ]; then
    SOURCEDIR=$(pwd)
fi

if [ ! -f "$SOURCEDIR/Cargo.toml" ]; then
  echo "Error: Cargo.toml not found in source directory: $SOURCEDIR"
  exit 1
fi

OUTPUT_FILE="${NOTICE_FILE:-NOTICE}"

# Generate JSON output from cargo-about
cargo about generate -c $SOURCEDIR/about.toml -m $SOURCEDIR/Cargo.toml --format json > /tmp/licenses.json

# Allowlist of crates to exclude (these are part of our own codebase)
ALLOWLIST="documentdb_gateway|documentdb_macros"

# Write header
{
    echo "This product includes software developed by the DocumentDB Gateway contributors and third-party packages."
    echo ""
    echo "The full license texts for all dependencies are located in the 'pg_documentdb_gw/licenses/' directory. Below is a summary of included components and their licenses:"
    echo ""

    # Extract crate name and license, sort alphabetically, remove duplicates
    # Uses jq to parse JSON
    jq -r '.licenses[] | .used_by[] | "- \(.crate.name) (\(.crate.license))"' /tmp/licenses.json \
        | grep -vE "^- ($ALLOWLIST) " \
        | sort -f -t'-' -k2 \
        | uniq
} > "$OUTPUT_FILE"

echo "Generated $OUTPUT_FILE with $(grep -c '^-' "$OUTPUT_FILE") dependencies (sorted alphabetically)"
