# The three spellings of one DocumentDB release, in one place. Sourced (POSIX
# sh) by the package build scripts and the gateway Dockerfiles so the RC
# grammar cannot drift between them.
#
#   package  1.0~rc2    deb/rpm Version; ~ sorts below the 1.0.0 / 1.0-0 release
#   display  1.0-rc2    file names, image tags, /version.txt, install.sh --version
#   cargo    1.0.0-rc2  the gateway binary; Cargo needs X.Y.Z and has no ~
#
# Stable versions pass through: 1.0.0 stays 1.0.0, and the control-file form
# 1.0-0 becomes 1.0.0 for Cargo.

# Any RC spelling a user can copy (1.0-rc2, v1.0-RC2, 1.0.0-rc2, 1.0~rc2) ->
# 1.0~rc2; a literal -rc2 would be a Debian revision that sorts above GA.
documentdb_package_version() {
    printf '%s' "$1" | sed -E \
        -e 's/^[vV]([0-9])/\1/' \
        -e 's/^([0-9]+\.[0-9]+)(\.0)?[-~][rR][cC]([0-9]+)$/\1~rc\3/' \
        -e 's/^([0-9]+\.[0-9]+\.[1-9][0-9]*)[-~][rR][cC]([0-9]+)$/\1~rc\2/'
}

# 1.0~rc2 -> 1.0-rc2
documentdb_display_version() {
    documentdb_package_version "$1" | tr '~' '-'
}

# 1.0~rc2 -> 1.0.0-rc2; 1.0.1~rc2 -> 1.0.1-rc2; 1.0-0 -> 1.0.0
documentdb_cargo_version() {
    documentdb_package_version "$1" | sed -E \
        -e 's/^([0-9]+\.[0-9]+)~rc([0-9]+)$/\1.0-rc\2/' \
        -e 's/^([0-9]+\.[0-9]+\.[0-9]+)~rc([0-9]+)$/\1-rc\2/' \
        -e 's/^([0-9]+\.[0-9]+)-([0-9]+)$/\1.\2/'
}

# The package version of a checkout sitting exactly on a release tag
# (v1.0-RC2 -> 1.0~rc2, v1.0-0 -> 1.0.0), or nothing. A build from the RC tag
# with no --version must not fall back to the control file's GA version.
documentdb_tag_version() {
    tag="$(git -C "$1" describe --exact-match --tags HEAD 2>/dev/null)" || return 0
    case "$tag" in
        v[0-9]*.[0-9]*-RC[1-9]*) documentdb_package_version "$tag" ;;
        v[0-9]*.[0-9]*-[0-9]*) printf '%s' "${tag#v}" | sed -E 's/^([0-9]+\.[0-9]+)-([0-9]+)$/\1.\2/' ;;
    esac
}
