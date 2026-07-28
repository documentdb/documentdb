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
fi

# Ensure the documentdb user has permissions to run tests
adduser --system --no-create-home documentdb || true
chown -R documentdb:documentdb .

# Switch to the documentdb user and run the tests
echo "Running make check as documentdb user..."
if ! su documentdb -c "export PG_CONFIG=/usr/pgsql-${POSTGRES_VERSION}/bin/pg_config && export PATH=/usr/pgsql-${POSTGRES_VERSION}/bin:\$PATH && make check"; then
    echo "make check failed. Displaying postmaster.log if it exists:"
    LOG_FILE="/usr/src/documentdb/pg_documentdb/src/test/regress/log/postmaster.log"
    if [ -f "$LOG_FILE" ]; then
        echo "=== Contents of $LOG_FILE ==="
        cat "$LOG_FILE"
        echo "==============================="
    else
        echo "Log file $LOG_FILE not found."
    fi
    exit 1
fi

echo "Package installation test completed successfully!"