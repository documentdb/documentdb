#!/bin/bash
set -e


if python3 -m venv /tmp/venv 2>/dev/null; then
    source /tmp/venv/bin/activate
    pip install pymongo
else
    python3 -m pip install --user pymongo
fi

emulator_log="/tmp/emulator.log"
: > "$emulator_log"

nohup /home/documentdb/gateway/scripts/emulator_entrypoint.sh --username cloudsa --password 123456 --skip-init-data > "$emulator_log" 2>&1 &

max_attempts=180
attempt=0
while ! grep -q "=== DocumentDB is ready ===" "$emulator_log"; do
    if [ "$attempt" -ge "$max_attempts" ]; then
        echo "Gateway failed to start within $max_attempts seconds."
        cat "$emulator_log"
        exit 1
    fi
    sleep 1
    attempt=$((attempt + 1))
done

echo "Gateway is ready, proceeding with next steps..."
python3 test_gateway.py --username cloudsa --password 123456
