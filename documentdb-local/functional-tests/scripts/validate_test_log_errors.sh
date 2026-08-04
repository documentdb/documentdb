#!/bin/bash
# Scan engine/gateway logs for internal-error signatures (same patterns and
# warning-only standard as the ADO gate's log check).
#
# Exits 1 when any signature is present so a caller can gate on it. The
# functional workflow does NOT gate: it turns a non-zero exit into a GitHub
# warning annotation, because these signatures are informational there and a
# step that exits non-zero under continue-on-error is rendered as an ERROR
# annotation on an otherwise green run.
#
# Output is a per-signature count plus the distinct messages behind it. A raw
# dump is unreadable here: a single gateway error line runs past 500 characters,
# and one known gap (a missing SQL function) accounts for hundreds of them, so
# the distinct-message summary is what makes a NEW signature visible.
#
# Usage: validate_test_log_errors.sh <log-file> [<log-file>...]
set -u

found=0
for file in "$@"; do
    [ -f "$file" ] || { echo "Log not found (skipping): $file"; continue; }
    echo "Checking log $file for errors"
    for pattern in "ContractViolationException" "InternalError"; do
        # Capture first, then test the captured text. `if grep ... | head; then`
        # would test the exit status of head, which is 0 whether or not grep
        # matched, so the check reported every signature on every run and always
        # exited 1 — a warning that carried no information.
        matches=$(grep -i "$pattern" "$file") || true
        [ -n "$matches" ] || continue
        echo "Found $pattern in $file ($(printf '%s\n' "$matches" | wc -l | tr -d ' ') occurrence(s)); distinct messages:"
        printf '%s\n' "$matches" \
            | sed -E 's/.*error_message_internal: //; s/, db_error_code.*//' \
            | cut -c1-160 \
            | sort | uniq -c | sort -rn | head -10 | sed 's/^/    /'
        found=1
    done
done
[ "$found" -eq 0 ] && echo "Found no internal errors."
exit "$found"
