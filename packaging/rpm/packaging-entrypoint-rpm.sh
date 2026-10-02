#!/bin/bash
set -e

# Ensure required environment variables are set
test -n "$OS" || (echo "OS not set" && false)
test -n "$POSTGRES_VERSION" || (echo "POSTGRES_VERSION not set" && false)

# Change to the build directory
cd /build

# Update packaging changelogs from CHANGELOG.md (fail build if this fails)
if [[ -n "${DOCUMENTDB_VERSION:-}" ]]; then
    echo "DOCUMENTDB_VERSION provided via environment: ${DOCUMENTDB_VERSION}"
else
    DOCUMENTDB_VERSION=$(grep -E "^default_version" pg_documentdb_core/documentdb_core.control | sed -E "s/.*'([0-9]+\.[0-9]+-[0-9]+)'.*/\1/" || true)
fi
if [[ -n "$DOCUMENTDB_VERSION" ]]; then
    echo "Running changelog update for version: $DOCUMENTDB_VERSION"
    /bin/bash /build/packaging/update_spec_changelog.sh "$DOCUMENTDB_VERSION"
else
    echo "WARNING: Could not determine documentdb version; skipping changelog update"
    exit 1
fi

# Remove 'internal' references from Makefile
sed -i '/internal/d' Makefile

# Create RPM build directories
mkdir -p ~/rpmbuild/{BUILD,BUILDROOT,RPMS,SOURCES,SPECS,SRPMS}

# Get the package version from the spec file
PACKAGE_VERSION=$(grep "^Version:" rpm/documentdb.spec | awk '{print $2}' | tr -d '\r')

# Construct the package name
PACKAGE_NAME="postgresql${POSTGRES_VERSION}-documentdb"

# Add PostgreSQL bin directory to PATH to ensure pg_config is found
export PATH="/usr/pgsql-${POSTGRES_VERSION}/bin:$PATH"
echo "Using PostgreSQL bin directory: $PATH"

echo "Package name: $PACKAGE_NAME"
echo "Package version: $PACKAGE_VERSION"
echo "PostgreSQL version: $POSTGRES_VERSION"

# Copy spec file to the SPECS directory
# If building for PG >= 18, remove the rum Requires line so the produced RPM
# won't require the distro 'rum' package (we provide documentdb_extended_rum for PG18+)
if [ "${POSTGRES_VERSION}" -ge 18 ]; then
    echo "POSTGRES_VERSION=${POSTGRES_VERSION} >= 18; removing rum Requires from rpm/documentdb.spec"
    # Delete the Requires line for rum
    sed -i '/^Requires:[[:space:]]*rum_%{pg_version}/d' rpm/documentdb.spec || true
fi

# Splice the regenerated %changelog into the build spec. rpm/documentdb.spec
# was COPY'd + placeholder-substituted at IMAGE build time, but
# update_spec_changelog.sh (run above, at CONTAINER run time) rewrites the
# other copy at packaging/rpm/spec/documentdb.spec — so without this splice
# rpmbuild consumes a stale static %changelog (newest entry pinned at
# whatever version the spec was last hand-edited for, e.g. 0.106-0 on a
# 0.117 package).
UPDATED_SPEC=packaging/rpm/spec/documentdb.spec
if grep -q '^%changelog' "$UPDATED_SPEC"; then
    awk '/^%changelog/{exit} {print}' rpm/documentdb.spec > /tmp/spec.head
    awk '/^%changelog/{f=1} f' "$UPDATED_SPEC" > /tmp/spec.tail
    cat /tmp/spec.head /tmp/spec.tail > rpm/documentdb.spec
    rm -f /tmp/spec.head /tmp/spec.tail
else
    echo "ERROR: no %changelog block found in $UPDATED_SPEC after update_spec_changelog.sh" >&2
    exit 1
fi

# Guard: the newest %changelog entry must document the version being built.
# This is what catches the stale-spec failure mode above — a %changelog left
# topped at whatever version the static spec was last hand-edited for.
#
# NOTE on scope: this compares DOCUMENTDB_VERSION against the changelog only.
# The spec's own Version:/Release: are NOT touched by the splice — they keep
# the dotted form substituted at image build time (Version: X.Y.Z, Release: 1),
# while changelog entries use the dashed form (X.Y-Z). rpmlint compares the
# changelog against %{version}-%{release}, so it will still report
# incoherent-version-in-changelog; this guard does not silence that.
# Do NOT "fix" that by also splicing Version:/Release: from the regenerated
# spec (which resolves them to X.Y / Z): that renames the RPM from
# ...-documentdb-X.Y.Z-1.el9.<arch>.rpm to ...-documentdb-X.Y-Z.el9.<arch>.rpm
# and breaks every consumer that selects packages by filename — the package
# lookup in build_packages.sh, the bundle category globs, and the downstream
# repository publisher. Reconciling the two version grammars is a separate
# change; see packaging/README.md ("Package version formats").
VER_DASH="$DOCUMENTDB_VERSION"
if [[ "$VER_DASH" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    VER_DASH="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
fi
first_entry=$(awk '/^%changelog/{f=1;next} f && /^\* /{print; exit}' rpm/documentdb.spec)
if [[ "$first_entry" != *"- ${VER_DASH}"* ]]; then
    echo "ERROR: newest %changelog entry does not document ${VER_DASH}: '${first_entry}'" >&2
    exit 1
fi
echo "Newest %changelog entry: ${first_entry}"

# Resolve versions for the spec's bundled() provides from the same source the build used.
# Subshell because setup_versions.sh runs `set -u`.
bundled_versions=$(bash -c 'set -e; . /build/scripts/setup_versions.sh
    printf "%s %s %s\n" "$(GetLibbsonVersion)" "$(GetPcre2Version)" "$(GetIntelDecimalMathLibVersion)"') \
    || { echo "ERROR: could not read versions from scripts/setup_versions.sh" >&2; exit 1; }
read -r LIBBSON_VER PCRE2_VER IDML_VER <<<"$bundled_versions"

# Strip the Launchpad packaging suffix; only the upstream version is rpm-legal.
IDML_VER=${IDML_VER#applied/}
IDML_VER=${IDML_VER%%-*}

for v in "$LIBBSON_VER" "$PCRE2_VER" "$IDML_VER"; do
    [[ "$v" =~ ^[A-Za-z0-9._+~]+$ ]] \
        || { echo "ERROR: '$v' is not usable as an rpm version in a bundled() provide" >&2; exit 1; }
done

# Only substitute inside bundled() Provides lines to avoid touching %changelog entries.
sed -i -e "/^Provides:[[:space:]]*bundled(/{
         s/LIBBSON_VERSION/${LIBBSON_VER}/
         s/PCRE2_VERSION/${PCRE2_VER}/
         s/INTEL_DECIMAL_MATH_LIB_VERSION/${IDML_VER}/
       }" rpm/documentdb.spec
if grep -n '^Provides:.*_VERSION' rpm/documentdb.spec >&2; then
    echo "ERROR: the bundled() provide above kept its placeholder" >&2
    exit 1
fi
echo "Bundled versions: libbson ${LIBBSON_VER}, pcre2 ${PCRE2_VER}, intel-decimal-math ${IDML_VER}"

cp rpm/documentdb.spec ~/rpmbuild/SPECS/

# Prepare the source directory
SOURCE_DIR="/tmp/${PACKAGE_NAME}-${PACKAGE_VERSION}"
mkdir -p "$SOURCE_DIR"

# Copy source files into the source directory
# Adjust this as needed to include all necessary files
cp -r /build/* "$SOURCE_DIR/"

# Create the source tarball
echo "Creating tarball: ~/rpmbuild/SOURCES/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz"
tar -czf ~/rpmbuild/SOURCES/${PACKAGE_NAME}-${PACKAGE_VERSION}.tar.gz -C /tmp "${PACKAGE_NAME}-${PACKAGE_VERSION}"

# Build the RPM package
rpmbuild -ba ~/rpmbuild/SPECS/documentdb.spec

# Rename and copy RPMs to the output directory
mkdir -p /output
if [ -n "${ARCH}" ]; then
    RPM_ARCH=${ARCH}
else
    UNAME_ARCH=$(uname -m)
    case "${UNAME_ARCH}" in
        aarch64|arm64)
            RPM_ARCH=aarch64
            ;;
        x86_64|amd64)
            RPM_ARCH=x86_64
            ;;
        *)
            echo "Unknown runtime arch: ${UNAME_ARCH}, defaulting to x86_64" >&2
            RPM_ARCH=x86_64
            ;;
    esac
fi

# Guard: the RPM must not ship or depend on libbson (it is statically linked).
# The only allowed libbson Provides is the bundled() declaration at the pinned version.
# All three bundled() declarations must be present for CVE scanner coverage.
shopt -s nullglob
rpm_files=(~/rpmbuild/RPMS/${RPM_ARCH}/*.rpm)
shopt -u nullglob
if (( ${#rpm_files[@]} == 0 )); then
    echo "ERROR: rpmbuild produced no RPM under ~/rpmbuild/RPMS/${RPM_ARCH}" >&2
    exit 1
fi
bundled_provides=(
    "bundled(libbson) = ${LIBBSON_VER}"
    "bundled(pcre2) = ${PCRE2_VER}"
    "bundled(intel-decimal-math) = ${IDML_VER}"
)
for rpm_file in "${rpm_files[@]}"; do
    for query in --list --provides --requires --conflicts --obsoletes; do
        out=$(rpm -qp "$query" "$rpm_file") \
            || { echo "ERROR: rpm -qp $query failed on $(basename "$rpm_file")" >&2; exit 1; }
        if [[ "$query" == --provides ]]; then
            out=$(grep -vxF "${bundled_provides[0]}" <<<"$out" || true)
        fi
        if grep -i libbson >&2 <<<"$out"; then
            echo "ERROR: $(basename "$rpm_file") ships or declares the libbson above (rpm -qp $query)." >&2
            exit 1
        fi
    done

    provides=$(rpm -qp --provides "$rpm_file") \
        || { echo "ERROR: rpm -qp --provides failed on $(basename "$rpm_file")" >&2; exit 1; }
    for decl in "${bundled_provides[@]}"; do
        grep -qxF "$decl" <<<"$provides" \
            || { echo "ERROR: $(basename "$rpm_file") does not Provide '${decl}'; see the Provides block in the spec." >&2; exit 1; }
    done
    echo "libbson guard: $(basename "$rpm_file") is clean, and declares ${bundled_provides[*]}"

    base_rpm=$(basename "$rpm_file")
    mv "$rpm_file" "/output/${OS}-${base_rpm}"
done

# Also handle source RPMs
# if [ -d ~/rpmbuild/SRPMS ]; then
#     for srpm_file in ~/rpmbuild/SRPMS/*.rpm; do
#         base_srpm=$(basename "$srpm_file")
#         mv "$srpm_file" "/output/${OS}-${base_srpm}"
#     done
# fi

# Adjust ownership of the output files
chown -R $(stat -c "%u:%g" /output) /output
