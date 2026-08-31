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

# Verbose server-side error reporting for the temp instances pg_regress spins
# up: every ereport then carries its SQLSTATE and originating
# file:line:function, often identifying the failing C site straight from
# postmaster.log. Server log only; pg_regress compares client output, so
# expected results are unaffected.
PG_SAMPLE_CONF="$(pg_config --sharedir)/postgresql.conf.sample"
if [ -f "$PG_SAMPLE_CONF" ]; then
    echo "log_error_verbosity = verbose" >> "$PG_SAMPLE_CONF"
fi

# Run the test
adduser --disabled-password --gecos "" documentdb
chown -R documentdb:documentdb .
# Pass PG bin dir on PATH so TAP tests can locate initdb under `su`.
# On failure, report-test-failure.sh dumps the regression diffs and every
# postmaster.log, so a backend crash leaves a real trail in the CI log instead
# of only "server closed the connection unexpectedly" diffs.
if ! su documentdb -c "PATH=\"$(pg_config --bindir):\$PATH\" make check"; then
    report-test-failure.sh /test-install
    exit 1
fi
