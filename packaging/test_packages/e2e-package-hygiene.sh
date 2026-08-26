#!/bin/bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# e2e-package-hygiene.sh — package-manager hygiene scenarios (P2/P3/P5
# and A11 from the E2E matrix) that the functional suites do not cover.
# Runs inside the deb gateway test image (packages staged at
# /tmp/install_setup):
#   docker run --rm --user root --entrypoint bash \
#     -v <repo>/oss/packaging/test_packages:/e2e:ro \
#     documentdb-test-gateway-packages:latest /e2e/e2e-package-hygiene.sh
#
#   CONFFILE  (P2)   administrator edits to a conffile survive an upgrade
#   REINSTALL (P5)   apt install --reinstall is sane and prints one banner
#   UPGRADE   (A11)  reinstall-as-upgrade runs the scriptlets cleanly with
#                    a live install and leaves it serving
#   RESIDUE   (P3)   after purging everything, no unexpected DocumentDB
#                    residue remains — and NO private key survives

set -uo pipefail

# Shared harness helpers (collect/newest/skip).
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/e2e-lib.sh"

PG_MAJOR="${PG_MAJOR:-18}"
PASS_COUNT=0
FAIL_COUNT=0
FAILED_IDS=()

SKIP_COUNT=0
SKIPPED_IDS=()

log()  { echo -e "\033[1;36m[e2e-hygiene]\033[0m $*"; }
pass() { PASS_COUNT=$((PASS_COUNT + 1)); echo -e "\033[1;32mPASS\033[0m $*"; }
fail() { FAIL_COUNT=$((FAIL_COUNT + 1)); FAILED_IDS+=("$1"); echo -e "\033[1;31mFAIL\033[0m $*"; }
skip() { e2e_skip "$@"; }

PW_FILE=/root/.e2e-hyg-pw
printf '%s' 'Hygiene-Pw1' > "${PW_FILE}"
chmod 600 "${PW_FILE}"

# Expand the glob into an array (nullglob drops an empty pattern) and refuse
# to proceed on an empty staging dir. Never `ls` the glob: with zero surviving
# arguments `apt-get install` installs nothing and exits 0, so an empty or
# mis-mounted /tmp/install_setup reported "packages installed" and every purge
# and residue assertion downstream then passed vacuously against a host where
# nothing was ever installed. Same hazard documented at
# systemd/run-systemd-e2e.sh:58-70.
STAGED_DEBS=()
collect_staged_debs() {
    e2e_collect_staged_debs || { STAGED_DEBS=(); return 1; }
    STAGED_DEBS=( "${E2E_STAGED_DEBS[@]}" )
}

install_all() {
    collect_staged_debs || return 2
    apt-get update -qq >/dev/null 2>&1
    apt-get install -y -qq -o Dpkg::Use-Pty=0 "${STAGED_DEBS[@]}" \
        > /tmp/e2e-hyg-install.log 2>&1
}

log "Installing all packages"
install_all; install_rc=$?
if (( install_rc == 2 )); then
    fail "HYG-INSTALL: no .deb packages staged in /tmp/install_setup; nothing to test"
    exit 1
elif (( install_rc != 0 )); then
    tail -30 /tmp/e2e-hyg-install.log >&2
    fail "HYG-INSTALL: initial install failed"
    exit 1
fi
log "Installed ${#STAGED_DEBS[@]} staged package(s)"
pass "HYG-INSTALL: packages installed"

if [[ -n "${E2E_SETUP_OVERRIDE:-}" && -r "${E2E_SETUP_OVERRIDE}" ]]; then
    install -m 0755 "${E2E_SETUP_OVERRIDE}" /usr/bin/documentdb-setup
    log "OVERRIDE: documentdb-setup replaced with ${E2E_SETUP_OVERRIDE}"
fi

# ── CONFFILE (P2): operator edits survive an upgrade ───────────────────
CONFFILE=/etc/documentdb/gateway/SetupConfiguration.json
log "Marking the conffile with an administrator edit"
marker_applied=false
if [[ -f "${CONFFILE}" ]]; then
    # The edit must keep the file VALID JSON — the gateway parses this
    # config at startup, so a comment-style marker would break the very
    # install this scenario needs alive for the upgrade test.
    if jq '. + {E2eAdminEditMarker: "kept-across-upgrade"}' "${CONFFILE}" \
            > "${CONFFILE}.e2e-tmp" 2>/dev/null \
            && jq -e . "${CONFFILE}.e2e-tmp" >/dev/null 2>&1; then
        mv "${CONFFILE}.e2e-tmp" "${CONFFILE}"
        marker_applied=true
        pass "CONFFILE: administrator edit applied (valid JSON preserved)"
    else
        rm -f "${CONFFILE}.e2e-tmp"
        fail "CONFFILE: could not apply a JSON-valid administrator edit"
    fi
else
    fail "CONFFILE: ${CONFFILE} was not shipped"
fi

# ── UPGRADE (A11) with a LIVE install ──────────────────────────────────
log "Setting up (greenfield) so the upgrade runs against a live install"
if ! documentdb-setup --admin-user admin --admin-password-file "${PW_FILE}" --yes \
        > /tmp/e2e-hyg-setup.log 2>&1; then
    tail -30 /tmp/e2e-hyg-setup.log >&2
    fail "HYG-SETUP: greenfield setup failed"
else
    pass "HYG-SETUP: greenfield install is live before the upgrade"
fi

log "Re-installing every package (dpkg treats this as an upgrade)"
if ! collect_staged_debs; then
    fail "UPGRADE: no .deb packages staged in /tmp/install_setup; cannot test the upgrade path"
elif apt-get install -y -qq --reinstall -o Dpkg::Use-Pty=0 "${STAGED_DEBS[@]}" \
        > /tmp/e2e-hyg-upgrade.log 2>&1; then
    pass "UPGRADE: reinstall-as-upgrade transaction succeeded"
else
    tail -40 /tmp/e2e-hyg-upgrade.log >&2
    fail "UPGRADE: reinstall-as-upgrade failed"
fi

if [[ "${marker_applied}" == "true" ]]; then
    if grep -q 'E2eAdminEditMarker' "${CONFFILE}"; then
        pass "CONFFILE: administrator edit survived the upgrade"
    else
        fail "CONFFILE: administrator edit to ${CONFFILE} was lost on upgrade"
    fi
fi

# The state and the data directory must survive an upgrade.
[[ -f "/etc/documentdb/local/${PG_MAJOR}/setup.conf" ]] \
    && pass "UPGRADE: per-major state survived" \
    || fail "UPGRADE: per-major state was lost"
[[ -f "/var/lib/documentdb-local/${PG_MAJOR}/data/PG_VERSION" ]] \
    && pass "UPGRADE: PostgreSQL data directory survived" \
    || fail "UPGRADE: PostgreSQL data directory was lost"

# ── REINSTALL (P5): banner accuracy on a gateway-only reinstall ────────
log "Reinstalling only documentdb-gateway (parent already configured)"
if apt-get install -y --reinstall -o Dpkg::Use-Pty=0 documentdb-gateway \
        > /tmp/e2e-hyg-gwreinstall.log 2>&1; then
    pass "REINSTALL: gateway-only reinstall succeeded"
    if grep -q "The pulling package's postinst will" /tmp/e2e-hyg-gwreinstall.log; then
        fail "REINSTALL: banner still promises another postinst will print steps"
    else
        pass "REINSTALL: banner makes no false promise about another postinst"
    fi
else
    tail -20 /tmp/e2e-hyg-gwreinstall.log >&2
    fail "REINSTALL: gateway-only reinstall failed"
fi

# ── RESIDUE (P3): purge everything, then audit ─────────────────────────
log "Detaching and purging every DocumentDB package"
documentdb-setup --restore --yes > /tmp/e2e-hyg-restore.log 2>&1 || true
documentdb-local-reset --pg-version "${PG_MAJOR}" --confirm-destroy \
    > /tmp/e2e-hyg-reset.log 2>&1 || true

# Purge only what is actually installed: naming an absent package (the
# meta is not part of the test image's install set) makes apt abort the
# whole transaction with "Unable to locate package".
purge_list=()
for p in documentdb "documentdb-${PG_MAJOR}" documentdb-common \
         documentdb-postgresql-tools documentdb-gateway \
         "postgresql-${PG_MAJOR}-documentdb"; do
    if dpkg-query -W -f='${db:Status-Status}\n' "${p}" 2>/dev/null | grep -q .; then
        purge_list+=("${p}")
    fi
done
log "Purging: ${purge_list[*]}"
if apt-get purge -y -qq -o Dpkg::Use-Pty=0 "${purge_list[@]}" \
        > /tmp/e2e-hyg-purge.log 2>&1; then
    pass "RESIDUE: purge transaction succeeded"
else
    tail -30 /tmp/e2e-hyg-purge.log >&2
    fail "RESIDUE: purge failed"
fi

# No private key may survive a full purge (a recycled UID could read it).
leftover_keys="$(find /var/lib /etc -name 'pkey.pem' -o -name '*.key' 2>/dev/null \
    | grep -i documentdb || true)"
if [[ -z "${leftover_keys}" ]]; then
    pass "RESIDUE: no DocumentDB private key survived the purge"
else
    echo "${leftover_keys}" >&2
    fail "RESIDUE: private key material survived the purge"
fi

# Config/state trees must be gone.
for tree in /etc/documentdb /var/lib/documentdb-gateway; do
    if [[ -d "${tree}" ]]; then
        remaining="$(find "${tree}" -type f 2>/dev/null | head -5)"
        if [[ -n "${remaining}" ]]; then
            echo "${remaining}" >&2
            fail "RESIDUE: files remain under ${tree} after purge"
        else
            pass "RESIDUE: ${tree} holds no files after purge"
        fi
    else
        pass "RESIDUE: ${tree} removed by purge"
    fi
done

# The gateway system user must be gone (its home was purged).
if id -u documentdb-gateway >/dev/null 2>&1; then
    fail "RESIDUE: documentdb-gateway system user survived the purge"
else
    pass "RESIDUE: documentdb-gateway system user removed"
fi

# Binaries must be gone from PATH. (documentdb-setup may legitimately be
# the E2E_SETUP_OVERRIDE copy this harness installed by hand, so ignore
# that one when an override is in effect.)
# NOTE: `command -v` consults bash's command HASH TABLE first, which
# still holds paths for commands this script executed earlier in the run
# (documentdb-setup, documentdb-local-reset) — it reports them as present
# long after dpkg deleted the files. Drop the cache, then test the real
# filesystem rather than trusting the shell's lookup.
hash -r
path_residue=()
for cmd in documentdb-setup documentdb-gateway documentdb-tune \
           documentdb-register-gateway documentdb-gateway-admin \
           documentdb-local-reset; do
    if [[ "${cmd}" == "documentdb-setup" && -n "${E2E_SETUP_OVERRIDE:-}" ]]; then
        # The harness overwrote this path, so file contents can no longer tell
        # "purge left it behind" from "the harness copy is still here". This
        # branch used to `rm -f` and continue, DELETING the residue it was
        # auditing and then reporting success for a command it never checked.
        # Use dpkg's ownership record, which the override does not alter, as
        # the real signal; otherwise record an explicit skip.
        if dpkg -S /usr/bin/documentdb-setup >/dev/null 2>&1; then
            path_residue+=("/usr/bin/documentdb-setup(still dpkg-owned)")
        else
            skip "RESIDUE: /usr/bin/documentdb-setup not audited (E2E_SETUP_OVERRIDE wrote a harness copy over the packaged path); the other bindirs are still checked"
        fi
        # Drop ONLY the harness copy at the overridden path, then fall through
        # to the normal sweep — do not `continue`. The override affects
        # /usr/bin alone, so a postrm regression that left documentdb-setup in
        # /usr/local/bin, /usr/sbin or /sbin must still be caught; the previous
        # `continue` skipped all of them for this one command.
        rm -f /usr/bin/documentdb-setup
    fi
    for bindir in /usr/bin /usr/local/bin /bin /usr/sbin /sbin; do
        [[ -e "${bindir}/${cmd}" ]] || continue
        # Resolve before recording: /bin -> /usr/bin and /sbin -> /usr/sbin on
        # usr-merged distros (Ubuntu 24.04, RHEL 9), so the same inode would
        # otherwise be listed twice and one leftover binary would read as two
        # independent packaging defects.
        path_residue+=("$(readlink -f "${bindir}/${cmd}" 2>/dev/null || echo "${bindir}/${cmd}")")
    done
done
if (( ${#path_residue[@]} > 0 )); then
    mapfile -t path_residue < <(printf '%s\n' "${path_residue[@]}" | sort -u)
fi
if (( ${#path_residue[@]} == 0 )); then
    pass "RESIDUE: all DocumentDB commands removed from PATH"
else
    fail "RESIDUE: commands still on PATH after purge: ${path_residue[*]}"
fi

echo ""
echo "══════════════════════════════════════════"
echo " e2e-hygiene: ${PASS_COUNT} passed, ${FAIL_COUNT} failed, ${SKIP_COUNT} skipped"
if (( SKIP_COUNT > 0 )); then
    echo " skipped: ${SKIPPED_IDS[*]}"
fi
if (( FAIL_COUNT > 0 )); then
    echo " failed: ${FAILED_IDS[*]}"
    exit 1
fi
echo " ALL HYGIENE SCENARIOS PASSED"
