# Shared helpers for the DocumentDB .deb build scripts: build-gateway-deb.sh,
# build-postgresql-tools-deb.sh, build-standalone-deb.sh and build-meta-deb.sh.
#
# This file is *sourced*, not executed. It centralizes the dpkg-deb scaffolding
# that was previously copy-pasted into each build script — the installed-size
# computation, the DEBIAN/control write, and the dpkg-deb --build + payload
# listing tail — so the four packages cannot drift on the build mechanics.
# Each script still owns its package-specific control fields (Package, Depends,
# Description, conffiles, maintainer scripts,...).
# shellcheck shell=bash

# Shared error helper for every .deb build script. Defined here (rather
# than per-script) so build-error reporting can evolve in one place; the
# sourcing scripts must not redefine it.
die() { echo "ERROR: $*" >&2; exit 1; }

DEB_MAINTAINER="DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com>"
DEB_COPYRIGHT_NOTICE="Copyright (c) 2015-present Microsoft Corporation"

_DEB_COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_DEB_COMMON_REPO_ROOT="$(cd "${_DEB_COMMON_DIR}/.." && pwd)"
DEB_DEFAULT_MIT_LICENSE_FILE="${_DEB_COMMON_REPO_ROOT}/LICENSE"

# deb_installed_size <pkg_dir>: print the Installed-Size (in KiB) of the staged
# package tree, in the form dpkg expects for the control file.
deb_installed_size() {
    du -sk "$1" | cut -f1
}

deb_emit_mit_permission_text() {
    local license_file="$1"

    if [[ -r "${license_file}" ]] && ! grep -Eq '<year>|<copyright holders>' "${license_file}"; then
        awk '
            $0 ~ /^MIT License[[:space:]]*$/ { next }
            $0 ~ /^Copyright \(c\)/ { next }
            { print }
        ' "${license_file}"
        return 0
    fi

    cat <<'EOF'
Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
EOF
}

# deb_install_mit_copyright <pkg_dir> <pkg_name> [license_file]: install a
# lintian-friendly Debian copyright file. The optional license file supplies
# the MIT permission text only; the concrete Microsoft copyright notice is
# emitted by this helper so placeholder MIT templates are never shipped.
deb_install_mit_copyright() {
    local pkg_dir="$1" pkg_name="$2" license_file="${3:-${DEB_DEFAULT_MIT_LICENSE_FILE}}"
    local doc_dir="${pkg_dir}/usr/share/doc/${pkg_name}"

    install -d "${doc_dir}"
    {
        echo "Upstream-Name: ${pkg_name}"
        echo "Source: https://github.com/documentdb/documentdb"
        echo
        echo "${DEB_COPYRIGHT_NOTICE}"
        echo
        echo "License: MIT"
        echo
        deb_emit_mit_permission_text "${license_file}"
    } > "${doc_dir}/copyright"
    chmod 0644 "${doc_dir}/copyright"
}

# deb_extension_dep_version <version>: normalize a package version to the
# EXTENSION packages' dashed form for use in dependency floors.
#
# The product deliberately carries two DEB version grammars:
#   - extension packages (postgresql-N-documentdb) use the control-file
#     upstream form "X.Y-Z" (e.g. 0.117-0: upstream X.Y, Debian revision Z);
#   - every other package (gateway/tools/common/documentdb-N/meta) uses the
#     flat dotted form "X.Y.Z" (e.g. 0.117.0).
# dpkg's comparator treats these as DIFFERENT versions — and orders them:
#   dpkg --compare-versions 0.117-0 ge 0.117.0  → FALSE  (0.117 < 0.117.0)
# so any cross-package floor that references the EXTENSION must use the
# dashed form or apt rejects a correctly-versioned install. Single-source
# that conversion here; see packaging/README.md ("Package version formats").
deb_extension_dep_version() {
    local version="$1"
    if [[ "${version}" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
        printf '%s.%s-%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}"
    else
        printf '%s' "${version}"
    fi
}

# deb_install_changelog <pkg_dir> <pkg_name> <version> <summary>: install a
# native-package Debian changelog at /usr/share/doc/<pkg>/changelog.gz. Keep
# this format aligned with packaging/update_spec_changelog.sh.
deb_install_changelog() {
    local pkg_dir="$1" pkg_name="$2" version="$3" summary="$4"
    local doc_dir="${pkg_dir}/usr/share/doc/${pkg_name}"
    local changelog="${doc_dir}/changelog"
    local date_rfc=""

    install -d "${doc_dir}"
    if [[ -n "${SOURCE_DATE_EPOCH:-}" && "${SOURCE_DATE_EPOCH}" =~ ^[0-9]+$ ]]; then
        # Portable epoch->RFC date: GNU `date -d @epoch` with a BSD/macOS
        # `date -r epoch` fallback, so the host-run builder works under both
        # GNU and BSD userlands.
        date_rfc="$(LC_ALL=C date -u -d "@${SOURCE_DATE_EPOCH}" +"%a, %d %b %Y %T +0000" 2>/dev/null \
            || LC_ALL=C date -u -r "${SOURCE_DATE_EPOCH}" +"%a, %d %b %Y %T +0000")"
    else
        date_rfc="$(LC_ALL=C date -u +"%a, %d %b %Y %T +0000")"
    fi

    {
        printf '%s (%s) unstable; urgency=medium\n\n' "${pkg_name}" "${version}"
        printf '  * %s\n\n' "${summary}"
        printf ' -- %s  %s\n' "${DEB_MAINTAINER}" "${date_rfc}"
    } > "${changelog}"
    gzip -9n -f "${changelog}"
    chmod 0644 "${changelog}.gz"
}

# emit_control <pkg_dir>: read the DEBIAN/control body from stdin and write it
# to <pkg_dir>/DEBIAN/control, substituting the literal token @INSTALLED_SIZE@
# with the computed installed size. Callers keep their package-specific fields
# in the heredoc and place "Installed-Size: @INSTALLED_SIZE@" at the
# conventional position, so the size is computed in exactly one place.
emit_control() {
    local pkg_dir="$1"
    install -d "${pkg_dir}/DEBIAN"
    sed "s/@INSTALLED_SIZE@/$(deb_installed_size "${pkg_dir}")/" \
        > "${pkg_dir}/DEBIAN/control"
}

# finalize_deb <pkg_dir> <deb_file>: build the .deb with root-owned payload
# (reproducible ownership regardless of the build user) and print a "Built:"
# line. Call deb_list_contents afterwards to additionally print the payload.
finalize_deb() {
    local pkg_dir="$1" deb_file="$2"
    # Universal backstop for every .deb build entry point — the leaf
    # build-*-deb.sh scripts are directly invocable, not only reached via
    # build_extra_packages.sh — so fail here with an actionable message instead
    # of a raw "dpkg-deb: command not found".
    command -v dpkg-deb >/dev/null 2>&1 \
        || die "dpkg-deb not found on PATH (required to build .deb packages on this host). Install dpkg: 'sudo apt install dpkg' on Debian/Ubuntu, or 'brew install dpkg' on macOS."
    mkdir -p "$(dirname "${deb_file}")"
    # Force xz compression. dpkg-deb defaults to zstd on modern build hosts
    # (Debian 12/13, Ubuntu 22/24), but older targets such as Debian 11
    # (bullseye) ship a dpkg that cannot read a zstd control.tar.zst and abort
    # unpacking with "unknown compression for member 'control.tar.zst'". xz is
    # understood by the dpkg on every supported target, so the host-built extras
    # stay installable everywhere without repacking.
    dpkg-deb -Zxz --build --root-owner-group "${pkg_dir}" "${deb_file}"
    echo "Built: ${deb_file}"
}

# deb_list_contents <deb_file>: print the package's payload file paths (indented,
# directory entries excluded), matching the previous inline listing.
deb_list_contents() {
    echo "Contents:"
    dpkg-deb -c "$1" | awk '{print "  " $NF}' | grep -v '/$'
}
