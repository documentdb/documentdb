#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# e2e-rhel-multimajor.sh — A5 on the RPM side: PostgreSQL 17 and 18
# side by side on one RHEL host.
#
# The deb twin (e2e-multimajor-scenario.sh) proves this on Debian; RHEL
# is worth its own run because per-major package naming, scriptlet
# semantics (%pre/%preun $1 counts) and the /usr/pgsql-N + /var/lib/pgsql
# layout are all different code paths.
#
# Needs BOTH majors' RPMs mounted at /pkgs (extension + per-major
# stand-alone) and installs the PG 17 server from PGDG at runtime, since
# the test image ships only PG 18.
#
#   docker run --rm --user root --entrypoint bash \
#     -v <repo>/oss/packaging:/pkgs:ro \
#     -v <repo>/oss/packaging/test_packages:/e2e:ro \
#     [-e E2E_SETUP_OVERRIDE=/host-scripts/documentdb-setup.sh] \
#     documentdb-test-gateway-rpm-packages:latest /e2e/e2e-rhel-multimajor.sh

set -uo pipefail

# Shared harness helpers (newest-artifact).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-lib.sh"

PASS_COUNT=0
FAIL_COUNT=0
FAILED_IDS=()

log()  { echo -e "\033[1;36m[e2e-rhel-mm]\033[0m $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "\033[1;32mPASS\033[0m $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_IDS+=("$1"); echo -e "\033[1;31mFAIL\033[0m $*"; }

PW_FILE=/root/.e2e-rhelmm-pw
printf '%s' 'RhelMM-Pw1' > "${PW_FILE}"
chmod 600 "${PW_FILE}"

MONGO_JS=/tmp/e2e-rhelmm-connect.js
cat > "${MONGO_JS}" <<'EOF'
const uri = `mongodb://${encodeURIComponent(process.env.DOCUMENTDB_USERNAME)}:${encodeURIComponent(process.env.DOCUMENTDB_PASSWORD)}@127.0.0.1:${process.env.DOCUMENTDB_PORT}/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true`;
db = connect(uri);
load(process.env.DOCUMENTDB_OP_FILE);
EOF
mongo_ping() { # port
    local op
    op="$(mktemp /tmp/e2e-rhelmm-op.XXXXXX.js)"
    printf '%s\n' 'print(JSON.stringify(db.runCommand({ping:1})));' > "${op}"
    DOCUMENTDB_USERNAME=admin DOCUMENTDB_PASSWORD="$(cat "${PW_FILE}")" \
        DOCUMENTDB_PORT="$1" DOCUMENTDB_OP_FILE="${op}" \
        mongosh --nodb --quiet "${MONGO_JS}" 2>&1
    local rc=$?
    rm -f "${op}"
    return "${rc}"
}

log "Installing the PostgreSQL 17 server (image ships only 18)"
if ! dnf install -y -q postgresql17-server postgresql17-contrib > /tmp/rhmm-pg17.log 2>&1; then
    tail -20 /tmp/rhmm-pg17.log >&2
    fail "RHMM-PREP: could not install postgresql17-server"
    exit 1
fi
pass "RHMM-PREP: PostgreSQL 17 server installed alongside 18"

log "Installing the PG17 extension + per-major package"
# Pick the NEWEST match by mtime, never `ls | head -1`, which returns the
# lexicographically first name: /pkgs is bind-mounted from oss/packaging and
# accumulates build outputs across runs, so with 0.115.0 and 0.116.0 both
# present the suite silently validated the stale artifact and reported
# co-installability for packages the developer never built. Same defect this
# series fixed in gateway/build_gateway_packages.sh.
# LC_ALL=C: %T@ is a decimal epoch, and under a locale whose decimal separator
# is ',' sort -n stops parsing at the '.', collapsing all same-second builds
# into a tie that resolves arbitrarily — which could still hand back the stale
# artifact this helper exists to avoid.
newest_rpm() { e2e_newest_artifact /pkgs "$1"; }
rpm17="$(newest_rpm 'rhel9-postgresql17-documentdb-*.rpm')"
std17="$(newest_rpm 'documentdb-17-*.rpm')"
if [[ -z "${rpm17}" || -z "${std17}" ]]; then
    fail "RHMM-PREP: PG17 RPMs not found under /pkgs (ext=${rpm17:-none} std=${std17:-none})"
    exit 1
fi
# Use dnf, not `rpm -Uvh`: the extension RPM declares real dependencies
# (pgvector_17, pg_cron_17, postgis36_17, rum_17) that must be resolved
# from PGDG. Installing with rpm alone fails on those — correctly, since
# the package is right to declare them.
if ! dnf install -y -q "${rpm17}" "${std17}" > /tmp/rhmm-install17.log 2>&1; then
    tail -25 /tmp/rhmm-install17.log >&2
    fail "RHMM-COINSTALL: installing the PG17 packages beside PG18 failed"
    exit 1
fi
pass "RHMM-COINSTALL: documentdb-17 co-installed with documentdb-18"

# The declared dependencies must have actually been pulled in, not just
# satisfied on paper.
for dep in pg_cron_17 rum_17; do
    rpm -q "${dep}" >/dev/null 2>&1 \
        || fail "RHMM-COINSTALL: declared dependency ${dep} was not installed"
done
pass "RHMM-COINSTALL: PG17 extension dependencies resolved from PGDG"

# The shared payload must still be owned/present for BOTH majors.
for f in /usr/bin/documentdb-setup /usr/bin/documentdb-local-reset; do
    [[ -x "${f}" ]] || fail "RHMM-COINSTALL: shared file ${f} missing after co-install"
done
pass "RHMM-COINSTALL: shared documentdb-common payload intact"

if [[ -n "${E2E_SETUP_OVERRIDE:-}" && -r "${E2E_SETUP_OVERRIDE}" ]]; then
    install -m 0755 "${E2E_SETUP_OVERRIDE}" /usr/bin/documentdb-setup
    log "OVERRIDE: documentdb-setup replaced with ${E2E_SETUP_OVERRIDE}"
fi

log "Greenfield setup for major 17 (--listen-port 10271)"
if ! documentdb-setup --pg-version 17 --listen-port 10271 \
        --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/rhmm-17.log 2>&1; then
    tail -30 /tmp/rhmm-17.log >&2
    fail "RHMM-17: greenfield setup for major 17 failed"
    exit 1
fi
pass "RHMM-17: major 17 installed on port 10271"

log "A second major on the SAME gateway port must be refused"
if documentdb-setup --pg-version 18 --listen-port 10271 \
        --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/rhmm-collide.log 2>&1; then
    fail "RHMM-COLLIDE: same-port second major was accepted"
elif grep -q "already in use by the documentdb-local@17 install" /tmp/rhmm-collide.log; then
    pass "RHMM-COLLIDE: port collision refused with the recorded-port message"
else
    tail -5 /tmp/rhmm-collide.log >&2
    fail "RHMM-COLLIDE: refused but with an unexpected message"
fi

log "Greenfield setup for major 18 (--listen-port 10272)"
if ! documentdb-setup --pg-version 18 --listen-port 10272 \
        --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/rhmm-18.log 2>&1; then
    tail -30 /tmp/rhmm-18.log >&2
    fail "RHMM-18: greenfield setup for major 18 failed"
    exit 1
fi
pass "RHMM-18: major 18 installed on port 10272"

out17="$(mongo_ping 10271)"
grep -q '"ok":1' <<<"${out17}" \
    && pass "RHMM-SERVE: major 17 gateway serving on 10271" \
    || fail "RHMM-SERVE: major 17 not serving: $(head -2 <<<"${out17}")"
out18="$(mongo_ping 10272)"
grep -q '"ok":1' <<<"${out18}" \
    && pass "RHMM-SERVE: major 18 gateway serving on 10272" \
    || fail "RHMM-SERVE: major 18 not serving: $(head -2 <<<"${out18}")"

log "gateway-admin must refuse the ambiguous host with usable flags"
if documentdb-gateway-admin list-users > /tmp/rhmm-admin.log 2>&1; then
    fail "RHMM-ADMIN: ambiguous list-users unexpectedly succeeded"
elif grep -q "multiple PostgreSQL instances" /tmp/rhmm-admin.log \
        && grep -q -- "--pg-port" /tmp/rhmm-admin.log; then
    pass "RHMM-ADMIN: ambiguity refused with copy-pasteable per-instance flags"
else
    cat /tmp/rhmm-admin.log >&2
    fail "RHMM-ADMIN: ambiguity message missing per-instance flags"
fi

port17="$(grep -Eo -- '--pg-port [0-9]+ --socket-dir /run/documentdb-local/17/postgresql' /tmp/rhmm-admin.log | awk '{print $2}' | head -1)"
if [[ -z "${port17}" ]]; then
    fail "RHMM-RECOVER: could not extract the major-17 port from the listing"
else
    if documentdb-gateway-admin list-users --pg-port "${port17}" \
            --socket-dir /run/documentdb-local/17/postgresql \
            > /tmp/rhmm-recover.log 2>&1; then
        pass "RHMM-RECOVER: the prescribed explicit re-run works (PG_OWNER recovered)"
    else
        cat /tmp/rhmm-recover.log >&2
        fail "RHMM-RECOVER: the prescribed explicit re-run failed"
    fi
fi

log "Scoped restore of major 17 must leave major 18 serving"
if ! documentdb-setup --restore --pg-version 17 --yes > /tmp/rhmm-restore17.log 2>&1; then
    tail -20 /tmp/rhmm-restore17.log >&2
    fail "RHMM-SCOPED: scoped restore of major 17 failed"
else
    [[ ! -f /etc/documentdb/local/17/setup.conf ]] \
        && pass "RHMM-SCOPED: major-17 state removed" \
        || fail "RHMM-SCOPED: major-17 state survived"
    [[ -f /etc/documentdb/local/18/setup.conf ]] \
        && pass "RHMM-SCOPED: major-18 state untouched" \
        || fail "RHMM-SCOPED: major-18 state was removed by the scoped restore"
    out18b="$(mongo_ping 10272)"
    grep -q '"ok":1' <<<"${out18b}" \
        && pass "RHMM-SCOPED: major 18 still serving after the major-17 restore" \
        || fail "RHMM-SCOPED: major 18 stopped serving: $(head -2 <<<"${out18b}")"
fi

log "Erasing documentdb-17 must not break the surviving major 18"
if rpm -e documentdb-17 > /tmp/rhmm-erase17.log 2>&1; then
    pass "RHMM-ERASE: documentdb-17 erased"
    for f in /usr/bin/documentdb-setup /usr/bin/documentdb-local-reset \
             /usr/lib/systemd/system/documentdb-postgresql@.service; do
        [[ -e "${f}" ]] \
            || fail "RHMM-ERASE: shared file ${f} deleted by erasing one major (payload-split regression)"
    done
    pass "RHMM-ERASE: shared documentdb-common payload survived for major 18"
    out18c="$(mongo_ping 10272)"
    grep -q '"ok":1' <<<"${out18c}" \
        && pass "RHMM-ERASE: major 18 still serving after erasing major 17" \
        || fail "RHMM-ERASE: major 18 stopped serving: $(head -2 <<<"${out18c}")"
else
    tail -20 /tmp/rhmm-erase17.log >&2
    fail "RHMM-ERASE: erasing documentdb-17 failed"
fi

documentdb-setup --restore --yes > /dev/null 2>&1 || true

echo ""
echo "══════════════════════════════════════════"
echo " e2e-rhel-multimajor: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if (( FAIL_COUNT > 0 )); then
    echo " failed: ${FAILED_IDS[*]}"
    exit 1
fi
echo " ALL RHEL MULTI-MAJOR SCENARIOS PASSED"
