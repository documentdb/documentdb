#!/usr/bin/env bash
# Behavioral co-install / removal / upgrade regression test for the
# documentdb-common shared-payload split (packaging-design.md §10.6).
#
# This is the automated package-manager reproduction of the exact bug the split
# fixes: before the split, every per-major documentdb-N shipped the same shared
# files, so removing the later-installed major deleted them from the surviving
# major. It builds the real packages with the repo builders and drives dpkg/rpm
# through three scenarios:
#
#   A. Fresh co-install of documentdb-common + documentdb-17 + documentdb-18,
#      then remove documentdb-18 — the shared files (documentdb-setup, the
#      template units, helper scripts) MUST survive for documentdb-17.
#   B. Full teardown — removing the last major + documentdb-common removes the
#      shared files.
#   C. Upgrade from a PRE-SPLIT documentdb-17 (which owned /usr/bin/documentdb-setup)
#      to documentdb-common + payload-free documentdb-17 — ownership must
#      transfer to documentdb-common with no file-ownership error. DEB proves
#      this via the unversioned Replaces: on documentdb-common (plain dpkg -i,
#      no --force-overwrite); RPM proves it via rpm's identical-file digest
#      takeover (plain rpm -U, no --replacefiles), so the synthetic pre-split
#      package ships the same documentdb-setup content documentdb-common does.
#
# Run inside a Debian/Ubuntu container (--type deb, needs dpkg-deb) or a
# RHEL-family container (--type rpm, needs rpmbuild). PostgreSQL/gateway
# dependencies are bypassed (dpkg --force-depends / rpm --nodeps) so the test
# stays fast and focused on shared-file OWNERSHIP, not the full stack.
#
# Usage:
#   test-documentdb-common-coinstall.sh --type {deb|rpm} [--version V] [--output-dir DIR]
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# test_packages/ is under oss/packaging/, so the OSS root is two levels up.
OSS_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Shared harness helpers (newest-artifact).
. "${SCRIPT_DIR}/e2e-lib.sh"

PACKAGE_TYPE=""
VERSION=""
OUTPUT_DIR=""
OLD_VERSION="0.0.1"   # synthetic pre-split version for scenario C

die() { echo "ERROR: $*" >&2; exit 1; }

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) PACKAGE_TYPE="${2:-}"; shift 2 ;;
        --version) VERSION="${2:-}"; shift 2 ;;
        --output-dir) OUTPUT_DIR="${2:-}"; shift 2 ;;
        -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

case "${PACKAGE_TYPE}" in
    deb|rpm) ;;
    *) die "--type must be 'deb' or 'rpm'" ;;
esac

# Resolve the version the build scripts use when not overridden.
if [[ -z "${VERSION}" ]]; then
    control_file="${OSS_ROOT}/pg_documentdb_core/documentdb_core.control"
    [[ -r "${control_file}" ]] || die "Cannot read ${control_file}; pass --version."
    VERSION="$(grep -E '^default_version' "${control_file}" \
        | sed -E "s/.*'([0-9]+\.[0-9]+-[0-9]+)'.*/\1/" | tr '-' '.')"
    [[ -n "${VERSION}" ]] || die "Failed to extract version from ${control_file}."
fi

OUTPUT_DIR="${OUTPUT_DIR:-$(mktemp -d)}"
mkdir -p "${OUTPUT_DIR}"

PASS=0
FAIL=0
check() { # check <description> <test-command...>
    local desc="$1"; shift
    if "$@"; then echo "  PASS: ${desc}"; PASS=$((PASS + 1));
    else echo "  FAIL: ${desc}"; FAIL=$((FAIL + 1)); fi
}
setup_present() { [ -f /usr/bin/documentdb-setup ]; }
setup_absent()  { [ ! -f /usr/bin/documentdb-setup ]; }

# ── Build the real packages via the repo builders ───────────────────
# Build output (incl. rpmbuild's verbose scriptlet trace) goes to a log; it is
# shown only if a build fails, keeping the pass/fail report readable in CI.
BUILD_LOG="${OUTPUT_DIR}/build.log"
run_build() { if ! "$@" >>"${BUILD_LOG}" 2>&1; then echo "--- build step failed: $* ---" >&2; cat "${BUILD_LOG}" >&2; exit 1; fi; }

echo "=== Building documentdb-common + documentdb-17 + documentdb-18 (${VERSION}, ${PACKAGE_TYPE}) ==="
if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
    command -v dpkg-deb >/dev/null 2>&1 || die "dpkg-deb required (run in a Debian/Ubuntu container)."
    run_build bash "${OSS_ROOT}/packaging/standalone/build-common-deb.sh" --version "${VERSION}" --output-dir "${OUTPUT_DIR}"
    run_build bash "${OSS_ROOT}/packaging/standalone/build-standalone-deb.sh" --version "${VERSION}" --pg-version 17 --output-dir "${OUTPUT_DIR}"
    run_build bash "${OSS_ROOT}/packaging/standalone/build-standalone-deb.sh" --version "${VERSION}" --pg-version 18 --output-dir "${OUTPUT_DIR}"
    COMMON="${OUTPUT_DIR}/documentdb-common_${VERSION}_all.deb"
    P17="${OUTPUT_DIR}/documentdb-17_${VERSION}_all.deb"
    P18="${OUTPUT_DIR}/documentdb-18_${VERSION}_all.deb"
    pkg_install() { dpkg -i --force-depends "$@" >/dev/null 2>&1; }
    pkg_remove()  { dpkg -r --force-depends "$@" >/dev/null 2>&1; }
    owner_of()    { dpkg -S /usr/bin/documentdb-setup 2>/dev/null | cut -d: -f1; }
else
    command -v rpmbuild >/dev/null 2>&1 || die "rpmbuild required (run in a RHEL-family container)."
    run_build bash "${OSS_ROOT}/packaging/build_extra_packages.sh" --type rpm --pg 17 --version "${VERSION}" --output-dir "${OUTPUT_DIR}"
    run_build bash "${OSS_ROOT}/packaging/build_extra_packages.sh" --type rpm --pg 18 --version "${VERSION}" --output-dir "${OUTPUT_DIR}"
    # VERSION is pinned, but the release/dist suffix still varies, and
    # `ls | head -1` takes the LEXICOGRAPHICALLY first match — so a stale
    # -1.el9 build beats the -2.el9 one just produced above. Select the
    # newest by mtime instead.
    # LC_ALL=C so the decimal epoch from %T@ sorts numerically regardless of
    # the build host's locale decimal separator.
    newest_rpm() { e2e_newest_artifact "${OUTPUT_DIR}" "$1"; }
    COMMON="$(newest_rpm "documentdb-common-${VERSION}-*.noarch.rpm")"
    P17="$(newest_rpm "documentdb-17-${VERSION}-*.noarch.rpm")"
    P18="$(newest_rpm "documentdb-18-${VERSION}-*.noarch.rpm")"
    pkg_install() { rpm -i --nodeps "$@" >/dev/null 2>&1; }
    pkg_remove()  { rpm -e --nodeps "$@" >/dev/null 2>&1; }
    owner_of()    { rpm -qf /usr/bin/documentdb-setup 2>/dev/null; }
fi
[[ -f "${COMMON}" && -f "${P17}" && -f "${P18}" ]] || die "expected built packages not found in ${OUTPUT_DIR}"

# owned_by_common: true when /usr/bin/documentdb-setup is owned by the
# documentdb-common package (dpkg prints "documentdb-common"; rpm prints
# "documentdb-common-<ver>-<rel>.noarch").
owned_by_common() { case "$(owner_of)" in documentdb-common*) return 0 ;; *) return 1 ;; esac; }

# ── Scenario A: co-install 17+18, remove 18, shared files survive ───
echo "=== Scenario A: co-install documentdb-common + 17 + 18, then remove 18 ==="
pkg_install "${COMMON}" "${P17}" "${P18}" || die "co-install failed"
check "documentdb-setup present after co-install" setup_present
check "documentdb-setup owned by documentdb-common" owned_by_common
pkg_remove documentdb-18 || die "removing documentdb-18 failed"
check "documentdb-setup survives removal of documentdb-18 (the fixed bug)" setup_present
check "documentdb-local-reset survives removal of documentdb-18" test -f /usr/bin/documentdb-local-reset
check "PostgreSQL service template survives removal of documentdb-18" test -f /usr/lib/systemd/system/documentdb-postgresql@.service
check "service helper script survives removal of documentdb-18" test -f /usr/share/documentdb/scripts/documentdb_postgresql_service.sh

# ── Scenario B: full teardown removes the shared files ──────────────
echo "=== Scenario B: remove documentdb-17 then documentdb-common ==="
pkg_remove documentdb-17 || die "removing documentdb-17 failed"
check "documentdb-setup still present while documentdb-common remains" setup_present
pkg_remove documentdb-common || die "removing documentdb-common failed"
check "documentdb-setup removed once documentdb-common is gone" setup_absent

# ── Scenario C: pre-split → split upgrade transfers ownership ────────
echo "=== Scenario C: upgrade from a PRE-SPLIT documentdb-17 that owned documentdb-setup ==="
fakedir="$(mktemp -d)"
if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
    fk="${fakedir}/documentdb-17"
    mkdir -p "${fk}/DEBIAN" "${fk}/usr/bin"
    printf '#!/bin/sh\necho pre-split\n' > "${fk}/usr/bin/documentdb-setup"
    chmod 0755 "${fk}/usr/bin/documentdb-setup"
    cat > "${fk}/DEBIAN/control" <<CTL
Package: documentdb-17
Version: ${OLD_VERSION}
Architecture: all
Maintainer: DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com>
Description: synthetic pre-split documentdb-17 that owns the shared file
CTL
    dpkg-deb --build --root-owner-group "${fk}" "${fakedir}/old17.deb" >/dev/null
    pkg_install "${fakedir}/old17.deb" || die "installing synthetic pre-split documentdb-17 failed"
    check "pre-split documentdb-17 owns documentdb-setup" bash -c '[ "$(dpkg -S /usr/bin/documentdb-setup | cut -d: -f1)" = documentdb-17 ]'
    # Plain dpkg -i (no --auto-deconfigure): unversioned Replaces alone must
    # permit the file takeover.
    if dpkg -i --force-depends "${COMMON}" "${P17}" >"${fakedir}/up.log" 2>&1; then
        check "upgrade succeeded (no overwrite error)" bash -c '! grep -q "trying to overwrite" '"${fakedir}/up.log"
    else
        echo "  FAIL: upgrade transaction errored"; cat "${fakedir}/up.log"; FAIL=$((FAIL + 1))
    fi
    check "documentdb-setup now owned by documentdb-common after upgrade" owned_by_common
    pkg_remove documentdb-17 documentdb-common >/dev/null 2>&1 || true
else
    fk="${fakedir}/rpmbuild"
    mkdir -p "${fk}"/{SPECS,BUILDROOT}
    # The pre-split documentdb-17 must ship the SAME documentdb-setup content
    # that documentdb-common installs (both are a verbatim copy of the one
    # source file, install -Dpm 0755). rpm keys its cross-package file takeover
    # on identical file digests, so identical content is what lets a plain
    # `rpm -U` (no --replacefiles) move ownership to documentdb-common — the
    # takeover this scenario proves. Different content would instead require
    # --replacefiles and mask a real conflict.
    real_setup="${OSS_ROOT}/documentdb-local/scripts/documentdb-setup.sh"
    [[ -r "${real_setup}" ]] || die "cannot read ${real_setup} for the synthetic pre-split RPM"
    cat > "${fk}/SPECS/old17.spec" <<SPEC
%define debug_package %{nil}
Name: documentdb-17
Version: ${OLD_VERSION}
Release: 1
Summary: synthetic pre-split documentdb-17 that owns the shared file
License: MIT
BuildArch: noarch
%description
synthetic pre-split documentdb-17
%install
install -Dpm 0755 ${real_setup} %{buildroot}/usr/bin/documentdb-setup
%files
/usr/bin/documentdb-setup
SPEC
    rpmbuild -bb "${fk}/SPECS/old17.spec" --define "_topdir ${fk}" >/dev/null 2>&1 || die "building synthetic pre-split RPM failed"
    old17rpm="$(ls "${fk}"/RPMS/noarch/documentdb-17-"${OLD_VERSION}"-*.noarch.rpm | head -1)"
    pkg_install "${old17rpm}" || die "installing synthetic pre-split documentdb-17 failed"
    check "pre-split documentdb-17 owns documentdb-setup" bash -c '[[ "$(rpm -qf /usr/bin/documentdb-setup)" == documentdb-17-* ]]'
    # Plain rpm -U (no --replacefiles/--force): within one transaction rpm must
    # move ownership of the shared file from the erased pre-split documentdb-17
    # to documentdb-common with no file-conflict error. --nodeps only bypasses
    # the postgresql/gateway deps, not file-conflict detection (mirrors the DEB
    # path, which proves the takeover with plain dpkg -i and no --force-overwrite).
    if rpm -U --nodeps "${COMMON}" "${P17}" >"${fakedir}/up.log" 2>&1; then
        check "upgrade succeeded (no file conflict)" bash -c '! grep -qi "conflicts with file" '"${fakedir}/up.log"
    else
        echo "  FAIL: rpm upgrade transaction errored"; cat "${fakedir}/up.log"; FAIL=$((FAIL + 1))
    fi
    check "documentdb-setup now owned by documentdb-common after upgrade" owned_by_common
    pkg_remove documentdb-17 documentdb-common >/dev/null 2>&1 || true
fi
rm -rf "${fakedir}"

echo ""
echo "=== documentdb-common co-install regression: ${PASS} passed, ${FAIL} failed ==="
[[ "${FAIL}" -eq 0 ]] || exit 1
