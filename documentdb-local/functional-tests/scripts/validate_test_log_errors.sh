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
    if grep -i -n "ContractViolationException" "$file" | head -20; then
        echo "Found ContractViolationException in $file"
        found=1
    fi
    if grep -i -n "InternalError" "$file" | head -20; then
        echo "Found InternalError in $file"
        found=1
    fi
done
[ "$found" -eq 0 ] && echo "Found no internal errors."
exit "$found"
