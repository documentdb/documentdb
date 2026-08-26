#!/bin/bash
# Clone the upstream functional-tests suite at the source_sha pinned in
# config/image.yml and install its python requirements.
#
# Fetches SHALLOW at the pinned SHA: this runs on every CI leg of every gate
# run, and a depth-1 fetch of the pinned commit transfers ~29 MB instead of the
# suite's full history.
# Usage: setup_functional_tests.sh <install-dir> [<image.yml path>]
set -eu

scriptDir="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
installRoot="${1:?usage: setup_functional_tests.sh <install-dir> [<image.yml>]}"
gitRefFile="${2:-$scriptDir/../config/image.yml}"

SUITE_REPO="https://github.com/documentdb/functional-tests.git"
GITREF=$(grep source_sha "$gitRefFile" | cut -d ' ' -f 2)
echo "Fetching functional-tests at $GITREF into $installRoot"

rm -rf "$installRoot"
mkdir -p "$installRoot"
git -C "$installRoot" init -q
git -C "$installRoot" remote add origin "$SUITE_REPO"
git -C "$installRoot" fetch --depth 1 origin "$GITREF"
git -C "$installRoot" checkout -q FETCH_HEAD

PIP_ARGS=""
if python3 -m pip install --break-system-packages --help >/dev/null 2>&1; then
    PIP_ARGS="--break-system-packages"
fi
python3 -m pip install $PIP_ARGS -r "$installRoot/requirements.txt"
