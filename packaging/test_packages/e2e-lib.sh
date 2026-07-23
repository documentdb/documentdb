#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# e2e-lib.sh — helpers shared by the e2e harness suites. Sourced, not run:
#   . "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-lib.sh"
# Works both on the host (repo checkout) and inside the test containers,
# which bind-mount this whole directory read-only at /e2e.
#
# Scope note (binding review): the two systemd-side scripts are deliberately
# NOT converted to this lib — test-systemd-lifecycle.sh is COPY-baked into an
# image whose build context is test_packages/systemd/ (this file is outside
# that context and /e2e is not mounted there), and run-systemd-e2e.sh's
# host-side collection uses six package-name patterns, a different contract.

# e2e_collect_staged_debs [dir]
#
# Fill the global E2E_STAGED_DEBS array with the staged .deb files in <dir>
# (default /tmp/install_setup). Returns 1 when none are found. NEVER hand the
# glob to `ls`: with zero surviving arguments `apt-get install` installs
# nothing and exits 0, so an empty or mis-mounted staging dir reported
# "packages installed" while every downstream assertion ran against a bare
# host. shopt state is saved/restored so sourcing suites' `set -euo` worlds
# see no side effects.
E2E_STAGED_DEBS=()
e2e_collect_staged_debs() {
    local dir="${1:-/tmp/install_setup}"
    local had_nullglob=""
    shopt -q nullglob && had_nullglob=yes
    shopt -s nullglob
    E2E_STAGED_DEBS=( "${dir}"/*.deb )
    [[ -n "${had_nullglob}" ]] || shopt -u nullglob
    (( ${#E2E_STAGED_DEBS[@]} > 0 ))
}

# e2e_newest_artifact <dir> <name-glob> [exclude-glob]
#
# Print the newest matching file (full path) by mtime, or nothing. Selection
# is by MTIME, never `ls | head -1`: output dirs accumulate builds across
# runs, and the lexicographically-first name silently selected a stale
# lower-version artifact (a bug this repo has now fixed in three separate
# copies). LC_ALL=C so the %T@ decimal epoch sorts numerically regardless of
# the host locale's decimal separator.
e2e_newest_artifact() {
    local dir="$1" glob="$2" exclude="${3:-}"
    if [[ -n "${exclude}" ]]; then
        find "${dir}" -maxdepth 1 -name "${glob}" ! -name "${exclude}" \
            -printf '%T@ %p\n' 2>/dev/null
    else
        find "${dir}" -maxdepth 1 -name "${glob}" \
            -printf '%T@ %p\n' 2>/dev/null
    fi | LC_ALL=C sort -rn | head -n 1 | cut -d' ' -f2-
}

# e2e_skip <id-and-message...>
#
# A check that could not be performed is NOT a pass. Record it in the suite's
# SKIP_COUNT / SKIPPED_IDS so reduced coverage shows in the totals instead of
# the suite quietly asserting less. The counter self-initialises: a suite that
# runs under `set -u` (all of them do) and reaches its first skip before having
# declared SKIP_COUNT would otherwise abort on `SKIP_COUNT: unbound variable`
# from the arithmetic below — turning a benign skip into a suite crash. The
# `+=` array append is already safe against an unset SKIPPED_IDS under `set -u`.
e2e_skip() {
    SKIP_COUNT=$(( ${SKIP_COUNT:-0} + 1 ))
    SKIPPED_IDS+=("$1")
    echo -e "\033[1;33mSKIP\033[0m $*"
}
