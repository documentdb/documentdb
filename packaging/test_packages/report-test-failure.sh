#!/bin/bash
# Failure diagnostics for the package test containers.
#
# These run with `docker run --rm`, so everything the regression suite wrote is
# destroyed on exit and stdout is the only channel that survives. After a failed
# `make check` this prints the evidence identifying the failure, and copies the
# raw files to TEST_ARTIFACTS_DIR when one is mounted so they outlive the
# container.
#
# Usage: report-test-failure.sh <search-root>
#
# Runs on an already-failing path: defensive throughout, always exits 0, and
# must never mask the real failure or abort a caller under `set -e`.

SEARCH_ROOT="${1:-}"
if [ -z "$SEARCH_ROOT" ]; then
    echo "usage: report-test-failure.sh <search-root>" >&2
    exit 0
fi

# Bounded for the log; the artifact keeps the complete files.
DIFF_LINES="${REPORT_DIFF_LINES:-400}"
LOG_LINES="${REPORT_LOG_LINES:-2000}"
CRASH_ANNOTATIONS=4
CRASH_WIDTH=300

# ##vso and ##[group] are consumed by Azure Pipelines and are inert text under
# any other runner, so emitting them unconditionally is safe.
emit_issue() {
    printf '##vso[task.logissue type=error]%s\n' "$1"
}

end_group() {
    # Force a line break first: a file truncated mid-line by a crash would
    # otherwise absorb the marker and fold the rest of the log into this group.
    printf '\n##[endgroup]\n'
}

# dump_file <label> <file> <max-lines> [head|tail]
# regression.diffs reads from the top (first failing hunk is the answer);
# postmaster.log from the bottom (grows monotonically, so a crash is in its last
# lines, and log_error_verbosity=verbose inflates everything before it).
dump_file() {
    local label="$1" file="$2" max="$3" mode="${4:-head}" total qualifier=first
    printf '##[group]%s: %s\n' "$label" "$file"
    if [ "$mode" = tail ]; then
        tail -n "$max" "$file" 2>/dev/null
        qualifier=last
    else
        head -n "$max" "$file" 2>/dev/null
    fi
    total=$(wc -l 2>/dev/null < "$file")
    case "$total" in
        ''|*[!0-9]*) total=0 ;;
    esac
    if [ "$total" -gt "$max" ]; then
        printf '\n[truncated: %s %s of %s lines shown; full file in the published artifact]\n' \
            "$qualifier" "$max" "$total"
    fi
    end_group
}

# 1. The verdict. pg_regress writes a fixed-name regression.out next to
#    regression.diffs, one per suite. (The Makefiles also tee to
#    log/summary*.out, but the suffix varies per suite, so that name is
#    unreliable.) Name the failing suite: several run before make stops. PG 16+
#    writes "# N of M tests failed"; match loosely in case the "# " ever goes.
FOUND_VERDICT=false
VERDICT_FILES=$(find "$SEARCH_ROOT" -type f -name regression.out 2>/dev/null)
if [ -n "$VERDICT_FILES" ]; then
    while IFS= read -r OUT_FILE; do
        [ -n "$OUT_FILE" ] || continue
        VERDICT=$(grep -hoE '[0-9]+ of [0-9]+ tests failed' "$OUT_FILE" 2>/dev/null | tail -1)
        if [ -z "$VERDICT" ]; then
            # PG 15's pg_regress closes regression.out before printing the
            # count (stdout-only there), so count its "... FAILED" lines.
            FAILED_COUNT=$(grep -cE '\.\.+ FAILED' "$OUT_FILE" 2>/dev/null)
            case "$FAILED_COUNT" in
                ''|*[!0-9]*|0) ;;
                *) VERDICT="$FAILED_COUNT test(s) FAILED" ;;
            esac
        fi
        [ -n "$VERDICT" ] || continue
        FOUND_VERDICT=true
        SUITE=$(dirname "$OUT_FILE")
        emit_issue "make check failed in ${SUITE#"$SEARCH_ROOT"/}: $VERDICT"
    done <<EOF
$VERDICT_FILES
EOF
fi
# The TAP recovery suite runs under prove, which writes no regression.out; its
# verdict is in the teed summary log as "Result: FAIL" plus "Failed n/m subtests".
if [ "$FOUND_VERDICT" = false ]; then
    TAP_VERDICT=$(find "$SEARCH_ROOT" -path '*/log/summary*.out' \
                    -exec grep -hE '^Result: FAIL|Failed [0-9]+/[0-9]+ subtests' {} + 2>/dev/null | head -n 3)
    if [ -n "$TAP_VERDICT" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && emit_issue "make check failed (TAP): $line"
        done <<EOF
$TAP_VERDICT
EOF
    else
        emit_issue "make check failed (no pg_regress or TAP verdict found under $SEARCH_ROOT)"
    fi
fi

# 2. The diffs, the answer for the common expected-output mismatch. The Makefile
#    recipes already cat this to raw stdout on failure; repeating its head here,
#    foldable and annotated, keeps the first hunk one click from the timeline.
DIFF_FILES=$(find "$SEARCH_ROOT" -type f -name regression.diffs -size +0 2>/dev/null)
if [ -n "$DIFF_FILES" ]; then
    while IFS= read -r DIFF_FILE; do
        [ -n "$DIFF_FILE" ] || continue
        # The first differing test name is the single most useful summary line.
        FIRST_TEST=$(grep -m1 -E "^(diff|---) " "$DIFF_FILE" 2>/dev/null)
        [ -n "$FIRST_TEST" ] && emit_issue "regression.diffs: ${FIRST_TEST:0:200}"
        dump_file "regression.diffs" "$DIFF_FILE" "$DIFF_LINES"
    done <<EOF
$DIFF_FILES
EOF
else
    echo "No non-empty regression.diffs found under $SEARCH_ROOT."
fi

# 3. Server logs. make check recurses into several suites, each with its own
#    regress log dir, so search the tree rather than one hard-coded path.
FOUND_LOGS=$(find "$SEARCH_ROOT" -type f -name postmaster.log 2>/dev/null)
if [ -n "$FOUND_LOGS" ]; then
    while IFS= read -r LOG_FILE; do
        [ -n "$LOG_FILE" ] || continue
        # The sed strips the log prefix plus the SQLSTATE that
        # log_error_verbosity=verbose adds; statements are truncated because
        # test documents can be megabytes.
        grep -hE "terminated by signal|Failed process was running" "$LOG_FILE" 2>/dev/null | \
            sed -E 's/.*(LOG|DETAIL): *([0-9A-Z]{5}: *)?//' | head -n "$CRASH_ANNOTATIONS" | \
            while IFS= read -r line; do
                emit_issue "${line:0:$CRASH_WIDTH}"
            done
        dump_file "postmaster.log" "$LOG_FILE" "$LOG_LINES" tail
    done <<EOF
$FOUND_LOGS
EOF
else
    echo "No postmaster.log found under $SEARCH_ROOT."
fi

# 4. Persist the raw files: the artifact keeps the untruncated originals, which
#    are the only copy that survives `docker run --rm`.
if [ -n "${TEST_ARTIFACTS_DIR:-}" ]; then
    if mkdir -p "$TEST_ARTIFACTS_DIR" 2>/dev/null; then
        COPIED=0
        while IFS= read -r -d '' f; do
            cp --parents "$f" "$TEST_ARTIFACTS_DIR" 2>/dev/null && COPIED=$((COPIED + 1))
        done < <(find "$SEARCH_ROOT" -type f \
                    \( -name 'regression.diffs' -o -name 'regression.out' \
                       -o -path '*/log/*' -o -path '*/tmp_check/log/*' \) \
                    -print0 2>/dev/null)
        # The container runs as root; relax modes so the host CI user can read
        # and publish what was written to the bind mount.
        chmod -R a+rX "$TEST_ARTIFACTS_DIR" 2>/dev/null
        echo "Copied $COPIED diagnostic file(s) to $TEST_ARTIFACTS_DIR."
    else
        echo "TEST_ARTIFACTS_DIR=$TEST_ARTIFACTS_DIR is not writable; skipping artifact copy."
    fi
fi

exit 0
