#!/bin/bash
set -e

wait_for_gateway_ready() {
    local emulator_pid="$1"
    local emulator_log="$2"
    local ready_timeout_seconds="${3:-180}"
    local shutdown_timeout_seconds="${4:-5}"
    local ready_wait_seconds=0

    while ! grep -q "=== DocumentDB is ready ===" "$emulator_log"; do
        if ! kill -0 "$emulator_pid" 2>/dev/null; then
            local emulator_status=0
            wait "$emulator_pid" || emulator_status=$?
            echo "Gateway entrypoint exited with status $emulator_status before becoming ready." >&2
            cat "$emulator_log" >&2
            return 1
        fi

        if [ "$ready_wait_seconds" -ge "$ready_timeout_seconds" ]; then
            echo "Gateway did not become ready within $ready_timeout_seconds seconds." >&2
            cat "$emulator_log" >&2
            kill "$emulator_pid" 2>/dev/null || true

            local shutdown_wait_seconds=0
            while kill -0 "$emulator_pid" 2>/dev/null &&
                [ "$shutdown_wait_seconds" -lt "$shutdown_timeout_seconds" ]; do
                sleep 1
                shutdown_wait_seconds=$((shutdown_wait_seconds + 1))
            done

            if kill -0 "$emulator_pid" 2>/dev/null; then
                kill -KILL "$emulator_pid" 2>/dev/null || true
            fi
            wait "$emulator_pid" 2>/dev/null || true
            return 1
        fi

        sleep 1
        ready_wait_seconds=$((ready_wait_seconds + 1))
    done
}

if [ "${BASH_SOURCE[0]}" != "$0" ]; then
    return 0
fi

python3 -m venv /tmp/venv
source /tmp/venv/bin/activate
pip install pymongo

verify_sample_data_loaded() {
python - <<'PY'
import sys

import pymongo

client = pymongo.MongoClient(
    "mongodb://docdb_admin:123456@localhost:10260/?tls=true&tlsAllowInvalidCertificates=true"
)
sample_db = client["sampledb"]
counts = {
    "users": sample_db.users.count_documents({}),
    "products": sample_db.products.count_documents({}),
    "orders": sample_db.orders.count_documents({}),
    "analytics": sample_db.analytics.count_documents({}),
}
expected = {"users": 5, "products": 5, "orders": 4, "analytics": 2}
if counts != expected:
    print(f"expected sample data {expected}, found {counts}", file=sys.stderr)
    sys.exit(1)

print(f"Verified built-in sample data via SKIP_INIT_DATA=false: {counts}")
PY
}

# Legacy callers may still rely on SKIP_INIT_DATA=false to enable the built-in sample data.
SKIP_INIT_DATA=false nohup /home/documentdb/gateway/scripts/emulator_entrypoint.sh --username docdb_admin --password 123456 > emulator.log 2>&1 &
emulator_pid=$!
wait_for_gateway_ready "$emulator_pid" emulator.log

echo "Gateway is ready, verifying sample data and proceeding with next steps..."
verify_sample_data_loaded
python test_gateway.py --username docdb_admin --password 123456
