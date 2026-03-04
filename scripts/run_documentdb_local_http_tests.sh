#!/bin/bash

set -euo pipefail

IMAGE_NAME="${1:-documentdb-local:test-tls}"
LOG_DIR="${2:-documentdb-local-logs}"
CONTAINER_SUFFIX="$$"

PLAIN_CONTAINER="docdb-plain-${CONTAINER_SUFFIX}"
TLS_CONTAINER="docdb-tls-${CONTAINER_SUFFIX}"

mkdir -p "$LOG_DIR"

cleanup() {
    for container in "$PLAIN_CONTAINER" "$TLS_CONTAINER"; do
        if docker ps -a --format '{{.Names}}' | grep -q "^${container}$"; then
            docker logs "$container" > "$LOG_DIR/${container}.log" 2>&1 || true
            docker rm -f "$container" >/dev/null 2>&1 || true
        fi
    done
}
trap cleanup EXIT

wait_for_ping() {
    local container=$1
    local mode=$2
    local args=()
    if [ "$mode" = "tls" ]; then
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

    echo "Timed out waiting for gateway ping in ${container} (${mode})."
    return 1
}

wait_for_sample_data() {
    local container=$1
    for attempt in {1..90}; do
        count="$(docker exec "$container" mongosh \
            --host localhost \
            --port 10260 \
            -u default_user \
            -p mypassword \
            --authenticationDatabase admin \
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

# Default mode: TLS not enforced (matching MongoDB default).
docker run -d --name "$PLAIN_CONTAINER" "$IMAGE_NAME" --password mypassword
wait_for_ping "$PLAIN_CONTAINER" plain
wait_for_sample_data "$PLAIN_CONTAINER"

# Plain connection must succeed in default mode.
docker exec "$PLAIN_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' | grep -q "1"

# TLS connection should also succeed in default mode (gateway accepts both).
docker exec "$PLAIN_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --tls \
    --tlsAllowInvalidCertificates \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' | grep -q "1"

docker rm -f "$PLAIN_CONTAINER" >/dev/null

# TLS mode: TLS enforcement enabled.
docker run -d --name "$TLS_CONTAINER" "$IMAGE_NAME" --password mypassword --enable-tls
wait_for_ping "$TLS_CONTAINER" tls

# TLS connection must succeed.
docker exec "$TLS_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --tls \
    --tlsAllowInvalidCertificates \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' | grep -q "1"

# Plain connection must fail when TLS is enforced.
if docker exec "$TLS_CONTAINER" mongosh \
    --host localhost \
    --port 10260 \
    -u default_user \
    -p mypassword \
    --authenticationDatabase admin \
    --quiet \
    --eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1; then
    echo "Expected plain connection to fail when TLS is enforced."
    exit 1
fi

docker rm -f "$TLS_CONTAINER" >/dev/null

# Invalid ENABLE_TLS value must fail.
if docker run --rm -e ENABLE_TLS=maybe "$IMAGE_NAME" --password mypassword > "$LOG_DIR/invalid-enable-tls.log" 2>&1; then
    echo "Expected invalid ENABLE_TLS value to fail."
    exit 1
fi
grep -q "Invalid enable-tls value" "$LOG_DIR/invalid-enable-tls.log"
