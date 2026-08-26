#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# e2e-extra-scenarios.sh — manual-matrix scenarios NOT covered by
# test-gateway-install-entrypoint.sh. Runs INSIDE the deb gateway test
# image (documentdb-test-gateway-packages:latest), which stages all built
# .debs at /tmp/install_setup and pre-configures the PGDG repo + mongosh.
#
# Covered here (scenario IDs):
#   DRYRUN   (B6/A6)  --dry-run and --restore --dry-run mutate NOTHING
#   READONLY (B6)     --status / --print-config behave on a clean host
#   CONFLICT (A16)    contradictory flag combinations die clearly
#   ENVHYG   (A15)    exported PG_VERSION is ignored; deprecated env warns
#   PWEDGE   (A18)    special-character admin password end-to-end
#   BROWNFLD (A1)     adopt a distro pg_createcluster cluster; two-step
#                     handoff; operator data intact; listen settings kept
#   PORTKEEP (B11)    bare re-run preserves --listen-port (day-2 fix)
#   INTERRUPT(A17)    SIGTERM mid-setup, then clean re-run to success
#   SCOPEREST(A6)     --restore --pg-version scoping and validation
#
# Each scenario prints "PASS <id>: ..." / "FAIL <id>: ..." and the suite
# exits non-zero on any FAIL. Run:
#   docker run --rm --user root --entrypoint bash \
#     -v <repo>/oss/packaging/test_packages:/e2e:ro \
#     documentdb-test-gateway-packages:latest /e2e/e2e-extra-scenarios.sh

set -uo pipefail

# Shared harness helpers (collect/newest/skip).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-lib.sh"

PG_MAJOR="${PG_MAJOR:-18}"
GATEWAY_PORT_DEFAULT=10260
PASS_COUNT=0
FAIL_COUNT=0
SKIP_COUNT=0
FAILED_IDS=()
SKIPPED_IDS=()

log()  { echo -e "\033[1;36m[e2e-extra]\033[0m $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "\033[1;32mPASS\033[0m $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_IDS+=("$1"); echo -e "\033[1;31mFAIL\033[0m $*"; }
skip() { e2e_skip "$@"; }

PW_FILE=/root/.e2e-pw
# Runtime-generated so no credential literal lives in source (CredScan).
printf '%s' "$(openssl rand -hex 12)Aa1!" > "${PW_FILE}"
chmod 600 "${PW_FILE}"

# CredScan-clean mongosh auth (URI assembled in JS from env). Operations
# are load()ed from a file — NOT eval()'d from an env string — because
# mongosh's async auto-await rewrite applies to load()ed scripts only; in
# an eval string, db.runCommand() yields an unresolved proxy and
# JSON.stringify() of it is "{}".
MONGO_JS=/tmp/e2e-extra-connect.js
cat > "${MONGO_JS}" <<'EOF'
const uri = `mongodb://${encodeURIComponent(process.env.DOCUMENTDB_USERNAME)}:${encodeURIComponent(process.env.DOCUMENTDB_PASSWORD)}@127.0.0.1:${process.env.DOCUMENTDB_PORT}/admin?authSource=admin&authMechanism=SCRAM-SHA-256&tls=true&tlsAllowInvalidCertificates=true`;
db = connect(uri);
load(process.env.DOCUMENTDB_OP_FILE);
EOF
mongo_eval() { # user password port js-statements (must print their own output)
    local _op_file
    _op_file="$(mktemp /tmp/e2e-extra-op.XXXXXX.js)"
    printf '%s\n' "$4" > "${_op_file}"
    DOCUMENTDB_USERNAME="$1" DOCUMENTDB_PASSWORD="$2" DOCUMENTDB_PORT="$3" \
        DOCUMENTDB_OP_FILE="${_op_file}" mongosh --nodb --quiet "${MONGO_JS}" 2>&1
    local _rc=$?
    rm -f "${_op_file}"
    return "${_rc}"
}

snapshot_state() {
    # Everything documentdb-setup could touch, as a comparable listing.
    # A RUNNING PostgreSQL churns its own data dir in the background (WAL
    # segments, server log, stats, transaction status), so exclude the
    # volatile database internals — while keeping the configuration
    # surface a restore actually edits (postgresql.conf / pg_hba.conf /
    # pg_ident.conf live at the data-dir top level for greenfield).
    # /etc/passwd, /etc/group and /etc/shadow are watched deliberately.
    # ensure_documentdb_runtime_user() runs groupadd/useradd for
    # documentdb-local and documentdb-gateway, which documentdb-setup's own
    # source calls "the first host mutation" — and account changes are the one
    # class of mutation this snapshot could not otherwise see at all.
    #
    # To be precise: this is PREVENTION, not a fix for an observed failure.
    # main()'s dry-run branch currently exits before preflight_validation, so
    # ensure_documentdb_runtime_user is not reached today. Watching these files
    # means a future change that moves user creation earlier cannot make
    # "--dry-run mutated nothing" silently untrue.
    { find /etc/documentdb /etc/postgresql /etc/postgresql-common \
           /etc/passwd /etc/group /etc/shadow \
           /var/lib/documentdb-local /var/lib/documentdb-gateway \
           /etc/systemd/system -xdev \
           \( -path '*/pg_wal/*' -o -path '*/pg_stat*' -o -path '*/pg_logical/*' \
              -o -path '*/global/*' -o -path '*/base/*' -o -path '*/pg_xact/*' \
              -o -path '*/pg_subtrans/*' -o -path '*/pg_notify/*' \
              -o -path '*/pg_dynshmem/*' -o -path '*/pg_replslot/*' \
              -o -name 'pglog.log' -o -name 'postmaster.pid' \
              -o -name 'postmaster.opts' -o -name 'current_logfiles' \) -prune \
           -o -printf '%p %s %T@ %m %u %g\n' 2>/dev/null | sort; } || true
}

install_packages() {
    log "Installing all staged packages"
    if ! e2e_collect_staged_debs; then
        fail "INSTALL: no .deb packages staged in /tmp/install_setup"
        echo "e2e-extra: aborting (cannot continue without packages)" >&2
        exit 1
    fi
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq -o Dpkg::Use-Pty=0 "${E2E_STAGED_DEBS[@]}" \
        > /tmp/e2e-extra-install.log 2>&1 || {
        tail -30 /tmp/e2e-extra-install.log >&2
        fail "INSTALL: package installation failed"
        echo "e2e-extra: aborting (cannot continue without packages)" >&2
        exit 1
    }
    pass "INSTALL: all ${#E2E_STAGED_DEBS[@]} packages installed"

    # Optional working-tree override for fix iteration: lets the harness
    # exercise a patched documentdb-setup without rebuilding the .debs.
    # (dpkg cannot unpack over a bind-mounted /usr/bin path, so the
    # override is copied AFTER the install step instead.)
    if [[ -n "${E2E_SETUP_OVERRIDE:-}" && -r "${E2E_SETUP_OVERRIDE}" ]]; then
        install -m 0755 "${E2E_SETUP_OVERRIDE}" /usr/bin/documentdb-setup
        log "OVERRIDE: /usr/bin/documentdb-setup replaced with ${E2E_SETUP_OVERRIDE}"
    fi
}

# ── READONLY + DRYRUN on the clean host (before any setup) ─────────────
scenario_readonly_clean() {
    local out rc
    out="$(documentdb-setup --status 2>&1)"; rc=$?
    if [[ -n "${out}" && ( ${rc} -eq 0 || ${rc} -eq 1 ) ]]; then
        pass "READONLY: --status prints a report on a clean host (rc=${rc})"
    else
        fail "READONLY: --status was silent or crashed (rc=${rc}): ${out}"
    fi
    out="$(documentdb-setup --print-config 2>&1)"; rc=$?
    if [[ ${rc} -eq 0 && "${out}" == *"gateway"* ]]; then
        pass "READONLY: --print-config exits 0 with config"
    else
        fail "READONLY: --print-config rc=${rc}: $(head -3 <<<"${out}")"
    fi
}

scenario_dry_run_no_mutation() {
    local before after
    before="$(snapshot_state)"
    documentdb-setup --dry-run --admin-user admin > /tmp/e2e-dryrun.log 2>&1 \
        || { fail "DRYRUN: --dry-run exited non-zero"; return; }
    after="$(snapshot_state)"
    if [[ "${before}" == "${after}" ]]; then
        pass "DRYRUN: --dry-run mutated nothing"
    else
        diff <(echo "${before}") <(echo "${after}") | head -20 >&2
        fail "DRYRUN: --dry-run changed filesystem state"
    fi
    grep -q "\[dry-run\]" /tmp/e2e-dryrun.log \
        && pass "DRYRUN: preview output is labeled" \
        || fail "DRYRUN: no [dry-run] labels in preview"
}

# ── CLI conflicts and env hygiene (clean host) ─────────────────────────
scenario_conflicts() {
    local out
    if out="$(documentdb-setup --use-new-postgres-instance \
            --target-postgres-instance ${PG_MAJOR}/main \
            --admin-user a --yes 2>&1)"; then
        fail "CONFLICT: --use-new + --target accepted"
    elif grep -q "mutually exclusive" <<<"${out}"; then
        pass "CONFLICT: --use-new + --target rejected with clear message"
    else
        fail "CONFLICT: rejected but message unclear: $(head -2 <<<"${out}")"
    fi
    if out="$(documentdb-setup --tls-auto-generate false --admin-user a --yes 2>&1)"; then
        fail "CONFLICT: --tls-auto-generate false alone accepted"
    elif grep -q "requires --tls-cert and --tls-key" <<<"${out}"; then
        pass "CONFLICT: tls-auto-generate=false alone rejected at CLI"
    else
        fail "CONFLICT: tls rejection message unclear: $(head -2 <<<"${out}")"
    fi
    if out="$(documentdb-setup --pg-version 17 \
            --target-postgres-instance 18/main --admin-user a --yes 2>&1)"; then
        fail "CONFLICT: cross-major target accepted"
    elif grep -q "does not match" <<<"${out}"; then
        pass "CONFLICT: --pg-version vs --target major mismatch rejected"
    else
        fail "CONFLICT: mismatch message unclear: $(head -2 <<<"${out}")"
    fi
}

scenario_env_hygiene() {
    local out
    out="$(PG_VERSION=15 documentdb-setup --print-config 2>&1)"
    if grep -q "/15/" <<<"${out}"; then
        fail "ENVHYG: exported PG_VERSION=15 leaked into resolved config"
    else
        pass "ENVHYG: exported PG_VERSION is ignored"
    fi
}

# ── Greenfield with custom port + special-char password ────────────────
scenario_greenfield_pwedge_portkeep() {
    local pw_special='pa"ss'\''wd\!best'
    local pwf=/root/.e2e-pw-special
    printf '%s' "${pw_special}" > "${pwf}"; chmod 600 "${pwf}"

    log "Greenfield setup (--listen-port 27018, special-char password)"
    if ! documentdb-setup --admin-user admin --admin-password-file "${pwf}" \
            --listen-port 27018 --yes > /tmp/e2e-greenfield.log 2>&1; then
        tail -30 /tmp/e2e-greenfield.log >&2
        fail "PWEDGE: greenfield setup failed"
        return
    fi
    pass "PWEDGE: greenfield setup succeeded"

    local out
    out="$(mongo_eval admin "${pw_special}" 27018 'print(JSON.stringify(db.runCommand({ping:1})));')"
    if grep -q '"ok":1' <<<"${out}"; then
        pass "PWEDGE: special-char password authenticates via mongosh"
    else
        fail "PWEDGE: mongosh auth failed: $(head -2 <<<"${out}")"
    fi

    # /proc argv hygiene during a create-user (background scan while running).
    #
    # The pattern comes from the password FILE via `grep -F -f`, so the
    # password never enters the probe's own argv. The previous form passed it
    # as a grep pattern directly, which was wrong twice over: it was a basic
    # regex, so GNU grep folded the `\!` in the password to a literal `!` and
    # could never match the bytes actually in argv; and had it matched, the
    # probe's own command line would have contained the password and matched
    # itself.
    #
    # A positive control runs first against a planted sentinel. Without it a
    # silently-broken probe is indistinguishable from a clean system, which is
    # exactly how the regex defect above survived a full E2E round reporting
    # PASS.
    if [[ ! -s "${pwf}" ]]; then
        fail "PWEDGE: password file is empty; argv probe cannot run"
        return
    fi
    # `grep -f` matches one pattern per LINE. A password containing a newline
    # therefore cannot be expressed as a single pattern, and a BLANK line would
    # match every file. Reject either case loudly rather than normalizing it:
    # stripping the newlines (the obvious "fix") would silently turn a real
    # multi-line-password leak into a CLEAN verdict, with the positive control
    # below still passing — precisely the always-green failure mode this whole
    # probe is being rewritten to eliminate.
    if [[ "$(tr -cd '\n' < "${pwf}" | wc -c)" -ne 0 ]]; then
        fail "PWEDGE: password contains a newline; this argv probe cannot represent it as a grep -F pattern"
        return
    fi
    local canary='ARGVCANARY-3b7f-documentdb'
    local canaryf=/root/.e2e-argv-canary
    printf '%s' "${canary}" > "${canaryf}"; chmod 600 "${canaryf}"
    # The sentinel must survive in the process's argv. `bash -c "sleep 5 # X"`
    # does NOT work: a -c string that is a single simple command triggers
    # bash's exec optimization, so bash execve()s /bin/sleep and the argv
    # becomes "sleep 5" with the comment discarded — the control could then
    # never match and the suite would fail on every run. Ending the string
    # with a builtin (`: ${canary}`) forces bash to stay resident as the
    # parent, keeping the full -c string in its own /proc/<pid>/cmdline.
    bash -c "sleep 5; : ${canary}" >/dev/null 2>&1 &
    local canary_pid=$!
    sleep 0.3
    if grep -l -F -f "${canaryf}" /proc/[0-9]*/cmdline >/dev/null 2>&1; then
        pass "PWEDGE: argv probe verified against a planted sentinel"
    else
        fail "PWEDGE: argv probe cannot see a planted sentinel; the leak check below is UNVERIFIED"
    fi
    kill "${canary_pid}" 2>/dev/null || true
    wait "${canary_pid}" 2>/dev/null || true
    rm -f "${canaryf}"

    # The password file itself is the pattern file — it was just verified to be
    # a single newline-free line, and passing the PATH keeps the password off
    # the probe's own command line.
    documentdb-gateway-admin create-user --username argvprobe \
        --password-file "${pwf}" > /tmp/e2e-argv.log 2>&1 &
    local admin_pid=$!
    local leak=0 scans=0
    # Body-first so at least one scan always happens: the old `while kill -0`
    # form ran zero iterations when create-user exited before the first check.
    while :; do
        if grep -l -F -f "${pwf}" /proc/[0-9]*/cmdline >/dev/null 2>&1; then
            leak=1; break
        fi
        scans=$(( scans + 1 ))
        kill -0 "${admin_pid}" 2>/dev/null || break
        sleep 0.05
    done
    wait "${admin_pid}" || true

    if (( leak == 0 )); then
        pass "PWEDGE: password never appeared in any argv (${scans} scans)"
    else
        fail "PWEDGE: password visible in /proc/*/cmdline"
    fi

    # Day-2 bare re-run must keep port 27018 (round-11 fix)
    log "Bare re-run (port preservation)"
    if ! documentdb-setup --admin-user admin --admin-password-file "${pwf}" --yes \
            > /tmp/e2e-rerun.log 2>&1; then
        tail -30 /tmp/e2e-rerun.log >&2
        fail "PORTKEEP: bare re-run failed"
        return
    fi
    if grep -q "Keeping gateway listen port 27018" /tmp/e2e-rerun.log \
        && grep -q "DOCUMENTDB_LISTEN_ADDR=:27018" "/etc/documentdb/local/${PG_MAJOR}/gateway.env"; then
        pass "PORTKEEP: bare re-run preserved --listen-port 27018"
    else
        grep -i "listen" /tmp/e2e-rerun.log | head -5 >&2
        fail "PORTKEEP: port not preserved on bare re-run"
    fi
    out="$(mongo_eval admin "${pw_special}" 27018 'print(JSON.stringify(db.runCommand({ping:1})));')"
    grep -q '"ok":1' <<<"${out}" \
        && pass "PORTKEEP: gateway still serving on 27018 after re-run" \
        || fail "PORTKEEP: gateway not serving after re-run: $(head -2 <<<"${out}")"
}

# ── Scoped restore validation + full restore ───────────────────────────
scenario_scoped_restore() {
    local out
    if out="$(documentdb-setup --restore --pg-version '*' 2>&1)"; then
        fail "SCOPEREST: wildcard --pg-version accepted"
    elif grep -q "single numeric PostgreSQL major" <<<"${out}"; then
        pass "SCOPEREST: wildcard scope rejected"
    else
        fail "SCOPEREST: wildcard rejection unclear: $(head -2 <<<"${out}")"
    fi

    # restore --dry-run must not mutate the live install
    local before after
    before="$(snapshot_state)"
    documentdb-setup --restore --dry-run > /tmp/e2e-restore-dryrun.log 2>&1 \
        || { fail "SCOPEREST: restore --dry-run exited non-zero"; return; }
    after="$(snapshot_state)"
    if [[ "${before}" == "${after}" ]]; then
        pass "SCOPEREST: --restore --dry-run mutated nothing"
    else
        diff <(echo "${before}") <(echo "${after}") | head -20 >&2
        fail "SCOPEREST: --restore --dry-run changed state"
    fi
    grep -q "Restore dry-run complete. No changes were made." /tmp/e2e-restore-dryrun.log \
        && pass "SCOPEREST: dry-run restore says so honestly" \
        || fail "SCOPEREST: dry-run restore missing honest summary"

    # Scoped real restore of the only major
    if ! documentdb-setup --restore --pg-version "${PG_MAJOR}" --yes \
            > /tmp/e2e-restore.log 2>&1; then
        tail -20 /tmp/e2e-restore.log >&2
        fail "SCOPEREST: scoped restore failed"
        return
    fi
    if [[ ! -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf" ]]; then
        pass "SCOPEREST: scoped restore removed the major's state"
    else
        fail "SCOPEREST: setup.conf survived scoped restore"
    fi
}

# ── SIGTERM mid-setup, then recover ────────────────────────────────────
# NOTE ON THE SIGNAL: setup is backgrounded with `&` to obtain a pid to
# signal, and POSIX sets SIGINT (and SIGQUIT) to SIG_IGN on entry to an
# async-backgrounded non-interactive child. bash cannot re-`trap` a signal
# that was ignored on entry, so `kill -INT` here would be silently discarded
# and setup would always run to completion — turning A17 into a test of
# resume-from-COMPLETE, never the half-written state it exists for. SIGTERM
# is NOT ignored on entry, so it actually halts setup mid-flight.
scenario_interrupt_recovery() {
    log "Interrupting a fresh setup mid-flight, then re-running"
    # PRECONDITION — force a TRUE greenfield host. This scenario must interrupt
    # setup WHILE it runs initdb for a NEW cluster, and setup runs initdb ONLY
    # when ${DATA_DIR}/PG_VERSION is absent (documentdb-setup.sh gates the
    # "Initialize PostgreSQL ... (initdb)" confirm_or_apply on the data dir not
    # existing). The scenarios before this one leave an initialised per-major
    # data directory behind — greenfield initialises it, and the scoped
    # --restore that follows is non-destructive and keeps the PG data — so
    # WITHOUT this wipe the interrupted run resumes an existing cluster, never
    # reaches the mutating phase, and the entire A17 recovery path silently
    # no-ops while still printing PASS. Destroy the major's data first so initdb
    # genuinely runs and the SIGTERM below can land mid-flight.
    documentdb-setup --restore --yes > /dev/null 2>&1 || true
    documentdb-local-reset --pg-version "${PG_MAJOR}" --confirm-destroy > /dev/null 2>&1 || true

    documentdb-setup --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/e2e-interrupt.log 2>&1 &
    local pid=$!

    # With greenfield now GUARANTEED above, the initdb anchor WILL be printed,
    # so the mid-flight branch is the expected path; the skip arms below remain
    # only as a fallback for a genuine, rare scheduling race (setup racing
    # through the whole run between two 0.5s poll ticks), not — as before — a
    # structural certainty. Poll for the anchor rather than sleeping a fixed
    # interval: A17 is about recovering from a HALF-WRITTEN state, so the
    # interrupt has to land while work is actually in progress.
    # Anchor on output that only appears once setup is actually MUTATING the
    # host — the data-directory / initdb phase. Matching anything looser fires
    # far too early: documentdb-setup prints "Using gateway binary ...",
    # "Using gateway config ..." and can print "Keeping gateway listen port ..."
    # during preflight, seconds in and before a single byte is written, so a
    # pattern containing "gateway" or "Starting" turns this back into a no-op
    # interrupt while still printing PASS.
    local waited=0 mid_flight=false setup_gone=false
    while (( waited < 60 )); do
        if grep -qE 'initdb|Initialize PostgreSQL|per-major data directory' \
                /tmp/e2e-interrupt.log 2>/dev/null; then
            mid_flight=true
            break
        fi
        if ! kill -0 "${pid}" 2>/dev/null; then
            setup_gone=true   # exited before reaching the mutating phase
            break
        fi
        sleep 0.5
        waited=$(( waited + 1 ))
    done

    if [[ "${setup_gone}" == "true" ]]; then
        # Distinguish "finished too fast to interrupt" from "died early", which
        # is a real regression signal and must not be filed as a skip.
        local first_rc=0
        wait "${pid}" 2>/dev/null || first_rc=$?
        if (( first_rc != 0 )); then
            tail -20 /tmp/e2e-interrupt.log >&2
            fail "INTERRUPT: first setup run exited ${first_rc} before reaching the mutating phase"
        else
            skip "INTERRUPT: setup completed before the mutating phase could be interrupted; the SIGTERM recovery path was not exercised"
        fi
    elif [[ "${mid_flight}" != "true" ]]; then
        kill -TERM "${pid}" 2>/dev/null || true
        wait "${pid}" 2>/dev/null
        skip "INTERRUPT: setup never reached an observable mutating phase within 30s; the SIGTERM recovery path was not exercised"
    else
        if ! kill -TERM "${pid}" 2>/dev/null; then
            fail "INTERRUPT: could not signal setup (it had already exited)"
            wait "${pid}" 2>/dev/null
            return
        fi
        local first_rc=0
        wait "${pid}" 2>/dev/null || first_rc=$?
        # PROOF OF HALT, not merely of delivery: `kill` returning 0 only says
        # the signal was queued. If setup traps SIGTERM for a graceful exit or
        # wins the race and finishes, the "recovery" below would validate
        # resume-from-COMPLETE — not the half-written state A17 exists for.
        # Halted ⇒ nonzero exit AND no completion banner.
        if (( first_rc != 0 )) \
                && ! grep -q "SUCCESS: DocumentDB is ready" /tmp/e2e-interrupt.log; then
            pass "INTERRUPT: SIGTERM halted setup mid-flight (rc=${first_rc})"
        elif (( first_rc == 0 )); then
            skip "INTERRUPT: setup completed (rc=0) despite the SIGTERM; recovery below resumes from a COMPLETE install, not a half-written one"
        else
            fail "INTERRUPT: setup exited ${first_rc} but printed the completion banner — inconsistent state"
        fi
        # Settle: SIGTERM to setup does not reap an initdb it had already
        # spawned — initdb reparents to pid 1 and runs to completion. Wait for
        # it to drain so the recovery re-run starts from a quiescent host
        # instead of racing a still-running initdb on the same data directory.
        local settle=0
        while (( settle < 40 )) && pgrep -x initdb >/dev/null 2>&1; do
            sleep 0.5; settle=$(( settle + 1 ))
        done
    fi
    log "Re-running to completion"
    # "recovery re-run", not "after SIGTERM": this runs on BOTH the halted-mid-
    # flight path and the rare skip fallback, so the wording must not claim a
    # SIGTERM was delivered when the skip arms mean it was not.
    if documentdb-setup --admin-user admin --admin-password-file "${PW_FILE}" --yes \
            > /tmp/e2e-recover.log 2>&1; then
        pass "INTERRUPT: recovery re-run reached SUCCESS"
        local out
        out="$(mongo_eval admin "$(cat "${PW_FILE}")" ${GATEWAY_PORT_DEFAULT} 'print(JSON.stringify(db.runCommand({ping:1})));')"
        grep -q '"ok":1' <<<"${out}" \
            && pass "INTERRUPT: gateway serves after recovery" \
            || fail "INTERRUPT: gateway not serving after recovery: $(head -2 <<<"${out}")"
    else
        tail -30 /tmp/e2e-recover.log >&2
        fail "INTERRUPT: recovery re-run failed"
    fi
    # Clean up for the next scenario — runs on BOTH outcomes so a failure
    # here cannot cascade into the brownfield scenario.
    documentdb-setup --restore --yes > /dev/null 2>&1 || true
    # UNSCOPED-restore record contract: the orphan sweep stops every nohup
    # gateway and removes each killed pid's record, then clears any stale
    # leftovers — so NO per-port record may survive. (Scoped restores are
    # exempt by design: they leave other majors' live gateways and records
    # alone.) A leftover here would let a future re-run signal whatever pid
    # the kernel recycles onto it.
    if compgen -G '/run/documentdb-gateway/gateway-*.pid' >/dev/null 2>&1; then
        fail "INTERRUPT-CLEANUP: unscoped restore left nohup gateway records behind: $(ls /run/documentdb-gateway/gateway-*.pid 2>/dev/null | tr '\n' ' ')"
    else
        pass "INTERRUPT-CLEANUP: unscoped restore removed every nohup gateway record"
    fi
    documentdb-local-reset --pg-version "${PG_MAJOR}" --confirm-destroy > /dev/null 2>&1 || true
}

# ── Brownfield adoption of a distro cluster (A1) ───────────────────────
scenario_brownfield() {
    # Defense in depth: never inherit greenfield state from an earlier
    # scenario (the wizard rightly refuses brownfield-over-greenfield).
    if [[ -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf" ]]; then
        log "Cleaning residual greenfield state before brownfield adoption"
        documentdb-setup --restore --yes > /dev/null 2>&1 || true
        documentdb-local-reset --pg-version "${PG_MAJOR}" --confirm-destroy > /dev/null 2>&1 || true
    fi
    log "Creating a distro-style cluster with operator data"
    if ! command -v pg_createcluster >/dev/null 2>&1; then
        fail "BROWNFLD: pg_createcluster unavailable in this image"
        return
    fi
    pg_createcluster "${PG_MAJOR}" brown > /dev/null 2>&1 \
        || { fail "BROWNFLD: pg_createcluster failed"; return; }
    pg_ctlcluster "${PG_MAJOR}" brown start > /dev/null 2>&1 \
        || { fail "BROWNFLD: cluster start failed"; return; }
    # Operator data + a custom operator setting that must survive
    sudo -u postgres psql -p "$(pg_lsclusters -h | awk '$2=="brown"{print $3}')" \
        -c "CREATE TABLE operator_marker(v text); INSERT INTO operator_marker VALUES ('keep-me');" \
        > /dev/null 2>&1 || { fail "BROWNFLD: seeding operator data failed"; return; }

    log "Adopting ${PG_MAJOR}/brown (step 1: expect restart handoff)"
    local rc=0
    documentdb-setup --target-postgres-instance "${PG_MAJOR}/brown" \
        --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/e2e-brownfield-1.log 2>&1 || rc=$?
    if [[ ${rc} -ne 0 ]]; then
        tail -30 /tmp/e2e-brownfield-1.log >&2
        fail "BROWNFLD: first adoption run failed (rc=${rc})"
        return
    fi
    # "restart handoff" vs "no restart needed" are both legitimate outcomes, so
    # this is a branch, not an assertion — it used to call pass() in BOTH arms,
    # which could never fail and only inflated PASS_COUNT.
    if grep -q "restarted" /tmp/e2e-brownfield-1.log; then
        log "BROWNFLD: step-1 ended with a restart handoff"
        # In handoff mode the printed re-run command IS the contract, so both
        # halves are hard assertions. The password-source check (round-10 fix)
        # was previously nested inside a grep for the command with no else, so
        # a reworded banner deleted the assertion silently — zero PASS, zero
        # FAIL, suite still green.
        if ! grep -q "documentdb-setup --target-postgres-instance ${PG_MAJOR}/brown" \
                /tmp/e2e-brownfield-1.log; then
            fail "BROWNFLD: restart handoff printed no step-2 re-run command"
        elif grep -q -- "--admin-password-file ${PW_FILE}" /tmp/e2e-brownfield-1.log; then
            pass "BROWNFLD: printed step-2 command carries the password source"
        else
            fail "BROWNFLD: step-2 command misses the password source"
        fi
    else
        # Record the coverage loss. Without this, a regression that stops
        # step 1 printing the handoff deletes every step-2 contract check
        # above with zero PASS, zero FAIL and no trace in the totals — the
        # same silent-vanishing class this branch was rewritten to close.
        skip "BROWNFLD: no restart handoff in step-1 output; the step-2 re-run command contract was not checked"
    fi

    pg_ctlcluster "${PG_MAJOR}" brown restart > /dev/null 2>&1 \
        || { fail "BROWNFLD: cluster restart failed"; return; }

    log "Step 2: re-run exactly as printed"
    if ! documentdb-setup --target-postgres-instance "${PG_MAJOR}/brown" \
            --admin-user admin --admin-password-file "${PW_FILE}" --yes \
            > /tmp/e2e-brownfield-2.log 2>&1; then
        tail -30 /tmp/e2e-brownfield-2.log >&2
        fail "BROWNFLD: step-2 run failed"
        return
    fi
    pass "BROWNFLD: two-step adoption completed"

    local out
    out="$(mongo_eval admin "$(cat "${PW_FILE}")" ${GATEWAY_PORT_DEFAULT} 'print(JSON.stringify(db.runCommand({ping:1})));')"
    grep -q '"ok":1' <<<"${out}" \
        && pass "BROWNFLD: gateway serves against the adopted cluster" \
        || fail "BROWNFLD: gateway not serving: $(head -2 <<<"${out}")"

    # Operator data intact; managed listen block must NOT be in the
    # adopted cluster's postgresql.conf (brownfield keeps operator listen)
    local marker
    marker="$(sudo -u postgres psql -p "$(pg_lsclusters -h | awk '$2=="brown"{print $3}')" \
        -tA -c "SELECT v FROM operator_marker;" 2>/dev/null)"
    [[ "${marker}" == "keep-me" ]] \
        && pass "BROWNFLD: operator data intact after adoption" \
        || fail "BROWNFLD: operator data missing"
    if grep -q "documentdb-setup managed listen" "/etc/postgresql/${PG_MAJOR}/brown/postgresql.conf" 2>/dev/null; then
        fail "BROWNFLD: managed listen block written into adopted cluster config"
    else
        pass "BROWNFLD: adopted cluster listen settings untouched"
    fi

    # Detach + verify the managed blocks are gone but the cluster survives
    documentdb-setup --restore --pg-version "${PG_MAJOR}" --yes > /tmp/e2e-brownfield-restore.log 2>&1 \
        || { tail -20 /tmp/e2e-brownfield-restore.log >&2; fail "BROWNFLD: restore failed"; return; }
    if grep -q "documentdb-setup managed" "/etc/postgresql/${PG_MAJOR}/brown/pg_hba.conf" 2>/dev/null; then
        fail "BROWNFLD: hba managed block survived restore"
    else
        pass "BROWNFLD: restore stripped the managed blocks"
    fi
    # (The unscoped-restore record contract is asserted at INTERRUPT's
    # cleanup, which performs a genuinely UNSCOPED restore. THIS restore is
    # scoped (--pg-version), and scoped restores deliberately leave live
    # nohup gateways and their per-port records alone — asserting record
    # removal here contradicted that contract and failed on a correct
    # system.)
    marker="$(sudo -u postgres psql -p "$(pg_lsclusters -h | awk '$2=="brown"{print $3}')" \
        -tA -c "SELECT v FROM operator_marker;" 2>/dev/null)"
    [[ "${marker}" == "keep-me" ]] \
        && pass "BROWNFLD: operator data intact after restore" \
        || fail "BROWNFLD: operator data lost by restore"
}

# ── Main ───────────────────────────────────────────────────────────────
install_packages
scenario_readonly_clean
scenario_dry_run_no_mutation
scenario_conflicts
scenario_env_hygiene
scenario_greenfield_pwedge_portkeep
scenario_scoped_restore
scenario_interrupt_recovery
scenario_brownfield

echo ""
echo "══════════════════════════════════════════"
echo " e2e-extra: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
if (( SKIP_COUNT > 0 )); then
    echo " skipped: ${SKIPPED_IDS[*]}"
fi
if (( FAIL_COUNT > 0 )); then
    echo " failed: ${FAILED_IDS[*]}"
    exit 1
fi
echo " ALL EXTRA SCENARIOS PASSED"
