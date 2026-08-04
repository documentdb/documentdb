#!/bin/bash
# Scan engine/gateway logs for internal-error signatures (same patterns and
# warning-only standard as the ADO gate's log check). Exits 1 if any are found
# so CI can surface a warning; run with continue-on-error.
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
        matches=$(grep -i -n "$pattern" "$file" | head -20) || true
        if [ -n "$matches" ]; then
            printf '%s\n' "$matches"
            echo "Found $pattern in $file"
            found=1
        fi
    done
done
[ "$found" -eq 0 ] && echo "Found no internal errors."
exit "$found"
