#!/bin/bash
set -e


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
# Give some time for the emulator to start
while ! grep -q "=== DocumentDB is ready ===" emulator.log; do
    sleep 1
done

echo "Gateway is ready, verifying sample data and proceeding with next steps..."
verify_sample_data_loaded
python test_gateway.py --username docdb_admin --password 123456
