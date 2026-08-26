#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# e2e-rhel-scenarios.sh — the manual scenario matrix on the RPM/RHEL side.
# The automated RPM clean-install suite covers install/setup/managed
# blocks/sample data/day-2/erase; this covers what it does not, focusing on
# the paths where RHEL genuinely differs from Debian:
#
#   RH-TUNE       documentdb-tune writes its managed block INTO the data
#                 dir's postgresql.conf (RHEL layout) rather than a
#                 separate fragment + include line (Debian layout), and
#                 merges an operator's existing shared_preload_libraries
#   RH-BROWNFIELD adoption of a /var/lib/pgsql/<N>/data cluster whose
#                 config files live inside the data dir
#   RH-HYGIENE    RPM scriptlet lifecycle: reinstall, erase residue audit
#                 (no private key, no gateway user, no binaries)
#   RH-GREENFIELD greenfield setup + special-character password + CRUD
#   RH-PORTKEEP   bare re-run preserves --listen-port (day-2 state)
#   RH-DRYRUN     --dry-run and --restore --dry-run mutate nothing
#   RH-CONFLICT   contradictory flags die clearly
#   RH-SCOPEREST  --restore --pg-version validation and scoping
#
# Runs INSIDE documentdb-test-gateway-rpm-packages:latest, which ships all
# five packages pre-installed and the .rpm files staged at /tmp/*.rpm:
#   docker run --rm --user root --entrypoint bash \
#     -v <repo>/oss/packaging/test_packages:/e2e:ro \
#     [-e E2E_SETUP_OVERRIDE=/host-scripts/documentdb-setup.sh] \
#     documentdb-test-gateway-rpm-packages:latest /e2e/e2e-rhel-scenarios.sh

set -uo pipefail

# Shared harness helpers (skip).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-lib.sh"

PG_MAJOR="${PG_MAJOR:-18}"
PG_BIN="/usr/pgsql-${PG_MAJOR}/bin"
RHEL_DATA_DIR="/var/lib/pgsql/${PG_MAJOR}/data"
GATEWAY_PORT_DEFAULT=10260
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_IDS=()
SKIPPED_IDS=()

log()  { echo -e "\033[1;36m[e2e-rhel]\033[0m $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "\033[1;32mPASS\033[0m $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_IDS+=("$1"); echo -e "\033[1;31mFAIL\033[0m $*"; }
skip() { e2e_skip "$@"; }

PW_FILE=/root/.e2e-rhel-pw
printf '%s' 'RhelE2e-Pw1' > "${PW_FILE}"
chmod 600 "${PW_FILE}"

if [[ -n "${E2E_SETUP_OVERRIDE:-}" && -r "${E2E_SETUP_OVERRIDE}" ]]; then
    install -m 0755 "${E2E_SETUP_OVERRIDE}" /usr/bin/documentdb-setup
    log "OVERRIDE: documentdb-setup replaced with ${E2E_SETUP_OVERRIDE}"
fi

# CredScan-clean mongosh auth; operations are load()ed from a file so
# mongosh's async auto-await applies (an eval'd string yields "{}").
MONGO_JS=/tmp/e2e-rhel-connect.js
cat > "${MONGO_JS}" <<'EOF'
const uri = `mongodb://${encodeURIComponent(process.env.DOCUMENTDB_USERNAME)}:${encodeURIComponent(process.env.DOCUMENTDB_PASSWORD)}@127.0.0.1:${process.env.DOCUMENTDB_PORT}/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true`;
db = connect(uri);
load(process.env.DOCUMENTDB_OP_FILE);
EOF
mongo_eval() { # user password port js
    local op
    op="$(mktemp /tmp/e2e-rhel-op.XXXXXX.js)"
    printf '%s\n' "$4" > "${op}"
    DOCUMENTDB_USERNAME="$1" DOCUMENTDB_PASSWORD="$2" DOCUMENTDB_PORT="$3" \
        DOCUMENTDB_OP_FILE="${op}" mongosh --nodb --quiet "${MONGO_JS}" 2>&1
    local rc=$?
    rm -f "${op}"
    return "${rc}"
}

snapshot_state() {
    # /etc/passwd, /etc/group and /etc/shadow are watched deliberately:
    # ensure_documentdb_runtime_user() runs groupadd/useradd for
    # documentdb-local and documentdb-gateway, and account changes are the one
    # class of mutation this snapshot could not otherwise see at all.
    # PREVENTION, not a fix for an observed failure — main()'s dry-run branch
    # currently exits before that function is reached, so this guards against a
    # future change moving user creation earlier.
    { find /etc/documentdb /etc/passwd /etc/group /etc/shadow \
           /var/lib/documentdb-local /var/lib/documentdb-gateway \
           /etc/systemd/system /var/lib/pgsql -xdev \
           \( -path '*/pg_wal/*' -o -path '*/pg_stat*' -o -path '*/pg_logical/*' \
              -o -path '*/global/*' -o -path '*/base/*' -o -path '*/pg_xact/*' \
              -o -path '*/pg_subtrans/*' -o -path '*/pg_notify/*' \
              -o -path '*/pg_dynshmem/*' -o -path '*/pg_replslot/*' \
              -o -name 'pglog.log' -o -name '*.log' -o -name 'postmaster.pid' \
              -o -name 'postmaster.opts' -o -name 'current_logfiles' \) -prune \
           -o -printf '%p %s %T@ %m %u %g\n' 2>/dev/null | sort; } || true
}

reset_install_state() {
    documentdb-setup --restore --yes >/dev/null 2>&1 || true
    documentdb-local-reset --pg-version "${PG_MAJOR}" --confirm-destroy >/dev/null 2>&1 || true
}

# ── RH-READONLY / RH-DRYRUN on a clean host ────────────────────────────
scenario_readonly_dryrun() {
    local out rc
    out="$(documentdb-setup --status 2>&1)"; rc=$?
    if [[ -n "${out}" && ( ${rc} -eq 0 || ${rc} -eq 1 ) ]]; then
        pass "RH-READONLY: --status reports on the RPM host (rc=${rc})"
    else
        fail "RH-READONLY: --status silent or crashed (rc=${rc}): ${out}"
    fi
    out="$(documentdb-setup --print-config 2>&1)"; rc=$?
    if [[ ${rc} -eq 0 && "${out}" == *"gateway"* ]]; then
        pass "RH-READONLY: --print-config exits 0 with resolved config"
    else
        fail "RH-READONLY: --print-config rc=${rc}: $(head -3 <<<"${out}")"
    fi

    local before after
    before="$(snapshot_state)"
    documentdb-setup --dry-run --admin-user admin > /tmp/rh-dryrun.log 2>&1 \
        || { fail "RH-DRYRUN: --dry-run exited non-zero"; return; }
    after="$(snapshot_state)"
    if [[ "${before}" == "${after}" ]]; then
        pass "RH-DRYRUN: --dry-run mutated nothing"
    else
        diff <(echo "${before}") <(echo "${after}") | head -15 >&2
        fail "RH-DRYRUN: --dry-run changed filesystem state"
    fi
    grep -q "\[dry-run\]" /tmp/rh-dryrun.log \
        && pass "RH-DRYRUN: preview output is labeled" \
        || fail "RH-DRYRUN: no [dry-run] labels"
}

scenario_conflicts() {
    local out
    if out="$(documentdb-setup --use-new-postgres-instance \
            --target-postgres-instance "${PG_MAJOR}/main" \
            --admin-user a --yes 2>&1)"; then
        fail "RH-CONFLICT: mode flags accepted together"
    elif grep -q "mutually exclusive" <<<"${out}"; then
        pass "RH-CONFLICT: mode flags rejected"
    else
        fail "RH-CONFLICT: unclear rejection: $(head -2 <<<"${out}")"
    fi
    if out="$(documentdb-setup --tls-auto-generate false --admin-user a --yes 2>&1)"; then
        fail "RH-CONFLICT: --tls-auto-generate false alone accepted"
    elif grep -q "requires --tls-cert and --tls-key" <<<"${out}"; then
        pass "RH-CONFLICT: tls-auto-generate=false alone rejected at the CLI"
    else
        fail "RH-CONFLICT: unclear TLS rejection: $(head -2 <<<"${out}")"
    fi
}

# ── RH-TUNE: the RHEL layout branch of documentdb-tune ─────────────────
scenario_tune_rhel_layout() {
    local tdir=/tmp/rh-tune-data
    rm -rf "${tdir}"; mkdir -p "${tdir}"
    # A config-only fixture standing in for an initialized cluster, with an
    # operator preload already set (in PostgreSQL's optional-'=' form, which
    # the parser must accept).
    cat > "${tdir}/postgresql.conf" <<'CONF'
port = 5599
shared_preload_libraries 'pg_stat_statements'
CONF

    if ! documentdb-tune --pgdata "${tdir}" --yes > /tmp/rh-tune.log 2>&1; then
        tail -20 /tmp/rh-tune.log >&2
        fail "RH-TUNE: apply against a RHEL-style data dir failed"
        return
    fi
    pass "RH-TUNE: apply succeeded against the data dir"

    # RHEL layout: the managed block goes INTO the data dir's
    # postgresql.conf (Debian instead writes a fragment + include line).
    if grep -q '>>> documentdb-setup managed configuration >>>' "${tdir}/postgresql.conf"; then
        pass "RH-TUNE: managed block written into the data dir postgresql.conf"
    else
        fail "RH-TUNE: no managed block in ${tdir}/postgresql.conf (RHEL layout regression)"
    fi
    if [[ -e "/etc/postgresql-common/documentdb/${PG_MAJOR}" ]]; then
        fail "RH-TUNE: Debian-style fragment tree created on a RHEL host"
    else
        pass "RH-TUNE: no Debian-style fragment tree created"
    fi

    # The operator's own preload must be merged, not clobbered.
    local spl
    spl="$(grep -E "^[[:space:]]*shared_preload_libraries" "${tdir}/postgresql.conf" | tail -1)"
    if grep -q 'pg_stat_statements' <<<"${spl}" && grep -q 'pg_documentdb' <<<"${spl}"; then
        pass "RH-TUNE: operator preload merged with DocumentDB's (${spl##*=})"
    else
        fail "RH-TUNE: operator preload not merged: ${spl}"
    fi

    # Restore must strip the block and leave the operator's line behind.
    if ! documentdb-tune --pgdata "${tdir}" --restore --yes > /tmp/rh-tune-restore.log 2>&1; then
        tail -20 /tmp/rh-tune-restore.log >&2
        fail "RH-TUNE: restore failed"
        return
    fi
    if grep -q '>>> documentdb-setup managed configuration >>>' "${tdir}/postgresql.conf"; then
        fail "RH-TUNE: managed block survived restore"
    else
        pass "RH-TUNE: restore stripped the managed block"
    fi
    grep -q 'pg_stat_statements' "${tdir}/postgresql.conf" \
        && pass "RH-TUNE: operator's own preload line survived restore" \
        || fail "RH-TUNE: restore removed the operator's preload line"
    rm -rf "${tdir}"
}

# ── RH-GREENFIELD + RH-PORTKEEP ────────────────────────────────────────
scenario_greenfield_portkeep() {
    local pw_special='rh"pa'\''ss\!1'
    local pwf=/root/.e2e-rhel-special
    printf '%s' "${pw_special}" > "${pwf}"; chmod 600 "${pwf}"

    log "Greenfield setup on RPM host (--listen-port 27019)"
    if ! documentdb-setup --admin-user admin --admin-password-file "${pwf}" \
            --listen-port 27019 --yes > /tmp/rh-greenfield.log 2>&1; then
        tail -30 /tmp/rh-greenfield.log >&2
        fail "RH-GREENFIELD: setup failed"
        return
    fi
    pass "RH-GREENFIELD: greenfield setup succeeded"

    [[ -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf" ]] \
        && pass "RH-GREENFIELD: per-major state written" \
        || fail "RH-GREENFIELD: per-major state missing"

    local url_file="/var/lib/documentdb-local/${PG_MAJOR}/gateway/pg-url"
    if [[ -f "${url_file}" ]]; then
        local mode owner
        mode="$(stat -c '%a' "${url_file}")"
        owner="$(stat -c '%U:%G' "${url_file}")"
        [[ "${mode}" == "640" && "${owner}" == "root:documentdb-gateway" ]] \
            && pass "RH-GREENFIELD: connection URL is ${mode} ${owner}" \
            || fail "RH-GREENFIELD: connection URL is ${mode} ${owner} (want 640 root:documentdb-gateway)"
    else
        fail "RH-GREENFIELD: connection URL file missing"
    fi

    local out
    out="$(mongo_eval admin "${pw_special}" 27019 'print(JSON.stringify(db.runCommand({ping:1})));')"
    grep -q '"ok":1' <<<"${out}" \
        && pass "RH-GREENFIELD: special-character password authenticates" \
        || fail "RH-GREENFIELD: mongosh auth failed: $(head -2 <<<"${out}")"

    out="$(mongo_eval admin "${pw_special}" 27019 '
        const c = db.getSiblingDB("rhe2e").docs;
        c.insertOne({_id: "k1", v: 42});
        const f = c.findOne({_id: "k1"});
        const d = c.deleteOne({_id: "k1"});
        print(JSON.stringify({v: f ? f.v : null, deleted: d.deletedCount}));')"
    if grep -q '"v":42' <<<"${out}" && grep -q '"deleted":1' <<<"${out}"; then
        pass "RH-GREENFIELD: CRUD round-trip through the gateway"
    else
        fail "RH-GREENFIELD: CRUD failed: $(head -3 <<<"${out}")"
    fi

    log "Bare re-run must preserve --listen-port 27019"
    if ! documentdb-setup --admin-user admin --admin-password-file "${pwf}" --yes \
            > /tmp/rh-rerun.log 2>&1; then
        tail -30 /tmp/rh-rerun.log >&2
        fail "RH-PORTKEEP: bare re-run failed"
        return
    fi
    if grep -q "Keeping gateway listen port 27019" /tmp/rh-rerun.log \
        && grep -q "DOCUMENTDB_LISTEN_ADDR=:27019" "/etc/documentdb/local/${PG_MAJOR}/gateway.env"; then
        pass "RH-PORTKEEP: bare re-run preserved the listen port"
    else
        grep -i listen /tmp/rh-rerun.log | head -5 >&2
        fail "RH-PORTKEEP: listen port not preserved"
    fi
    out="$(mongo_eval admin "${pw_special}" 27019 'print(JSON.stringify(db.runCommand({ping:1})));')"
    grep -q '"ok":1' <<<"${out}" \
        && pass "RH-PORTKEEP: gateway still serving on 27019 after re-run" \
        || fail "RH-PORTKEEP: not serving after re-run: $(head -2 <<<"${out}")"
}

# ── RH-SCOPEREST ───────────────────────────────────────────────────────
scenario_scoped_restore() {
    local out
    if out="$(documentdb-setup --restore --pg-version '*' 2>&1)"; then
        fail "RH-SCOPEREST: wildcard --pg-version accepted"
    elif grep -q "single numeric PostgreSQL major" <<<"${out}"; then
        pass "RH-SCOPEREST: wildcard scope rejected"
    else
        fail "RH-SCOPEREST: unclear rejection: $(head -2 <<<"${out}")"
    fi

    local before after
    before="$(snapshot_state)"
    documentdb-setup --restore --dry-run > /tmp/rh-restore-dry.log 2>&1 \
        || { fail "RH-SCOPEREST: --restore --dry-run exited non-zero"; return; }
    after="$(snapshot_state)"
    [[ "${before}" == "${after}" ]] \
        && pass "RH-SCOPEREST: --restore --dry-run mutated nothing" \
        || { diff <(echo "${before}") <(echo "${after}") | head -12 >&2
             fail "RH-SCOPEREST: --restore --dry-run changed state"; }

    if documentdb-setup --restore --pg-version "${PG_MAJOR}" --yes > /tmp/rh-restore.log 2>&1; then
        [[ ! -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf" ]] \
            && pass "RH-SCOPEREST: scoped restore removed the major's state" \
            || fail "RH-SCOPEREST: state survived the scoped restore"
    else
        tail -20 /tmp/rh-restore.log >&2
        fail "RH-SCOPEREST: scoped restore failed"
    fi
    reset_install_state
}

# ── RH-BROWNFIELD: adopt a /var/lib/pgsql/<N>/data cluster ─────────────
scenario_brownfield_rhel() {
    reset_install_state
    log "Creating a RHEL-layout cluster at ${RHEL_DATA_DIR}"
    rm -rf "${RHEL_DATA_DIR}"
    install -d -o postgres -g postgres -m 0700 "${RHEL_DATA_DIR}"
    if ! runuser -u postgres -- "${PG_BIN}/initdb" -D "${RHEL_DATA_DIR}" \
            > /tmp/rh-initdb.log 2>&1; then
        tail -20 /tmp/rh-initdb.log >&2
        fail "RH-BROWNFIELD: initdb failed"
        return
    fi
    # An operator setting that adoption must not clobber, on a non-default port.
    printf "\nport = 5433\nlisten_addresses = '*'\n" >> "${RHEL_DATA_DIR}/postgresql.conf"
    if ! runuser -u postgres -- "${PG_BIN}/pg_ctl" -D "${RHEL_DATA_DIR}" \
            -l /tmp/rh-brownfield-pg.log -w start > /tmp/rh-pgstart.log 2>&1; then
        tail -20 /tmp/rh-brownfield-pg.log >&2
        fail "RH-BROWNFIELD: cluster start failed"
        return
    fi
    pass "RH-BROWNFIELD: operator cluster initialized and started"

    runuser -u postgres -- "${PG_BIN}/psql" -p 5433 -c \
        "CREATE TABLE operator_marker(v text); INSERT INTO operator_marker VALUES ('keep-me');" \
        > /dev/null 2>&1 \
        || { fail "RH-BROWNFIELD: could not seed operator data"; return; }
    pass "RH-BROWNFIELD: operator data seeded"

    log "Adopting ${PG_MAJOR}/main (step 1)"
    local rc=0
    documentdb-setup --target-postgres-instance "${PG_MAJOR}/main" \
        --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/rh-bf1.log 2>&1 || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        tail -30 /tmp/rh-bf1.log >&2
        fail "RH-BROWNFIELD: first adoption run failed (rc=${rc})"
        return
    fi
    pass "RH-BROWNFIELD: adoption step 1 completed"

    # If a restart handoff was printed, honor it exactly as an operator would.
    if grep -q "must be restarted" /tmp/rh-bf1.log; then
        grep -q -- "--admin-password-file ${PW_FILE}" /tmp/rh-bf1.log \
            && pass "RH-BROWNFIELD: printed re-run command carries the password source" \
            || fail "RH-BROWNFIELD: printed re-run command omits the password source"
        runuser -u postgres -- "${PG_BIN}/pg_ctl" -D "${RHEL_DATA_DIR}" \
            -l /tmp/rh-brownfield-pg.log -w restart > /dev/null 2>&1 \
            || { fail "RH-BROWNFIELD: cluster restart failed"; return; }
        log "Adoption step 2 (after restart)"
        if ! documentdb-setup --target-postgres-instance "${PG_MAJOR}/main" \
                --admin-user admin --admin-password-file "${PW_FILE}" --yes \
                > /tmp/rh-bf2.log 2>&1; then
            tail -30 /tmp/rh-bf2.log >&2
            fail "RH-BROWNFIELD: adoption step 2 failed"
            return
        fi
        pass "RH-BROWNFIELD: two-step adoption completed"
    else
        # Everything above — the password-source check, the cluster restart,
        # the step-2 run and the completion assertion — lived inside the grep
        # with no else. A reworded banner (or a handoff regression that wrongly
        # claimed step 1 was sufficient) deleted all four at once: zero PASS,
        # zero FAIL, and the suite's headline count silently shrank with no
        # indication a scenario had been skipped.
        skip "RH-BROWNFIELD: no restart handoff in step-1 output; the two-step adoption path was not exercised"
    fi

    local out
    out="$(mongo_eval admin "$(cat "${PW_FILE}")" ${GATEWAY_PORT_DEFAULT} 'print(JSON.stringify(db.runCommand({ping:1})));')"
    grep -q '"ok":1' <<<"${out}" \
        && pass "RH-BROWNFIELD: gateway serves against the adopted cluster" \
        || fail "RH-BROWNFIELD: gateway not serving: $(head -2 <<<"${out}")"

    # Managed blocks must be in the DATA DIR's config files (RHEL layout).
    grep -q '>>> documentdb-setup managed' "${RHEL_DATA_DIR}/pg_hba.conf" 2>/dev/null \
        && pass "RH-BROWNFIELD: managed hba block written into the data dir" \
        || fail "RH-BROWNFIELD: no managed hba block in ${RHEL_DATA_DIR}/pg_hba.conf"

    # The operator's own listen/port settings must survive adoption.
    grep -qE "^[[:space:]]*listen_addresses[[:space:]]*=[[:space:]]*'\*'" \
        "${RHEL_DATA_DIR}/postgresql.conf" \
        && pass "RH-BROWNFIELD: operator listen_addresses preserved" \
        || fail "RH-BROWNFIELD: operator listen_addresses was overwritten"

    local marker
    marker="$(runuser -u postgres -- "${PG_BIN}/psql" -p 5433 -tA -c 'SELECT v FROM operator_marker;' 2>/dev/null)"
    [[ "${marker}" == "keep-me" ]] \
        && pass "RH-BROWNFIELD: operator data intact after adoption" \
        || fail "RH-BROWNFIELD: operator data missing after adoption"

    log "Detaching with --restore"
    if ! documentdb-setup --restore --pg-version "${PG_MAJOR}" --yes > /tmp/rh-bf-restore.log 2>&1; then
        tail -20 /tmp/rh-bf-restore.log >&2
        fail "RH-BROWNFIELD: restore failed"
        return
    fi
    grep -q '>>> documentdb-setup managed' "${RHEL_DATA_DIR}/pg_hba.conf" 2>/dev/null \
        && fail "RH-BROWNFIELD: managed hba block survived restore" \
        || pass "RH-BROWNFIELD: restore stripped the managed blocks"
    marker="$(runuser -u postgres -- "${PG_BIN}/psql" -p 5433 -tA -c 'SELECT v FROM operator_marker;' 2>/dev/null)"
    [[ "${marker}" == "keep-me" ]] \
        && pass "RH-BROWNFIELD: operator data intact after restore" \
        || fail "RH-BROWNFIELD: operator data lost by restore"

    runuser -u postgres -- "${PG_BIN}/pg_ctl" -D "${RHEL_DATA_DIR}" -m fast stop > /dev/null 2>&1 || true
}

# ── RH-HYGIENE: RPM scriptlet lifecycle + erase residue ────────────────
scenario_rpm_hygiene() {
    reset_install_state
    log "Reinstalling every RPM (exercises %pre/%post upgrade scriptlets)"
    if rpm -Uvh --replacepkgs /tmp/documentdb-common.rpm /tmp/documentdb-postgresql-tools.rpm \
            /tmp/documentdb-gateway.rpm /tmp/documentdb-standalone.rpm \
            > /tmp/rh-reinstall.log 2>&1; then
        pass "RH-HYGIENE: RPM reinstall/upgrade transaction succeeded"
    else
        tail -25 /tmp/rh-reinstall.log >&2
        fail "RH-HYGIENE: RPM reinstall/upgrade failed"
    fi
    for cmd in documentdb-setup documentdb-tune documentdb-register-gateway \
               documentdb-gateway-admin documentdb-local-reset; do
        command -v "${cmd}" >/dev/null 2>&1 \
            || fail "RH-HYGIENE: ${cmd} missing after reinstall"
    done
    pass "RH-HYGIENE: all commands present after reinstall"

    log "Erasing every DocumentDB RPM"
    # Per-major names must track ${PG_MAJOR}: the list previously hardcoded
    # documentdb-18, so on any other major the stand-alone package was never
    # added and `rpm -e` aborted on its unsatisfied dependency — turning every
    # residue assertion below into a false failure that looked like an RPM
    # scriptlet bug. Mirrors the DEB list at e2e-package-hygiene.sh, including
    # the bare `documentdb` meta package.
    local erase_list=()
    for p in documentdb "documentdb-${PG_MAJOR}" documentdb-common \
             documentdb-postgresql-tools documentdb-gateway \
             "postgresql${PG_MAJOR}-documentdb"; do
        rpm -q "${p}" >/dev/null 2>&1 && erase_list+=("${p}")
    done
    if (( ${#erase_list[@]} == 0 )); then
        # Deliberately NOT an early return: the private-key, gateway-user and
        # binary residue audits below are independent of this transaction and
        # must still run. Returning here would silently drop three assertions
        # from the suite — the coverage-loss pattern this file is being fixed
        # for elsewhere.
        fail "RH-HYGIENE: no DocumentDB RPMs are installed; nothing to erase"
    else
        log "Erasing: ${erase_list[*]}"
        if rpm -e "${erase_list[@]}" > /tmp/rh-erase.log 2>&1; then
            pass "RH-HYGIENE: erase transaction succeeded"
        else
            tail -25 /tmp/rh-erase.log >&2
            fail "RH-HYGIENE: erase failed"
        fi
    fi

    local leftover_keys
    leftover_keys="$(find /var/lib /etc -name 'pkey.pem' -o -name '*.key' 2>/dev/null | grep -i documentdb || true)"
    [[ -z "${leftover_keys}" ]] \
        && pass "RH-HYGIENE: no DocumentDB private key survived the erase" \
        || { echo "${leftover_keys}" >&2; fail "RH-HYGIENE: private key survived the erase"; }

    id -u documentdb-gateway >/dev/null 2>&1 \
        && fail "RH-HYGIENE: documentdb-gateway user survived the erase" \
        || pass "RH-HYGIENE: documentdb-gateway user removed"

    # bash caches command paths; drop the cache and test the filesystem.
    hash -r
    local residue=()
    for cmd in documentdb-setup documentdb-gateway documentdb-tune \
               documentdb-register-gateway documentdb-gateway-admin \
               documentdb-local-reset; do
        if [[ "${cmd}" == "documentdb-setup" && -n "${E2E_SETUP_OVERRIDE:-}" ]]; then
            # The harness overwrote this path with its own copy, so its
            # contents can no longer distinguish "rpm left the file behind"
            # from "the harness copy is still here". Previously this branch
            # `rm -f`'d the file and continued, which DELETED the very residue
            # being audited and let the loop report success for a command it
            # never checked. Report it as an explicit skip instead, and use
            # rpm's own ownership record — which the override does not alter —
            # as the real signal.
            if rpm -qf /usr/bin/documentdb-setup >/dev/null 2>&1; then
                residue+=("/usr/bin/documentdb-setup(still rpm-owned)")
            else
                skip "RH-HYGIENE: /usr/bin/documentdb-setup not audited (E2E_SETUP_OVERRIDE wrote a harness copy over the packaged path); the other bindirs are still checked"
            fi
            # Drop ONLY the harness copy at the overridden path, then fall
            # through to the normal sweep — do not `continue`. The override
            # affects /usr/bin alone, so a scriptlet regression that left
            # documentdb-setup in /usr/local/bin, /usr/sbin or /sbin must
            # still be caught; the previous `continue` skipped all of them.
            rm -f /usr/bin/documentdb-setup
        fi
        for bindir in /usr/bin /usr/local/bin /bin /usr/sbin /sbin; do
            [[ -e "${bindir}/${cmd}" ]] || continue
            # Resolve before recording: /bin -> /usr/bin and /sbin ->
            # /usr/sbin on usr-merged RHEL 9, so the same inode would
            # otherwise be listed twice and one leftover binary would read as
            # two independent packaging defects.
            residue+=("$(readlink -f "${bindir}/${cmd}" 2>/dev/null || echo "${bindir}/${cmd}")")
        done
    done
    if (( ${#residue[@]} > 0 )); then
        mapfile -t residue < <(printf '%s\n' "${residue[@]}" | sort -u)
    fi
    (( ${#residue[@]} == 0 )) \
        && pass "RH-HYGIENE: all DocumentDB binaries removed by erase" \
        || fail "RH-HYGIENE: binaries survived the erase: ${residue[*]}"
}

scenario_readonly_dryrun
scenario_conflicts
scenario_tune_rhel_layout
scenario_greenfield_portkeep
scenario_scoped_restore
scenario_brownfield_rhel
scenario_rpm_hygiene

echo ""
echo "══════════════════════════════════════════"
echo " e2e-rhel: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
if (( SKIP_COUNT > 0 )); then
    echo " skipped: ${SKIPPED_IDS[*]}"
fi
if (( FAIL_COUNT > 0 )); then
    echo " failed: ${FAILED_IDS[*]}"
    exit 1
fi
echo " ALL RHEL SCENARIOS PASSED"
