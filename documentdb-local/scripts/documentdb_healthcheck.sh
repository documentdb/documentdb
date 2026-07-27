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
# Healthy means ALL of:
#   1. the entrypoint finished startup: the readiness marker exists. The
#      marker is written after one-shot data initialization completes, so
#      dependents gated on `condition: service_healthy` observe seeded data
#      instead of racing the seed scripts (the gateway accepts connections
#      before initialization runs),
#   2. the backgrounded gateway job recorded in the marker is still alive
#      (the marker alone would go stale if the gateway later died), and
#   3. something still listens on the gateway's effective port.
#
# The marker carries its own inputs -- line 1 the effective gateway port,
# line 2 the gateway job's PID -- because Docker spawns healthcheck processes
# with the container's static environment, not the entrypoint's exports, so a
# `--documentdb-port` flag would otherwise be invisible here. DOCUMENTDB_PORT
# is only a fallback for a marker written by an older entrypoint. The
# entrypoint's cleanup removes the marker on shutdown.
#
# Deliberately NO TCP connection is opened. The gateway logs an ERROR for
# every accepted-then-immediately-closed connection, which is exactly what a
# `nc -z` style probe does, so connecting here would pollute `docker logs`
# once per interval for the life of the container. Reading /proc/net/tcp{,6}
# (state 0A = LISTEN) gets the same signal passively. A mongosh ping is also
# out: ~2s of Node.js startup per probe for no extra signal, and it cannot
# authenticate when the operator passed `--create-user false`.

READY_MARKER_FILE=${READY_MARKER_FILE:-/tmp/documentdb-local.ready}

[ -f "$READY_MARKER_FILE" ] || exit 1

port=$(sed -n '1p' "$READY_MARKER_FILE" 2>/dev/null | tr -d '[:space:]')
pid=$(sed -n '2p' "$READY_MARKER_FILE" 2>/dev/null | tr -d '[:space:]')

# The recorded PID is the tail of the backgrounded `gateway | tee` pipeline,
# which the entrypoint also `wait`s on: it exits as soon as the gateway closes
# the pipe, so its liveness tracks the gateway's.
case "$pid" in
    ''|*[!0-9]*) exit 1 ;;
esac
[ -d "/proc/$pid" ] || exit 1

case "$port" in
    ''|*[!0-9]*) port="${DOCUMENTDB_PORT:-10260}" ;;
esac
# Port still unknowable: report healthy on the marker and liveness checks
# alone rather than wedging the container in `unhealthy` over a probe input.
case "$port" in
    ''|*[!0-9]*) exit 0 ;;
esac

# LISTEN check. /proc/net/tcp rows look like
#   sl  local_address rem_address   st ...
#    0: 00000000:2814 00000000:0000 0A ...
# where 2814 is the local port in uppercase hex and st 0A means LISTEN.
# Absence of both files (unusual kernel config) degrades to the checks above.
if [ ! -r /proc/net/tcp ] && [ ! -r /proc/net/tcp6 ]; then
    exit 0
fi
# 10# forces base 10: printf would read a zero-padded port as octal.
port_hex=$(printf '%04X' "$((10#$port))")
grep -qsE ":${port_hex} [0-9A-F]+:[0-9A-F]+ 0A " /proc/net/tcp /proc/net/tcp6 || exit 1

exit 0
