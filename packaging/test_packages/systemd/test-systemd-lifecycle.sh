#!/bin/bash
# Systemd lifecycle E2E for the DocumentDB stand-alone packages.
#
# Runs INSIDE the systemd container (see Dockerfile-systemd-deb-test) as root,
# one stage per invocation so the host driver can `docker restart` between
# stages to simulate a reboot. Stages are ordered and stateful:
#
#   install      apt-install the four packages from /opt/documentdb-pkgs
#   setup        Workflow C greenfield `documentdb-setup`, then assert that the
#                wizard left systemd in the state packaging-design.md promises
#   verify       services active, port listening, mongosh CRUD round-trip
#   restart      `systemctl restart documentdb-local.target` keeps serving
#   stopstart    stop really stops (port gone), start brings it back
#   post-reboot  THE point of this suite: after a cold boot, with nothing run
#                by hand, the whole stack must come back on its own
#   day2         create/list/reset/drop users through documentdb-gateway-admin
#   restore      `documentdb-setup --restore` detaches; PG data survives
#
# Every assertion prints PASS/FAIL with context; the stage exits non-zero on the
# first failure so the driver can stop and surface the log.
set -uo pipefail

PG_MAJOR="${PG_MAJOR:-18}"
GATEWAY_PORT="${GATEWAY_PORT:-10260}"
ADMIN_USER="${ADMIN_USER:-admin}"
# Runtime-generated default so no credential literal lives in source (CredScan).
ADMIN_PASSWORD="${ADMIN_PASSWORD:-$(openssl rand -hex 12)Aa1!}"
PW_FILE="/root/.documentdb-admin-pw"
STATE_DIR="/var/lib/documentdb-e2e"
PASS_COUNT=0
FAIL_COUNT=0

mkdir -p "${STATE_DIR}"

log()  { echo "[systemd-e2e] $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo "[systemd-e2e] PASS: $*"; }
fail() {
    FAIL_COUNT=$((FAIL_COUNT + 1))
    echo "[systemd-e2e] FAIL: $*" >&2
    echo "--- diagnostics ---" >&2
    systemctl --no-pager --failed 2>&1 | head -20 >&2
    systemctl --no-pager status "documentdb-local@${PG_MAJOR}.target" 2>&1 | head -20 >&2
    systemctl --no-pager status "documentdb-postgresql@${PG_MAJOR}.service" 2>&1 | head -25 >&2
    systemctl --no-pager status "documentdb-gateway-local@${PG_MAJOR}.service" 2>&1 | head -25 >&2
    journalctl -n 60 --no-pager -u "documentdb-gateway-local@${PG_MAJOR}.service" 2>&1 | tail -40 >&2
    exit 1
}

assert_active() {
    local unit="$1"
    local state
    state="$(systemctl is-active "${unit}" 2>&1)"
    [[ "${state}" == "active" ]] || fail "${unit} is '${state}', expected active"
    pass "${unit} is active"
}

assert_enabled() {
    local unit="$1"
    local state
    state="$(systemctl is-enabled "${unit}" 2>&1)"
    case "${state}" in
        enabled|enabled-runtime|static|indirect|alias)
            pass "${unit} is enabled at boot (${state})" ;;
        *)
            fail "${unit} is '${state}', expected enabled at boot" ;;
    esac
}

# The wizard enables the PUBLIC ALIAS documentdb-local.target when the major
# matches the meta package's default (18), and documentdb-local@N.target
# otherwise. Accept whichever one this host is supposed to use, but require
# that at least one of them is enabled -- that symlink is what makes the stack
# come back after a reboot.
assert_documentdb_target_enabled() {
    local alias_state per_major_state
    alias_state="$(systemctl is-enabled documentdb-local.target 2>&1)"
    per_major_state="$(systemctl is-enabled "documentdb-local@${PG_MAJOR}.target" 2>&1)"
    log "target enablement: documentdb-local.target=${alias_state} documentdb-local@${PG_MAJOR}.target=${per_major_state}"
    case "${alias_state}${per_major_state}" in
        *enabled*) pass "a documentdb-local target is enabled at boot" ;;
        *) fail "neither documentdb-local.target (${alias_state}) nor documentdb-local@${PG_MAJOR}.target (${per_major_state}) is enabled; the stack will not return after a reboot" ;;
    esac
}

# Whichever target this host uses for day-2 verbs.
active_target_name() {
    if systemctl is-enabled documentdb-local.target >/dev/null 2>&1; then
        echo "documentdb-local.target"
    else
        echo "documentdb-local@${PG_MAJOR}.target"
    fi
}

assert_port_listening() {
    local port="$1"
    local what="$2"
    for _ in $(seq 1 30); do
        if ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port}"; then
            pass "${what}: port ${port} is listening"
            return 0
        fi
        sleep 1
    done
    fail "${what}: nothing is listening on port ${port} after 30s"
}

assert_port_closed() {
    local port="$1"
    local what="$2"
    for _ in $(seq 1 20); do
        ss -ltn "sport = :${port}" 2>/dev/null | grep -q ":${port}" || {
            pass "${what}: port ${port} is closed"
            return 0
        }
        sleep 1
    done
    fail "${what}: port ${port} is still listening when it should be closed"
}

# Connect via a mongosh JS bootstrap that assembles the URI from environment
# variables (same CredScan-clean pattern as create_mongosh_wrapper_script in
# test-gateway-install-entrypoint.sh): credentials never appear in shell
# source, argv, or any mongodb:// literal.
MONGO_CONNECT_JS="/tmp/documentdb-systemd-e2e-connect.js"
write_mongo_connect_js() {
    # Operations are load()ed from a file — NOT eval()'d from an env
    # string — because mongosh's async auto-await rewrite applies to
    # load()ed scripts only; in an eval string, db.runCommand() yields an
    # unresolved proxy and JSON.stringify() of it is "{}".
    cat > "${MONGO_CONNECT_JS}" <<'EOF'
const host = process.env.DOCUMENTDB_HOST || '127.0.0.1';
const port = process.env.DOCUMENTDB_PORT;
const username = process.env.DOCUMENTDB_USERNAME;
const password = process.env.DOCUMENTDB_PASSWORD;
const uri = `mongodb://${encodeURIComponent(username)}:${encodeURIComponent(password)}@${host}:${port}/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true`;
db = connect(uri);
load(process.env.DOCUMENTDB_OP_FILE);
EOF
}

# Run mongosh statements (which must print their own output) as
# USER/PASSWORD; echoes output. Retries briefly because the gateway may
# still be finishing startup right after a boot.
mongo_eval_as() {
    local user="$1" password="$2" script="$3"
    local out="" attempt=0
    local op_file
    op_file="$(mktemp /tmp/documentdb-systemd-e2e-op.XXXXXX.js)"
    printf '%s\n' "${script}" > "${op_file}"
    write_mongo_connect_js
    while (( attempt < 15 )); do
        if out="$(DOCUMENTDB_PORT="${GATEWAY_PORT}" \
                  DOCUMENTDB_USERNAME="${user}" \
                  DOCUMENTDB_PASSWORD="${password}" \
                  DOCUMENTDB_OP_FILE="${op_file}" \
                  mongosh --nodb --quiet "${MONGO_CONNECT_JS}" 2>&1)"; then
            rm -f "${op_file}"
            printf '%s' "${out}"
            return 0
        fi
        attempt=$((attempt + 1))
        sleep 2
    done
    rm -f "${op_file}"
    printf '%s' "${out}"
    return 1
}

mongo_eval() {
    mongo_eval_as "${ADMIN_USER}" "${ADMIN_PASSWORD}" "$1"
}

# Single connection attempt (no retry) — for negative tests that EXPECT
# authentication to fail fast.
mongo_try_once_as() {
    local user="$1" password="$2" script="$3"
    local op_file rc
    op_file="$(mktemp /tmp/documentdb-systemd-e2e-op.XXXXXX.js)"
    printf '%s\n' "${script}" > "${op_file}"
    write_mongo_connect_js
    DOCUMENTDB_PORT="${GATEWAY_PORT}" \
    DOCUMENTDB_USERNAME="${user}" \
    DOCUMENTDB_PASSWORD="${password}" \
    DOCUMENTDB_OP_FILE="${op_file}" \
        mongosh --nodb --quiet "${MONGO_CONNECT_JS}" >/dev/null 2>&1
    rc=$?
    rm -f "${op_file}"
    return "${rc}"
}

# Expand the staged .deb glob into STAGED_DEBS, failing when it is empty.
# Never hand the glob to `ls`: with zero surviving arguments `apt-get install`
# installs nothing and exits 0, so an unstaged /opt/documentdb-pkgs reported a
# successful install and every later stage asserted against a bare host. Same
# hazard the driver documents at run-systemd-e2e.sh:58-70.
STAGED_DEBS=()
collect_staged_debs() {
    shopt -s nullglob
    STAGED_DEBS=( /opt/documentdb-pkgs/*.deb )
    shopt -u nullglob
    (( ${#STAGED_DEBS[@]} > 0 ))
}

# ── Stages ──────────────────────────────────────────────────────────

stage_install() {
    log "Installing DocumentDB packages from /opt/documentdb-pkgs"
    collect_staged_debs \
        || fail "no .deb packages staged in /opt/documentdb-pkgs; nothing to install"
    apt-get update -qq
    # Install every staged .deb in one transaction so apt resolves the
    # inter-package dependencies (meta -> standalone -> gateway/tools/common)
    # and pulls postgresql-N from PGDG the way a user's `apt install` would.
    if ! apt-get install -y -o Dpkg::Use-Pty=0 "${STAGED_DEBS[@]}" > "${STATE_DIR}/install.log" 2>&1; then
        tail -40 "${STATE_DIR}/install.log" >&2
        fail "package installation failed"
    fi
    pass "packages installed"

    for cmd in documentdb-setup documentdb-register-gateway documentdb-gateway-admin documentdb-tune documentdb-gateway; do
        command -v "${cmd}" >/dev/null 2>&1 || fail "${cmd} is not on PATH after install"
    done
    pass "all expected commands are on PATH"

    # Unit files must be installed and parseable by the real systemd.
    #
    # Gate on systemd-analyze's EXIT STATUS, not on grepping its output for
    # "error"/"failed". Its diagnostics routinely contain neither word —
    # "Unknown key name 'X' in section 'Service', ignoring" or
    # "Command /usr/bin/documentdb-gateway is not executable: No such file or
    # directory" — so a unit referencing a dropped binary passed the old check.
    # Verify EVERY unit this suite depends on, too: the previous version checked
    # one non-template unit and claimed "shipped units parse cleanly" for all.
    # NOTE: fail() in this file calls exit 1, so the first offending unit ends
    # the suite — there is no point accumulating state across the loop.
    #
    # Only the on-disk unit FILES are verified here, and templates are verified
    # uninstantiated. stage_install runs before stage_setup, so the per-major
    # runtime directories a template's WorkingDirectory refers to
    # (/var/lib/documentdb-local/<major>/gateway) do not exist yet; verifying an
    # INSTANTIATED template name at this point can fail on that missing path and
    # abort the whole reboot-lifecycle suite over a package set that is fine.
    local unit_file analyze_out analyze_rc
    for unit_file in "documentdb-gateway.service" \
                     "documentdb-postgresql@.service" \
                     "documentdb-gateway-local@.service" \
                     "documentdb-local@.target"; do
        if [[ ! -e "/usr/lib/systemd/system/${unit_file}" ]]; then
            fail "unit file missing after install: /usr/lib/systemd/system/${unit_file}"
        fi
        analyze_out="$(systemd-analyze verify "/usr/lib/systemd/system/${unit_file}" 2>&1)"
        analyze_rc=$?
        if (( analyze_rc != 0 )); then
            echo "${analyze_out}" | head -15 >&2
            fail "${unit_file} fails systemd-analyze verify (rc=${analyze_rc})"
        fi
    done
    pass "all shipped units parse cleanly"
}

stage_setup() {
    log "Running Workflow C greenfield setup (documentdb-setup)"
    printf '%s' "${ADMIN_PASSWORD}" > "${PW_FILE}"
    chmod 0600 "${PW_FILE}"

    if ! documentdb-setup \
            --admin-user "${ADMIN_USER}" \
            --admin-password-file "${PW_FILE}" \
            --pg-version "${PG_MAJOR}" \
            --yes --skip-init-data --verbose > "${STATE_DIR}/setup.log" 2>&1; then
        tail -60 "${STATE_DIR}/setup.log" >&2
        fail "documentdb-setup failed"
    fi
    pass "documentdb-setup completed"

    grep -Fq "SUCCESS: DocumentDB is ready." "${STATE_DIR}/setup.log" \
        || fail "setup did not report readiness"
    pass "setup reported readiness"

    # The wizard must not leak the password it was handed.
    if grep -Fq "${ADMIN_PASSWORD}" "${STATE_DIR}/setup.log"; then
        fail "setup leaked the admin password into its own output"
    fi
    pass "setup did not leak the admin password"

    # packaging-design.md: after setup returns, the target is enabled at boot
    # and the stack is running -- no second command.
    assert_documentdb_target_enabled
    assert_active  "$(active_target_name)"
    assert_active  "documentdb-postgresql@${PG_MAJOR}.service"
    assert_active  "documentdb-gateway-local@${PG_MAJOR}.service"
}

stage_verify() {
    log "Verifying the running stack serves the wire protocol"
    assert_active "documentdb-gateway-local@${PG_MAJOR}.service"
    assert_port_listening "${GATEWAY_PORT}" "gateway"

    local out
    out="$(mongo_eval 'print(JSON.stringify(db.runCommand({ping: 1})));')" \
        || fail "mongosh could not reach the gateway: ${out}"
    grep -q '"ok":1' <<<"${out}" || fail "ping did not return ok:1 (got: ${out})"
    pass "mongosh ping round-tripped"

    # A real CRUD cycle, not just a ping: this exercises the extension through
    # the gateway the way an application would.
    out="$(mongo_eval '
        const c = db.getSiblingDB("e2e").items;
        c.insertOne({_id: "k1", n: 1, tag: "systemd"});
        c.updateOne({_id: "k1"}, {$set: {n: 42}});
        const found = c.findOne({_id: "k1"});
        const del = c.deleteOne({_id: "k1"});
        print(JSON.stringify({n: found.n, tag: found.tag, deleted: del.deletedCount}));
    ')" || fail "CRUD failed: ${out}"
    grep -q '"n":42' <<<"${out}" || fail "update did not persist (got: ${out})"
    grep -q '"deleted":1' <<<"${out}" || fail "delete did not remove the doc (got: ${out})"
    pass "CRUD insert/update/find/delete round-tripped"
}

# Write a document that later stages (notably post-reboot) read back, proving
# data survived, not just that the service restarted.
stage_seed_data() {
    log "Seeding a durable document for the reboot check"
    local out
    out="$(mongo_eval '
        const c = db.getSiblingDB("e2e").durable;
        c.deleteMany({});
        c.insertOne({_id: "survives-reboot", value: "hello-from-before-reboot"});
        print(JSON.stringify({count: c.countDocuments({})}));
    ')" || fail "could not seed durable data: ${out}"
    grep -q '"count":1' <<<"${out}" || fail "seed did not persist (got: ${out})"
    pass "durable document written"
}

stage_restart() {
    log "systemctl restart documentdb-local@${PG_MAJOR}.target"
    systemctl restart "documentdb-local@${PG_MAJOR}.target" \
        || fail "restart of the target failed"
    sleep 3
    assert_active "documentdb-postgresql@${PG_MAJOR}.service"
    assert_active "documentdb-gateway-local@${PG_MAJOR}.service"
    assert_port_listening "${GATEWAY_PORT}" "gateway after restart"
    local out
    out="$(mongo_eval 'print(JSON.stringify(db.runCommand({ping: 1})));')" \
        || fail "gateway unreachable after target restart: ${out}"
    grep -q '"ok":1' <<<"${out}" || fail "ping failed after restart (got: ${out})"
    pass "stack still serves after target restart"
}

stage_stopstart() {
    local target; target="$(active_target_name)"
    log "systemctl stop/start ${target}"
    systemctl stop "${target}" || fail "stop failed"
    sleep 2
    assert_port_closed "${GATEWAY_PORT}" "gateway after stop"

    systemctl start "${target}" || fail "start failed"
    sleep 3
    assert_active "documentdb-gateway-local@${PG_MAJOR}.service"
    assert_port_listening "${GATEWAY_PORT}" "gateway after start"
    pass "stop/start cycle works"
}

stage_post_reboot() {
    log "Post-reboot verification (nothing was run by hand after boot)"
    # Give systemd a moment to finish the boot transaction.
    for _ in $(seq 1 30); do
        [[ "$(systemctl is-system-running 2>&1)" =~ running|degraded ]] && break
        sleep 2
    done
    log "system state: $(systemctl is-system-running 2>&1)"

    assert_documentdb_target_enabled
    assert_active  "documentdb-postgresql@${PG_MAJOR}.service"
    assert_active  "documentdb-gateway-local@${PG_MAJOR}.service"
    assert_port_listening "${GATEWAY_PORT}" "gateway after reboot"

    local out
    out="$(mongo_eval '
        const c = db.getSiblingDB("e2e").durable;
        const d = c.findOne({_id: "survives-reboot"});
        print(JSON.stringify({value: d ? d.value : null}));
    ')" || fail "gateway unreachable after reboot: ${out}"
    grep -q 'hello-from-before-reboot' <<<"${out}" \
        || fail "data written before the reboot did not survive (got: ${out})"
    pass "data written before the reboot survived it"
}

stage_day2() {
    log "Day-2 user management via documentdb-gateway-admin"
    local pw2="/root/.documentdb-user2-pw"
    printf '%s' "$(openssl rand -hex 12)Aa1!" > "${pw2}"
    chmod 0600 "${pw2}"

    documentdb-gateway-admin create-user --username e2euser --password-file "${pw2}" \
        > "${STATE_DIR}/day2-create.log" 2>&1 \
        || { tail -20 "${STATE_DIR}/day2-create.log" >&2; fail "create-user failed"; }
    pass "create-user succeeded"

    documentdb-gateway-admin list-users > "${STATE_DIR}/day2-list.log" 2>&1 \
        || { tail -20 "${STATE_DIR}/day2-list.log" >&2; fail "list-users failed"; }
    grep -q 'e2euser' "${STATE_DIR}/day2-list.log" \
        || { cat "${STATE_DIR}/day2-list.log" >&2; fail "list-users did not show the new user"; }
    pass "list-users shows the new user"

    # The new user must actually be able to authenticate through the gateway.
    local out
    out="$(mongo_eval_as e2euser "$(cat "${pw2}")" 'print(JSON.stringify(db.runCommand({ping: 1})));')" \
        || fail "new user could not authenticate: ${out}"
    grep -q '"ok":1' <<<"${out}" || fail "new user ping failed (got: ${out})"
    pass "new user authenticates through the gateway"

    documentdb-gateway-admin drop-user --username e2euser --yes \
        > "${STATE_DIR}/day2-drop.log" 2>&1 \
        || { tail -20 "${STATE_DIR}/day2-drop.log" >&2; fail "drop-user failed"; }
    pass "drop-user succeeded"

    # And must no longer authenticate (single attempt: failure is expected).
    if mongo_try_once_as e2euser "$(cat "${pw2}")" 'db.runCommand({ping: 1})'; then
        fail "dropped user can still authenticate"
    fi
    pass "dropped user can no longer authenticate"
    rm -f "${pw2}"
}

stage_bad_password() {
    log "Wrong password must be rejected"
    if mongo_try_once_as "${ADMIN_USER}" 'definitely-the-wrong-password' 'db.runCommand({ping: 1})'; then
        fail "gateway accepted a wrong password"
    fi
    pass "gateway rejected a wrong password"
}

stage_upgrade() {
    log "Package upgrade: reinstalling the same version exercises the upgrade scriptlets"
    # dpkg treats installing over an installed package as an upgrade, so this
    # runs prerm(upgrade)/postinst(configure <old-version>) -- i.e. the
    # restart_active_services_after_upgrade path -- which otherwise only ever
    # runs on a real user's host.
    local gw_pid_before
    gw_pid_before="$(systemctl show -p MainPID --value "documentdb-gateway-local@${PG_MAJOR}.service" 2>/dev/null)"

    collect_staged_debs \
        || fail "no .deb packages staged in /opt/documentdb-pkgs; cannot test the upgrade path"
    if ! apt-get install -y --reinstall -o Dpkg::Use-Pty=0 "${STAGED_DEBS[@]}" \
            > "${STATE_DIR}/upgrade.log" 2>&1; then
        tail -40 "${STATE_DIR}/upgrade.log" >&2
        fail "package upgrade/reinstall failed"
    fi
    pass "packages upgraded (reinstall transaction succeeded)"

    sleep 5
    assert_active "documentdb-postgresql@${PG_MAJOR}.service"
    assert_active "documentdb-gateway-local@${PG_MAJOR}.service"
    assert_port_listening "${GATEWAY_PORT}" "gateway after upgrade"

    local gw_pid_after
    gw_pid_after="$(systemctl show -p MainPID --value "documentdb-gateway-local@${PG_MAJOR}.service" 2>/dev/null)"
    log "gateway MainPID before=${gw_pid_before} after=${gw_pid_after}"
    # The design requires active gateways to be restarted onto the new binary.
    [[ -n "${gw_pid_after}" && "${gw_pid_after}" != "0" ]] \
        || fail "gateway has no MainPID after upgrade"
    [[ "${gw_pid_before}" != "${gw_pid_after}" ]] \
        || fail "gateway was NOT restarted by the upgrade (same PID ${gw_pid_after}); it would keep running the old binary"
    pass "upgrade restarted the active gateway onto the new binary"

    # Config/state must survive the upgrade.
    [[ -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf" ]] \
        || fail "per-major setup.conf did not survive the upgrade"
    pass "per-major state survived the upgrade"

    local out
    out="$(mongo_eval '
        const d = db.getSiblingDB("e2e").durable.findOne({_id: "survives-reboot"});
        print(JSON.stringify({value: d ? d.value : null}));
    ')" || fail "gateway unreachable after upgrade: ${out}"
    grep -q 'hello-from-before-reboot' <<<"${out}" \
        || fail "data did not survive the upgrade (got: ${out})"
    pass "data survived the upgrade"
}

# Round-8 behavior, verified against a REAL systemd rather than a fake
# systemctl: Debian keeps enablement across remove -> reinstall and clears it
# only on purge. A prerm that disabled on remove (or on dpkg's temporary
# "deconfigure") silently stopped the gateway from coming up at boot.
stage_enablement() {
    local unit="documentdb-gateway.service"
    local link="/etc/systemd/system/multi-user.target.wants/${unit}"

    log "Enablement lifecycle for ${unit} (round-8 contract)"
    systemctl enable "${unit}" >/dev/null 2>&1 || fail "could not enable ${unit}"
    [[ -L "${link}" ]] || fail "enable did not create ${link}"
    pass "operator-enabled ${unit} (symlink present)"

    apt-get remove -y -o Dpkg::Use-Pty=0 documentdb-gateway \
        > "${STATE_DIR}/gw-remove.log" 2>&1 \
        || { tail -30 "${STATE_DIR}/gw-remove.log" >&2; fail "apt remove documentdb-gateway failed"; }

    # Debian policy: enablement survives a remove so a later reinstall keeps
    # the operator's choice.
    [[ -L "${link}" ]] \
        || fail "'apt remove' cleared the boot-enablement symlink; it must survive removal and be cleared only on purge"
    pass "enablement survived 'apt remove' (as Debian policy requires)"

    apt-get purge -y -o Dpkg::Use-Pty=0 documentdb-gateway \
        > "${STATE_DIR}/gw-purge.log" 2>&1 \
        || { tail -30 "${STATE_DIR}/gw-purge.log" >&2; fail "apt purge documentdb-gateway failed"; }

    [[ -e "${link}" || -L "${link}" ]] \
        && fail "'apt purge' left a dangling enablement symlink at ${link} (systemd logs 'Failed to load unit' on every boot)"
    pass "purge cleared the enablement symlink"
}

stage_restore() {
    log "documentdb-setup --restore detaches the integration"
    local data_dir="/var/lib/documentdb-local/${PG_MAJOR}/data"
    [[ -f "${data_dir}/PG_VERSION" ]] || fail "expected data dir ${data_dir} before restore"

    if ! documentdb-setup --restore --pg-version "${PG_MAJOR}" --yes \
            > "${STATE_DIR}/restore.log" 2>&1; then
        tail -40 "${STATE_DIR}/restore.log" >&2
        fail "documentdb-setup --restore failed"
    fi
    pass "restore completed"

    # Non-destructive: PostgreSQL data must survive a restore.
    [[ -f "${data_dir}/PG_VERSION" ]] \
        || fail "restore deleted the PostgreSQL data directory (it must be non-destructive)"
    pass "PostgreSQL data directory survived restore"
}

main() {
    local stage="${1:-}"
    case "${stage}" in
        install)      stage_install ;;
        setup)        stage_setup ;;
        verify)       stage_verify ;;
        seed)         stage_seed_data ;;
        restart)      stage_restart ;;
        stopstart)    stage_stopstart ;;
        post-reboot)  stage_post_reboot ;;
        day2)         stage_day2 ;;
        bad-password) stage_bad_password ;;
        upgrade)      stage_upgrade ;;
        enablement)   stage_enablement ;;
        restore)      stage_restore ;;
        *)
            echo "usage: $0 <install|setup|verify|seed|restart|stopstart|post-reboot|day2|bad-password|upgrade|enablement|restore>" >&2
            exit 2 ;;
    esac
    log "stage '${stage}': ${PASS_COUNT} passed, ${FAIL_COUNT} failed"
    (( FAIL_COUNT == 0 )) || exit 1
}

main "$@"
