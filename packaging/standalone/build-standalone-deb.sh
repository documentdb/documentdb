#!/bin/bash
# Build the documentdb-N DEB package — the per-major stand-alone
# package per packaging-design.md §4.4. It ships NO payload files: the shared,
# PG-agnostic payload (systemd template units, the documentdb-setup wizard,
# documentdb-local-reset, the private PG service helper, and sample data) is
# owned by documentdb-common. documentdb-N pins the PostgreSQL major + its
# extension and Hard-Depends on documentdb-common (>= the package version — a
# lockstep floor, not an exact pin; see the Depends: line and its rationale
# below), which in turn pulls documentdb-gateway + documentdb-postgresql-tools,
# so apt installs the full Workflow C stack. Per-major systemd instance
# management and per-major state cleanup live in this package's maintainer
# scripts.
#
# Usage:
#  build-standalone-deb.sh --version <ver> --pg-version <N> [--output-dir <dir>]

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Shared dpkg-deb scaffolding (emit_control / finalize_deb / deb_list_contents).
# shellcheck source=../deb-common.sh
source "${SCRIPT_DIR}/../deb-common.sh"

VERSION=""
PG_VERSION=""
OUTPUT_DIR="."

# die comes from deb-common.sh (sourced above).

usage() {
    cat <<'EOF'
Usage: build-standalone-deb.sh --version <ver> --pg-version <N> [--output-dir <dir>]

Build the documentdb-N stand-alone DEB package.

Required:
  --version VER       Package version (e.g., 0.114.0)
  --pg-version N      PostgreSQL major version this stand-alone targets (e.g., 18)

Optional:
  --output-dir DIR    Where to write the .deb (default: current dir)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="$2"; shift 2 ;;
        --pg-version) PG_VERSION="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${VERSION}" ]] || die "--version is required"
[[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "--pg-version must be a number (e.g., 18)"
(( PG_VERSION >= 16 )) || die "documentdb-${PG_VERSION} stand-alone requires PostgreSQL 16+: it wraps the gateway (Depends: documentdb-gateway), which requires PostgreSQL 16+. PostgreSQL 15 is supported for the extension only (use packaging/build_packages.sh --pg 15)."

ARCH="all"
DEB_PKG_NAME="documentdb-${PG_VERSION}"
FILE_PKG_NAME="documentdb-${PG_VERSION}"
PKG_DIR="$(mktemp -d)"
trap 'rm -rf "${PKG_DIR}"' EXIT

echo "Building ${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb ..."

# ── Directory structure ─────────────────────────────────────────────
# documentdb-N ships NO payload files. The shared, byte-identical payload
# (documentdb-setup / documentdb-local-reset, the systemd template units, the
# sysusers.d/tmpfiles.d drop-ins, the helper scripts, and the sample data) is
# owned once by documentdb-common (see Depends: below); shipping it from every
# per-major package caused a DEB shared-file ownership hazard on multi-major
# co-install. This package is the per-major dependency + maintainer-script
# owner: per-major systemd instance management (postinst/prerm) and per-major
# state cleanup (postrm) stay here.
install -d "${PKG_DIR}/DEBIAN"
install -d "${PKG_DIR}/usr/share/doc/${FILE_PKG_NAME}"

# ── Copyright + changelog ──────────────────────────────────────────
deb_install_mit_copyright "${PKG_DIR}" "${FILE_PKG_NAME}" "${REPO_ROOT}/LICENSE"
deb_install_changelog "${PKG_DIR}" "${FILE_PKG_NAME}" "${VERSION}" \
    "Initial documentdb-${PG_VERSION} stand-alone package."

# ── Control file ────────────────────────────────────────────────────
# The extension package's apt-version uses the DASHED form (e.g.
# "0.114-0", where 0.114 is the upstream version and 0 is the Debian
# revision) because debian/changelog uses that form. The standalone +
# gateway + tools DEBs use the DOTTED form (e.g. "0.114.0", a flat
# three-part version with no Debian revision).
#
# dpkg's version comparator treats these as DIFFERENT:
#  dpkg --compare-versions 0.114-0 ge 0.114.0 → FALSE
# because the upstream parts compare as 0.114 < 0.114.0.
#
# So `Depends: postgresql-N-documentdb (>= ${VERSION})` written with
# the dotted form REJECTS an installed extension at 0.114-0 with the
# infuriating "Some packages could not be installed... Requested an
# impossible situation" apt error.
#
# Fix: convert the dotted form to the dashed form when referencing
# the extension, leaving the dotted form for the standalone-owned
# gateway/tools peers (which all use the dotted form themselves).
# This script accepts either form on --version and normalizes here.
EXT_DEP_VERSION="${VERSION}"
if [[ "${VERSION}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    EXT_DEP_VERSION="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
fi

# Hard Depends:
#  - postgresql-N + postgresql-N-documentdb: the underlying PG + extension
#  (extension is referenced in its DASHED apt version — see above)
#  - documentdb-common (>= ${VERSION}): the PG-agnostic shared payload
#  (documentdb-setup, systemd template units, sysusers/tmpfiles, helper
#  scripts, sample data). documentdb-common in turn depends on
#  documentdb-gateway and documentdb-postgresql-tools, so the gateway/tools
#  runtime is pulled transitively and pinned in lockstep there (>= ${VERSION}
#  rather than an exact pin, so point-release upgrades where one DEB ships
#  before the others are not blocked, per design §4.4).
#
# documentdb-N ships no shared files itself, so there is NO cross-major
# Replaces: (it existed only to allow two majors to unpack byte-identical
# shared files side-by-side). Multiple majors now co-install cleanly because
# each only depends on the single shared-payload owner; removing one major
# never removes files a surviving major needs.
emit_control "${PKG_DIR}" <<CONTROL
Package: ${DEB_PKG_NAME}
Version: ${VERSION}
Architecture: ${ARCH}
Maintainer: ${DEB_MAINTAINER}
Installed-Size: @INSTALLED_SIZE@
Depends: postgresql-${PG_VERSION}, postgresql-${PG_VERSION}-documentdb (>= ${EXT_DEP_VERSION}), documentdb-common (>= ${VERSION})
Section: database
Priority: optional
Homepage: https://github.com/documentdb/documentdb
Description: DocumentDB stand-alone package for PostgreSQL ${PG_VERSION}
 Makes DocumentDB work on this machine with a single command. This per-major
 package pins PostgreSQL ${PG_VERSION} and its DocumentDB extension and owns
 the per-major systemd instance lifecycle (documentdb-postgresql@${PG_VERSION}.service
 + documentdb-gateway-local@${PG_VERSION}.service, wired via
 documentdb-local@${PG_VERSION}.target). The shared, PG-agnostic payload —
 including the documentdb-setup wizard that creates a fresh private PostgreSQL
 instance (greenfield) or adopts an existing one (brownfield) with
 backup-and-rollback safety — is provided by the documentdb-common dependency.
CONTROL

# ── Postinst (per-major systemd instance restart + next-steps banner) ─
# The PG-agnostic sysusers/tmpfiles bootstrap now lives in documentdb-common's
# postinst (it owns those drop-ins). documentdb-N Depends: documentdb-common,
# and dpkg configures the dependency first, so the documentdb-local user and
# runtime dirs already exist here. This postinst is per-major only: it restarts
# the active per-major gateway instance on upgrade and prints the setup banner
# on fresh install. Per design §6/§7 it never mutates PostgreSQL.
cat > "${PKG_DIR}/DEBIAN/postinst" <<POSTINST
#!/bin/bash
set -e

case "\$1" in
    configure)
        # Per packaging-design.md §6 "Restart active gateway service on
        # upgrade: documentdb-N install: Yes (gateway side only)": on an
        # upgrade (\$2 is the previously-installed version, empty on a
        # fresh install) restart only the per-major templated gateway-
        # local instance, not the per-major target, so we never restart
        # the underlying PostgreSQL service as a side effect of upgrading
        # the stand-alone wrapper. Maintainer scripts MUST NOT restart
        # PG per §7. If the gateway service isn't currently active we
        # leave the state untouched (matches Citus/pgvector convention).
        if [ -n "\${2:-}" ] && { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            gw_unit="documentdb-gateway-local@${PG_VERSION}.service"
            if systemctl is-active --quiet "\${gw_unit}" 2>/dev/null; then
                systemctl restart "\${gw_unit}" 2>/dev/null || \\
                    echo "WARNING: failed to restart \${gw_unit} after upgrade." >&2
            fi
        fi

        if [ -z "\${2:-}" ]; then
            # On a fresh install, advertise the next steps for this
            # per-major standalone — BUT suppress when the documentdb
            # meta package is also being installed in the same dpkg
            # transaction (it will print its own "Next steps" right
            # after us, and its advice uses the public alias target,
            # which is the recommended user-facing form). Without this
            # suppression, \`apt install documentdb\` prints two near-
            # identical "Next steps" banners.
            meta_in_transaction=false
            if command -v dpkg-query >/dev/null 2>&1; then
                meta_status=\$(dpkg-query -W -f='\${db:Status-Status}\\n' documentdb 2>/dev/null || true)
                # Only mid-transaction states count. dpkg configures
                # dependencies first, so while this per-major postinst
                # runs, a meta being installed in the SAME transaction is
                # still unpacked/half-configured/etc. A status of
                # "installed" means the meta was configured in an EARLIER
                # transaction — its postinst will NOT run again now, so
                # suppressing our banner then would leave the user with no
                # guidance at all.
                case "\${meta_status}" in
                    half-installed|unpacked|half-configured|triggers-awaited|triggers-pending)
                        meta_in_transaction=true
                        ;;
                esac
            fi

            if [ "\${meta_in_transaction}" = "true" ]; then
                echo "DocumentDB stand-alone package for PostgreSQL ${PG_VERSION} installed."
                echo "(The 'documentdb' meta package will print the recommended setup steps.)"
            else
                echo "DocumentDB stand-alone package for PostgreSQL ${PG_VERSION} installed."
                echo ""
                # wizard auto-enables the
                # target — second command was redundant. Single step.
                echo "Next: sudo documentdb-setup --admin-user admin --pg-version ${PG_VERSION}"
                echo "(The wizard prompts for the first admin password, runs initdb / CREATE EXTENSION /"
                echo "first-user bootstrap, and enables documentdb-local@${PG_VERSION}.target so the stack survives reboot.)"
            fi
        fi
        ;;
esac

exit 0
POSTINST
chmod 0755 "${PKG_DIR}/DEBIAN/postinst"

# ── Prerm: stop and disable the per-major target before file removal ─
#
# The RPM spec already has
# a %preun block that stops + disables documentdb-local@N.target on
# remove (but NOT on upgrade). The DEB equivalent was missing —
# `apt remove`/`apt purge` would unlink the unit files and config
# while the per-major target and its child services were still
# running. systemd then has stale active units pointing at deleted
# unit files. Mirror the RPM behavior: stop + disable on the actual
# remove invocation (Debian prerm $1 is "remove" / "upgrade" /
# "deconfigure" / "failed-upgrade"; skip the upgrade-side branches
# so package upgrades do not flap services).
cat > "${PKG_DIR}/DEBIAN/prerm" <<PRERM
#!/bin/bash
set -e

case "\$1" in
    remove)
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl stop "documentdb-local@${PG_VERSION}.target" 2>/dev/null || true
            systemctl disable "documentdb-local@${PG_VERSION}.target" 2>/dev/null || true
        fi
        ;;
esac

exit 0
PRERM
chmod 0755 "${PKG_DIR}/DEBIAN/prerm"

# ── Postrm: strip the wizard's per-major managed blocks on purge ────
#
# The original implementation walked
# /etc/documentdb/local/*/ across all majors, so purging one
# documentdb-N package would clean state for ALL co-installed majors.
# The design (§4.4 "Co-installable across majors") explicitly supports
# documentdb-18 and documentdb-19 side-by-side. The postrm is now scoped
# to this package's own ${PG_VERSION} by substituting a placeholder
# after the heredoc.
cat > "${PKG_DIR}/DEBIAN/postrm" <<'POSTRM'
#!/bin/bash
set -e

# This is the documentdb-__PG_VERSION__ postrm. Scope all cleanup to PG
# major __PG_VERSION__ so a side-by-side documentdb-N install for a
# different major is not disturbed by purging this one.
PKG_PG_VERSION='__PG_VERSION__'

# Per packaging-design.md §4.3: the stand-alone package is the owner
# of the per-major DocumentDB integration on this host. On purge we
# strip the documentdb-setup managed blocks from the underlying
# PostgreSQL instance's config files (greenfield + brownfield),
# remove the per-major state and gateway env fragment, and clear the
# connection URL file from tmpfs. PostgreSQL data, in-database
# content, and the system PostgreSQL service config are preserved.

documentdb_strip_managed_block() {
    target_file="$1"
    block_start="$2"
    block_end="$3"
    [ -f "${target_file}" ] || return 0
    grep -Fqx "${block_start}" "${target_file}" 2>/dev/null || return 0
    if ! grep -Fqx "${block_end}" "${target_file}" 2>/dev/null; then
        echo "documentdb postrm: refusing to strip managed block in ${target_file}: end marker missing." >&2
        return 0
    fi
    temp_file="$(mktemp "${target_file}.documentdb-cleanup.XXXXXX")" || return 0
    if ! awk -v start="${block_start}" -v end="${block_end}" '
            $0 == start { skip = 1; next }
            $0 == end   { skip = 0; next }
            !skip       { print }
        ' "${target_file}" > "${temp_file}"; then
        rm -f "${temp_file}"
        return 0
    fi
    chown --reference="${target_file}" "${temp_file}" 2>/dev/null || true
    chmod --reference="${target_file}" "${temp_file}" 2>/dev/null || true
    mv "${temp_file}" "${target_file}"
}

documentdb_restore_debian_tune_fragment() {
    config_file="$1"
    target_cluster="${2:-}"
    tune_pgver=""
    tune_cluster=""

    if [[ "${target_cluster}" =~ ^([0-9]+)/([A-Za-z0-9][A-Za-z0-9_-]*)$ ]]; then
        tune_pgver="${BASH_REMATCH[1]}"
        tune_cluster="${BASH_REMATCH[2]}"
    elif [[ "${config_file}" =~ ^/etc/postgresql/([0-9]+)/([A-Za-z0-9][A-Za-z0-9_-]*)/postgresql\.conf$ ]]; then
        tune_pgver="${BASH_REMATCH[1]}"
        tune_cluster="${BASH_REMATCH[2]}"
    else
        return 0
    fi

    [ "${tune_pgver}" = "${PKG_PG_VERSION}" ] || return 0

    live_conf="/etc/postgresql/${tune_pgver}/${tune_cluster}/postgresql.conf"
    fragment_dir="/etc/postgresql-common/documentdb/${tune_pgver}/${tune_cluster}"
    fragment_file="${fragment_dir}/documentdb.conf"

    documentdb_strip_managed_block "${live_conf}" \
        "# >>> documentdb-tune managed include >>>" \
        "# <<< documentdb-tune managed include <<<"
    rm -f "${fragment_file}" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "${fragment_dir}" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "/etc/postgresql-common/documentdb/${tune_pgver}" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "/etc/postgresql-common/documentdb" 2>/dev/null || true
}

case "$1" in
    purge)
        for sf in "/etc/documentdb/local/${PKG_PG_VERSION}/setup.conf" \
                  "/etc/documentdb/local/${PKG_PG_VERSION}/brownfield.conf" \
                  "/etc/documentdb/local/${PKG_PG_VERSION}/gateway-setup.state"; do
            [ -r "${sf}" ] || continue
            hba_file="$(grep -E '^HBA_FILE=' "${sf}" | head -1 | cut -d= -f2- || true)"
            ident_file="$(grep -E '^IDENT_FILE=' "${sf}" | head -1 | cut -d= -f2- || true)"
            config_file="$(grep -E '^CONFIG_FILE=' "${sf}" | head -1 | cut -d= -f2- || true)"
            target_cluster="$(grep -E '^TARGET_CLUSTER=' "${sf}" | head -1 | cut -d= -f2- || true)"
            [ -n "${hba_file}" ] && documentdb_strip_managed_block "${hba_file}" \
                "# >>> documentdb-setup managed hba >>>" \
                "# <<< documentdb-setup managed hba <<<"
            [ -n "${ident_file}" ] && documentdb_strip_managed_block "${ident_file}" \
                "# >>> documentdb-setup managed pg_ident >>>" \
                "# <<< documentdb-setup managed pg_ident <<<"
            [ -n "${config_file}" ] && documentdb_strip_managed_block "${config_file}" \
                "# >>> documentdb-setup managed configuration >>>" \
                "# <<< documentdb-setup managed configuration <<<"
            [ -n "${config_file}" ] && documentdb_strip_managed_block "${config_file}" \
                "# >>> documentdb-setup managed listen >>>" \
                "# <<< documentdb-setup managed listen <<<"
            # Debian brownfield: documentdb-tune writes a per-cluster fragment
            # under /etc/postgresql-common/documentdb/<V>/<C>/documentdb.conf
            # plus a managed include block in the live postgresql.conf. The
            # tools package may already be removed by the time `apt purge
            # documentdb-N` runs, so postrm must clean this state itself.
            documentdb_restore_debian_tune_fragment "${config_file}" "${target_cluster}" || true
            state_dir="$(dirname "${sf}")"
            env_file="${state_dir}/gateway.env"
            if [ -f "${env_file}" ]; then
                documentdb_strip_managed_block "${env_file}" \
                    "# >>> documentdb-register-gateway managed env >>>" \
                    "# <<< documentdb-register-gateway managed env <<<"
                grep -q '[^[:space:]]' "${env_file}" 2>/dev/null || rm -f "${env_file}" 2>/dev/null || true
            fi
            rm -f "${sf}"
            rmdir --ignore-fail-on-non-empty "${state_dir}" 2>/dev/null || true
        done

        # Per-major orphan sweep (scoped to this package's PG major).
        # Catches files left behind by an earlier --restore that removed
        # the state-file pointer. Side-by-side installs for other majors
        # are NOT touched.
        dropin_dir="/etc/systemd/system/documentdb-gateway-local@${PKG_PG_VERSION}.service.d"
        if [ -d "${dropin_dir}" ]; then
            brownfield_file="${dropin_dir}/brownfield.conf"
            if [ -f "${brownfield_file}" ] && \
                    grep -Fq "# Generated by documentdb-setup --target-postgres-instance" \
                    "${brownfield_file}" 2>/dev/null; then
                rm -f "${brownfield_file}"
            fi
            rmdir --ignore-fail-on-non-empty "${dropin_dir}" 2>/dev/null || true
        fi
        per_major_env="/etc/documentdb/local/${PKG_PG_VERSION}/gateway.env"
        if [ -f "${per_major_env}" ]; then
            documentdb_strip_managed_block "${per_major_env}" \
                "# >>> documentdb-register-gateway managed env >>>" \
                "# <<< documentdb-register-gateway managed env <<<"
            grep -q '[^[:space:]]' "${per_major_env}" 2>/dev/null || rm -f "${per_major_env}" 2>/dev/null || true
        fi
        rmdir --ignore-fail-on-non-empty "/etc/documentdb/local/${PKG_PG_VERSION}" 2>/dev/null || true
        # Pg-url moved from tmpfs /run
        # to persistent /var/lib so it survives reboot. Clean BOTH paths
        # So upgrades from legacy installs don't leak the legacy file.
        rm -f "/run/documentdb-local/${PKG_PG_VERSION}/gateway/pg-url" 2>/dev/null || true
        rm -f "/var/lib/documentdb-local/${PKG_PG_VERSION}/gateway/pg-url" 2>/dev/null || true

        # The legacy host-level state file
        # /etc/documentdb/documentdb-postgresql.env (written by
        # documentdb-setup's read_persisted_managed_data_dir flow) was
        # never cleaned by purge. It's shared across all majors, so we
        # only remove it when no other documentdb-N is still installed
        # (detected by checking whether any other per-major state file
        # remains under /etc/documentdb/local/*/).
        if [ -f "/etc/documentdb/documentdb-postgresql.env" ]; then
            other_majors_remain=false
            for other_state in /etc/documentdb/local/*/setup.conf \
                               /etc/documentdb/local/*/brownfield.conf; do
                if [ -r "${other_state}" ]; then
                    other_majors_remain=true
                    break
                fi
            done
            if [ "${other_majors_remain}" = "false" ]; then
                rm -f /etc/documentdb/documentdb-postgresql.env
            fi
        fi

        # Only collapse the top-level /etc/documentdb/local and /etc/documentdb
        # dirs if THIS package was the last per-major install on the host —
        # rmdir --ignore-fail-on-non-empty does that safely (succeeds only
        # when empty), so side-by-side majors keep their state intact.
        rmdir --ignore-fail-on-non-empty /etc/documentdb/local 2>/dev/null || true
        rmdir --ignore-fail-on-non-empty /etc/documentdb 2>/dev/null || true
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi
        ;;
    remove|disappear|upgrade|failed-upgrade|abort-install|abort-upgrade)
        if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
            systemctl daemon-reload 2>/dev/null || true
        fi
        ;;
esac

exit 0
POSTRM
# Now substitute the placeholder with the package's PG major. Use a
# delimiter that can't appear in version strings. Filter to a temp file and
# move it back rather than editing in place, whose backup-suffix handling
# differs between GNU and BSD/macOS `sed` — keeping the host-run builder
# portable. Guard the substitution with `|| die` so a failed sed is
# fail-closed (a bare `&& mv` would let set -e fall through and package an
# unsubstituted postrm).
sed "s|__PG_VERSION__|${PG_VERSION}|g" "${PKG_DIR}/DEBIAN/postrm" > "${PKG_DIR}/DEBIAN/postrm.tmp" \
    || die "failed to substitute __PG_VERSION__ in the generated postrm"
mv "${PKG_DIR}/DEBIAN/postrm.tmp" "${PKG_DIR}/DEBIAN/postrm"
chmod 0755 "${PKG_DIR}/DEBIAN/postrm"

# ── Build ───────────────────────────────────────────────────────────
DEB_FILE="${OUTPUT_DIR}/${FILE_PKG_NAME}_${VERSION}_${ARCH}.deb"
finalize_deb "${PKG_DIR}" "${DEB_FILE}"
deb_list_contents "${DEB_FILE}"
