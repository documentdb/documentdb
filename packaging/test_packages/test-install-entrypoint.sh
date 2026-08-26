#!/bin/bash
set -e

# Change to the test directory
cd /test-install

# One-glance environment fingerprint. When this suite goes red across all PRs
# (as it did when PGDG rolled 18.4 -> 18.6 under us), the first question is
# "what changed vs the last green run" -- answer it here instead of making
# someone diff two 12k-line logs.
echo "=== Installed PostgreSQL/PGDG packages ==="
dpkg-query -W -f='${Package} ${Version}\n' 'postgresql*' 'libpq*' 2>/dev/null | sort
echo "=========================================="

# Keep the internal directory out of the testing
sed -i '/internal/d' Makefile

# Run the test
adduser --disabled-password --gecos "" documentdb
chown -R documentdb:documentdb .
# Pass PG bin dir on PATH so TAP tests can locate initdb under `su`.
# On failure, dump every postmaster.log so backend crashes (e.g. the segfault
# cascade first seen against PG 18.6) leave a stack/stderr trail in the CI log
# instead of only "server closed the connection unexpectedly" diffs.
if ! su documentdb -c "PATH=\"$(pg_config --bindir):\$PATH\" make check"; then
    echo "make check failed. Displaying any postmaster.log found:"
    FOUND_LOGS=$(find /test-install -type f -name postmaster.log 2>/dev/null)
    if [ -n "$FOUND_LOGS" ]; then
        for LOG_FILE in $FOUND_LOGS; do
            echo "=== Contents of $LOG_FILE ==="
            cat "$LOG_FILE"
            echo "==============================="
        done
    else
        echo "No postmaster.log found under /test-install."
    fi
    exit 1
fi
