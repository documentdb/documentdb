#!/bin/bash
#
# documentdb_healthcheck.sh
#
# Container health probe for documentdb-local (issue #482). Wired up as the
# image's HEALTHCHECK so `docker compose` dependents can gate on
# `condition: service_healthy` without hand-rolling a probe, and kept at a
# stable path so compose files that target engines without --start-interval
# support can point an explicit `healthcheck:` block at it.
#
# Healthy means BOTH of:
#   1. the entrypoint finished startup: the readiness marker exists. The
#      marker is written after one-shot data initialization completes, so
#      dependents gated on `condition: service_healthy` observe seeded data
#      instead of racing the seed scripts (the gateway accepts connections
#      before initialization runs), and
#   2. the gateway currently accepts TCP connections on its effective listen
#      port (the marker alone would go stale if the gateway later died).
#
# The port is read from the runtime-generated gateway configuration because a
# `--documentdb-port` entrypoint flag changes the effective port without
# changing this probe's environment (Docker spawns healthcheck processes with
# the container's static environment, not the entrypoint's exports); the
# DOCUMENTDB_PORT environment variable is only the fallback before that file
# exists.
#
# Deliberately a plain TCP probe rather than a mongosh ping: mongosh is a
# Node.js client that burns ~2s of CPU per invocation for no additional
# signal here -- the entrypoint verifies end-to-end readiness (including
# authentication) before writing the marker.

READY_MARKER_FILE=${READY_MARKER_FILE:-/tmp/documentdb-local.ready}
GATEWAY_HOME=${GATEWAY_HOME:-/home/documentdb/gateway}

[ -f "$READY_MARKER_FILE" ] || exit 1

port=""
runtimeConfig="$GATEWAY_HOME/pg_documentdb_gw/target/SetupConfiguration_temp.json"
if [ -f "$runtimeConfig" ]; then
    port=$(jq -r '.GatewayListenPort // empty' "$runtimeConfig" 2>/dev/null)
fi
case "$port" in
    ''|*[!0-9]*) port="${DOCUMENTDB_PORT:-10260}" ;;
esac

exec nc -z localhost "$port"
