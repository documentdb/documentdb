#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# e2e-container-scenarios.sh — C1-C4 from the E2E matrix: live behavior
# of the documentdb-local emulator image, which this PR changed
# substantially (clean PostgreSQL stop on gateway self-exit, ON_ERROR_STOP
# on admin-user creation, password kept out of argv).
#
# Runs on the DOCKER HOST (not inside the image):
#   DOCUMENTDB_LOCAL_IMAGE=documentdb-local:e2e ./e2e-container-scenarios.sh
#
#   C1  external-connection default: the internal PostgreSQL port is NOT
#       published to the host unless --allow-external-connections is set
#       (the CHANGELOG's breaking fix)
#   C3  gateway self-exit stops PostgreSQL cleanly — the next start shows
#       no WAL recovery — and the container exits with the gateway's code
#   C4  a special-character admin password round-trips, never appears in
#       any process argv, and a REJECTED user creation fails the container
#       instead of reporting ready (the ON_ERROR_STOP fix)

set -uo pipefail

IMAGE="${DOCUMENTDB_LOCAL_IMAGE:-documentdb-local:e2e}"
PASS_COUNT=0
FAIL_COUNT=0
FAILED_IDS=()
CONTAINERS=()

log()  { echo -e "\033[1;36m[e2e-container]\033[0m $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "\033[1;32mPASS\033[0m $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_IDS+=("$1"); echo -e "\033[1;31mFAIL\033[0m $*"; }

cleanup() {
    local c
    for c in "${CONTAINERS[@]:-}"; do
        [[ -n "${c}" ]] && docker rm -f "${c}" >/dev/null 2>&1
    done
}
trap cleanup EXIT

wait_for_ready() { # container timeout_s
    local c="$1" limit="${2:-180}" i=0
    while (( i < limit )); do
        if docker logs "${c}" 2>&1 | grep -q "DocumentDB is ready\|Gateway ready to accept connections"; then
            return 0
        fi
        if ! docker ps -q --no-trunc --filter "id=$(docker inspect -f '{{.Id}}' "${c}" 2>/dev/null)" | grep -q .; then
            return 1   # container exited
        fi
        sleep 2
        i=$((i + 2))
    done
    return 1
}

# ── C1: internal PostgreSQL must not be externally reachable by default ─
scenario_external_connections() {
    local c=documentdb-e2e-c1
    docker rm -f "${c}" >/dev/null 2>&1
    CONTAINERS+=("${c}")
    log "C1: default run (no --allow-external-connections)"
    # Runtime-generated so no credential literal lives in source (CredScan).
    local pw; pw="$(openssl rand -hex 12)Aa1!"
    docker run -d --name "${c}" -P \
        -e USERNAME=admin -e PASSWORD="${pw}" \
        "${IMAGE}" >/dev/null 2>&1 || { fail "C1: container failed to start"; return; }
    if ! wait_for_ready "${c}" 240; then
        docker logs --tail 30 "${c}" 2>&1 | tail -20 >&2
        fail "C1: container never became ready"
        return
    fi
    pass "C1: container became ready"

    # The image must publish ONLY the gateway port, never PostgreSQL's.
    local published
    published="$(docker port "${c}" 2>/dev/null || true)"
    log "C1: published ports: ${published//$'\n'/, }"
    if grep -qE '^(9712|5432)/tcp' <<<"${published}"; then
        fail "C1: an internal PostgreSQL port is published by default"
    else
        pass "C1: no internal PostgreSQL port published by default"
    fi

    # And PG must not be bound to all interfaces inside the container.
    # DATA_PATH defaults to /data (emulator_entrypoint.sh); locate the
    # live postgresql.conf by asking the running postmaster rather than
    # guessing a layout — a guess that misses would silently skip the
    # assertion, which is exactly the failure mode this suite exists to
    # catch elsewhere.
    # Assert on the LIVE listener rather than on config text: with
    # external connections disabled the entrypoint writes no
    # listen_addresses at all and PostgreSQL applies its built-in default
    # of 'localhost' — which is the closed behavior we want, so requiring
    # the setting to be present would fail on correct behavior.
    # /proc/net/tcp local_address is hex BE-encoded: 0100007F = 127.0.0.1,
    # 00000000 = 0.0.0.0. st 0A = LISTEN.
    local pg_listeners
    pg_listeners="$(docker exec "${c}" sh -c "awk 'NR>1 && \$4==\"0A\" {split(\$2,a,\":\"); print a[1]}' /proc/net/tcp | sort -u" 2>/dev/null | tr -d '\r')"
    if [[ -z "${pg_listeners}" ]]; then
        fail "C1: could not read listening sockets inside the container"
    else
        local pg_port_hex
        pg_port_hex="$(docker exec "${c}" sh -c "awk 'NR>1 && \$4==\"0A\" {print \$2}' /proc/net/tcp" 2>/dev/null | tr -d '\r')"
        log "C1: listening sockets (hex addr:port): ${pg_port_hex//$'\n'/, }"
        # PostgreSQL's port (9712 = 0x25F0 by default) must be bound to
        # loopback only; a 00000000 (0.0.0.0) binding for it is the leak
        # the CHANGELOG's breaking fix closed.
        if grep -qi '^00000000:25F0$' <<<"${pg_port_hex}"; then
            fail "C1: PostgreSQL is listening on 0.0.0.0 by default"
        else
            pass "C1: PostgreSQL is not listening on 0.0.0.0 by default"
        fi
    fi
    docker rm -f "${c}" >/dev/null 2>&1
}

# ── C3: gateway self-exit → clean PG stop, no WAL recovery, exit code ───
scenario_gateway_self_exit() {
    local c=documentdb-e2e-c3
    docker rm -f "${c}" >/dev/null 2>&1
    CONTAINERS+=("${c}")
    local vol=documentdb-e2e-c3-data
    docker volume rm -f "${vol}" >/dev/null 2>&1
    log "C3: starting with a persistent volume"
    # Runtime-generated (CredScan); reused verbatim on the restart below so the
    # user persisted in the volume still authenticates.
    local pw; pw="$(openssl rand -hex 12)Aa1!"
    docker run -d --name "${c}" -v "${vol}:/data" \
        -e USERNAME=admin -e PASSWORD="${pw}" \
        "${IMAGE}" >/dev/null 2>&1 || { fail "C3: container failed to start"; return; }
    if ! wait_for_ready "${c}" 240; then
        docker logs --tail 30 "${c}" 2>&1 | tail -20 >&2
        fail "C3: container never became ready"
        return
    fi
    pass "C3: first boot ready"

    log "C3: killing the gateway daemon inside the container"
    docker exec "${c}" bash -lc "pkill -9 -f 'documentdb_gateway|documentdb-gateway-daemon'" >/dev/null 2>&1 || true

    # The entrypoint must run its cleanup (pg_ctl fast stop) and exit.
    local waited=0 state=""
    while (( waited < 90 )); do
        state="$(docker inspect -f '{{.State.Status}}' "${c}" 2>/dev/null || echo gone)"
        [[ "${state}" == "exited" ]] && break
        sleep 2; waited=$((waited + 2))
    done
    if [[ "${state}" != "exited" ]]; then
        fail "C3: container still running ${waited}s after the gateway died (entrypoint did not exit)"
    else
        pass "C3: entrypoint exited after the gateway self-exit"
        local logs
        logs="$(docker logs "${c}" 2>&1 | tail -40)"
        if grep -q "Stopping PostgreSQL (fast)" <<<"${logs}"; then
            pass "C3: PostgreSQL was stopped cleanly on the crash path"
        else
            echo "${logs}" | tail -15 >&2
            fail "C3: no clean PostgreSQL stop on the gateway-crash path"
        fi
        local code
        code="$(docker inspect -f '{{.State.ExitCode}}' "${c}" 2>/dev/null || echo '?')"
        if [[ "${code}" != "0" ]]; then
            pass "C3: container propagated a non-zero exit code (${code})"
        else
            fail "C3: container exited 0 despite the gateway being killed"
        fi
    fi

    # Restart on the same volume: a clean shutdown means no WAL recovery.
    log "C3: restarting on the same volume to check for WAL recovery"
    docker rm -f "${c}" >/dev/null 2>&1
    local c2=documentdb-e2e-c3b
    CONTAINERS+=("${c2}")
    docker rm -f "${c2}" >/dev/null 2>&1
    docker run -d --name "${c2}" -v "${vol}:/data" \
        -e USERNAME=admin -e PASSWORD="${pw}" \
        "${IMAGE}" >/dev/null 2>&1 || { fail "C3: restart container failed to start"; return; }
    if wait_for_ready "${c2}" 240; then
        pass "C3: second boot on the same volume became ready"
        if docker logs "${c2}" 2>&1 | grep -qiE "database system was not properly shut down|automatic recovery in progress"; then
            fail "C3: WAL recovery ran on the next boot (the stop was not clean)"
        else
            pass "C3: no WAL recovery on the next boot"
        fi
    else
        docker logs --tail 30 "${c2}" 2>&1 | tail -20 >&2
        fail "C3: second boot never became ready"
    fi
    docker rm -f "${c2}" >/dev/null 2>&1
    docker volume rm -f "${vol}" >/dev/null 2>&1
}

# ── C4: password hygiene + failed user creation must fail the container ─
scenario_password_handling() {
    local c=documentdb-e2e-c4
    docker rm -f "${c}" >/dev/null 2>&1
    CONTAINERS+=("${c}")
    local special='pa"ss'\''w0rd\!x'
    log "C4: starting with a special-character admin password"
    docker run -d --name "${c}" \
        -e USERNAME=admin -e PASSWORD="${special}" \
        "${IMAGE}" >/dev/null 2>&1 || { fail "C4: container failed to start"; return; }
    if ! wait_for_ready "${c}" 240; then
        docker logs --tail 40 "${c}" 2>&1 | tail -25 >&2
        fail "C4: container with a special-character password never became ready"
    else
        pass "C4: special-character password accepted end-to-end"
        # The password must not be visible in any process argv.
        #
        # The password reaches the probe on STDIN and is written to a pattern
        # file that `grep -F -f` reads by PATH — it is never interpolated into
        # any command line. Two reasons: the password contains a single quote,
        # which broke the old `bash -lc "grep -- '${special}' ..."` form into a
        # syntax error whose stderr was discarded (so the check reported "no
        # leak" unconditionally); and a password that IS on the probe's own
        # argv makes the probe match itself, flipping it to a permanent false
        # failure. Note the plaintext does briefly exist at $pwfile inside the
        # container; an EXIT trap removes it on every path, including the early
        # BROKEN returns.
        #
        # A positive control runs first. The sentinel below is part of the
        # script text, so it is guaranteed to be present in this shell's own
        # /proc/<pid>/cmdline: if the probe cannot find it, then /proc, the
        # glob or grep -F is unavailable and a "clean" verdict means nothing.
        # In that case we FAIL rather than report hygiene we did not verify.
        #
        # mktemp is avoided (slim images may not ship it). A multi-line
        # password is REJECTED rather than normalized: grep -f matches one
        # pattern per line, so stripping the newlines would silently turn a
        # real leak into a CLEAN verdict while the control still passed.
        local probe='
set -u
d="${TMPDIR:-/tmp}"
pwfile="$d/.ddb-argvprobe-pw.$$"
ctlfile="$d/.ddb-argvprobe-ctl.$$"
trap "rm -f \"$pwfile\" \"$ctlfile\"" EXIT
cat > "$pwfile" 2>/dev/null || { echo BROKEN; exit 0; }
printf %s ARGVPROBECANARY7f3a > "$ctlfile" 2>/dev/null || { echo BROKEN; exit 0; }
verdict=CLEAN
if [ ! -s "$pwfile" ]; then
    verdict=BROKEN
elif [ "$(tr -cd "\n" < "$pwfile" | wc -c)" -gt 1 ]; then
    # More than the single trailing newline the here-string appends means the
    # password itself spans lines (or starts with a blank one, which would
    # match every file). Neither can be matched correctly here.
    verdict=BROKEN
elif ! grep -l -F -f "$ctlfile" /proc/[0-9]*/cmdline >/dev/null 2>&1; then
    verdict=BROKEN
elif grep -l -F -f "$pwfile" /proc/[0-9]*/cmdline >/dev/null 2>&1; then
    verdict=LEAK
fi
echo "$verdict"
'
        # Here-string, not a pipeline: with `set -o pipefail`, a probe that
        # exits before draining stdin gives printf EPIPE (141), which would
        # propagate and overwrite a perfectly valid verdict with EXECFAIL.
        local verdict
        verdict="$(docker exec -i "${c}" sh -c "${probe}" 2>/dev/null <<<"${special}")" \
            || verdict=EXECFAIL
        case "${verdict}" in
            CLEAN)
                pass "C4: password never appears in any process argv" ;;
            LEAK)
                fail "C4: password is visible in a process command line" ;;
            *)
                fail "C4: argv probe did not run (verdict='${verdict:-<no output>}'); password hygiene is UNVERIFIED" ;;
        esac
    fi
    docker rm -f "${c}" >/dev/null 2>&1

    # A REJECTED user creation must fail the container, not report ready.
    # "documentdb" is a blocked role prefix, so create_user raises.
    local c2=documentdb-e2e-c4b
    CONTAINERS+=("${c2}")
    docker rm -f "${c2}" >/dev/null 2>&1
    log "C4: starting with a blocked username (create_user must fail the run)"
    docker run -d --name "${c2}" \
        -e USERNAME=documentdb_blocked -e PASSWORD="$(openssl rand -hex 12)Aa1!" \
        "${IMAGE}" >/dev/null 2>&1 || { fail "C4: blocked-user container failed to start"; return; }
    local waited=0 state=""
    while (( waited < 240 )); do
        state="$(docker inspect -f '{{.State.Status}}' "${c2}" 2>/dev/null || echo gone)"
        [[ "${state}" == "exited" ]] && break
        if docker logs "${c2}" 2>&1 | grep -q "DocumentDB is ready"; then
            break
        fi
        sleep 3; waited=$((waited + 3))
    done
    if docker logs "${c2}" 2>&1 | grep -q "DocumentDB is ready"; then
        fail "C4: container reported READY despite a rejected admin-user creation"
    elif [[ "${state}" == "exited" ]]; then
        local code
        code="$(docker inspect -f '{{.State.ExitCode}}' "${c2}" 2>/dev/null || echo '?')"
        if [[ "${code}" != "0" ]]; then
            pass "C4: rejected admin-user creation failed the container (exit ${code})"
        else
            fail "C4: container exited 0 despite a rejected admin-user creation"
        fi
    else
        fail "C4: container neither became ready nor exited within the timeout"
    fi
    docker rm -f "${c2}" >/dev/null 2>&1
}

scenario_external_connections
scenario_gateway_self_exit
scenario_password_handling

echo ""
echo "══════════════════════════════════════════"
echo " e2e-container: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if (( FAIL_COUNT > 0 )); then
    echo " failed: ${FAILED_IDS[*]}"
    exit 1
fi
echo " ALL CONTAINER SCENARIOS PASSED"
