#!/bin/bash
set -e


if python3 -m venv /tmp/venv 2>/dev/null; then
    source /tmp/venv/bin/activate
    pip install pymongo
else
    python3 -m pip install --user pymongo
fi

# Pre-flight: verify the gateway binary is present and loadable
echo "=== Pre-flight checks ==="
if [ -x /usr/bin/documentdb_gateway ]; then
    echo "Gateway binary found at /usr/bin/documentdb_gateway"
    file /usr/bin/documentdb_gateway || true
    ldd /usr/bin/documentdb_gateway || echo "WARNING: ldd failed (static binary or missing libs)"
else
    echo "ERROR: /usr/bin/documentdb_gateway not found or not executable"
    ls -la /usr/bin/documentdb_gateway 2>/dev/null || echo "  File does not exist"
    exit 1
fi
echo "=== End pre-flight checks ==="

emulator_log="/tmp/emulator.log"
: > "$emulator_log"

nohup /home/documentdb/gateway/scripts/emulator_entrypoint.sh --username cloudsa --password 123456 --skip-init-data > "$emulator_log" 2>&1 &
emulator_pid=$!

max_attempts=180
attempt=0
while ! grep -q "=== DocumentDB is ready ===" "$emulator_log"; do
    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "Gateway failed to start within $max_attempts seconds."
        echo ""
        echo "=== Emulator log ==="
        cat "$emulator_log"
        echo ""
        echo "=== Gateway log ==="
        cat /var/log/documentdb/gateway.log 2>/dev/null || echo "(no gateway log found)"
        echo ""
        echo "=== Gateway process status ==="
        ls -la /proc/*/exe 2>/dev/null | grep documentdb_gateway || echo "(no gateway process found)"
        echo ""
        echo "=== Emulator process status ==="
        if kill -0 "$emulator_pid" 2>/dev/null; then
            echo "Emulator process $emulator_pid is still running"
        else
            echo "Emulator process $emulator_pid has exited"
            wait "$emulator_pid" 2>/dev/null && echo "Exit code: $?" || echo "Exit code: $?"
        fi
        exit 1
    fi
    sleep 1
    attempt=$((attempt + 1))
done

echo "Gateway is ready, proceeding with next steps..."
python3 test_gateway.py --username cloudsa --password 123456
