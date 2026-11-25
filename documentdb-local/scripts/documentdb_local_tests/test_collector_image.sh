#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
# Run against an already-built collector image. No published ports or egress.
set -euo pipefail
image=${1:?pass the derived image tag}
cid=''
cleanup() { if [[ -n $cid ]]; then docker rm -fv "$cid" >/dev/null; fi; }
trap cleanup EXIT

# Check the independent default-on reporter in the built image. Capture the
# complete curl argument vector, not just the query builder's return value.
docker run --rm -i --network none --entrypoint bash "$image" -se <<'PRIVACY'
source /home/documentdb/gateway/scripts/usage_telemetry.sh
export USERNAME=private_user_sentinel PASSWORD=private_password_sentinel
usage_telemetry_enabled
capture=$(mktemp -d)
mkfifo "$capture/request"
curl() { printf '%s\n' "$@" > "$capture/request"; }
read -r version _ < /version.txt
for event in emulator_launch emulator_heartbeat; do
    usage_telemetry_send "$event"
    expected="https://documentdb.gateway.scarf.sh/telemetry?event=$event&version=$version&platform=linux&arch=$(uname -m)&db_system=documentdb"
    diff -u <(printf '%s\n' -fsS --max-time "$USAGE_TELEMETRY_TIMEOUT_S" -o /dev/null "$expected") \
        <(timeout 5 cat "$capture/request")
done
PRIVACY

# Exercise the entrypoint decision with the actual collector installed. An
# explicit endpoint, even on loopback, belongs to the operator.
docker run --rm -i --network none --entrypoint bash "$image" -se <<'TEST'
source /home/documentdb/gateway/scripts/lib/gateway.sh
configFile=$(mktemp)
skip() ( collector_pid=''; start_local_metrics_collector; [[ -z $collector_pid ]]; )
echo '{}' > "$configFile"
skip
ENABLE_TELEMETRY=true OTEL_METRICS_ENABLED=false skip
export ENABLE_TELEMETRY=true OTEL_METRICS_ENABLED=true
OTEL_EXPORTER_OTLP_METRICS_ENDPOINT=http://localhost:9999 skip
OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:9999 skip
echo '{"TelemetryOptions":{"Metrics":{"Enabled":false}}}' > "$configFile"
skip
echo '{"TelemetryOptions":{"Metrics":{"OtlpEndpoint":"http://localhost:9999"}}}' > "$configFile"
skip
TEST

cid=$(docker run -d --network none -e DOCUMENTDB_USAGE_TELEMETRY=false \
    -e MONGOSH_DISABLE_TELEMETRY=1 -e USERNAME=collector_test -e PASSWORD="test-$RANDOM-$RANDOM-Aa!" \
    -e OTEL_METRIC_EXPORT_INTERVAL=1000 "$image" --enable-telemetry true)
ping_gateway() {
    docker exec "$cid" bash -ec 'mongosh --quiet --norc --host 127.0.0.1 --port 10260 --username "$USERNAME" --password "$PASSWORD" --authenticationDatabase admin --eval "db.runCommand({ping:1}).ok"' | grep -qx 1
}
for ((i=0; i<120; i++)); do
    if docker exec "$cid" documentdb-healthcheck >/dev/null 2>&1; then break; fi
    sleep 1
done
ping_gateway
for ((i=0; i<30; i++)); do
    if metrics=$(docker exec "$cid" curl --noproxy 127.0.0.1 -fsS http://127.0.0.1:9464/metrics) &&
        grep -Ei '^docdb_gateway_operation_duration_count\{.*db_operation_name="ping".*\} [1-9]' <<< "$metrics"; then break; fi
    sleep 1
done
[[ $i -lt 30 ]]
docker exec "$cid" pkill -STOP -x otelcol-contrib
docker stop -t 15 "$cid" >/dev/null
[[ $(docker inspect -f '{{.State.ExitCode}}' "$cid") == 0 ]]
docker logs "$cid" 2>&1 | grep -F 'Shutdown complete' >/dev/null
docker start "$cid" >/dev/null
for ((i=0; i<120; i++)); do
    if docker exec "$cid" documentdb-healthcheck >/dev/null 2>&1; then break; fi
    sleep 1
done
docker exec "$cid" pkill -KILL -x otelcol-contrib
ping_gateway
echo 'Collector routing, real gateway metrics, shutdown and crash isolation passed.'