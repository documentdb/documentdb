#!/bin/bash

set -euo pipefail

IMAGE_NAME="${1:-documentdb-local:test-tls}"
LOG_DIR="${2:-documentdb-local-logs}"
CONTAINER_SUFFIX="$$"

DEFAULT_CONTAINER="docdb-default-${CONTAINER_SUFFIX}"
ENFORCE_CONTAINER="docdb-enforce-${CONTAINER_SUFFIX}"
ENVVAR_CONTAINER="docdb-envvar-${CONTAINER_SUFFIX}"

mkdir -p "$LOG_DIR"

cleanup() {
    for container in "$DEFAULT_CONTAINER" "$ENFORCE_CONTAINER" "$ENVVAR_CONTAINER"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            docker logs "$container" > "$LOG_DIR/${container}.log" 2>&1 || true
            docker rm -f "$container" >/dev/null 2>&1 || true
        fi
    done
}
trap cleanup EXIT

wait_for_ping() {
    local container=$1
    local use_tls=$2
    local args=()
    if [ "$use_tls" = "true" ]; then
        args=(--tls --tlsAllowInvalidCertificates)
    fi

    for attempt in {1..90}; do
        if docker exec "$container" mongosh \
            --host localhost \
            --port 10260 \
            -u default_user \
            -p mypassword \
            --authenticationDatabase admin \
            "${args[@]}" \
            --quiet \
            --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
            return 0
        fi

        if ! docker ps --format '{{.Names}}' | grep -q "^${container}$"; then
            echo "Container ${container} exited unexpectedly."
            return 1
        fi
        sleep 2
    done

    echo "Timed out waiting for gateway ping in ${container} (tls=${use_tls})."
    return 1
}

wait_for_sample_data() {
    local container=$1
    local use_tls=$2
    local args=()
    if [ "$use_tls" = "true" ]; then
        args=(--tls --tlsAllowInvalidCertificates)
    fi

    for attempt in {1..90}; do
        count="$(docker exec "$container" mongosh \
            --host localhost \
            --port 10260 \
            -u default_user \
            -p mypassword \
            --authenticationDatabase admin \
            "${args[@]}" \
            --quiet \
            --eval 'db.getSiblingDB("sampledb").users.countDocuments()' 2>/dev/null || true)"

        if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
            return 0
        fi
        sleep 2
    done

    echo "Timed out waiting for sample data in ${container}."
    return 1
}

echo "=== Test: Default mode (TLS not enforced) ==="

docker run -d --name "$DEFAULT_CONTAINER" "$IMAGE_NAME" --password mypassword --init-data true
wait_for_ping "$DEFAULT_CONTAINER" false
wait_for_sample_data "$DEFAULT_CONTAINER" true

echo "Test 1: Default mode - plain connection..."
docker exec "$DEFAULT_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' | grep -q "1"
echo "  PASSED"

echo "Test 2: Default mode - TLS connection..."
docker exec "$DEFAULT_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --tls \
    --tlsAllowInvalidCertificates \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' | grep -q "1"
echo "  PASSED"

echo "Test 3: Default mode - sample data loaded..."
count="$(docker exec "$DEFAULT_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --tls \
    --tlsAllowInvalidCertificates \
    --quiet \
    --eval 'db.getSiblingDB("sampledb").users.countDocuments()')"
if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
    echo "  PASSED (count=$count)"
else
    echo "  FAILED: Sample data not found."
    exit 1
fi

docker rm -f "$DEFAULT_CONTAINER" >/dev/null

echo ""
echo "=== Test: --tlsMode requireTLS ==="

docker run -d --name "$ENFORCE_CONTAINER" "$IMAGE_NAME" \
    --password mypassword --tlsMode requireTLS --init-data true
wait_for_ping "$ENFORCE_CONTAINER" true
wait_for_sample_data "$ENFORCE_CONTAINER" true

echo "Test 4: --tlsMode requireTLS - TLS connection..."
docker exec "$ENFORCE_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --tls \
    --tlsAllowInvalidCertificates \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' | grep -q "1"
echo "  PASSED"

echo "Test 5: --tlsMode requireTLS - plain connection rejected..."
if docker exec "$ENFORCE_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
    echo "  FAILED: Expected plain connection to be rejected when TLS is enforced."
    exit 1
fi
echo "  PASSED"

echo "Test 6: --tlsMode requireTLS - sample data loaded..."
count="$(docker exec "$ENFORCE_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --tls \
    --tlsAllowInvalidCertificates \
    --quiet \
    --eval 'db.getSiblingDB("sampledb").users.countDocuments()')"
if [[ "$count" =~ ^[0-9]+$ ]] && [ "$count" -gt 0 ]; then
    echo "  PASSED (count=$count)"
else
    echo "  FAILED: Sample data not found."
    exit 1
fi

docker rm -f "$ENFORCE_CONTAINER" >/dev/null

echo ""
echo "=== Test: Environment variable path ==="

echo "Test 7: -e TLS_MODE=requireTLS - TLS-only behavior..."
docker run -d --name "$ENVVAR_CONTAINER" -e TLS_MODE=requireTLS \
    "$IMAGE_NAME" --password mypassword
wait_for_ping "$ENVVAR_CONTAINER" true

docker exec "$ENVVAR_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --tls \
    --tlsAllowInvalidCertificates \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' | grep -q "1"

if docker exec "$ENVVAR_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
    echo "  FAILED: Expected plain connection to be rejected when TLS enforcement is enabled via env var."
    exit 1
fi
echo "  PASSED"

docker rm -f "$ENVVAR_CONTAINER" >/dev/null

echo ""
echo "=== Test: Input validation ==="

echo "Test 8: TLS_MODE=maybe - rejected..."
if docker run --rm -e TLS_MODE=maybe "$IMAGE_NAME" \
    --password mypassword > "$LOG_DIR/invalid-tls-mode.log" 2>&1; then
    echo "  FAILED: Expected invalid TLS_MODE value to fail."
    exit 1
fi
grep -q "Invalid tlsMode value" \
    "$LOG_DIR/invalid-tls-mode.log"
echo "  PASSED"

echo ""
echo "All TLS tests passed."
