# Auto-detect whether to use the distro's native PostgreSQL (Fedora >=43) or
# the PGDG repository layout (EL9 and older Fedora). Dependencies pin PG 18.
# Callers can
# override with `--define "postgresql_default N"`.
%if 0%{?fedora} >= 43
%{!?postgresql_default:%global postgresql_default 1}
%else
%{!?postgresql_default:%global postgresql_default 0}
%endif

%global sname documentdb
%global pgversion 18

%if %?postgresql_default
%global pkgname %{sname}
%else
%global pkgname postgresql%{pgversion}-%{sname}
%endif

%if %?postgresql_default
%global pg_config   %{_bindir}/pg_config
%global pg_libdir   %{_libdir}/pgsql
%global pg_sharedir %{_datadir}/pgsql
%else
%global pginstdir  /usr/pgsql-%{pgversion}
%global pg_config   %{pginstdir}/bin/pg_config
%global pg_libdir   %{pginstdir}/lib
%global pg_sharedir %{pginstdir}/share
%endif

%global pg_cron_version 1.6.7
%global libbson_version 1.28.0
%global intelmathlib_version 2.0u3-1
%global pcre2_version 10.44

# Debuginfo is disabled: mixed C (PGXS) and Rust (cargo) builds with vendored
# libraries make split-debuginfo unreliable.  Revisit when pgrx gains native
# debuginfo support.  Binaries are stripped by the default %%__os_install_post.
%global debug_package %{nil}

Name:           %{pkgname}
Version:        1.0
Release:        0%{?dist}
Summary:        Document-oriented NoSQL engine for PostgreSQL
License:        MIT AND Apache-2.0 AND BSD-3-Clause AND PostgreSQL
URL:            https://documentdb.io
Source0:        https://github.com/%{sname}/%{sname}/archive/refs/tags/v%{version}-0.tar.gz#/%{sname}-%{version}-0.tar.gz
# Bundled: libbson (from mongo-c-driver).  The extensions link against
# libbson-static-1.0 (see Makefile.cflags) to avoid a soname ABI coupling
# between the extension .so and whatever libbson the user may have
# installed via other packages.  Fedora's libbson-devel does not ship a
# static archive, so we must vendor and build our own.
Source1:        https://github.com/mongodb/mongo-c-driver/releases/download/%{libbson_version}/mongo-c-driver-%{libbson_version}.tar.gz
# Bundled: Intel Decimal Floating-Point Math Library.  Not packaged in
# Fedora or EPEL.  Required by pg_documentdb_core for BSON Decimal128
# arithmetic; linked statically as libbid.a.
# Generate: git clone --depth 1 -b applied/2.0u3-1 https://git.launchpad.net/ubuntu/+source/intelrdfpmath intelrdfpmath-2.0u3-1 && tar czf intelrdfpmath-2.0u3-1.tar.gz intelrdfpmath-2.0u3-1
Source2:        intelrdfpmath-%{intelmathlib_version}.tar.gz
# Gateway Cargo vendor tree (offline Rust build; see %%cargo_prep below).
# Generate with packaging/copr/Makefile to include Cargo's Git source replacements.
Source3:        documentdb-gateway-vendor.tar.gz
# Bundled: pg_cron (PostgreSQL License).  Only used on Fedora native PG,
# where no pg_cron RPM exists in the distro repos.  PGDG builds get
# pg_cron_%%{pgversion} from the PGDG repository and don't extract this.
Source4:        https://github.com/citusdata/pg_cron/archive/refs/tags/v%{pg_cron_version}.tar.gz#/pg_cron-%{pg_cron_version}.tar.gz
# Bundled: PCRE2 (BSD).  Only used on EL9/PGDG, which does not ship
# pcre2-static (it exists in Fedora and on EL9 only as mingw cross
# packages).  Fedora builds use the distro pcre2-static instead and do
# not extract this source.
Source5:        https://github.com/PCRE2Project/pcre2/releases/download/pcre2-%{pcre2_version}/pcre2-%{pcre2_version}.tar.gz
Source6:        documentdb-gateway.logrotate
Source7:        documentdb-sources.sha256
Source8:        documentdb-gateway-sysusers.conf

ExclusiveArch:  x86_64 aarch64

BuildRequires: gcc
BuildRequires: make
BuildRequires: cmake
BuildRequires: pkgconfig
BuildRequires: jq
%if %?postgresql_default
BuildRequires: postgresql-server-devel >= %{pgversion}
BuildRequires: postgresql-server-devel < 19
%else
# PGDG ships the PostgreSQL server headers in postgresql<NN>-devel on EL,
# not postgresql<NN>-server-devel (the latter does not exist in pgdg repos).
BuildRequires: postgresql%{pgversion}-devel
%endif
BuildRequires: pkgconfig(icu-uc)
BuildRequires: pkgconfig(icu-i18n)
BuildRequires: pkgconfig(krb5)
BuildRequires: pkgconfig(libpcre2-8)
# pcre2 is linked statically into the extension .so (pg_documentdb_core's
# Makefile uses `pkg-config --static --libs libpcre2-8`).  pcre2-static
# is available in Fedora; on EL9/PGDG no x86_64 pcre2-static exists
# (only mingw cross packages), so we vendor and build PCRE2 from source
# in that branch instead.
%if %?postgresql_default
BuildRequires: pcre2-static
%endif
BuildRequires: pkgconfig(openssl)
BuildRequires: rust >= 1.92
BuildRequires: cargo >= 1.92
BuildRequires: cargo-rpm-macros
BuildRequires: systemd-rpm-macros
BuildRequires: pkgconfig(libsasl2)
BuildRequires: pkgconfig(snappy)
BuildRequires: pkgconfig(zlib)
BuildRequires: pkgconfig(libcurl)
BuildRequires: pkgconfig(uuid)
BuildRequires: pkgconfig(liblz4)
# bzip2-devel does not ship a .pc file; kept as a package name dependency.
BuildRequires: bzip2-devel

# ---------------------------------------------------------------------------
# Runtime dependencies (extension package only; see packaging-design.md §4.1).
#
# The extension package follows the PGDG/Fedora convention used by Citus,
# pgvector, pg_cron and TimescaleDB: it ships only the extension files and
# the PostgreSQL-side runtime deps it links against / `CREATE EXTENSION
# CASCADE`s into.  It does NOT pull in operator helpers, gateway, or
# appliance lifecycle -- those live in `documentdb-tools`, `documentdb-
# gateway`, and `documentdb-local-N` respectively.
# ---------------------------------------------------------------------------
%if %?postgresql_default
Requires:       postgresql-server >= %{pgversion}
Requires:       postgresql-server < 19
Requires:       postgresql-contrib >= %{pgversion}
Requires:       postgresql-contrib < 19
Requires:       pgvector
Requires:       postgis
%else
Requires:       postgresql%{pgversion}-server
Requires:       pgvector_%{pgversion}
Requires:       pg_cron_%{pgversion}
Requires:       postgis36_%{pgversion}
%endif

Provides:       bundled(libbson) = %{libbson_version}
Provides:       bundled(intelmathlib) = %{intelmathlib_version}
%if %?postgresql_default
Provides:       bundled(pg_cron) = %{pg_cron_version}
%else
Provides:       bundled(pcre2) = %{pcre2_version}
%endif

%description
DocumentDB is the open-source engine powering Azure DocumentDB.
It offers a native implementation of document-oriented NoSQL database,
enabling seamless CRUD operations on BSON data types within a PostgreSQL
framework.

This package ships the PostgreSQL extension only (documentdb_core,
documentdb, documentdb_extended_rum).  Install `documentdb-gateway` for
the MongoDB wire-protocol daemon.  (TODO: a future `documentdb-local-N`
appliance subpackage will bundle the extension + gateway + setup wizard;
see packaging-design.md.)

# ---------------------------------------------------------------------------
# Subpackage: documentdb-gateway (see packaging-design.md §4.3).
#
# The "lean daemon" promise: this package ships the MongoDB wire-protocol
# daemon and its systemd plumbing only.  It does NOT install PostgreSQL,
# the documentdb extension, the setup wizard, or sample data.  TODO: those
# will be pulled in by the planned `documentdb-local-N` appliance meta
# subpackage once that work lands (see packaging-design.md §4.4).  This
# mirrors the design's per-package promises and keeps `apt/dnf install
# documentdb-gateway` usable against a separately-provisioned PostgreSQL.
#
# Per design §7: the gateway-to-extension relationship is `Suggests:` (not
# `Requires:` or `Recommends:`).  apt installs `Recommends:` by default,
# which would silently pull an extension package onto hosts that already
# have their own provisioning -- exactly the surprise the design rules out.
# ---------------------------------------------------------------------------
%package -n documentdb-gateway
Summary:        MongoDB wire protocol proxy for PostgreSQL
Suggests:       %{name} = %{version}-%{release}
Requires:       jq
# The gateway invokes the `openssl` CLI at startup to auto-generate self-signed
# TLS material when no certificate paths are configured (see docdb_openssl.rs).
# Without this, gateway startup fails with "Failed to create TLS provider".
Requires:       openssl
Requires:       /usr/sbin/runuser
# Required by Fedora packaging guidelines: packages must rotate their own logs.
# We ship a logrotate.d drop-in for the gateway's state directory.
Requires:       logrotate
Requires(pre):  shadow-utils
%{?systemd_requires}
BuildRequires:  systemd

%description -n documentdb-gateway
The DocumentDB Gateway is a Rust-based proxy that implements the MongoDB
wire protocol and translates requests to the DocumentDB PostgreSQL
extensions.  This package ships the gateway daemon, its hardened systemd
unit, a logrotate drop-in, and the example SetupConfiguration.json.

%pre -n documentdb-gateway
%if %{defined sysusers_create_compat}
%sysusers_create_compat %{SOURCE8}
%else
getent group documentdb-gateway >/dev/null || groupadd -r documentdb-gateway
getent passwd documentdb-gateway >/dev/null || \
    useradd -r -M -g documentdb-gateway -d /nonexistent -s /sbin/nologin \
            -c "DocumentDB Gateway" documentdb-gateway
%endif

%post -n documentdb-gateway
%systemd_post documentdb-gateway.service
systemd-tmpfiles --create %{_tmpfilesdir}/documentdb-gateway.conf || :

%preun -n documentdb-gateway
%systemd_preun documentdb-gateway.service

%postun -n documentdb-gateway
%systemd_postun_with_restart documentdb-gateway.service

# ---------------------------------------------------------------------------
# Subpackage: documentdb-local-%%{pgversion}  --  TODO (not yet implemented).
# See packaging-design.md §4.4.
#
# DEFERRED: the appliance subpackage will bring up DocumentDB end-to-end on
# a single host -- pulling in the extension and the gateway, owning the
# appliance-side PostgreSQL systemd unit, and shipping the `documentdb-
# setup` wizard plus sample data and helper scripts.  None of that code
# is wired into the spec yet; the corresponding `%%package`, scriptlets,
# `%%install` actions for `documentdb-setup`, `documentdb-postgresql.
# service`, helper scripts, and sample data, and the `%%files` block must
# all be added together when the appliance work lands.  Until then this
# spec emits only the extension and gateway subpackages.
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# Subpackage: documentdb-tools (operator helpers).  See
# packaging-design.md §4.2.
#
# DEFERRED: the design's `documentdb-tune`, `documentdb-createcluster`,
# and `documentdb-local switch-default` helpers do not exist in the
# source tree yet.  Until they land, there is no `documentdb-tools`
# subpackage.  When the helpers ship, add the subpackage here and have
# the (also TODO) `documentdb-local-%%{pgversion}` appliance declare
# `Requires: documentdb-tools = ...`.
# ---------------------------------------------------------------------------

%ldconfig_scriptlets

# PGDG installs to /usr/pgsql-18/lib which triggers the default RPATH check.
# Native PG paths don't have this issue.
%if !0%{?postgresql_default}
%global __brp_check_rpaths QA_RPATHS=0x0002 /usr/lib/rpm/check-rpaths
%endif

# ===========================================================================
%prep
pushd %{_sourcedir}
sha256sum --check %{SOURCE7}
popd

# Source tarball is always named documentdb-VERSION-0 regardless of %{name}
%setup -q -n %{sname}-%{version}-0

# Extract vendored dependency sources inside the main source tree
tar xf %{SOURCE1}
tar xf %{SOURCE2}


%if %?postgresql_default
# Native PG: extract vendored pg_cron (not in distro repos)
tar xf %{SOURCE4}
%else
# PGDG: extract vendored pcre2 (no x86_64 pcre2-static on EL9)
tar xf %{SOURCE5}
%endif

# Set up Cargo vendored dependencies for the gateway build using the
# Fedora cargo-rpm-macros.  %%cargo_prep -v <dir> writes a .cargo/config.toml
# that pins the build to the vendored crate tree.
pushd pg_documentdb_gw
tar xf %{SOURCE3}
%cargo_prep -v vendor
mv vendor-config.toml .cargo/vendor-config.toml
%if 0%{?rhel} == 9
# nacelle 0.3.1 declares Rust 1.95, but this locked gateway also builds with
# EL9's Rust 1.92. Backport only these manifests; keep Cargo's MSRV checks.
for crate in nacelle nacelle-codec nacelle-core nacelle-openssl nacelle-tcp; do
    manifest="vendor/${crate}/Cargo.toml"
    grep -qx 'rust-version = "1.95"' "$manifest"
    sed -i 's/^rust-version = "1.95"$/rust-version = "1.92"/' "$manifest"
    checksum="vendor/${crate}/.cargo-checksum.json"
    digest=$(sha256sum "$manifest" | cut -d' ' -f1)
    jq --arg digest "$digest" '.files["Cargo.toml"] = $digest' "$checksum" > "${checksum}.tmp"
    mv "${checksum}.tmp" "$checksum"
done
%endif
popd

# Remove internal/ (proprietary pg_documentdb_distributed) from build targets
sed -i '/internal/d' Makefile

# Strip -Werror from all Makefiles to avoid build failures with newer GCC.
# This must be done here rather than via a PG_CFLAGS command-line override because
# sub-Makefiles append to PG_CFLAGS (e.g. -DCROARING_ATOMIC_IMPL=3 in pg_documentdb/).
sed -i 's/-Werror //g' Makefile.cflags pg_documentdb_extended_rum/core/Makefile

%if !%?postgresql_default
# Polyfill str::floor_char_boundary() which is only stable since Rust 1.91.
# EL9 ships Rust 1.88, so replace with an equivalent using is_char_boundary()
# (stable since Rust 1.0). Only apply when the system Rust is too old.
RUST_MINOR=$(rustc --version | sed -n 's/^rustc [0-9]\+\.\([0-9]\+\)\..*/\1/p')
if [ "${RUST_MINOR:-0}" -lt 91 ]; then
    sed -i 's|command_str\.floor_char_boundary(MAX_EXPLAIN_BSON_COMMAND_LENGTH)|{ let mut i = MAX_EXPLAIN_BSON_COMMAND_LENGTH.min(command_str.len()); while i > 0 \&\& !command_str.is_char_boundary(i) { i -= 1; } i }|' \
        pg_documentdb_gw/documentdb_gateway_core/src/explain/mod.rs
fi
%endif

# NOTE: we deliberately do NOT use %%generate_buildrequires /
# %%cargo_generate_buildrequires here.  The gateway's crate tree is fully
# vendored by Source3 and wired in via `%%cargo_prep -v vendor` in %prep,
# so cargo never touches the network at build time.  Emitting dynamic
# `BuildRequires: crate(...)` lines would force dnf to install the crates
# from distro repos instead -- that works on Fedora 43 (which has a
# reasonably complete rust-* set) but fails on EPEL 9, which ships almost
# no crate RPMs.  See packaging/copr/test_copr_dynamic_br.sh for the local
# reproducer of that Copr failure mode.

# ===========================================================================
%build
_vendored=$(pwd)/_vendored
mkdir -p ${_vendored}/lib/pkgconfig

# ---- 1. Build vendored libbson from mongo-c-driver ----
# The PostgreSQL extensions link libbson statically via the
# `libbson-static-1.0` pkg-config module (see Makefile.cflags).  We enable
# the static archive explicitly here and do NOT install the shared .so
# into %%{_libdir} (it would be dead weight and would clash with Fedora's
# own libbson package on systems that happen to have it installed).
mkdir -p mongo-c-driver-%{libbson_version}/build
pushd mongo-c-driver-%{libbson_version}/build
%{__cmake} \
    -DENABLE_MONGOC=OFF \
    -DENABLE_STATIC=ON \
    -DMONGOC_ENABLE_ICU=OFF \
    -DENABLE_ICU=OFF \
    -DCMAKE_C_FLAGS="-fPIC -g" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=${_vendored} \
    -DCMAKE_INSTALL_LIBDIR=lib \
    ..
%{__make} %{?_smp_mflags} install
popd

# ---- 2. Build vendored Intel Decimal Math Library ----
pushd intelrdfpmath-%{intelmathlib_version}/LIBRARY
%{__make} %{?_smp_mflags} _CFLAGS_OPT=-fPIC CC=gcc \
    CALL_BY_REF=0 GLOBAL_RND=0 GLOBAL_FLAGS=0 UNCHANGED_BINARY_FLAGS=0
popd

# Create intelmathlib pkg-config file pointing at the source build tree
cat > ${_vendored}/lib/pkgconfig/intelmathlib.pc << EOF
prefix=$(pwd)/intelrdfpmath-%{intelmathlib_version}
libdir=\${prefix}/LIBRARY
includedir=\${prefix}/LIBRARY/src

Name: intelmathlib
Description: Intel Decimal Floating point math library
Version: 2.0 Update 2
Cflags: -I\${includedir}
Libs: -L\${libdir} -lbid
EOF

%if !%?postgresql_default
# ---- 3. Build vendored pcre2 static library (PGDG only) ----
# EL9 has no x86_64 pcre2-static package, so we build PCRE2 from source
# with -DBUILD_SHARED_LIBS=OFF and let the extension link in libpcre2-8.a
# via the existing `pkg-config --static --libs libpcre2-8` flow.  Only
# the 8-bit code unit width is built (matching what PostgreSQL uses).
mkdir -p pcre2-%{pcre2_version}/build
pushd pcre2-%{pcre2_version}/build
%{__cmake} \
    -DCMAKE_C_FLAGS="-fPIC" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=${_vendored} \
    -DCMAKE_INSTALL_LIBDIR=lib \
    -DBUILD_SHARED_LIBS=OFF \
    -DPCRE2_BUILD_PCRE2_8=ON \
    -DPCRE2_BUILD_PCRE2_16=OFF \
    -DPCRE2_BUILD_PCRE2_32=OFF \
    -DPCRE2_BUILD_PCRE2GREP=OFF \
    -DPCRE2_BUILD_TESTS=OFF \
    ..
%{__make} %{?_smp_mflags} install
popd
%endif

# ---- 4. Build C PostgreSQL extensions ----
# Disable LLVM/JIT bitcode: we don't ship bitcode (removed in the install stage).
export PKG_CONFIG_PATH=${_vendored}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}
%{__make} %{?_smp_mflags} \
    PG_CONFIG=%{pg_config} \
    with_llvm=no

%if %?postgresql_default
# ---- 4b. Build vendored pg_cron (native PG only) ----
pushd pg_cron-%{pg_cron_version}
%{__make} %{?_smp_mflags} PG_CONFIG=%{pg_config} with_llvm=no
popd
%endif

# ---- 5. Build gateway binary ----
pushd pg_documentdb_gw
%cargo_build -- -p documentdb_gateway --config .cargo/vendor-config.toml
popd

# ===========================================================================
%install
_vendored=$(pwd)/_vendored
export PKG_CONFIG_PATH=${_vendored}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}

# ---- Install C extensions via PGXS ----
%{__make} install DESTDIR=%{buildroot} \
    PG_CONFIG=%{pg_config} \
    with_llvm=no

# Remove LLVM/JIT bitcode directory
rm -rf %{buildroot}%{pg_libdir}/bitcode

%if %?postgresql_default
# ---- Install vendored pg_cron (native PG only) ----
pushd pg_cron-%{pg_cron_version}
%{__make} install DESTDIR=%{buildroot} PG_CONFIG=%{pg_config}
popd
%endif

# ---- Bundle vendored libbson ----
# Only the static archive is linked into the extension .so; nothing at
# runtime needs the shared library, so we deliberately do NOT ship the
# libbson-1.0.so* set that the upstream `make install` placed into
# ${_vendored}/lib.  This keeps the package free of a second libbson
# soname on disk and avoids OWASP A06 (vulnerable bundled component)
# exposure for a shared library we'd otherwise have to track for CVEs.

# ---- Bundle Intel Decimal Math Library static lib ----
mkdir -p %{buildroot}%{_libdir}/intelmathlib/LIBRARY
cp intelrdfpmath-%{intelmathlib_version}/LIBRARY/libbid.a \
   %{buildroot}%{_libdir}/intelmathlib/LIBRARY/

# ---- Install gateway runtime (binary, config, systemd unit, logrotate) ----
# The gateway crate is one member of a Cargo workspace, so invoke
# %%cargo_install from the specific crate directory rather than the workspace
# root.  This installs the `documentdb_gateway` binary into
# %%{buildroot}%%{_bindir}.
#
# TODO: when the `documentdb-local-%%{pgversion}` appliance subpackage lands
# (see packaging-design.md §4.4), re-add the `install` lines for
# `documentdb-setup`, `documentdb-postgresql.service`, the helper scripts
# under `documentdb-local/scripts/`, and the sample-data tree alongside
# its corresponding `%%files` block.
pushd pg_documentdb_gw/documentdb_gateway
%cargo_install -- --locked --config ../.cargo/vendor-config.toml
popd
install -d %{buildroot}%{_prefix}/lib/documentdb-gateway
mv %{buildroot}%{_bindir}/documentdb_gateway \
    %{buildroot}%{_prefix}/lib/documentdb-gateway/documentdb-gateway-daemon
install -D -m 0755 packaging/gateway/documentdb-gateway-wrapper.sh \
    %{buildroot}%{_bindir}/documentdb-gateway
install -d %{buildroot}%{_sysconfdir}/documentdb/gateway
bash packaging/gateway/strip-setup-config.sh pg_documentdb_gw/SetupConfiguration.json \
    %{buildroot}%{_sysconfdir}/documentdb/gateway/SetupConfiguration.json
chmod 0644 %{buildroot}%{_sysconfdir}/documentdb/gateway/SetupConfiguration.json
install -D -m 0644 packaging/gateway/config/gateway.env \
    %{buildroot}%{_sysconfdir}/documentdb/gateway/gateway.env
install -D -m 0644 %{SOURCE8} \
    %{buildroot}%{_sysusersdir}/documentdb-gateway.conf
install -D -m 0644 packaging/gateway/tmpfiles/documentdb-gateway.conf \
    %{buildroot}%{_tmpfilesdir}/documentdb-gateway.conf
install -d -m 0750 %{buildroot}%{_localstatedir}/lib/documentdb-gateway
install -D -m 0644 packaging/gateway/systemd/documentdb-gateway.service \
    %{buildroot}%{_unitdir}/documentdb-gateway.service
install -D -m 0644 %{SOURCE6} \
    %{buildroot}%{_sysconfdir}/logrotate.d/documentdb-gateway

# ---- Bundle source code for make check ----
%global docdb_srcdir %{_datadir}/documentdb/source
mkdir -p %{buildroot}%{docdb_srcdir}
cp -r . %{buildroot}%{docdb_srcdir}/
# Clean up build artifacts and vendored build trees from the source copy
find %{buildroot}%{docdb_srcdir} -name "*.o" -delete
find %{buildroot}%{docdb_srcdir} -name "*.so" -delete
find %{buildroot}%{docdb_srcdir} -name "*.bc" -delete
rm -rf %{buildroot}%{docdb_srcdir}/.git*
rm -rf %{buildroot}%{docdb_srcdir}/build
rm -rf %{buildroot}%{docdb_srcdir}/_vendored
rm -rf %{buildroot}%{docdb_srcdir}/mongo-c-driver-%{libbson_version}
rm -rf %{buildroot}%{docdb_srcdir}/intelrdfpmath-%{intelmathlib_version}
rm -rf %{buildroot}%{docdb_srcdir}/pg_documentdb_gw/target
rm -rf %{buildroot}%{docdb_srcdir}/pg_documentdb_gw/vendor
# Strip the .cargo/config.toml that %cargo_prep wrote with the absolute
# buildroot path baked in (e.g. `root = "/root/rpmbuild/BUILDROOT/..."`).
rm -rf %{buildroot}%{docdb_srcdir}/pg_documentdb_gw/.cargo
%if %?postgresql_default
rm -rf %{buildroot}%{docdb_srcdir}/pg_cron-%{pg_cron_version}
%else
rm -rf %{buildroot}%{docdb_srcdir}/pcre2-%{pcre2_version}
%endif

# Ensure extension shared objects are marked as executable ELF files.
chmod 0755 %{buildroot}%{pg_libdir}/*.so

# ===========================================================================
# FEDORA GUIDELINE NOTE: %check section is intentionally absent.
# DocumentDB's regression suite (`make check`) requires
# a running PostgreSQL cluster, the documentdb extensions to be loaded into
# shared_preload_libraries, and a working pg_cron + pgvector + postgis stack
# -- none of which are available in the rpmbuild/mock chroot.  The packaged
# source tree under %%{_datadir}/documentdb/source lets a downstream operator
# run the full suite post-install.
%files
%license LICENSE NOTICE licenses/
%doc README.md CHANGELOG.md
%{pg_libdir}/*.so
%{pg_sharedir}/extension/*.control
%{pg_sharedir}/extension/*.sql
# Both the extension and gateway subpackages own %%{_datadir}/documentdb so
# a single-package install leaves no unowned directory.  TODO: the planned
# `documentdb-local-%%{pgversion}` appliance subpackage will also need to
# claim ownership of this directory when it lands.
%dir %{_datadir}/documentdb
%{_datadir}/documentdb/source
%{_libdir}/intelmathlib/LIBRARY/libbid.a

%files -n documentdb-gateway
%license LICENSE NOTICE pg_documentdb_gw/licenses
%doc README.md
%{_bindir}/documentdb-gateway
%dir %{_prefix}/lib/documentdb-gateway
%{_prefix}/lib/documentdb-gateway/documentdb-gateway-daemon
%dir %{_sysconfdir}/documentdb
%dir %{_sysconfdir}/documentdb/gateway
%config(noreplace) %{_sysconfdir}/documentdb/gateway/SetupConfiguration.json
%config(noreplace) %{_sysconfdir}/documentdb/gateway/gateway.env
%{_sysusersdir}/documentdb-gateway.conf
%{_tmpfilesdir}/documentdb-gateway.conf
%dir %attr(0750,documentdb-gateway,documentdb-gateway) %{_localstatedir}/lib/documentdb-gateway
%{_unitdir}/documentdb-gateway.service
%config(noreplace) %{_sysconfdir}/logrotate.d/documentdb-gateway
%dir %{_datadir}/documentdb

# TODO: %%files -n documentdb-local-%%{pgversion} block goes here once the
# appliance subpackage is implemented (see packaging-design.md §4.4).
# It will own /usr/bin/documentdb-setup, the documentdb-postgresql
# systemd unit, the helper scripts under %%{_datadir}/documentdb/scripts,
# and the sample-data tree.


# ===========================================================================
%changelog
* Thu Oct 29 2026 DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com> - 1.0-2
- Build only libbson from mongo-c-driver for newer Fedora OpenSSL headers.
- Constrain native PostgreSQL dependencies to major 18.
- Backport the pinned nacelle manifests for EL9's Rust 1.92 toolchain.

* Thu Oct 29 2026 DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com> - 1.0-1
- Package the DocumentDB v1.0-0 release as RPM version 1.0.
- Align the gateway runtime layout with the release's service and wrapper.

* Fri May 15 2026 Alexander Laye <alaye@microsoft.com> - 0.110-0
- Initial Release