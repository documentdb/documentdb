#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

set -euo pipefail

if [[ $# -ne 2 ]]; then
    printf 'Usage: bash compatibility/persist.sh RESULT_JSON EXPECTED_RUN_URL\n' >&2
    exit 2
fi

result=$(realpath --no-symlinks "$1")
run_url=$2
repo_root=$(git rev-parse --show-toplevel)
cd "$repo_root"
worktree=""
scratch=""

cleanup() {
    if [[ -n "$worktree" ]]; then
        git worktree remove --force "$worktree"
        worktree=""
        scratch=""
    elif [[ -n "$scratch" ]]; then
        rmdir "$scratch"
        scratch=""
    fi
}
trap cleanup EXIT

for attempt in 1 2 3 4 5; do
    lookup=0
    git ls-remote --exit-code --heads origin refs/heads/compatibility-data >/dev/null || lookup=$?
    if [[ $lookup != 0 && $lookup != 2 ]]; then
        printf 'Could not look up the result history branch.\n' >&2
        exit "$lookup"
    fi

    if [[ $lookup == 0 ]]; then
        git fetch --no-tags origin refs/heads/compatibility-data
    fi
    scratch=$(mktemp -d "${RUNNER_TEMP:-${TMPDIR:-/tmp}}/compat-history.XXXXXX")
    if [[ $lookup == 0 ]]; then
        git worktree add --detach "$scratch" FETCH_HEAD
    else
        git worktree add --detach "$scratch" HEAD
    fi
    worktree=$scratch
    if [[ $lookup == 2 ]]; then
        git -C "$worktree" switch --orphan "history-$(basename "$worktree")"
    fi

    python -m compatibility.publish --result "$result" \
        --store "$worktree/results" --expected-run-url "$run_url"
    git -C "$worktree" add -- results
    if git -C "$worktree" diff --cached --quiet; then
        printf 'Identical result is already persisted.\n'
        exit 0
    fi
    git -C "$worktree" \
        -c user.name='github-actions[bot]' \
        -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
        commit -s -m "Record compatibility result from $run_url"
    revision=$(git -C "$worktree" rev-parse HEAD)
    if git push origin "$revision:refs/heads/compatibility-data"; then
        exit 0
    fi
    cleanup
    printf 'History push failed; retrying from the current remote history (%s/5).\n' "$attempt" >&2
    sleep "$attempt"
done

printf 'Could not append the result after five conflict-safe attempts.\n' >&2
exit 1
