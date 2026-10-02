#!/bin/bash
set -e

test -n "$OS" || (echo "OS not set" && false)

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

# Keep the internal directory out of the Debian package
sed -i '/internal/d' Makefile

# Resolve versions for Static-Built-Using and Bundled from the same source the build used.
# Subshell because setup_versions.sh runs `set -u`.
bundled_versions=$(bash -c 'set -e; . /build/scripts/setup_versions.sh
    printf "%s %s %s\n" "$(GetLibbsonVersion)" "$(GetPcre2Version)" "$(GetIntelDecimalMathLibVersion)"') \
   || { echo "ERROR: could not read versions from scripts/setup_versions.sh" >&2; exit 1; }
read -r LIBBSON_VER PCRE2_VER IDML_VER <<<"$bundled_versions"

# The Launchpad ref names the exact Ubuntu intelrdfpmath source version we build from.
IDML_VER=${IDML_VER#applied/}

for v in "$LIBBSON_VER" "$PCRE2_VER" "$IDML_VER"; do
   [[ "$v" =~ ^[A-Za-z0-9.+~-]+$ ]] \
      || { echo "ERROR: '$v' is not usable as a Debian version in debian/control" >&2; exit 1; }
done

sed -i -e "/^XB-\(Static-Built-Using\|Bundled\):/{
         s/LIBBSON_VERSION/${LIBBSON_VER}/
         s/PCRE2_VERSION/${PCRE2_VER}/
         s/INTEL_DECIMAL_MATH_LIB_VERSION/${IDML_VER}/
       }" debian/control
if grep -nE '^XB-(Static-Built-Using|Bundled):.*_VERSION' debian/control >&2; then
   echo "ERROR: the field above kept its placeholder" >&2
   exit 1
fi
echo "Bundled versions: libbson ${LIBBSON_VER}, pcre2 ${PCRE2_VER}, intel-decimal-math ${IDML_VER}"

# Build the Debian package
debuild -us -uc

# Change to the root to make file renaming expression simpler
cd /

# Guard: the .deb must not ship or depend on libbson (it is statically linked).
# Bundled is checked separately since naming libbson there is correct.
shopt -s nullglob
deb_files=(*.deb)
shopt -u nullglob
if (( ${#deb_files[@]} == 0 )); then
   echo "ERROR: debuild produced no .deb in $(pwd)" >&2
   exit 1
fi
# Whole items, not substrings: 'notlibbson (= 1.28.0)' must not satisfy this.
require_decls() {
   local field=$1 value decl items
   shift
   value=$(dpkg-deb -f "$f" "$field") \
      || { echo "ERROR: dpkg-deb -f $field failed on $f" >&2; exit 1; }
   mapfile -t items < <(tr ',' '\n' <<<"${value}" | sed 's/^ *//; s/ *$//')
   for decl in "$@"; do
      printf '%s\n' "${items[@]}" | grep -qxF "${decl}" \
         || { echo "ERROR: $f does not record '${decl}' in ${field} (got: '${value}')." >&2; exit 1; }
   done
}
for f in "${deb_files[@]}"; do
   contents=$(dpkg-deb -c "$f") \
      && control=$(dpkg-deb -f "$f" Depends Pre-Depends Provides Conflicts Breaks Replaces) \
      || { echo "ERROR: dpkg-deb failed on $f" >&2; exit 1; }
   if grep -i libbson >&2 <<<"${contents}"; then
      echo "ERROR: $f ships the libbson file above (dpkg-deb -c)." >&2
      exit 1
   fi
   if grep -i libbson >&2 <<<"${control}"; then
      echo "ERROR: $f declares the libbson relationship above (dpkg-deb -f)." >&2
      exit 1
   fi

   # Skip auto-built debug packages; debhelper may strip custom fields from them.
   auto_built_package=$(dpkg-deb -f "$f" Auto-Built-Package) \
      || { echo "ERROR: dpkg-deb -f Auto-Built-Package failed on $f" >&2; exit 1; }
   if [[ -n "${auto_built_package}" ]]; then
      echo "libbson guard: $f is clean (auto-built, no declaration expected)"
      continue
   fi

   require_decls Static-Built-Using "intelrdfpmath (= ${IDML_VER})"
   require_decls Bundled "libbson (= ${LIBBSON_VER})" "pcre2 (= ${PCRE2_VER})"
   echo "libbson guard: $f is clean, and records its embedded libraries"
done

# Rename .deb files to include the OS name prefix
for f in *.deb; do
   mv $f $OS-$f;
done

# Create the output directory if it doesn't exist
mkdir -p /output

# Copy the built packages to the output directory
cp *.deb /output/

# Change ownership of the output files to match the host user's UID and GID
chown -R $(stat -c "%u:%g" /output) /output