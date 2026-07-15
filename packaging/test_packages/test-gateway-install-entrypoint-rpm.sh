#!/bin/bash
#
# SPDX-License-Identifier: MIT
#
# Copyright (c) Microsoft Corporation.
#
# Clean-install smoke for the documentdb-gateway RPM. The package is installed
# by the test Dockerfile; this script asserts the install side effects and
# exercises the wrapper's root-shell privilege-drop path -- the path that broke
# on EL8 (RHEL/Rocky/Alma 8 ship util-linux 2.32, whose runuser lacks
# --whitelist-environment), so this gates that class of regression.
set -euo pipefail

fail() { echo "FAIL: $*" >&2; exit 1; }

osname="$( . /etc/os-release 2>/dev/null && echo "${PRETTY_NAME:-unknown}" )"
echo "=== documentdb-gateway RPM install smoke (${osname}; $(runuser --version 2>/dev/null | head -1)) ==="

# 1. System user created with the expected identity (EL9 sysusers_create_compat
#    or the EL8 useradd fallback both go through here).
ent="$(getent passwd documentdb-gateway)" || fail "documentdb-gateway user was not created"
echo "${ent}" | grep -q 'DocumentDB Gateway' || fail "user GECOS is not 'DocumentDB Gateway': ${ent}"
echo "${ent}" | grep -q '/nonexistent'      || fail "user home is not /nonexistent: ${ent}"
echo "${ent}" | grep -q 'nologin'           || fail "user shell is not nologin: ${ent}"
echo "OK: system user (${ent})"

# 2. File layout.
for f in /usr/bin/documentdb-gateway \
         /usr/lib/documentdb-gateway/documentdb-gateway-daemon \
         /usr/lib/systemd/system/documentdb-gateway.service \
         /usr/lib/sysusers.d/documentdb-gateway.conf \
         /usr/lib/tmpfiles.d/documentdb-gateway.conf; do
    test -e "${f}" || fail "missing packaged file: ${f}"
done
echo "OK: file layout"

# 3. EL8 gate: a root-shell `documentdb-gateway --version` must run the real
#    daemon through the wrapper (env-file load + runuser privilege drop). With
#    the pre-fix wrapper this exited non-zero on EL8 with
#    "runuser: unrecognized option '--whitelist-environment'".
if ! ver="$(documentdb-gateway --version 2>&1)"; then
    fail "root-shell 'documentdb-gateway --version' errored: ${ver}"
fi
echo "${ver}" | grep -Eqi 'documentdb-gateway|[0-9]+\.[0-9]+' \
    || fail "unexpected 'documentdb-gateway --version' output: ${ver}"
echo "OK: root-shell 'documentdb-gateway --version' -> ${ver}"

# 4. `--check` must also reach the real daemon through the wrapper. Without a
#    PostgreSQL backend the check is expected to FAIL, but it must fail in the
#    daemon (backend unreachable), not in the wrapper/runuser layer.
chk="$(documentdb-gateway --check 2>&1 || true)"
echo "${chk}" | grep -qi 'unrecognized option' \
    && fail "wrapper/runuser error leaked from --check: ${chk}"
echo "OK: '--check' reached the daemon (no wrapper/runuser error)"

echo "=== documentdb-gateway RPM install smoke PASSED ==="
