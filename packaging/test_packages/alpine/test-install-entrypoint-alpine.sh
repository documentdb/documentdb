#!/bin/bash
set -e

echo "Testing Alpine package installation..."

cd /usr/src/documentdb

# Set up environment for make check
export PG_CONFIG=/usr/bin/pg_config
export PATH=/usr/bin:$PATH

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

# Create a user for running tests (Alpine uses adduser differently)
adduser -D -s /bin/bash documentdb || true
chown -R documentdb:documentdb .

# Switch to the documentdb user and run the tests
echo "Running make check as documentdb user..."
if ! su documentdb -c "export PG_CONFIG=/usr/bin/pg_config && export PATH=/usr/bin:\$PATH && make check"; then
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

echo "Alpine package installation test completed successfully!"
