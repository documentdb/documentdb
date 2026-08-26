#!/bin/bash
# Build the three "extra" packages that complete the four-package shape from
# packaging-design.md §4:
#
#  - documentdb-postgresql-tools (admin helpers; arch:all / noarch, PG-agnostic)
#  - documentdb-N (per-major stand-alone wrapper; arch:all / noarch)
#  - documentdb (meta package; arch:all / noarch; pinned to default PG major)
#
# The main extension build (packaging/build_packages.sh) and the gateway
# build (packaging/gateway/build_gateway_packages.sh) already cover the
# other two of the four packages. This orchestrator is the missing piece
# CI used to skip.
#
# Usage:
#  build_extra_packages.sh --type deb --pg N --version V [--output-dir DIR] [--default-pg-major N] [--os-prefix STR] [--check-build-deps-only]
#  build_extra_packages.sh --type rpm --pg N --version V [--output-dir DIR] [--default-pg-major N] [--check-build-deps-only]
#
# The --os-prefix is applied to .deb filenames so they sit alongside the
# extension/gateway outputs (which already use an OS-name prefix produced
# by packaging-entrypoint.sh / build-gateway-deb.sh).

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

PACKAGE_TYPE=""
PG_VERSION=""
DOCUMENTDB_VERSION=""
OUTPUT_DIR="${SCRIPT_DIR}"
DEFAULT_PG_MAJOR="18"
OS_PREFIX=""
CHECK_BUILD_DEPS_ONLY=false

die() { echo "ERROR: $*" >&2; exit 1; }

rpm_macro_number() {
    local macro_name="$1"
    local value=""
    value="$(rpm --eval "%{?${macro_name}}" 2>/dev/null || true)"
    if [[ "${value}" =~ ^[0-9]+$ ]]; then
        printf '%s' "${value}"
    else
        printf '0'
    fi
}

is_rhel_or_fedora_rpm_context() {
    local rhel fedora
    rhel="$(rpm_macro_number rhel)"
    fedora="$(rpm_macro_number fedora)"
    (( rhel > 0 || fedora > 0 ))
}

run_noninteractive_package_install() {
    local package_name="$1"
    local installer=""

    if command -v dnf >/dev/null 2>&1; then
        installer="dnf"
    elif command -v microdnf >/dev/null 2>&1; then
        installer="microdnf"
    elif command -v yum >/dev/null 2>&1; then
        installer="yum"
    else
        die "${package_name} is required to build documentdb-N RPM extras in a RHEL/Fedora rpm macro context. Install it first (for example: sudo dnf install -y ${package_name})."
    fi

    echo "Installing missing RPM build dependency ${package_name} with ${installer}."
    if [[ "${EUID}" -eq 0 ]]; then
        "${installer}" install -y "${package_name}"
    elif command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1; then
        sudo -n "${installer}" install -y "${package_name}"
    else
        die "${package_name} is required to build documentdb-N RPM extras in this RHEL/Fedora rpm macro context. Install it first: sudo ${installer} install -y ${package_name}"
    fi
}

ensure_rpm_extra_build_dependencies() {
    command -v rpmbuild >/dev/null 2>&1 || die "rpmbuild not found on PATH"
    command -v rpm >/dev/null 2>&1 || die "rpm not found on PATH"

    # documentdb-common.spec declares BuildRequires: systemd-rpm-macros only
    # when the local rpm macro context defines %rhel or %fedora. Ubuntu CI
    # intentionally builds the noarch extras with those macros undefined, so
    # the spec guard is inactive there and this preflight must be a no-op.
    if ! is_rhel_or_fedora_rpm_context; then
        return 0
    fi

    if rpm -q systemd-rpm-macros >/dev/null 2>&1; then
        return 0
    fi

    run_noninteractive_package_install systemd-rpm-macros

    rpm -q systemd-rpm-macros >/dev/null 2>&1 \
        || die "systemd-rpm-macros is still missing after installation. Install it manually and re-run: sudo dnf install -y systemd-rpm-macros"
}

ensure_deb_extra_build_dependencies() {
    # The .deb 'extras' are assembled on the host with dpkg-deb (see
    # deb-common.sh), not inside a container. Mirror
    # ensure_rpm_extra_build_dependencies so both formats preflight their host
    # build tool the same way — no matter whether the builder is reached via
    # build_gateway_packages.sh --test-clean-install
    # or a direct invocation here — instead of failing with a raw
    # "dpkg-deb: command not found" partway through the per-package builders.
    command -v dpkg-deb >/dev/null 2>&1 \
        || die "dpkg-deb not found on PATH (required to build the DEB 'extras' on this host). Install dpkg: 'sudo apt install dpkg' on Debian/Ubuntu, or 'brew install dpkg' on macOS."
}

usage() {
    cat <<'EOF'
Usage: build_extra_packages.sh --type {deb|rpm} --pg N --version V [OPTIONS]

Build documentdb-postgresql-tools, documentdb-<N>, and documentdb (meta).

Required:
  --type {deb|rpm}        Package format
  --pg N                  PostgreSQL major version the stand-alone wraps
  --version V             DocumentDB version string (e.g., 0.114.0)

Optional:
  --output-dir DIR        Drop directory for built artifacts (default: packaging/)
  --default-pg-major N    PG major the meta package pins to (default: 18)
  --os-prefix STR         Prefix prepended to DEB filenames (matches the
                          existing OS-name convention used by
                          packaging-entrypoint.sh / build-gateway-deb.sh)
  --check-build-deps-only Check the host extra-package build dependencies
                          (rpm: rpmbuild/rpm plus systemd-rpm-macros; deb:
                          dpkg-deb) and exit without building packages
  -h, --help              Show this help
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --type) PACKAGE_TYPE="$2"; shift 2 ;;
        --pg) PG_VERSION="$2"; shift 2 ;;
        --version) DOCUMENTDB_VERSION="$2"; shift 2 ;;
        --output-dir) OUTPUT_DIR="$2"; shift 2 ;;
        --default-pg-major) DEFAULT_PG_MAJOR="$2"; shift 2 ;;
        --os-prefix) OS_PREFIX="$2"; shift 2 ;;
        --check-build-deps-only) CHECK_BUILD_DEPS_ONLY=true; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown argument: $1" ;;
    esac
done

[[ -n "${PACKAGE_TYPE}" ]] || die "--type is required"
[[ -n "${PG_VERSION}" && "${PG_VERSION}" =~ ^[0-9]+$ ]] || die "--pg must be a number (e.g., 18)"
[[ -n "${DOCUMENTDB_VERSION}" ]] || die "--version is required"
# The meta package (built when PG_VERSION == DEFAULT_PG_MAJOR) pins the
# paved-road default major to documentdb-<major>, which wraps the gateway and
# requires PostgreSQL 16+. Reject a PG<16 paved-road default up front so the
# meta (DEB via build-meta-deb.sh, RPM via documentdb-local-meta.spec) can never
# pin to an unusable stand-alone. PG15 extension-only builds pass through with
# the default major (18) and simply skip the standalone/meta below.
[[ "${DEFAULT_PG_MAJOR}" =~ ^[0-9]+$ ]] || die "--default-pg-major must be a number (e.g., 18)"
(( DEFAULT_PG_MAJOR >= 16 )) || die "--default-pg-major must be PostgreSQL 16+ (the documentdb meta package pins the paved-road default major to documentdb-<major>, which wraps the gateway and requires PG16+); got ${DEFAULT_PG_MAJOR}."

mkdir -p "${OUTPUT_DIR}"
OUTPUT_DIR="$(cd "${OUTPUT_DIR}" && pwd -P)"

if [[ "${CHECK_BUILD_DEPS_ONLY}" == "true" ]]; then
    if [[ "${PACKAGE_TYPE}" == "rpm" ]]; then
        ensure_rpm_extra_build_dependencies
        echo "RPM extra-package build dependencies are satisfied."
    elif [[ "${PACKAGE_TYPE}" == "deb" ]]; then
        ensure_deb_extra_build_dependencies
        echo "DEB extra-package build dependencies are satisfied."
    else
        die "Unknown --type: ${PACKAGE_TYPE} (expected deb or rpm)"
    fi
    exit 0
fi

if [[ "${PACKAGE_TYPE}" == "deb" ]]; then
    echo "Building extras (DEB) for pg=${PG_VERSION} version=${DOCUMENTDB_VERSION} ..."

    # Preflight the host build tool (dpkg-deb) with an actionable message before
    # delegating to the per-package .deb builders, matching the rpm branch's
    # ensure_rpm_extra_build_dependencies call below.
    ensure_deb_extra_build_dependencies

    # 1. documentdb-postgresql-tools (PG-agnostic; arch:all)
    "${SCRIPT_DIR}/postgresql-tools/build-postgresql-tools-deb.sh" \
        --version "${DOCUMENTDB_VERSION}" \
        --output-dir "${OUTPUT_DIR}"

    # 2. documentdb-N (per-major stand-alone). It wraps the gateway, which
    # requires PostgreSQL 16+ (documentdb-register-gateway / documentdb-setup
    # reject PG<16), so only build it for PG16+. PostgreSQL 15 gets the
    # extension-only tooling (documentdb-postgresql-tools) built above.
    if (( PG_VERSION >= 16 )); then
        "${SCRIPT_DIR}/standalone/build-standalone-deb.sh" \
            --version "${DOCUMENTDB_VERSION}" \
            --pg-version "${PG_VERSION}" \
            --output-dir "${OUTPUT_DIR}"
    else
        echo "Skipping documentdb-${PG_VERSION} stand-alone package: the gateway requires PostgreSQL 16+; PostgreSQL ${PG_VERSION} is extension-only."
    fi

    # 2b. documentdb-common (PG-agnostic shared payload owned once). It is the
    # dependency of every documentdb-N, so it is built alongside the stand-alone
    # (PG16+). PostgreSQL 15 is extension-only and needs neither. The artifact is
    # noarch/identical across majors; building it in each PG16+ cell mirrors the
    # tools package and dedups on upload.
    if (( PG_VERSION >= 16 )); then
        "${SCRIPT_DIR}/standalone/build-common-deb.sh" \
            --version "${DOCUMENTDB_VERSION}" \
            --output-dir "${OUTPUT_DIR}"
    fi

    # 3. documentdb meta — only built when this PG version matches the
    # paved-road default. The meta package pins to one default major; building
    # it once per matrix cell would produce redundant identical artifacts (it
    # depends only on documentdb-<DEFAULT_PG_MAJOR>), and uploads would clash
    # on artifact name. Mirrors the RPM path below.
    if [[ "${PG_VERSION}" == "${DEFAULT_PG_MAJOR}" ]]; then
        "${SCRIPT_DIR}/standalone/build-meta-deb.sh" \
            --version "${DOCUMENTDB_VERSION}" \
            --default-pg-major "${DEFAULT_PG_MAJOR}" \
            --output-dir "${OUTPUT_DIR}"
    fi

    # Match the OS-name prefix convention used by the other DEB builders
    # so artifact paths are uniform across the four packages.
    if [[ -n "${OS_PREFIX}" ]]; then
        cd "${OUTPUT_DIR}"
        extras_to_rename=(
            "documentdb-postgresql-tools_${DOCUMENTDB_VERSION}_all.deb"
        )
        # Only rename the stand-alone we actually built (PG16+); gating this the
        # same way as the build above avoids picking up and re-presenting a
        # stale documentdb-15 artifact left in a reused output directory.
        if (( PG_VERSION >= 16 )); then
            extras_to_rename+=("documentdb-${PG_VERSION}_${DOCUMENTDB_VERSION}_all.deb")
            extras_to_rename+=("documentdb-common_${DOCUMENTDB_VERSION}_all.deb")
        fi
        if [[ "${PG_VERSION}" == "${DEFAULT_PG_MAJOR}" ]]; then
            extras_to_rename+=("documentdb_${DOCUMENTDB_VERSION}_all.deb")
        fi
        for base in "${extras_to_rename[@]}"; do
            if [[ -f "${base}" ]]; then
                mv -f "${base}" "${OS_PREFIX}-${base}"
            fi
        done
        cd - >/dev/null
    fi

elif [[ "${PACKAGE_TYPE}" == "rpm" ]]; then
    echo "Building extras (RPM) for pg=${PG_VERSION} version=${DOCUMENTDB_VERSION} ..."

    ensure_rpm_extra_build_dependencies

    # rpmbuild needs a topdir tree. Use a tmpdir under the chosen output
    # directory so build artifacts are cleaned up automatically.
    RPM_TOPDIR="$(mktemp -d "${OUTPUT_DIR}/.rpmbuild.XXXXXX")"
    trap 'rm -rf "${RPM_TOPDIR}"' EXIT
    mkdir -p "${RPM_TOPDIR}"/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

    # Source files that the three specs reference via %{_sourcedir}/
    SCRIPTS_SRC="${REPO_ROOT}/documentdb-local/scripts"
    APPLIANCE_SRC="${REPO_ROOT}/packaging/appliance"

    # 1. documentdb-postgresql-tools sources + spec
    cp "${SCRIPTS_SRC}/documentdb-tune.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/documentdb-createcluster.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/documentdb-register-gateway.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/documentdb-gateway-admin.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPTS_SRC}/documentdb-tools-lib.sh" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPT_DIR}/postgresql-tools/documentdb.conf.sample" "${RPM_TOPDIR}/SOURCES/"
    cp "${SCRIPT_DIR}/rpm/spec/documentdb-tools.spec" "${RPM_TOPDIR}/SPECS/"
    sed -i "s/DOCUMENTDB_VERSION/${DOCUMENTDB_VERSION}/g" "${RPM_TOPDIR}/SPECS/documentdb-tools.spec"
    rpmbuild -bb "${RPM_TOPDIR}/SPECS/documentdb-tools.spec" --define "_topdir ${RPM_TOPDIR}"

    # 2. documentdb-<N> sources + spec. The stand-alone wraps the gateway, which
    # requires PostgreSQL 16+, so only build it for PG16+ (PostgreSQL 15 is
    # extension-only; the tools package above still ships).
    if (( PG_VERSION >= 16 )); then
        cp "${SCRIPTS_SRC}/documentdb-setup.sh" "${RPM_TOPDIR}/SOURCES/"
        cp "${SCRIPTS_SRC}/documentdb-local-reset.sh" "${RPM_TOPDIR}/SOURCES/"
        cp "${SCRIPTS_SRC}/documentdb_postgresql_service.sh" "${RPM_TOPDIR}/SOURCES/"
        cp "${SCRIPTS_SRC}/init_documentdb_data.sh" "${RPM_TOPDIR}/SOURCES/"
        cp "${APPLIANCE_SRC}/systemd/documentdb-local@.target" "${RPM_TOPDIR}/SOURCES/"
        cp "${APPLIANCE_SRC}/systemd/documentdb-postgresql@.service" "${RPM_TOPDIR}/SOURCES/"
        cp "${APPLIANCE_SRC}/systemd/documentdb-gateway-local@.service" "${RPM_TOPDIR}/SOURCES/"
        cp "${APPLIANCE_SRC}/sysusers/documentdb-local.conf" "${RPM_TOPDIR}/SOURCES/documentdb-local-sysusers.conf"
        cp "${APPLIANCE_SRC}/tmpfiles/documentdb-local.conf" "${RPM_TOPDIR}/SOURCES/documentdb-local-tmpfiles.conf"
        mkdir -p "${RPM_TOPDIR}/SOURCES/sample-data"
        cp -r "${REPO_ROOT}/documentdb-local/sample-data/." "${RPM_TOPDIR}/SOURCES/sample-data/"

        cp "${SCRIPT_DIR}/rpm/spec/documentdb-local.spec" "${RPM_TOPDIR}/SPECS/documentdb-local.spec"
        sed -i "s/POSTGRES_VERSION/${PG_VERSION}/g; s/DOCUMENTDB_VERSION/${DOCUMENTDB_VERSION}/g" \
            "${RPM_TOPDIR}/SPECS/documentdb-local.spec"
        rpmbuild -bb "${RPM_TOPDIR}/SPECS/documentdb-local.spec" --define "_topdir ${RPM_TOPDIR}"

        # 2b. documentdb-common (PG-agnostic shared payload, noarch). Owns the
        # shared files (documentdb-setup, template units, sysusers/tmpfiles,
        # helper scripts, sample data) that documentdb-N used to ship, so the
        # per-major packages co-install without a file-ownership conflict. It
        # reuses the same %{_sourcedir} files copied above and is the dependency
        # of documentdb-N, hence built inside the same PG16+ gate.
        cp "${SCRIPT_DIR}/rpm/spec/documentdb-common.spec" "${RPM_TOPDIR}/SPECS/documentdb-common.spec"
        sed -i "s/DOCUMENTDB_VERSION/${DOCUMENTDB_VERSION}/g" \
            "${RPM_TOPDIR}/SPECS/documentdb-common.spec"
        rpmbuild -bb "${RPM_TOPDIR}/SPECS/documentdb-common.spec" --define "_topdir ${RPM_TOPDIR}"
    else
        echo "Skipping documentdb-${PG_VERSION} stand-alone RPM: the gateway requires PostgreSQL 16+; PostgreSQL ${PG_VERSION} is extension-only."
    fi

    # 3. documentdb meta — only build it when this PG version matches the
    # paved-road default. The meta package pins to one default major; building
    # it once per matrix cell would produce redundant identical artifacts and
    # uploads would clash on artifact name.
    if [[ "${PG_VERSION}" == "${DEFAULT_PG_MAJOR}" ]]; then
        cp "${SCRIPT_DIR}/rpm/spec/documentdb-local-meta.spec" "${RPM_TOPDIR}/SPECS/"
        sed -i "s/DOCUMENTDB_VERSION/${DOCUMENTDB_VERSION}/g; s/^%define default_pg_major .*/%define default_pg_major ${DEFAULT_PG_MAJOR}/" \
            "${RPM_TOPDIR}/SPECS/documentdb-local-meta.spec"
        rpmbuild -bb "${RPM_TOPDIR}/SPECS/documentdb-local-meta.spec" --define "_topdir ${RPM_TOPDIR}"
    fi

    # Move every produced RPM out to the output dir
    find "${RPM_TOPDIR}/RPMS" -type f -name '*.rpm' -exec cp -f {} "${OUTPUT_DIR}/" \;

else
    die "Unknown --type: ${PACKAGE_TYPE} (expected deb or rpm)"
fi

echo "Extras built into: ${OUTPUT_DIR}"
ls -1 "${OUTPUT_DIR}"/documentdb*postgresql-tools* "${OUTPUT_DIR}"/documentdb-common* "${OUTPUT_DIR}"/documentdb-${PG_VERSION}* "${OUTPUT_DIR}"/documentdb[._-]${DOCUMENTDB_VERSION}* 2>/dev/null || true
