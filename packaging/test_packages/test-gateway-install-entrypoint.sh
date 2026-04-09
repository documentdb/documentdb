#!/bin/bash
set -e


USERNAME="docdb_admin"
PASSWORD="123456"

python3 -m venv /tmp/venv
source /tmp/venv/bin/activate
pip install pymongo

nohup /home/documentdb/gateway/scripts/emulator_entrypoint.sh --username "$USERNAME" --password "$PASSWORD" --skip-init-data > emulator.log 2>&1 &
# Give some time for the emulator to start
while ! grep -q "=== DocumentDB is ready ===" emulator.log; do
    sleep 1
done

echo "Gateway is ready, proceeding with next steps..."
python test_gateway.py --username "$USERNAME" --password "$PASSWORD"
