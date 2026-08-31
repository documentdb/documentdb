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
#      gated on `service_healthy` never start against a database that is
#      still initializing. (A custom seed that failed on an earlier boot is
#      deliberately skipped on restart and the container reports healthy
#      without it — see the entrypoint's one-shot marker handling.)
#   2. PostgreSQL accepts connections on localhost. Probed unconditionally:
#      the gateway in this image always dials localhost — its PostgresHostName
#      config key is absent from SetupConfiguration.json and defaults to
#      localhost, and the entrypoint never sets it — so even a PostgreSQL this
#      container did not start (START_POSTGRESQL=false, shared into the
#      network namespace) must answer for the container to be usable.
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

# Open explicitly and FAIL CLOSED: `[ -f ]` only proves the path stats, not
# that it can be opened. With a plain `done < "$STATE_FILE"` an open failure
# (permissions, deletion between check and open) would print to stderr, skip
# the loop, and let the probe continue on env/default ports — reporting
# healthy on values nobody verified.
if ! { exec 3< "$STATE_FILE"; } 2>/dev/null; then
    echo "unhealthy: startup has not completed (state file $STATE_FILE not found or not readable)"
    exit 1
fi

# Parse, never source, the KEY=VALUE lines emulator_entrypoint.sh writes:
# `.` would execute whatever a corrupt or hand-edited file contains, on every
# probe, and would silently truncate values containing whitespace instead of
# letting is_port reject them. Unlisted keys are ignored, and an empty value
# falls through to the environment/default resolved above. A trailing CR is
# stripped so a CRLF-edited file yields values, not a baffling
# "invalid port '10260'" with an invisible difference.
while IFS= read -r line <&3 || [ -n "$line" ]; do
    line="${line%$'\r'}"
    case "$line" in
        *=*) ;;
        *) continue ;;
    esac
    value="${line#*=}"
    [ -n "$value" ] || continue
    case "${line%%=*}" in
        DOCUMENTDB_PORT) documentdb_port="$value" ;;
        POSTGRESQL_PORT) postgresql_port="$value" ;;
    esac
done
exec 3<&-

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

# Same reasoning as the pg_isready guard: a missing openssl is a broken image
# and must not be misreported as a failed handshake.
if ! command -v openssl >/dev/null 2>&1; then
    echo "unhealthy: openssl not found, cannot probe the gateway on localhost:$documentdb_port"
    exit 1
fi

# </dev/null (not `echo |`, and never -quiet): with stdin at EOF s_client
# exits right after the handshake without sending stray bytes into the wire
# protocol, and its exit status directly reflects connect/handshake success.
# -quiet implies -ign_eof, which would leave the probe hanging on the open
# connection until the healthcheck timeout kills it.
#
# The timeout bounds a listener that accepts TCP but never answers the
# handshake — s_client would otherwise block forever, which Docker's 10s
# HEALTHCHECK timeout hides but a documented `docker exec ...
# documentdb-healthcheck` run does not. 5s keeps the worst case (with
# pg_isready's own 3s default) inside Docker's budget. Guarded because the
# probe also runs outside the image, where coreutils timeout may be absent.
tls_probe=(openssl s_client -connect "localhost:$documentdb_port")
if command -v timeout >/dev/null 2>&1; then
    tls_probe=(timeout 5 "${tls_probe[@]}")
fi
if ! "${tls_probe[@]}" </dev/null >/dev/null 2>&1; then
    echo "unhealthy: TLS handshake with the gateway on localhost:$documentdb_port failed"
    exit 1
fi

echo "healthy: gateway accepting TLS connections on localhost:$documentdb_port"
exit 0
