#!/bin/bash
# Build the documentdb-common DEB package — the PG-agnostic shared payload
# for the stand-alone product per packaging-design.md §4.4.
#
# Every per-major documentdb-N package ships the SAME byte-identical files:
# the documentdb-setup / documentdb-local-reset CLIs, the systemd *template*
# units (documentdb-local@.target, documentdb-postgresql@.service,
# documentdb-gateway-local@.service — the PG major is the systemd instance
# parameter, so the unit files themselves are major-agnostic), the sysusers.d
# and tmpfiles.d drop-ins, the helper scripts the units consume, and the
# sample data. Shipping them from every documentdb-N created a shared-file
# ownership hazard on DEB: co-installing two majors and then removing the
# later-installed one deleted these files while the surviving major still
# needed them (dpkg has no cross-package refcount for identically-pathed
# files declared with Replaces:).
#
# documentdb-common owns that shared payload exactly once. Each documentdb-N
# depends on it and ships none of these files, so removing one major never
# removes files the surviving major relies on; the shared payload is removed
# only when the last documentdb-N is gone and apt autoremoves documentdb-common.
#
# This package is PG-agnostic (arch:all) and carries the PG-agnostic
# system-user / runtime-directory bootstrap (sysusers.d + tmpfiles.d) in its
# postinst. Per-major systemd instance management and per-major state cleanup
# stay in the documentdb-N maintainer scripts.
#
# Usage:
#  build-common-deb.sh --version <version> [--output-dir <dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Shared dpkg-deb scaffolding (emit_control / finalize_deb / deb_list_contents).
# shellcheck source=../deb-common.sh
source "${SCRIPT_DIR}/../deb-common.sh"

VERSION=""
OUTPUT_DIR="."

# die comes from deb-common.sh (sourced above).

usage() {
    cat <<'EOF'
Usage: build-common-deb.sh --version <ver> [--output-dir <dir>]

Build the documentdb-common DEB package (PG-agnostic shared payload).

Required:
  --version VER      Package version (e.g., 0.114.0)

Optional:
  --output-dir DIR   Where to write the .deb (default: current dir)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) [[ $# -ge 2 ]] || die "--version requires a value."; VERSION="$2"; shift 2 ;;
        --output-dir) [[ $# -ge 2 ]] || die "--output-dir requires a value."; OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${VERSION}" ]] || die "--version is required"

ARCH="all"
DEB_PKG_NAME="documentdb-common"
FILE_PKG_NAME="documentdb-common"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${PKG_DIR}"' EXIT

echo "Building ${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb ..."

# ── Directory structure ─────────────────────────────────────────────
install -d "${PKG_DIR}/DEBIAN"
install -d "${PKG_DIR}/usr/bin"
# Install systemd units under /usr/lib/systemd/system (the canonical
# usr-merged location), matching the documentdb-gateway DEB and the RPM spec.
install -d "${PKG_DIR}/usr/lib/systemd/system"
install -d "${PKG_DIR}/usr/lib/sysusers.d"
install -d "${PKG_DIR}/usr/lib/tmpfiles.d"
install -d "${PKG_DIR}/usr/share/documentdb/scripts"
install -d "${PKG_DIR}/usr/share/documentdb/sample-data"
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}"

# ── CLIs ────────────────────────────────────────────────────────────
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb-setup.sh" \
    "${PKG_DIR}/usr/bin/documentdb-setup"
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb-local-reset.sh" \
    "${PKG_DIR}/usr/bin/documentdb-local-reset"

# ── systemd template units + sysusers/tmpfiles ──────────────────────
install -m 0644 "${REPO_ROOT}/packaging/appliance/systemd/documentdb-local@.target" \
    "${PKG_DIR}/usr/lib/systemd/system/documentdb-local@.target"
install -m 0644 "${REPO_ROOT}/packaging/appliance/systemd/documentdb-postgresql@.service" \
    "${PKG_DIR}/usr/lib/systemd/system/documentdb-postgresql@.service"
install -m 0644 "${REPO_ROOT}/packaging/appliance/systemd/documentdb-gateway-local@.service" \
    "${PKG_DIR}/usr/lib/systemd/system/documentdb-gateway-local@.service"
install -m 0644 "${REPO_ROOT}/packaging/appliance/sysusers/documentdb-local.conf" \
    "${PKG_DIR}/usr/lib/sysusers.d/documentdb-local.conf"
install -m 0644 "${REPO_ROOT}/packaging/appliance/tmpfiles/documentdb-local.conf" \
    "${PKG_DIR}/usr/lib/tmpfiles.d/documentdb-local.conf"

# ── Helper scripts (consumed by the systemd template units) ─────────
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/documentdb_postgresql_service.sh" \
    "${PKG_DIR}/usr/share/documentdb/scripts/documentdb_postgresql_service.sh"
install -m 0755 "${REPO_ROOT}/documentdb-local/scripts/init_documentdb_data.sh" \
    "${PKG_DIR}/usr/share/documentdb/scripts/init_documentdb_data.sh"

# ── Sample data ─────────────────────────────────────────────────────
for sd in "${REPO_ROOT}/documentdb-local/sample-data/"*; do
    [[ -f "${sd}" ]] || continue
    install -m 0644 "${sd}" "${PKG_DIR}/usr/share/documentdb/sample-data/"
done

# ── Copyright + changelog ──────────────────────────────────────────
deb_install_mit_copyright "${PKG_DIR}" "${FILE_PKG_NAME}" "${REPO_ROOT}/LICENSE"
deb_install_changelog "${PKG_DIR}" "${FILE_PKG_NAME}" "${VERSION}" \
    "Initial documentdb-common shared-payload package."

# ── Control file ────────────────────────────────────────────────────
# documentdb-common owns documentdb-setup, which delegates to documentdb-tune
# and documentdb-register-gateway (documentdb-postgresql-tools) and drives the
# gateway runtime, so the PG-agnostic runtime dependencies live here (moved
# from the per-major documentdb-N packages). The per-major documentdb-N pins
# the PostgreSQL major + extension and depends on this package.
#
# Replaces: implements the standard Debian "file takeover" idiom for the shared
# files that a PRE-SPLIT documentdb-N used to ship at these same paths. Without
# it, `dpkg` refuses to unpack documentdb-common while an older documentdb-N
# still owns e.g. /usr/bin/documentdb-setup ("trying to overwrite ... which is
# also in package documentdb-N"). It is unversioned so the takeover works
# regardless of the old package's version, and it is inert for the post-split
# documentdb-N (which ships no files at all). The pre-split documentdb-N was
# never released, so Replaces: is inert for real first-time installs and only
# smooths an in-place upgrade from a pre-split dev/CI build.
#
# We intentionally do NOT add a matching Breaks:. A rolling
# `Breaks: documentdb-N (<< ${VERSION}~)` would forbid a newer documentdb-common
# from coexisting with a slightly older documentdb-N, which contradicts the
# `Depends: documentdb-common (>= ${VERSION})` floor above — that floor is
# deliberately a lower bound (not an exact pin), so the packages tolerate a
# staggered point release where they ship a short time apart. Replaces: alone is
# sufficient to transfer file ownership (dpkg permits the overwrite and the old
# owner is upgraded to the payload-free version in the same run).
emit_control "${PKG_DIR}" <<CONTROL
Package: ${DEB_PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: ${DEB_MAINTAINER}
Installed-Size: @INSTALLED_SIZE@
Depends: documentdb-postgresql-tools (>= ${VERSION}), documentdb-gateway (>= ${VERSION}), jq
Replaces: documentdb-16, documentdb-17, documentdb-18
Section: database
Priority: optional
Homepage: https://github.com/documentdb/documentdb
Description: DocumentDB stand-alone shared payload (PG-agnostic)
 Shared, PostgreSQL-major-agnostic payload for the DocumentDB stand-alone
 packages: the documentdb-setup wizard, documentdb-local-reset, the systemd
 template units (documentdb-local@.target, documentdb-postgresql@.service,
 documentdb-gateway-local@.service), the sysusers.d and tmpfiles.d drop-ins,
 the helper scripts those units consume, and the sample data. Each per-major
 documentdb-N package depends on this package, so the shared payload is owned
 exactly once regardless of how many PostgreSQL majors are installed.
CONTROL

# ── Postinst (sysusers/tmpfiles bootstrap; per design §6 no PG mutation) ─
# This PG-agnostic bootstrap moved here from documentdb-N: documentdb-common
# owns the sysusers.d/tmpfiles.d drop-ins, so it is the correct owner of the
# system-user / runtime-directory creation. dpkg configures this package
# before any documentdb-N that depends on it, so the documentdb-local user and
# runtime dirs exist before a per-major package's postinst runs.
cat > "${PKG_DIR}/DEBIAN/postinst" <<'POSTINST'
#!/bin/bash
set -e

case "$1" in
    configure)
        # Create the system user via systemd-sysusers when it is present and
        # succeeds; otherwise fall back to a single manual groupadd/useradd copy
        # (the fallback also covers the "systemd-sysusers absent" case).
        if ! { command -v systemd-sysusers >/dev/null 2>&1 \
                && systemd-sysusers /usr/lib/sysusers.d/documentdb-local.conf 2>/dev/null; }; then
            if ! getent group documentdb-local >/dev/null 2>&1; then
                groupadd --system documentdb-local
            fi
            if ! id -u documentdb-local >/dev/null 2>&1; then
                NOLOGIN=$(command -v nologin 2>/dev/null || echo /usr/sbin/nologin)
                useradd --system --home-dir /var/lib/documentdb-local --shell "${NOLOGIN}" --gid documentdb-local documentdb-local
            fi
        fi
        # Create the runtime directories via systemd-tmpfiles when it is present
        # and succeeds; otherwise fall back to a single manual install -d copy.
        if ! { command -v systemd-tmpfiles >/dev/null 2>&1 \
                && systemd-tmpfiles --create /usr/lib/tmpfiles.d/documentdb-local.conf 2>/dev/null; }; then
            install -d -m 0755 -o documentdb-local -g documentdb-local /var/lib/documentdb-local
            install -d -m 0755 -o documentdb-local -g documentdb-local /run/documentdb-local
            install -d -m 0755 -o documentdb-local -g documentdb-local /var/log/documentdb-local
        fi
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi
        ;;
esac

exit 0
POSTINST
chmod 0755 "${PKG_DIR}/DEBIAN/postinst"

# ── Postrm: reload systemd after the template units are removed ─────
# On remove/purge dpkg unlinks the shipped template units; ask systemd to
# reload so it no longer references the deleted unit files. The documentdb-local
# system user and /var/lib/documentdb-local (which may hold private PostgreSQL
# data in greenfield installs) are intentionally left in place, matching the
# per-major packages' data-preservation behavior.
cat > "${PKG_DIR}/DEBIAN/postrm" <<'POSTRM'
#!/bin/bash
set -e

case "$1" in
    remove|purge)
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi
        ;;
esac

exit 0
POSTRM
chmod 0755 "${PKG_DIR}/DEBIAN/postrm"

# ── Build ───────────────────────────────────────────────────────────
DEB_FILE="${OUTPUT_DIR}/${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb"
finalize_deb "${PKG_DIR}" "${DEB_FILE}"
deb_list_contents "${DEB_FILE}"
