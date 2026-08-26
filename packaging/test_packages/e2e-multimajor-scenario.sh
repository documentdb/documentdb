#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# e2e-multimajor-scenario.sh — A5 from the E2E matrix: side-by-side
# greenfield installs of two PostgreSQL majors (17 + 18) on one host.
# Requires BOTH majors' packages staged in the mounted /pkgs dir
# (ubuntu24.04-postgresql-{17,18}-documentdb, documentdb-{17,18},
# gateway, tools, common). Runs inside the deb gateway test image:
#   docker run --rm --user root --entrypoint bash \
#     -v <repo>/oss/packaging:/pkgs:ro \
#     -v <repo>/oss/packaging/test_packages:/e2e:ro \
#     [-e E2E_SETUP_OVERRIDE=...] \
#     documentdb-test-gateway-packages:latest /e2e/e2e-multimajor-scenario.sh
#
# Asserts: distinct-port co-install works; same-port second install dies
# with the collision message; gateway-admin refuses ambiguous auto-detect
# with copy-pasteable per-instance flags and recovers PG_OWNER on the
# prescribed re-run; scoped restore detaches one major while the other
# keeps serving.

set -uo pipefail

PASS_COUNT=0
FAIL_COUNT=0
FAILED_IDS=()

log()  { echo -e "\033[1;36m[e2e-mm]\033[0m $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "\033[1;32mPASS\033[0m $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_IDS+=("$1"); echo -e "\033[1;31mFAIL\033[0m $*"; }

PW_FILE=/root/.e2e-mm-pw
printf '%s' 'MultiMajor-Pw1' > "${PW_FILE}"
chmod 600 "${PW_FILE}"

MONGO_JS=/tmp/e2e-mm-connect.js
cat > "${MONGO_JS}" <<'EOF'
const uri = `mongodb://${encodeURIComponent(process.env.DOCUMENTDB_USERNAME)}:${encodeURIComponent(process.env.DOCUMENTDB_PASSWORD)}@127.0.0.1:${process.env.DOCUMENTDB_PORT}/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true`;
db = connect(uri);
load(process.env.DOCUMENTDB_OP_FILE);
EOF
mongo_ping() { # port
    local op
    op="$(mktemp /tmp/e2e-mm-op.XXXXXX.js)"
    printf '%s\n' 'print(JSON.stringify(db.runCommand({ping:1})));' > "${op}"
    DOCUMENTDB_USERNAME=admin DOCUMENTDB_PASSWORD="$(cat "${PW_FILE}")" \
        DOCUMENTDB_PORT="$1" DOCUMENTDB_OP_FILE="${op}" \
        mongosh --nodb --quiet "${MONGO_JS}" 2>&1
    local rc=$?
    rm -f "${op}"
    return "${rc}"
}

log "Installing BOTH majors' packages from /pkgs"
apt-get update -qq >/dev/null 2>&1
debs=(
    /pkgs/ubuntu24.04-postgresql-17-documentdb_*.deb
    /pkgs/ubuntu24.04-postgresql-18-documentdb_*.deb
    /pkgs/ubuntu24.04-documentdb-gateway_*.deb
    /pkgs/ubuntu24.04-documentdb-postgresql-tools_*.deb
    /pkgs/ubuntu24.04-documentdb-common_*.deb
    /pkgs/ubuntu24.04-documentdb-17_*.deb
    /pkgs/ubuntu24.04-documentdb-18_*.deb
)
# shellcheck disable=SC2068
if ! apt-get install -y -qq -o Dpkg::Use-Pty=0 ${debs[@]} > /tmp/e2e-mm-install.log 2>&1; then
    tail -30 /tmp/e2e-mm-install.log >&2
    fail "MM-INSTALL: co-install of both majors failed"
    exit 1
fi
pass "MM-INSTALL: both majors co-installed in one transaction"

if [[ -n "${E2E_SETUP_OVERRIDE:-}" && -r "${E2E_SETUP_OVERRIDE}" ]]; then
    install -m 0755 "${E2E_SETUP_OVERRIDE}" /usr/bin/documentdb-setup
    log "OVERRIDE: documentdb-setup replaced with ${E2E_SETUP_OVERRIDE}"
fi

log "Greenfield setup for major 17 (--listen-port 10261)"
if ! documentdb-setup --pg-version 17 --listen-port 10261 \
        --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/e2e-mm-17.log 2>&1; then
    tail -30 /tmp/e2e-mm-17.log >&2
    fail "MM-17: greenfield setup for major 17 failed"
    exit 1
fi
pass "MM-17: major 17 set up on port 10261"

log "Second major on the SAME port must be refused"
if documentdb-setup --pg-version 18 --listen-port 10261 \
        --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/e2e-mm-collide.log 2>&1; then
    fail "MM-COLLIDE: same-port second major was accepted"
else
    if grep -q "already in use by the documentdb-local@17 install" /tmp/e2e-mm-collide.log; then
        pass "MM-COLLIDE: collision refused with the recorded-port message"
    else
        tail -5 /tmp/e2e-mm-collide.log >&2
        fail "MM-COLLIDE: refused but message unexpected"
    fi
fi

log "Greenfield setup for major 18 (--listen-port 10262)"
if ! documentdb-setup --pg-version 18 --listen-port 10262 \
        --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/e2e-mm-18.log 2>&1; then
    tail -30 /tmp/e2e-mm-18.log >&2
    fail "MM-18: greenfield setup for major 18 failed"
    exit 1
fi
pass "MM-18: major 18 set up on port 10262"

out17="$(mongo_ping 10261)"
grep -q '"ok":1' <<<"${out17}" \
    && pass "MM-SERVE: major 17 gateway serves on 10261" \
    || fail "MM-SERVE: major 17 not serving: $(head -2 <<<"${out17}")"
out18="$(mongo_ping 10262)"
grep -q '"ok":1' <<<"${out18}" \
    && pass "MM-SERVE: major 18 gateway serves on 10262" \
    || fail "MM-SERVE: major 18 not serving: $(head -2 <<<"${out18}")"

log "gateway-admin auto-detect must refuse the ambiguity with usable flags"
if documentdb-gateway-admin list-users > /tmp/e2e-mm-admin.log 2>&1; then
    fail "MM-ADMIN: ambiguous list-users unexpectedly succeeded"
else
    if grep -q "multiple PostgreSQL instances" /tmp/e2e-mm-admin.log \
            && grep -Eq -- '--pg-port 97(17|00).*--socket-dir /run/documentdb-local/17/postgresql' /tmp/e2e-mm-admin.log; then
        pass "MM-ADMIN: ambiguity error lists copy-pasteable per-instance flags"
    else
        cat /tmp/e2e-mm-admin.log >&2
        fail "MM-ADMIN: ambiguity error missing per-instance flags"
    fi
fi

log "Prescribed explicit re-run must work (PG_OWNER recovery)"
pg17_port="$(grep -Eo -- '--pg-port [0-9]+ --socket-dir /run/documentdb-local/17/postgresql' /tmp/e2e-mm-admin.log | awk '{print $2}' | head -1)"
if [[ -z "${pg17_port}" ]]; then
    fail "MM-RECOVER: could not extract major-17 port from the ambiguity listing"
else
    if documentdb-gateway-admin list-users --pg-port "${pg17_port}" \
            --socket-dir /run/documentdb-local/17/postgresql \
            > /tmp/e2e-mm-recover.log 2>&1; then
        pass "MM-RECOVER: explicit flags + state recovery worked (list-users ok)"
    else
        cat /tmp/e2e-mm-recover.log >&2
        fail "MM-RECOVER: prescribed explicit re-run failed"
    fi
fi

log "Scoped restore of major 17 must leave major 18 serving"
if ! documentdb-setup --restore --pg-version 17 --yes > /tmp/e2e-mm-restore17.log 2>&1; then
    tail -20 /tmp/e2e-mm-restore17.log >&2
    fail "MM-SCOPED: scoped restore of 17 failed"
else
    [[ ! -f /etc/documentdb/local/17/setup.conf ]] \
        && pass "MM-SCOPED: major-17 state removed" \
        || fail "MM-SCOPED: major-17 setup.conf survived"
    [[ -f /etc/documentdb/local/18/setup.conf ]] \
        && pass "MM-SCOPED: major-18 state untouched" \
        || fail "MM-SCOPED: major-18 setup.conf was removed by the scoped restore"
    out18b="$(mongo_ping 10262)"
    grep -q '"ok":1' <<<"${out18b}" \
        && pass "MM-SCOPED: major 18 still serving after major-17 restore" \
        || fail "MM-SCOPED: major 18 stopped serving: $(head -2 <<<"${out18b}")"
fi

log "Unscoped restore now covers the single remaining major"
if documentdb-setup --restore --yes > /tmp/e2e-mm-restore-all.log 2>&1; then
    [[ ! -f /etc/documentdb/local/18/setup.conf ]] \
        && pass "MM-FINAL: unscoped restore detached the remaining major" \
        || fail "MM-FINAL: major-18 state survived the unscoped restore"
else
    tail -20 /tmp/e2e-mm-restore-all.log >&2
    fail "MM-FINAL: unscoped restore failed"
fi

echo ""
echo "══════════════════════════════════════════"
echo " e2e-multimajor: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if (( FAIL_COUNT > 0 )); then
    echo " failed: ${FAILED_IDS[*]}"
    exit 1
fi
echo " ALL MULTI-MAJOR SCENARIOS PASSED"
