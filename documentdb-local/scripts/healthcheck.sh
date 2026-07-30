#!/bin/bash

# Health probe for the documentdb-local container. Backs the image's built-in
# HEALTHCHECK and docker-compose `healthcheck:` blocks:
#
#   test: ["CMD", "/usr/local/bin/documentdb-healthcheck"]
#
# Exits 0 (healthy) only when all of the following hold:
#   1. The entrypoint finished startup: it publishes its resolved runtime
#      settings to $DOCUMENTDB_RUNTIME_STATE_FILE only after initialization
#      (including sample/custom data seeding) completes, so orchestrators
#      gated on `service_healthy` never see a half-initialized database.
#   2. The bundled PostgreSQL accepts connections (skipped when this
#      container did not start PostgreSQL, i.e. START_POSTGRESQL=false).
#   3. The gateway completes a TLS handshake on the DocumentDB port. The
#      gateway serves TLS in every tlsMode (allowTLS/disabled additionally
#      accept plain connections), so a TLS probe is valid in all modes.
#
# The state file — not this process's environment — is the authority for the
# ports: HEALTHCHECK / `docker exec` sessions only see the image's ENV
# defaults, never values the entrypoint parsed from CLI flags such as
# `--documentdb-port`. The state file is always required — its absence means
# startup has not completed — while environment variables supply any key it
# omits and the optional port argument overrides the DocumentDB port.
#
# Usage: healthcheck.sh [gateway-port]
#   gateway-port  overrides the DocumentDB port from the state file/env.

set -u

STATE_FILE="${DOCUMENTDB_RUNTIME_STATE_FILE:-/tmp/documentdb-local-runtime.env}"

# Precedence per setting: CLI argument > state file > environment > default.
documentdb_port="${DOCUMENTDB_PORT:-10260}"
postgresql_port="${POSTGRESQL_PORT:-9712}"
start_postgresql="${START_POSTGRESQL:-true}"

if [ ! -f "$STATE_FILE" ]; then
    echo "unhealthy: startup has not completed (state file $STATE_FILE not found)"
    exit 1
fi

# Parse, never source, the KEY=VALUE lines emulator_entrypoint.sh writes: the
# entrypoint does not validate every value it publishes (START_POSTGRESQL takes
# whatever `--start-pg` was given), so `.` would execute a value such as
# `false; some-command` on every probe and would silently truncate any value
# containing whitespace. Reading the values literally also keeps this probe's
# view byte-identical to the entrypoint's, so the two cannot disagree about
# whether START_POSTGRESQL was exactly "true". Unlisted keys are ignored, and an
# empty value falls through to the environment/default resolved above.
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        *=*) ;;
        *) continue ;;
    esac
    value="${line#*=}"
    [ -n "$value" ] || continue
    case "${line%%=*}" in
        DOCUMENTDB_PORT) documentdb_port="$value" ;;
        POSTGRESQL_PORT) postgresql_port="$value" ;;
        START_POSTGRESQL) start_postgresql="$value" ;;
    esac
done < "$STATE_FILE"

if [ "$#" -ge 1 ] && [ -n "$1" ]; then
    documentdb_port="$1"
fi

# Fail (rather than probe a guessed port) on a corrupt value: a state file the
# entrypoint did not write correctly is itself a sign the container is broken.
is_port() {
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
    # Drop leading zeros, then bound the width before comparing: a digits-only
    # value wider than the shell's integer type makes `[ -ge ]` write
    # "integer expression expected" into the container's health log.
    _port="${1#"${1%%[!0]*}"}"
    [ -n "$_port" ] && [ "${#_port}" -le 5 ] || return 1
    [ "$_port" -ge 1 ] && [ "$_port" -le 65535 ]
}

if ! is_port "$documentdb_port"; then
    echo "unhealthy: invalid DocumentDB port '$documentdb_port'"
    exit 1
fi

# Mirrors the entrypoint's own `[ "$START_POSTGRESQL" = "true" ]` test, which
# does not validate the value either: any other value means it did not start
# PostgreSQL, so rejecting one here would report unhealthy for a container that
# is running exactly as the entrypoint decided.
if [ "$start_postgresql" = "true" ]; then
    if ! is_port "$postgresql_port"; then
        echo "unhealthy: invalid PostgreSQL port '$postgresql_port'"
        exit 1
    fi
    # A missing pg_isready is a broken image, not a reason to skip the probe:
    # reporting healthy here would mean reporting healthy with a dead database
    # whenever the gateway's TLS listener happens to answer.
    if ! command -v pg_isready >/dev/null 2>&1; then
        echo "unhealthy: pg_isready not found, cannot probe PostgreSQL on localhost:$postgresql_port"
        exit 1
    fi
    if ! pg_isready -q -h localhost -p "$postgresql_port"; then
        echo "unhealthy: PostgreSQL is not accepting connections on localhost:$postgresql_port"
        exit 1
    fi
fi

# </dev/null (not `echo |`, and never -quiet): with stdin at EOF s_client
# exits right after the handshake without sending stray bytes into the wire
# protocol, and its exit status directly reflects connect/handshake success.
# -quiet implies -ign_eof, which would leave the probe hanging on the open
# connection until the healthcheck timeout kills it.
if ! openssl s_client -connect "localhost:$documentdb_port" </dev/null >/dev/null 2>&1; then
    echo "unhealthy: TLS handshake with the gateway on localhost:$documentdb_port failed"
    exit 1
fi

echo "healthy: gateway accepting TLS connections on localhost:$documentdb_port"
exit 0
