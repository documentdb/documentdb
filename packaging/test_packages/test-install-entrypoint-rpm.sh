#!/bin/bash
set -e

echo "Testing RPM package installation..."

# Debug: report runtime architecture
echo "Runtime uname -m: $(uname -m)"
if [ -n "${TARGETARCH:-}" ]; then
    echo "TARGETARCH env: ${TARGETARCH}"
fi

# Install the RPM package
dnf install -y /tmp/documentdb.rpm

echo "RPM package installed successfully!"

# One-glance environment fingerprint. When this suite goes red across all PRs
# (as it did when PGDG rolled 18.4 -> 18.6 under us), the first question is
# "what changed vs the last green run" -- answer it here instead of making
# someone diff two 12k-line logs.
echo "=== Installed PostgreSQL/PGDG packages ==="
rpm -qa 'postgresql*' 'pgvector*' 'pg_cron*' 'postgis*' | sort
echo "=========================================="

# Assert the package installed what it claims to, BEFORE running anything that
# could accidentally pass against a different tree.
for f in /usr/pgsql-${POSTGRES_VERSION}/lib/pg_documentdb.so \
         /usr/pgsql-${POSTGRES_VERSION}/share/extension/documentdb.control; do
    if [ ! -e "$f" ]; then
        echo "✗ expected packaged file missing: $f"
        rpm -ql postgresql${POSTGRES_VERSION}-documentdb | head -40
        exit 1
    fi
done
echo "✓ packaged extension artifacts present"

# The RPM no longer ships a source tree (see the note in the spec's %install).
# `make check` below therefore runs against the REPO COPY this test image was
# built from — /usr/src/documentdb comes from the test Dockerfile's
# `COPY . /usr/src/documentdb`, not from the package. That was already true
# before the source tree was dropped: once the spec moved its copy to
# /usr/src/documentdb-<major>, this `cd` silently stopped touching packaged
# content while still being described as validating it. Name it explicitly so
# nobody reads the result as evidence about the package payload.
if [ ! -d /usr/src/documentdb ]; then
    echo "✗ /usr/src/documentdb not found; the test image must COPY the repo there"
    exit 1
fi
echo "NOTE: running the regression suite against the repo copy at" \
     "/usr/src/documentdb (test-image COPY). The package ships no source tree."
cd /usr/src/documentdb

# Keep the internal directory out of the testing, exactly as the DEB entrypoint
# (test-install-entrypoint.sh) does: the internal distributed suite preloads
# citus, which this test container does not install -- and the RPM under test
# ships only the OSS extensions, so the internal suite tests nothing the
# package delivers. Without this, `make check` recurses into
# internal/pg_documentdb_distributed and its postmaster fails to start on the
# missing citus library.
sed -i '/internal/d' Makefile

# Set up environment for make check
export PG_CONFIG=/usr/pgsql-${POSTGRES_VERSION}/bin/pg_config
export PATH=/usr/pgsql-${POSTGRES_VERSION}/bin:$PATH

# Test environment setup first
echo "=== Testing environment for make check ==="

# Test pg_config
if [ -x "$PG_CONFIG" ]; then
    echo "✓ pg_config found: $($PG_CONFIG --version)"
else
    echo "✗ pg_config not found at $PG_CONFIG"
    find /usr -name "pg_config" 2>/dev/null | head -3
    exit 1
fi

# Test libbson pkg-config
if pkg-config --exists libbson-static-1.0; then
    echo "✓ libbson-static-1.0 pkg-config available"
else
    echo "✗ libbson-static-1.0 pkg-config not found"
    echo "Available pkg-config packages with 'bson':"
    pkg-config --list-all | grep -i bson || echo "None found"
    exit 1
fi

# Test pg_regress
PGXS=$($PG_CONFIG --pgxs)
PG_REGRESS_PATH="$(dirname "$PGXS")/../test/regress/pg_regress"
if [ -x "$PG_REGRESS_PATH" ]; then
    echo "✓ pg_regress found at $PG_REGRESS_PATH"
else
    echo "✗ pg_regress not found at expected path: $PG_REGRESS_PATH"
    echo "Searching for pg_regress..."
    find /usr -name "pg_regress" 2>/dev/null | head -3
    exit 1
fi

# Test diff -- pg_regress shells out to it for every output comparison and
# reports a missing binary as a per-test "diff command failed with status
# 32512", which reads like a test failure rather than a broken image.
if command -v diff >/dev/null 2>&1; then
    echo "✓ diff found at $(command -v diff)"
else
    echo "✗ diff not found; the test image must install diffutils (pg_regress needs it)"
    exit 1
fi

echo "=== Environment tests passed! ==="

# PGDG RHEL's postgresql.conf.sample enables logging_collector by default, which
# redirects server logs to a separate file and leaves the postmaster stderr
# logfile empty after startup. The PostgreSQL TAP framework (used by the
# extended_rum_recovery suite) detects events by scanning that stderr logfile via
# wait_for_log, so with the collector on those tests hang until timeout even
# though the behavior under test fires correctly. Disable it in the sample so
# every TAP cluster initdb'd here logs to stderr.
PG_SAMPLE_CONF="$($PG_CONFIG --sharedir)/postgresql.conf.sample"
if [ -f "$PG_SAMPLE_CONF" ]; then
    sed -i 's/^[[:space:]]*logging_collector[[:space:]]*=.*/#logging_collector = off/' "$PG_SAMPLE_CONF"
    # Verbose server-side error reporting: every ereport then carries its
    # SQLSTATE and originating file:line:function, often identifying the
    # failing C site straight from postmaster.log. Server log only; pg_regress
    # compares client output, so expected results are unaffected.
    echo "log_error_verbosity = verbose" >> "$PG_SAMPLE_CONF"
fi

# Ensure the documentdb user has permissions to run tests
adduser --system --no-create-home documentdb || true
chown -R documentdb:documentdb .

# Switch to the documentdb user and run the tests
echo "Running make check as documentdb user..."
if ! su documentdb -c "export PG_CONFIG=/usr/pgsql-${POSTGRES_VERSION}/bin/pg_config && export PATH=/usr/pgsql-${POSTGRES_VERSION}/bin:\$PATH && make check"; then
    report-test-failure.sh /usr/src/documentdb
    exit 1
fi

echo "Package installation test completed successfully!"