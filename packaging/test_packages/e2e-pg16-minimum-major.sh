#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# e2e-pg16-minimum-major.sh — validate the OLDEST supported PostgreSQL
# major end to end.
#
# Why PG 16 specifically: documentdb-setup's
# enforce_gateway_pg_major_supported() sets the floor at 16 because the
# gateway maps its OS user to per-user database roles through
# pg_ident.conf GROUP MEMBERSHIP ('+role'), which PostgreSQL only
# supports from 16 onward, and SCRAM users have no password fallback. So
# PG 16 is not just "another matrix cell" — it is the version where that
# mechanism is newest and most likely to differ.
#
# Run inside a deb gateway test image built with PG 16 packages:
#   docker run --rm --user root --entrypoint bash \
#     -v <repo>/oss/packaging/test_packages:/e2e:ro \
#     [-e E2E_SETUP_OVERRIDE=/host-scripts/documentdb-setup.sh] \
#     documentdb-test-gateway-packages-pg16:latest /e2e/e2e-pg16-minimum-major.sh

set -uo pipefail

# Shared harness helpers.
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-lib.sh"

PG_MAJOR="${PG_MAJOR:-16}"
PASS_COUNT=0
FAIL_COUNT=0
FAILED_IDS=()

log()  { echo -e "\033[1;36m[e2e-pg16]\033[0m $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "\033[1;32mPASS\033[0m $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_IDS+=("$1"); echo -e "\033[1;31mFAIL\033[0m $*"; }

PW_FILE=/root/.e2e-pg16-pw
printf '%s' 'Pg16-E2e-Pw1' > "${PW_FILE}"
chmod 600 "${PW_FILE}"

MONGO_JS=/tmp/e2e-pg16-connect.js
cat > "${MONGO_JS}" <<'EOF'
const uri = `mongodb://${encodeURIComponent(process.env.DOCUMENTDB_USERNAME)}:${encodeURIComponent(process.env.DOCUMENTDB_PASSWORD)}@127.0.0.1:${process.env.DOCUMENTDB_PORT}/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true`;
db = connect(uri);
load(process.env.DOCUMENTDB_OP_FILE);
EOF
mongo_eval() { # user password port js
    local op
    op="$(mktemp /tmp/e2e-pg16-op.XXXXXX.js)"
    printf '%s\n' "$4" > "${op}"
    DOCUMENTDB_USERNAME="$1" DOCUMENTDB_PASSWORD="$2" DOCUMENTDB_PORT="$3" \
        DOCUMENTDB_OP_FILE="${op}" mongosh --nodb --quiet "${MONGO_JS}" 2>&1
    local rc=$?
    rm -f "${op}"
    return "${rc}"
}

log "Installing packages"
if ! e2e_collect_staged_debs; then
    fail "PG16-INSTALL: no .deb packages staged in /tmp/install_setup"
    exit 1
fi
apt-get update -qq >/dev/null 2>&1
if ! apt-get install -y -qq -o Dpkg::Use-Pty=0 "${E2E_STAGED_DEBS[@]}" \
        > /tmp/pg16-install.log 2>&1; then
    tail -30 /tmp/pg16-install.log >&2
    fail "PG16-INSTALL: package installation failed"
    exit 1
fi
pass "PG16-INSTALL: ${#E2E_STAGED_DEBS[@]} packages installed"

if [[ -n "${E2E_SETUP_OVERRIDE:-}" && -r "${E2E_SETUP_OVERRIDE}" ]]; then
    install -m 0755 "${E2E_SETUP_OVERRIDE}" /usr/bin/documentdb-setup
    log "OVERRIDE: documentdb-setup replaced with ${E2E_SETUP_OVERRIDE}"
fi

# The floor must be enforced, not merely documented: a below-minimum major
# has to be refused with the real reason.
log "Minimum-major guard: PG 15 must be refused"
out="$(documentdb-setup --pg-version 15 --admin-user admin \
        --admin-password-file "${PW_FILE}" --yes 2>&1)"
if grep -q "requires PostgreSQL 16 or newer" <<<"${out}"; then
    pass "PG16-FLOOR: a below-minimum major is refused with the reason"
else
    fail "PG16-FLOOR: PG 15 not refused as expected: $(head -3 <<<"${out}")"
fi

log "Greenfield setup on the minimum supported major (PG ${PG_MAJOR})"
if ! documentdb-setup --pg-version "${PG_MAJOR}" --admin-user admin \
        --admin-password-file "${PW_FILE}" --yes > /tmp/pg16-setup.log 2>&1; then
    tail -30 /tmp/pg16-setup.log >&2
    fail "PG16-SETUP: greenfield setup failed on PG ${PG_MAJOR}"
    exit 1
fi
pass "PG16-SETUP: greenfield setup succeeded on PG ${PG_MAJOR}"

# THE PG16-specific mechanism: pg_ident.conf '+role' group membership.
IDENT="/var/lib/documentdb-local/${PG_MAJOR}/data/pg_ident.conf"
if [[ -f "${IDENT}" ]]; then
    if grep -qE '^\s*documentdb-gateway-map\s+\S+\s+\+' "${IDENT}"; then
        pass "PG16-IDENT: '+role' group-membership mapping written to pg_ident.conf"
        log "  $(grep -E '^\s*documentdb-gateway-map\s+\S+\s+\+' "${IDENT}" | head -2 | tr '\n' ';')"
    else
        head -25 "${IDENT}" >&2
        fail "PG16-IDENT: no '+role' group-membership entry (the PG16 feature this floor exists for)"
    fi
else
    fail "PG16-IDENT: ${IDENT} not found"
fi

# And it must actually WORK: the gateway authenticates through that mapping.
out="$(mongo_eval admin "$(cat "${PW_FILE}")" 10260 'print(JSON.stringify(db.runCommand({ping:1})));')"
if grep -q '"ok":1' <<<"${out}"; then
    pass "PG16-AUTH: gateway authenticates via the '+role' ident mapping on PG ${PG_MAJOR}"
else
    fail "PG16-AUTH: gateway auth failed on PG ${PG_MAJOR}: $(head -3 <<<"${out}")"
fi

out="$(mongo_eval admin "$(cat "${PW_FILE}")" 10260 '
    const c = db.getSiblingDB("pg16e2e").docs;
    c.insertOne({_id: "a", n: 7});
    const f = c.findOne({_id: "a"});
    const d = c.deleteOne({_id: "a"});
    print(JSON.stringify({n: f ? f.n : null, deleted: d.deletedCount}));')"
if grep -q '"n":7' <<<"${out}" && grep -q '"deleted":1' <<<"${out}"; then
    pass "PG16-CRUD: insert/find/delete round-trip on PG ${PG_MAJOR}"
else
    fail "PG16-CRUD: round-trip failed: $(head -3 <<<"${out}")"
fi

# Day-2 user management must work through the same mapping. NOTE the
# username deliberately avoids the gateway's blocked prefixes
# (documentdb / citus / pg / internal_role) — "pg16user" would be refused,
# which is how the missing-validation bug below was found.
PW2=/root/.e2e-pg16-user2
printf '%s' 'Pg16-User2-Pw' > "${PW2}"; chmod 600 "${PW2}"
if documentdb-gateway-admin create-user --username e2e16user --password-file "${PW2}" \
        > /tmp/pg16-createuser.log 2>&1; then
    pass "PG16-DAY2: create-user succeeded"
    out="$(mongo_eval e2e16user "$(cat "${PW2}")" 10260 'print(JSON.stringify(db.runCommand({ping:1})));')"
    grep -q '"ok":1' <<<"${out}" \
        && pass "PG16-DAY2: the new user authenticates through the gateway" \
        || fail "PG16-DAY2: new user cannot authenticate: $(head -2 <<<"${out}")"
else
    tail -20 /tmp/pg16-createuser.log >&2
    fail "PG16-DAY2: create-user failed"
fi

# A username the gateway blocks must be refused UP FRONT rather than
# creating a role that reports success and then fails every login with
# "Username is invalid".
if documentdb-gateway-admin create-user --username pgblocked --password-file "${PW2}" \
        > /tmp/pg16-blocked.log 2>&1; then
    fail "PG16-BLOCKED: create-user accepted a reserved-prefix username"
elif grep -q "reserved prefix" /tmp/pg16-blocked.log; then
    pass "PG16-BLOCKED: create-user refuses a reserved-prefix username with the reason"
else
    tail -3 /tmp/pg16-blocked.log >&2
    fail "PG16-BLOCKED: refused but without the reserved-prefix explanation"
fi

log "Restore must detach cleanly and preserve PostgreSQL data"
if documentdb-setup --restore --pg-version "${PG_MAJOR}" --yes > /tmp/pg16-restore.log 2>&1; then
    pass "PG16-RESTORE: restore completed"
    [[ -f "/var/lib/documentdb-local/${PG_MAJOR}/data/PG_VERSION" ]] \
        && pass "PG16-RESTORE: PostgreSQL data directory survived" \
        || fail "PG16-RESTORE: PostgreSQL data directory was removed"
    [[ ! -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf" ]] \
        && pass "PG16-RESTORE: per-major state removed" \
        || fail "PG16-RESTORE: per-major state survived"
else
    tail -20 /tmp/pg16-restore.log >&2
    fail "PG16-RESTORE: restore failed"
fi

echo ""
echo "══════════════════════════════════════════"
echo " e2e-pg16: ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
if (( FAIL_COUNT > 0 )); then
    echo " failed: ${FAILED_IDS[*]}"
    exit 1
fi
echo " ALL PG16 MINIMUM-MAJOR SCENARIOS PASSED"
