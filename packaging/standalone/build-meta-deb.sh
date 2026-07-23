#!/bin/bash
# Build the documentdb meta DEB package per packaging-design.md §4.4.
# The meta package depends on the paved-road per-major package
# (documentdb-18 by default) and owns the public systemd alias
# documentdb-local.target → documentdb-local@${default_pg_major}.target.
#
# Usage:
#  build-meta-deb.sh --version <ver> [--default-pg-major 18] [--output-dir <dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Shared dpkg-deb scaffolding (emit_control / finalize_deb / deb_list_contents).
# shellcheck source=../deb-common.sh
source "${SCRIPT_DIR}/../deb-common.sh"

VERSION=""
DEFAULT_PG_MAJOR="18"
OUTPUT_DIR="."

# die comes from deb-common.sh (sourced above).

usage() {
    cat <<'EOF'
Usage: build-meta-deb.sh --version <ver> [--default-pg-major 18] [--output-dir <dir>]

Build the documentdb meta DEB package. The meta package pins to one
PostgreSQL major (paved-road default = 18) and installs the
documentdb-local.target alias on its postinst.

Required:
  --version VER          Package version (e.g., 0.114.0)

Optional:
  --default-pg-major N   PostgreSQL major to pin (default: 18)
  --output-dir DIR       Where to write the .deb (default: current dir)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --default-pg-major) DEFAULT_PG_MAJOR="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${VERSION}" ]] || die "--version is required"
[[ "${DEFAULT_PG_MAJOR}" =~ ^[0-9]+$ ]] || die "--default-pg-major must be a number (e.g., 18)"
(( DEFAULT_PG_MAJOR >= 16 )) || die "the documentdb meta package pins the paved-road default major to documentdb-${DEFAULT_PG_MAJOR}, which wraps the gateway and requires PostgreSQL 16+. PostgreSQL 15 is supported for the extension only."

ARCH="all"
DEB_PKG_NAME="documentdb"
FILE_PKG_NAME="documentdb"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${PKG_DIR}"' EXIT

echo "Building ${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb (pinned to documentdb-${DEFAULT_PG_MAJOR}) ..."

install -d "${PKG_DIR}/DEBIAN"
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}"

deb_install_mit_copyright "${PKG_DIR}" "${FILE_PKG_NAME}"
deb_install_changelog "${PKG_DIR}" "${FILE_PKG_NAME}" "${VERSION}" \
    "Initial documentdb meta package."

emit_control "${PKG_DIR}" <<CONTROL
Package: ${DEB_PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: ${DEB_MAINTAINER}
Installed-Size: @INSTALLED_SIZE@
Depends: documentdb-${DEFAULT_PG_MAJOR} (>= ${VERSION})
Section: database
Priority: optional
Homepage: https://github.com/documentdb/documentdb
Description: Stand-alone meta package for DocumentDB
 The recommended install target for new users:
 .
   sudo apt install documentdb
 .
 Pulls the paved-road combination (PostgreSQL ${DEFAULT_PG_MAJOR} +
 documentdb-${DEFAULT_PG_MAJOR} + documentdb-gateway +
 documentdb-postgresql-tools) and installs the public systemd alias
 documentdb-local.target -> documentdb-local@${DEFAULT_PG_MAJOR}.target.
 .
 To fully uninstall, run:
 .
   sudo apt purge documentdb documentdb-${DEFAULT_PG_MAJOR} documentdb-common \\
       documentdb-gateway documentdb-postgresql-tools
 .
 'apt purge documentdb' alone only removes this meta package; the
 per-major stand-alone package, the gateway runtime, and the
 administrator tools remain installed.
CONTROL

# Postinst installs the public alias so `systemctl enable --now
# documentdb-local.target` Just Works (per design §1 "What done looks like").
#
# A plain `Requires=` wrapper unit does
# NOT propagate stop/restart from the wrapper to the per-major target.
# `systemctl stop documentdb-local.target` would leave the appliance
# running. The fix is to install a drop-in on the per-major target
# itself that declares `PartOf=documentdb-local.target` — PartOf
# propagates stop/restart from a parent target to its child units.
# Combined with the wrapper's `Requires=` for start-time pull-in, this
# gives the alias the full start/stop/restart/status semantics the
# design promises.
cat > "${PKG_DIR}/DEBIAN/postinst" <<POSTINST
#!/bin/bash
set -e

DEFAULT_PG_MAJOR="${DEFAULT_PG_MAJOR}"

case "\$1" in
    configure)
        install -d -m 0755 /etc/systemd/system

        # Wrapper unit: start of this pulls in the per-major target
        # via Requires=. PartOf= cannot live here because PartOf
        # propagates FROM the named unit TO this one (wrong
        # direction); the inverse direction lives in the per-major
        # drop-in below.
        cat > /etc/systemd/system/documentdb-local.target <<DROPIN
[Unit]
Description=DocumentDB Local Appliance (alias to documentdb-local@\${DEFAULT_PG_MAJOR}.target)
Requires=documentdb-local@\${DEFAULT_PG_MAJOR}.target
After=documentdb-local@\${DEFAULT_PG_MAJOR}.target

[Install]
WantedBy=multi-user.target
DROPIN

        # Sweep stale meta-owned drop-ins before writing the current one.
        # The glob includes the current major too, so reversing this
        # order would delete the file we just created.
        for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do
            [ -e "\$dropin" ] || [ -L "\$dropin" ] || continue
            instance=\${dropin#/etc/systemd/system/documentdb-local@}
            instance=\${instance%.target.d/wrapper-partof.conf}
            case "\$instance" in
                ''|*[!0-9]*) continue ;;
            esac
            if grep -Fq '# Managed-by: documentdb-meta-package' "\$dropin" 2>/dev/null || \\
               { grep -Fq 'Installed by the documentdb meta' "\$dropin" 2>/dev/null && \\
                 grep -Fxq 'PartOf=documentdb-local.target' "\$dropin" 2>/dev/null; }; then
                dropin_dir=\${dropin%/wrapper-partof.conf}
                rm -f "\$dropin" 2>/dev/null || true
                rmdir --ignore-fail-on-non-empty "\$dropin_dir" 2>/dev/null || true
            fi
        done

        # Stop-propagation drop-in on the per-major target. Without
        # this, \`systemctl stop documentdb-local.target\` leaves
        # documentdb-local@\${DEFAULT_PG_MAJOR}.target running. With
        # PartOf= on the per-major target, stopping the wrapper also
        # stops the appliance (the design's documented day-2
        # surface). The drop-in lives under /etc/systemd/system so
        # package upgrades don't overwrite it. See packaging-design.md §8.
        install -d -m 0755 /etc/systemd/system/documentdb-local@\${DEFAULT_PG_MAJOR}.target.d
        cat > /etc/systemd/system/documentdb-local@\${DEFAULT_PG_MAJOR}.target.d/wrapper-partof.conf <<DROPIN2
[Unit]
# Managed-by: documentdb-meta-package
# Propagate stop/restart from the public documentdb-local.target alias
# down to this per-major instance. Installed by the documentdb meta
# package's postinst. Removed on purge.
PartOf=documentdb-local.target
DROPIN2

        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi
        echo "DocumentDB meta package installed (paved-road: PostgreSQL \${DEFAULT_PG_MAJOR})."
        echo ""
        # The wizard now enables the
        # documentdb-local target at boot itself, so the "systemctl enable
        # --now documentdb-local.target" follow-up is redundant. Single
        # step ⇒ less confusion.
        echo "Next: sudo documentdb-setup --admin-user admin"
        echo "(The wizard prompts for the first admin password, runs initdb / CREATE EXTENSION /"
        echo "first-user bootstrap, and enables documentdb-local.target so the stack survives reboot."
        echo "Pass --no-enable to defer the start-at-boot step.)"
        echo ""
        echo "When the wizard finishes, connect via mongosh:"
        echo "  mongosh 'mongodb://admin:<password>@127.0.0.1:10260/mydb?tls=true&tlsAllowInvalidCertificates=true'"
        echo "  (Replace <password> with the admin password you set during setup.)"
        ;;
esac

exit 0
POSTINST
chmod 0755 "${PKG_DIR}/DEBIAN/postinst"

cat > "${PKG_DIR}/DEBIAN/postrm" <<POSTRM
#!/bin/bash
set -e

DEFAULT_PG_MAJOR="${DEFAULT_PG_MAJOR}"

case "\$1" in
    purge|remove)
        if command -v systemctl >/dev/null 2>&1; then
            # Disable before deleting the unit; systemctl reads [Install]
            # metadata from the unit file to locate enablement symlinks.
            systemctl disable documentdb-local.target >/dev/null 2>&1 || true
        fi
        rm -f /etc/systemd/system/multi-user.target.wants/documentdb-local.target 2>/dev/null || true
        rm -f /etc/systemd/system/documentdb-local.target 2>/dev/null || true
        # Remove all meta-owned stop-propagation drop-ins, including
        # stale ones left behind by future default-major changes.
        for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do
            [ -e "\$dropin" ] || [ -L "\$dropin" ] || continue
            instance=\${dropin#/etc/systemd/system/documentdb-local@}
            instance=\${instance%.target.d/wrapper-partof.conf}
            case "\$instance" in
                ''|*[!0-9]*) continue ;;
            esac
            if grep -Fq '# Managed-by: documentdb-meta-package' "\$dropin" 2>/dev/null || \\
               { grep -Fq 'Installed by the documentdb meta' "\$dropin" 2>/dev/null && \\
                 grep -Fxq 'PartOf=documentdb-local.target' "\$dropin" 2>/dev/null; }; then
                dropin_dir=\${dropin%/wrapper-partof.conf}
                rm -f "\$dropin" 2>/dev/null || true
                rmdir --ignore-fail-on-non-empty "\$dropin_dir" 2>/dev/null || true
            fi
        done
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi

        # Remind the operator that purging the meta only removes the
        # alias; the actual stand-alone stack, gateway, and tools are
        # separate packages and are still installed (or held in
        # "config-files" state) until purged explicitly. Without this,
        # an operator who runs \`apt purge documentdb\` assuming a full
        # wipe is surprised to find the gateway service still running.
        remaining_pkgs=""
        for pkg in "documentdb-\${DEFAULT_PG_MAJOR}" \\
                   "documentdb-common" \\
                   "documentdb-gateway" \\
                   "documentdb-postgresql-tools"; do
            status=\$(dpkg-query -W -f='\${db:Status-Status}\\n' "\$pkg" 2>/dev/null || true)
            case "\$status" in
                installed|half-installed|unpacked|half-configured|triggers-awaited|triggers-pending|config-files)
                    remaining_pkgs="\${remaining_pkgs} \$pkg"
                    ;;
            esac
        done
        if [ -n "\${remaining_pkgs}" ]; then
            echo ""
            echo "Note: removing the 'documentdb' meta package only removed the"
            echo "public 'documentdb-local.target' alias. The following packages"
            echo "are still installed on this host:"
            for pkg in \${remaining_pkgs}; do
                echo "  - \${pkg}"
            done
            echo ""
            echo "To fully uninstall DocumentDB, run:"
            echo "  sudo apt purge\${remaining_pkgs}"
            echo ""
            echo "PostgreSQL data directories under /var/lib/documentdb-local/"
            echo "are preserved across purge; use documentdb-local-reset to wipe"
            echo "them when intended."
        fi
        ;;
esac

exit 0
POSTRM
chmod 0755 "${PKG_DIR}/DEBIAN/postrm"

DEB_FILE="${OUTPUT_DIR}/${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb"
finalize_deb "${PKG_DIR}" "${DEB_FILE}"
echo "Depends: documentdb-${DEFAULT_PG_MAJOR} (>= ${VERSION})"
