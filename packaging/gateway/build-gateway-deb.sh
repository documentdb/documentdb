#!/bin/bash
# Build the documentdb_gateway DEB package from a pre-built binary.
#
# This script replaces cargo-deb for the gateway package, keeping all
# packaging control in oss/packaging/ and oss/documentdb-local/ without
# modifying the gateway crate's Cargo.toml.
#
# Usage:
#   build-gateway-deb.sh --binary <path> --version <version> [--output-dir <dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

BINARY_PATH=""
VERSION=""
OUTPUT_DIR="."
ARCH=""

die() { echo "ERROR: $*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: build-gateway-deb.sh --binary <path> --version <ver> [--output-dir <dir>]

Build the documentdb_gateway DEB package from a pre-built binary.

Required:
  --binary PATH      Path to the compiled documentdb_gateway binary
  --version VER      Package version (e.g., 0.114.0)

Optional:
  --output-dir DIR   Where to write the .deb (default: current dir)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --binary) [[ $# -ge 2 ]] || die "--binary requires a value"; BINARY_PATH="$2"; shift 2 ;;
        --version) [[ $# -ge 2 ]] || die "--version requires a value"; VERSION="$2"; shift 2 ;;
        --output-dir) [[ $# -ge 2 ]] || die "--output-dir requires a value"; OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${BINARY_PATH}" ]] || die "--binary is required"
[[ -x "${BINARY_PATH}" ]] || die "Binary not found or not executable: ${BINARY_PATH}"
[[ -n "${VERSION}" ]] || die "--version is required"

ARCH="$(dpkg --print-architecture)"
# Debian policy requires the Package field to use only [a-z0-9.+-].
# The filename uses the same hyphen-separated form so dpkg's
# <package>_<version>_<arch>.deb convention parses cleanly.
DEB_PKG_NAME="documentdb-gateway"
FILE_PKG_NAME="documentdb-gateway"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${PKG_DIR}"' EXIT

echo "Building ${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb ..."

# ── Directory structure ─────────────────────────────────────────────
install -d "${PKG_DIR}/DEBIAN"
install -d "${PKG_DIR}/usr/bin"
install -d "${PKG_DIR}/usr/lib/systemd/system"
install -d "${PKG_DIR}/usr/lib/sysusers.d"
install -d "${PKG_DIR}/usr/lib/tmpfiles.d"
install -d "${PKG_DIR}/etc/documentdb/gateway"
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}"

install -d "${PKG_DIR}/usr/lib/documentdb-gateway"

# ── Binary + wrapper ────────────────────────────────────────────────
# Deliberate deviation from packaging-design.md section 4.3 (which specifies a
# single binary at /usr/bin): the split daemon+wrapper layout below should be
# reflected back into section 4.3 so the doc stays the source of truth.
# Real-user E2E flagged (Gap #6): when an operator runs
# `documentdb-gateway --check` from a shell, the binary reads only its
# JSON config (which still encodes PostgresDataUser=documentdb-local
# for back-compat) and ignores the per-major gateway.env, producing a
# false-negative auth failure. The systemd path is fine because the
# unit sets EnvironmentFile= — but a manual smoke test should give the
# same result.
#
# Fix: install the Rust daemon at /usr/lib/documentdb-gateway/, ship a
# thin wrapper at /usr/bin/documentdb-gateway that auto-sources the
# right per-major or global env file before exec'ing the daemon, AND
# (for manual --check) downgrades to the documentdb-gateway OS user via
# runuser so the daemon's pg_hba peer-auth match succeeds. The wrapper
# is a pass-through for `run` so the systemd unit (which already sets
# User= and EnvironmentFile=) sees identical behavior.
install -m 0755 "${BINARY_PATH}" "${PKG_DIR}/usr/lib/documentdb-gateway/documentdb-gateway-daemon"

# Install the shared wrapper (single source of truth; see
# oss/packaging/gateway/documentdb-gateway-wrapper.sh). The RPM spec
# installs the same file, so the wrapper logic lives in one place.
install -m 0755 "${REPO_ROOT}/packaging/gateway/documentdb-gateway-wrapper.sh" \
    "${PKG_DIR}/usr/bin/documentdb-gateway"

# ── Systemd / sysusers / tmpfiles ───────────────────────────────────
# Install the systemd unit under /usr/lib/systemd/system (the canonical
# usr-merged location), not the legacy /lib/systemd/system: systemd
# searches /usr/lib on every supported target including split-usr Debian 11
# (verified via systemd-analyze unit-paths), it matches the sysusers.d /
# tmpfiles.d drop-ins below and the RPM's %{_unitdir}, and it follows the
# usr-merge direction of not shipping new files under /lib.
install -m 0644 "${REPO_ROOT}/packaging/gateway/systemd/documentdb-gateway.service" \
    "${PKG_DIR}/usr/lib/systemd/system/documentdb-gateway.service"
install -m 0644 "${REPO_ROOT}/packaging/gateway/sysusers/documentdb-gateway.conf" \
    "${PKG_DIR}/usr/lib/sysusers.d/documentdb-gateway.conf"
install -m 0644 "${REPO_ROOT}/packaging/gateway/tmpfiles/documentdb-gateway.conf" \
    "${PKG_DIR}/usr/lib/tmpfiles.d/documentdb-gateway.conf"

# ── Config files ────────────────────────────────────────────────────
# Per packaging-design.md §4.3: ship the env sample under
# /usr/share/doc/.../examples/ (PostgreSQL convention) and let the
# administrator copy it to /etc/documentdb/gateway/gateway.env when they
# want non-default settings. The systemd unit uses EnvironmentFile=-
# so absence of the live file is fine. SetupConfiguration.json is still
# shipped at the historical path for back-compat with pre-Phase-3
# deployments; new installs are env-only.
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/examples"
install -m 0644 "${REPO_ROOT}/packaging/gateway/config/gateway.env" \
    "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/examples/gateway.env.sample"
install -d "${PKG_DIR}/etc/documentdb/gateway"
# Reviewer-flagged (external review iter 18): the dev-tree
# SetupConfiguration.json carries PostgresPort: 9712 / GatewayListenPort:
# 10260 for the local `cargo run` workflow. Shipping those values
# verbatim into the package contradicts the design's per-major port
# promise (PG 18 → 9718, etc.) AND the env-first/new-installs-env-only
# boundary. Strip the connection-pinning fields when packaging so
# fresh installs are env-driven; existing installs with operator
# edits are preserved by the conffile mechanism (administrator gets
# a dpkg prompt on upgrade if they had local edits).
#
# Also strip PostgresDataUserPassword — Track 1 is passwordless local
# peer auth; matches the runtime rejection in setup.rs.
PACKAGED_JSON="${PKG_DIR}/etc/documentdb/gateway/SetupConfiguration.json"
# Strip via the shared helper (single source of truth, also used by the RPM
# spec %install) so the stripped-field set cannot drift between families.
bash "${REPO_ROOT}/packaging/gateway/strip-setup-config.sh" \
    "${REPO_ROOT}/pg_documentdb_gw/SetupConfiguration.json" "${PACKAGED_JSON}" \
    || die "failed to strip connection-pinning fields from SetupConfiguration.json"
chmod 0644 "${PACKAGED_JSON}"

# ── Maintainer scripts ──────────────────────────────────────────────
install -m 0755 "${REPO_ROOT}/documentdb-local/maintainer-scripts/gateway/postinst" \
    "${PKG_DIR}/DEBIAN/postinst"
install -m 0755 "${REPO_ROOT}/documentdb-local/maintainer-scripts/gateway/postrm" \
    "${PKG_DIR}/DEBIAN/postrm"
install -m 0755 "${REPO_ROOT}/documentdb-local/maintainer-scripts/gateway/prerm" \
    "${PKG_DIR}/DEBIAN/prerm"

# ── Conffiles (preserved on upgrade) ────────────────────────────────
# Only files that are actually shipped under /etc/. The env sample at
# /usr/share/doc/ is not a conffile (it's an example) so isn't listed.
cat > "${PKG_DIR}/DEBIAN/conffiles" <<'CONF'
/etc/documentdb/gateway/SetupConfiguration.json
CONF

# ── Auto-detect shared library dependencies ─────────────────────────
SHLIBDEPS=""
if command -v dpkg-shlibdeps >/dev/null 2>&1; then
    # dpkg-shlibdeps needs a debian/control stub
    mkdir -p "${PKG_DIR}/debian"
    cat > "${PKG_DIR}/debian/control" <<CTRL
Source: ${DEB_PKG_NAME}
Package: ${DEB_PKG_NAME}
Architecture: ${ARCH}
CTRL
    # Analyze the actual ELF daemon (installed at usr/lib/documentdb-gateway/),
    # not the usr/bin/documentdb-gateway shell wrapper — dpkg-shlibdeps emits
    # nothing for a non-ELF, which would silently drop the binary's versioned
    # libc/libssl runtime deps from the package.
    #
    # Do NOT mask failures (no "2>/dev/null", no "|| true"): when
    # dpkg-shlibdeps is available it is authoritative, and a failure means we
    # cannot determine the shared-library dependencies. Swallowing the error
    # would ship a package missing its required libc/libssl deps, so fail the
    # build instead.
    if ! SHLIBDEPS_RAW="$(cd "${PKG_DIR}" && dpkg-shlibdeps -O usr/lib/documentdb-gateway/documentdb-gateway-daemon)"; then
        die "dpkg-shlibdeps failed; cannot safely determine shared-library dependencies"
    fi
    SHLIBDEPS="$(printf '%s' "${SHLIBDEPS_RAW}" | sed 's/^shlibs:Depends=//')"
    rm -rf "${PKG_DIR}/debian"
fi

# Append our explicit deps. Reviewer-flagged (Sonnet iter 7): jq is NOT
# a gateway runtime dep — only documentdb-gateway-admin uses it, and
# that ships in documentdb-postgresql-tools. Per packaging-design.md
# §4.3 the gateway package has "no product-specific runtime dependency
# beyond the OS/runtime libraries that the binary links to". jq has
# been removed; openssl stays because the gateway's TLS auto-gen flow
# shells out to it when DOCUMENTDB_TLS_AUTO_GENERATE=true.
if [[ -n "${SHLIBDEPS}" ]]; then
    DEPENDS="${SHLIBDEPS}, openssl"
else
    DEPENDS="openssl"
fi

# ── Copyright ───────────────────────────────────────────────────────
# The gateway's own code is MIT (workspace Cargo.toml: license = "MIT").
# The statically-linked Rust dependencies include Apache-2.0 licensed
# components, so the package distributes code under both licenses. Ship
# both license texts in the single Debian copyright file; this mirrors
# the RPM spec, which %license-ships both LICENSE_MIT and
# LICENSE_Apache-2.0, and matches the "MIT AND Apache-2.0" package tag.
MIT_LICENSE="${REPO_ROOT}/pg_documentdb_gw/licenses/LICENSE_MIT"
APACHE_LICENSE="${REPO_ROOT}/pg_documentdb_gw/licenses/LICENSE_Apache-2.0"
[[ -f "${MIT_LICENSE}" ]] || die "license file not found: ${MIT_LICENSE}"
[[ -f "${APACHE_LICENSE}" ]] || die "license file not found: ${APACHE_LICENSE}"
{
    echo "Upstream-Name: documentdb-gateway"
    echo "Source: https://github.com/documentdb/documentdb"
    echo
    echo "Copyright (c) 2015-present Microsoft Corporation"
    echo
    echo "License: MIT AND Apache-2.0"
    echo
    echo "The gateway's own source is licensed under the MIT License. The"
    echo "compiled binary statically links third-party Rust dependencies"
    echo "licensed under the Apache License 2.0. Both license texts follow."
    echo
    echo "==================== MIT License (documentdb-gateway) ===================="
    echo
    cat "${MIT_LICENSE}"
    echo
    echo "============= Apache License 2.0 (bundled Rust dependencies) ============="
    echo
    cat "${APACHE_LICENSE}"
} > "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}/copyright"

# ── Control file ────────────────────────────────────────────────────
INSTALLED_SIZE=$(du -sk "${PKG_DIR}" | cut -f1)

# Deliberate deviation from packaging-design.md section 4.3 (which specifies
# per-major postgresql-N-documentdb): captured here so section 4.3 can be
# updated to match and stay the source of truth for parts 2-4 of the series.
# Reviewer-flagged (Sonnet iter 9): the previous Suggests included
# postgresql-18-documentdb, the same misleading pattern iter-8 removed
# from the tools package. On PG 15/16/17 hosts the gateway is
# PG-major-agnostic at the binary level, but apt would suggest the wrong
# extension. Suggest only documentdb-postgresql-tools (PG-agnostic admin
# helpers); the postinst message points the operator at the right
# per-major extension package.
cat > "${PKG_DIR}/DEBIAN/control" <<CONTROL
Package: ${DEB_PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: documentdb-packaging-maintainers@microsoft.com
Installed-Size: ${INSTALLED_SIZE}
Depends: ${DEPENDS}
Suggests: documentdb-postgresql-tools
Section: database
Priority: optional
Homepage: https://github.com/documentdb/documentdb
Description: DocumentDB wire-protocol gateway daemon
 The DocumentDB gateway provides wire-protocol compatibility, enabling
 connections from compatible clients and drivers. This is the lean
 runtime package; PostgreSQL-side helpers ship in documentdb-postgresql-tools.
CONTROL

# ── Build ───────────────────────────────────────────────────────────
mkdir -p "${OUTPUT_DIR}"
DEB_FILE="${OUTPUT_DIR}/${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb"
dpkg-deb --build --root-owner-group "${PKG_DIR}" "${DEB_FILE}"

echo "Built: ${DEB_FILE}"
echo "Contents:"
dpkg-deb -c "${DEB_FILE}" | awk '{print "  " $NF}' | grep -v '/$'
