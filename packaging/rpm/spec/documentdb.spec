%global pg_version POSTGRES_VERSION
%define debug_package %{nil}

# Disable brp-mangle-shebangs. This originally existed because the spec
# shipped the whole source tree under /usr/src/documentdb-<major>: on a
# Windows/WSL-mounted build host every file shows as mode 0777, so the hook
# treated every text file as a script and choked on Rust sources whose first
# line is an attribute like `#![expect(...)]`. The source tree is no longer
# packaged, so the buildroot now holds only the extension .so files, the
# .control/.sql files and the bundled libbson — none of which carry shebangs.
# Retained as a defensive no-op: it costs nothing and keeps the build portable
# across native-Linux and WSL-mounted hosts where mode bits are unreliable.
%undefine __brp_mangle_shebangs

# Filters two auto-generated runtime Requires. The `make` half is now moot: it
# came from the source tree's Makefile shebangs, which are no longer packaged.
# The `pkg-config` half is LOAD-BEARING: this package ships
# %%{_libdir}/pkgconfig/libbson-static-1.0.pc, and rpm's pkgconfig dependency
# generator emits `Requires: /usr/bin/pkg-config` for any packaged .pc — VERIFIED
# by rebuilding without this filter (the requirement appears; with it, it does
# not). Nothing in the package invokes pkg-config at RUN time — the .pc exists
# for build-time consumers of the bundled libbson — so pulling pkgconf onto
# every install is unwanted dependency creep. Do NOT delete this filter while
# the .pc ships.
#
# Caveat before touching it: __requires_exclude is SINGLE-VALUED, so a second
# filter written the same way REPLACES this one rather than adding to it; and it
# drops matches with no build-time diagnostic. If a future component genuinely
# needs pkg-config at run time, widen the alternation here rather than adding a
# second %%global, and re-verify with `rpm -qpR` after a build.
%global __requires_exclude ^/usr/bin/(make|pkg-config)$

Name:           postgresql%{pg_version}-documentdb
Version:        DOCUMENTDB_VERSION
# NOTE: both of these lines are REWRITTEN at build time. packaging-entrypoint-rpm.sh
# runs packaging/update_spec_changelog.sh before rpmbuild, and that script derives
# Version and Release from the version argument (CHANGELOG.md's latest section) and
# substitutes them here. Editing them in this file has no effect on the built RPM;
# change CHANGELOG.md instead.
Release:        1%{?dist}
Summary:        DocumentDB is the open-source engine powering vCore-based Azure Cosmos DB for MongoDB

License:        MIT
URL:            https://github.com/documentdb/documentdb
Source0:        %{name}-%{version}.tar.gz

BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  cmake
BuildRequires:  postgresql%{pg_version}-devel
BuildRequires:  libicu-devel
BuildRequires:  krb5-devel
BuildRequires:  pkg-config
# The following BuildRequires are for system packages.
# Libbson and pcre2 development files are provided by scripts
# in the Dockerfile_build_rpm_packages environment, not by system RPMs.
# BuildRequires: libbson-devel
# BuildRequires: pcre2-devel
# BuildRequires: intel-decimal-math-devel # If a devel package exists and is used

Requires:       (postgresql%{pg_version} or percona-postgresql%{pg_version})
Requires:       (postgresql%{pg_version}-server or percona-postgresql%{pg_version}-server)
Requires:       (pgvector_%{pg_version} or percona-pgvector_%{pg_version})
Requires:       pg_cron_%{pg_version}
Requires:       postgis36_%{pg_version}
# rum extension is bundled with PG 18+; only require the external package on PG ≤17.
%if %{pg_version} < 18
Requires:       rum_%{pg_version}
%endif
# Suggests (not Requires/Recommends) the administrator tools package; useful
# when the operator wants documentdb-tune for postgresql.conf hardening but
# can omit it for read-only / driver-only deployments.
Suggests:       documentdb-postgresql-tools
# Libbson is now bundled, so no runtime Requires for it.
# pcre2 is statically linked.
# The Intel Decimal Math library is statically linked into the extension .so;
# libbid.a itself is not packaged (see the note in %%install).

%description
DocumentDB is the open-source engine powering vCore-based Azure Cosmos DB for MongoDB. 
It offers a native implementation of document-oriented NoSQL database, enabling seamless 
CRUD operations on BSON data types within a PostgreSQL framework.

This package depends on PGDG-provided PostgreSQL extension packages
(pgvector_%{pg_version}, pg_cron_%{pg_version}, postgis36_%{pg_version}). On
RHEL/Rocky/AlmaLinux, enable the PGDG, EPEL, and CodeReady Builder (CRB)
repositories BEFORE installing so dependency resolution succeeds (adjust the
EL major and arch for your host; use 'powertools' instead of 'crb' on EL8):

  sudo dnf install -y dnf-plugins-core
  sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
  sudo dnf install -y epel-release
  sudo dnf config-manager --set-enabled crb
  sudo dnf -qy module disable postgresql

Then install this extension-only package: sudo dnf install postgresql%{pg_version}-documentdb
For the full stand-alone experience (gateway + wire-protocol endpoint + the
documentdb-setup wizard), install the meta package instead: sudo dnf install documentdb

%prep
%setup -q

%build
# Keep the internal directory out of the RPM package
sed -i '/internal/d' Makefile

# On older toolchains (RHEL 8 / binutils 2.30) the linker publishes ELF
# section-boundary symbols (_end, _edata, __bss_start and their aarch64
# aliases) in .dynsym as globals. The pg_documentdb_extended_rum export
# duplication self-check then sees them in both RUM shared objects and fails
# the build with "duplicate export(s)". Newer linkers (RHEL 9, Ubuntu, Azure
# Linux) already hide them, so only the RHEL 8 RPM build breaks. Localize just
# those linker-generated symbols via a version script so they drop out of
# .dynsym on every toolchain. This is a package-build-only change; the
# extension source and the validation script are untouched. COPT is PGXS's
# supported flag hook (appended to CFLAGS and LDFLAGS), so it reaches the
# MODULE_big link of both pg_documentdb_extended_rum_core.so and
# pg_documentdb_extended_rum_core_builtin_rmgr.so.
cat > %{_builddir}/documentdb-hide-linker-syms.map <<'EOF'
{
  local:
    _end; __end__;
    _edata; edata;
    _etext; etext;
    __bss_start; __bss_start__; __bss_end__; _bss_end__;
};
EOF

# The map lists names that may be absent from a given object (e.g. the aarch64
# aliases when linking x86_64). binutils < 2.42 silently ignores unmatched
# version-script entries, but binutils >= 2.42 defaults to --no-undefined-version,
# under which an unmatched (even local:) entry becomes a fatal link error. RHEL
# 8/9 ship binutils 2.30/2.35 so this is not hit today; pass --undefined-version
# when the linker supports it (that option only exists on binutils >= 2.42) so a
# future base-image bump cannot silently reintroduce a version-dependent failure.
UNDEF_VERSION_FLAG=""
if echo 'int _documentdb_uvprobe;' | gcc -shared -fPIC -x c - -o %{_builddir}/.uvprobe.so -Wl,--undefined-version 2>/dev/null; then
  UNDEF_VERSION_FLAG="-Wl,--undefined-version"
fi
rm -f %{_builddir}/.uvprobe.so

# Build the extension
# Ensure PG_CONFIG points to the correct pg_config for PGDG paths
make %{?_smp_mflags} PG_CONFIG=/usr/pgsql-%{pg_version}/bin/pg_config PG_CFLAGS="-std=gnu99 -Wall -Wno-error" CFLAGS="" COPT="$UNDEF_VERSION_FLAG -Wl,--version-script=%{_builddir}/documentdb-hide-linker-syms.map"

%install
make install DESTDIR=%{buildroot}

# Remove the bitcode directory if it's not needed in the final package
rm -rf %{buildroot}/usr/pgsql-%{pg_version}/lib/bitcode

# libbid.a (Intel Decimal Math Library static archive) is deliberately NOT
# packaged. It is a STATIC library already linked into the extension .so, so
# nothing needs it at run time, and the DEB package has never shipped it. Its
# only stated purpose was to support rebuilding from the bundled source tree —
# which is no longer packaged either. It was also unusable where it was put:
# pg_documentdb_core/Makefile resolves the archive exclusively through
# `pkg-config intelmathlib`, and install_setup_intel_decimal_math_lib.sh
# generates that .pc with a hardcoded prefix=/usr/lib/intelmathlib, a path the
# package does not create and no intelmathlib.pc was ever shipped to override.
# Dropping it removes 5.4MB per PostgreSQL major.
#
# NOTE for upgrades from the previous release: /usr/pgsql-<major>/lib/intelmathlib
# and its LIBRARY/ subdirectory were never RPM-OWNED (only the .a file inside was
# listed in %%files), so rpm removes the archive but cannot remove the now-empty
# directories. They survive as unowned empties, and because /usr/pgsql-<major>/lib
# is then non-empty rpm will also skip removing it when the PostgreSQL packages go.
# Accepted rather than papered over with a %%posttrans rmdir: the leftovers are two
# empty directories, and a scriptlet that deletes paths it does not own is a worse
# precedent than the cosmetic residue.

# Bundle libbson shared library and pkg-config file
# These are installed by install_setup_libbson.sh into /usr (default INSTALLDESTDIR)
mkdir -p %{buildroot}%{_libdir}
mkdir -p %{buildroot}%{_libdir}/pkgconfig

# fully versioned .so file
cp /usr/%{_lib}/libbson-1.0.so.0.0.0 %{buildroot}%{_libdir}/
# Copy the main symlinks
cp -P /usr/%{_lib}/libbson-1.0.so %{buildroot}%{_libdir}/
cp -P /usr/%{_lib}/libbson-1.0.so.0 %{buildroot}%{_libdir}/
# static library
cp /usr/%{_lib}/pkgconfig/libbson-static-1.0.pc %{buildroot}%{_libdir}/pkgconfig/

# The source tree is deliberately NOT packaged.
#
# It used to be copied wholesale with `cp -r .` into /usr/src/documentdb (later
# /usr/src/documentdb-<major>) "for make check". That was unsound in several
# ways at once, and none of them were worth fixing for a feature nothing used:
#
#   * Non-reproducible payload. `cp -r .` shipped whatever the build tree
#     happened to hold — generated SQL and headers under per-subproject build/
#     dirs, .deps stubs, __pycache__ from test runs, and previously built
#     .deb/.rpm artifacts the builders drop into packaging/. The exclusion list
#     had already grown to ten patterns and was still incomplete.
#   * It shipped internal/pg_documentdb_distributed (30MB, 737 files) even
#     though %%build removes it from the Makefile precisely to keep it out of
#     the package, and that component carries AGPL-licensed third-party
#     material (see internal/pg_documentdb_distributed/NOTICE) under this
#     package's MIT License tag.
#   * It was the source of cross-major file conflicts, which the per-major
#     path papered over at the cost of duplicating ~68MB per major installed.
#   * It did not actually work: `make` in the shipped tree fails at link
#     because libbid.a is resolved via `pkg-config intelmathlib` and no
#     intelmathlib.pc is packaged.
#
# Nothing referenced it: no documentation mentions /usr/src/documentdb, the
# DEB package has never shipped a source tree, and the RPM install test that
# claimed to exercise it was in fact compiling the Dockerfile's own COPY of the
# repo. Removing it takes the package from ~84MB to ~10MB installed.

%files
%defattr(-,root,root,-)
/usr/pgsql-%{pg_version}/lib/*.so
/usr/pgsql-%{pg_version}/share/extension/*.control
/usr/pgsql-%{pg_version}/share/extension/*.sql

# Bundled libbson files.
#
# KNOWN LIMITATION — these four paths are MAJOR-INDEPENDENT (%%{_libdir} is
# /usr/lib64), yet every per-major postgresql<N>-documentdb owns them. RPM
# tolerates a shared path only when the files are byte-identical, and this
# pipeline does not guarantee that: each major builds in its own container
# layer (POSTGRES_VERSION is baked into the build image). Co-installing two
# majors therefore works only while their libbson artifacts happen to match; a
# staggered release that bumps one major's version first can produce
#   "file /usr/lib64/libbson-1.0.so.0.0.0 ... conflicts with file from package
#    postgresql<M>-documentdb"
#
# Splitting these into a shared subpackage was tried and reverted: it makes the
# extension RPM un-installable on its own (every image and test that does
# `dnf install <one rpm>` fails on the unresolvable dependency until the new
# package is threaded through build_packages.sh, all three test Dockerfiles and
# the gateway build script), and it does not actually fix the root cause —
# each per-major build would still emit its own copy at the same NEVRA, so
# which bytes ship becomes decided by build order instead of by a file
# conflict. The real fix is to build libbson ONCE as its own target and publish
# it once; that is a build-pipeline change, tracked separately.
%{_libdir}/libbson-1.0.so
%{_libdir}/libbson-1.0.so.0
%{_libdir}/libbson-1.0.so.0.0.0
%{_libdir}/pkgconfig/libbson-static-1.0.pc

%changelog
# NOTE: this block is REPLACED at build time by
# packaging/update_spec_changelog.sh, which regenerates it from CHANGELOG.md.
# Entries added here are discarded; record user-visible changes in CHANGELOG.md.
* Fri Aug 29 2025 Shuai Tian <shuaitian@microsoft.com> - 0.106-0
- Add internal extension that provides extensions to the `rum` index. *[Feature]*
- Enable let support for update queries *[Feature]*. Requires `EnableVariablesSupportForWriteCommands` to be `on`.
- Enable let support for findAndModify queries *[Feature]*. Requires `EnableVariablesSupportForWriteCommands` to be `on`.
- Add internal extension that provides extensions to the `rum` index. *[Feature]*
- Optimized query for `usersInfo` command.
- Support collation with `delete` *[Feature]*. Requires `EnableCollation` to be `on`.
- Support for index hints for find/aggregate/count/distinct *[Feature]*
- Support `createRole` command *[Feature]*
- Add schema changes for Role CRUD APIs *[Feature]*
- Add support for using EntraId tokens via Plain Auth

* Mon Jul 28 2025 Shuai Tian <shuaitian@microsoft.com> - 0.105-0
- Support `$bucketAuto` aggregation stage, with granularity types: `POWERSOF2`, `1-2-5`, `R5`, `R10`, `R20`, `R40`, `R80`, `E6`, `E12`, `E24`, `E48`, `E96`, `E192` *[Feature]*
- Support `conectionStatus` command *[Feature]*.

* Mon Jun 09 2025 Shuai Tian <shuaitian@microsoft.com> - 0.104-0
- Add string case support for `$toDate` operator
- Support `sort` with collation in runtime*[Feature]*
- Support collation with `$indexOfArray` aggregation operator. *[Feature]*
- Support collation with arrays and objects comparisons *[Feature]*
- Support background index builds *[Bugfix]* (#36)
- Enable user CRUD by default *[Feature]*
- Enable let support for delete queries *[Feature]*. Requires `EnableVariablesSupportForWriteCommands` to be `on`.
- Enable rum_enable_index_scan as default on *[Perf]*
- Add public `documentdb-local` Docker image with gateway to GHCR
- Support `compact` command *[Feature]*. Requires `documentdb.enablecompact` GUC to be `on`.
- Enable role privileges for `usersInfo` command *[Feature]* 

* Fri May 09 2025 Shuai Tian <shuaitian@microsoft.com> - 0.103-0
- Support collation with aggregation and find on sharded collections *[Feature]*
- Support `$convert` on `binData` to `binData`, `string` to `binData` and `binData` to `string` (except with `format: auto`) *[Feature]*
- Fix list_databases for databases with size > 2 GB *[Bugfix]* (#119)
- Support half-precision vector indexing, vectors can have up to 4,000 dimensions *[Feature]*
- Support ARM64 architecture when building docker container *[Preview]*
- Support collation with `$documents` and `$replaceWith` stage of the aggregation pipeline *[Feature]*
- Push pg_documentdb_gw for documentdb connections *[Feature]*

* Wed Mar 26 2025 Shuai Tian <shuaitian@microsoft.com> - 0.102-0
- Support index pushdown for vector search queries *[Bugfix]*
- Support exact search for vector search queries *[Feature]*
- Inline $match with let in $lookup pipelines as JOIN Filter *[Perf]*
- Support TTL indexes *[Bugfix]* (#34)
- Support joining between postgres and documentdb tables *[Feature]* (#61)
- Support current_op command *[Feature]* (#59)
- Support for list_databases command *[Feature]* (#45)
- Disable analyze statistics for unique index uuid columns which improves resource usage *[Perf]*
- Support collation with `$expr`, `$in`, `$cmp`, `$eq`, `$ne`, `$lt`, `$lte`, `$gt`, `$gte` comparison operators (Opt-in) *[Feature]*
- Support collation in `find`, aggregation `$project`, `$redact`, `$set`, `$addFields`, `$replaceRoot` stages (Opt-in) *[Feature]*
- Support collation with `$setEquals`, `$setUnion`, `$setIntersection`, `$setDifference`, `$setIsSubset` in the aggregation pipeline (Opt-in) *[Feature]*
- Support unique index truncation by default with new operator class *[Feature]*
- Top level aggregate command `let` variables support for `$geoNear` stage *[Feature]*
- Enable Backend Command support for Statement Timeout *[Feature]*
- Support type aggregation operator `$toUUID`. *[Feature]*
- Support Partial filter pushdown for `$in` predicates *[Perf]*
- Support the $dateFromString operator with full functionality *[Feature]*
- Support extended syntax for `$getField` aggregation operator. Now the value of 'field' could be an expression that resolves to a string. *[Feature]*

* Wed Feb 12 2025 Shuai Tian <shuaitian@microsoft.com> - 0.101-0
- Push $graphlookup recursive CTE JOIN filters to index *[Perf]*
- Build pg_documentdb for PostgreSQL 17 *[Infra]* (#13)
- Enable support of currentOp aggregation stage, along with collstats, dbstats, and indexStats *[Commands]* (#52)
- Allow inlining $unwind with $lookup with `preserveNullAndEmptyArrays` *[Perf]*
- Skip loading documents if group expression is constant *[Perf]*
- Fix Merge stage not outputing to target collection *[Bugfix]* (#20)

* Thu Jan 23 2025 Shuai Tian <shuaitian@microsoft.com> - 0.100-0
- Initial Release
