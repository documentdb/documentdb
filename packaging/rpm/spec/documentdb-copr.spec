%global pg_version 18
%global libbson_version 1.28.0
%global intelmathlib_version 2.0u3-1
%global pcre2_version 10.44

%define debug_package %{nil}

Name:           postgresql%{pg_version}-documentdb
Version:        0.111.0
Release:        1%{?dist}
Summary:        DocumentDB — document-oriented NoSQL engine for PostgreSQL

License:        MIT
URL:            https://github.com/documentdb/documentdb
Source0:        %{name}-%{version}.tar.gz
Source1:        https://github.com/mongodb/mongo-c-driver/releases/download/%{libbson_version}/mongo-c-driver-%{libbson_version}.tar.gz
# Generate: git clone --depth 1 -b applied/2.0u3-1 https://git.launchpad.net/ubuntu/+source/intelrdfpmath intelrdfpmath-2.0u3-1 && tar czf intelrdfpmath-2.0u3-1.tar.gz intelrdfpmath-2.0u3-1
Source2:        intelrdfpmath-%{intelmathlib_version}.tar.gz
# Generate: cd pg_documentdb_gw && cargo vendor && tar czf ../documentdb-gateway-vendor.tar.gz vendor/
Source3:        documentdb-gateway-vendor.tar.gz
# Vendored pcre2 source (EL9 lacks pcre2-static without CRB)
Source4:        https://github.com/PCRE2Project/pcre2/releases/download/pcre2-%{pcre2_version}/pcre2-%{pcre2_version}.tar.gz

ExclusiveArch:  x86_64 aarch64

BuildRequires:  gcc
BuildRequires:  gcc-c++
BuildRequires:  make
BuildRequires:  cmake
BuildRequires:  pkg-config
BuildRequires:  postgresql%{pg_version}-devel
BuildRequires:  libicu-devel
BuildRequires:  krb5-devel
BuildRequires:  pcre2-devel
BuildRequires:  openssl-devel
BuildRequires:  rust
BuildRequires:  cargo
BuildRequires:  cyrus-sasl-devel
BuildRequires:  snappy-devel
BuildRequires:  zlib-devel
BuildRequires:  libcurl-devel
BuildRequires:  libuuid-devel
BuildRequires:  lz4-devel
BuildRequires:  bzip2-devel

Requires:       postgresql%{pg_version}
Requires:       postgresql%{pg_version}-server
Requires:       pgvector_%{pg_version}
Requires:       pg_cron_%{pg_version}
Requires:       postgis36_%{pg_version}
# rum_18 is NOT required — documentdb_extended_rum replaces it for PG 18+

Provides:       bundled(libbson) = %{libbson_version}
Provides:       bundled(intelmathlib) = %{intelmathlib_version}
Provides:       bundled(pcre2) = %{pcre2_version}

%description
DocumentDB is the open-source engine powering Azure DocumentDB.
It offers a native implementation of document-oriented NoSQL database,
enabling seamless CRUD operations on BSON data types within a PostgreSQL
framework.

This package contains the PostgreSQL extensions: documentdb_core, documentdb,
and documentdb_extended_rum.

# ---------------------------------------------------------------------------
# Subpackage: documentdb-gateway
# ---------------------------------------------------------------------------
%package -n documentdb-gateway
Summary:        DocumentDB Gateway — MongoDB wire protocol proxy
Requires:       openssl-libs

%description -n documentdb-gateway
The DocumentDB Gateway is a Rust-based proxy that implements the MongoDB wire
protocol and translates requests to the DocumentDB PostgreSQL extensions.

# ---------------------------------------------------------------------------
# Subpackage: documentdb-server (meta-package)
# ---------------------------------------------------------------------------
%package -n documentdb-server
Summary:        DocumentDB Server — complete installation meta-package
Requires:       %{name} = %{version}-%{release}
Requires:       documentdb-gateway = %{version}-%{release}
Requires:       postgresql%{pg_version}-server

%description -n documentdb-server
Meta-package that pulls in all DocumentDB components: the PostgreSQL extensions,
the gateway binary, and the PostgreSQL server.

# PGDG installs to /usr/pgsql-18/lib which triggers Fedora's RPATH check
# (error 0x0002: "standard library path"). This is expected for PGDG extensions.
%global __brp_check_rpaths QA_RPATHS=0x0002 /usr/lib/rpm/check-rpaths

# ===========================================================================
%prep
%setup -q

# Extract vendored dependency sources inside the main source tree
tar xf %{SOURCE1}
tar xf %{SOURCE2}
tar xf %{SOURCE4}

# Set up Cargo vendored dependencies for the gateway build
pushd pg_documentdb_gw
tar xf %{SOURCE3}
mkdir -p .cargo
cat > .cargo/config.toml << 'EOF'
[source.crates-io]
replace-with = "vendored-sources"

[source.vendored-sources]
directory = "vendor"
EOF
popd

# Remove internal/ (proprietary pg_documentdb_distributed) from build targets
sed -i '/internal/d' Makefile

# Strip -Werror from all Makefiles to avoid build failures with newer GCC on Fedora.
# This must be done here rather than via a PG_CFLAGS command-line override because
# sub-Makefiles append to PG_CFLAGS (e.g. -DCROARING_ATOMIC_IMPL=3 in pg_documentdb/).
sed -i 's/-Werror //g' Makefile.cflags pg_documentdb_extended_rum/core/Makefile

# Polyfill str::floor_char_boundary() which is only stable since Rust 1.91.
# EL9 ships Rust 1.88, so replace with an equivalent using is_char_boundary()
# (stable since Rust 1.0). Only apply when the system Rust is too old.
RUST_MINOR=$(rustc --version | sed -n 's/^rustc [0-9]\+\.\([0-9]\+\)\..*/\1/p')
if [ "${RUST_MINOR:-0}" -lt 91 ]; then
    sed -i 's|command_str\.floor_char_boundary(MAX_EXPLAIN_BSON_COMMAND_LENGTH)|{ let mut i = MAX_EXPLAIN_BSON_COMMAND_LENGTH.min(command_str.len()); while i > 0 \&\& !command_str.is_char_boundary(i) { i -= 1; } i }|' \
        pg_documentdb_gw/documentdb_gateway_core/src/explain/mod.rs
fi

# ===========================================================================
%build
_vendored=$(pwd)/_vendored
mkdir -p ${_vendored}/lib/pkgconfig

# ---- 1. Build vendored libbson from mongo-c-driver ----
mkdir -p mongo-c-driver-%{libbson_version}/build
pushd mongo-c-driver-%{libbson_version}/build
cmake \
    -DENABLE_MONGOC=ON \
    -DMONGOC_ENABLE_ICU=OFF \
    -DENABLE_ICU=OFF \
    -DCMAKE_C_FLAGS="-fPIC -g" \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=${_vendored} \
    -DCMAKE_INSTALL_LIBDIR=lib \
    ..
make %{?_smp_mflags} install
popd

# ---- 2. Build vendored Intel Decimal Math Library ----
pushd intelrdfpmath-%{intelmathlib_version}/LIBRARY
make %{?_smp_mflags} _CFLAGS_OPT=-fPIC CC=gcc \
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

# ---- 3. Build vendored pcre2 static library (avoids pcre2-static dep on EL9) ----
mkdir -p pcre2-%{pcre2_version}/build
pushd pcre2-%{pcre2_version}/build
cmake \
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
make %{?_smp_mflags} install
popd

# ---- 4. Build C PostgreSQL extensions ----
export PKG_CONFIG_PATH=${_vendored}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}
make %{?_smp_mflags} \
    PG_CONFIG=/usr/pgsql-%{pg_version}/bin/pg_config

# ---- 5. Build gateway binary ----
cd pg_documentdb_gw
cargo build --release
cd ..

# ===========================================================================
%install
_vendored=$(pwd)/_vendored
export PKG_CONFIG_PATH=${_vendored}/lib/pkgconfig${PKG_CONFIG_PATH:+:${PKG_CONFIG_PATH}}

# ---- Install C extensions via PGXS ----
make install DESTDIR=%{buildroot} \
    PG_CONFIG=/usr/pgsql-%{pg_version}/bin/pg_config

# Remove LLVM/JIT bitcode directory
rm -rf %{buildroot}/usr/pgsql-%{pg_version}/lib/bitcode

# ---- Bundle vendored libbson shared libraries ----
mkdir -p %{buildroot}%{_libdir}/pkgconfig
cp    ${_vendored}/lib/libbson-1.0.so.0.0.0   %{buildroot}%{_libdir}/
cp -P ${_vendored}/lib/libbson-1.0.so.0       %{buildroot}%{_libdir}/
cp -P ${_vendored}/lib/libbson-1.0.so         %{buildroot}%{_libdir}/
cp    ${_vendored}/lib/pkgconfig/libbson-static-1.0.pc %{buildroot}%{_libdir}/pkgconfig/

# ---- Bundle Intel Decimal Math Library static lib ----
mkdir -p %{buildroot}/usr/lib/intelmathlib/LIBRARY
cp intelrdfpmath-%{intelmathlib_version}/LIBRARY/libbid.a \
   %{buildroot}/usr/lib/intelmathlib/LIBRARY/

# ---- Install gateway binary ----
install -D -m 0755 pg_documentdb_gw/target/release/documentdb_gateway \
    %{buildroot}%{_bindir}/documentdb_gateway

# ---- Bundle source code for make check ----
mkdir -p %{buildroot}/usr/src/documentdb
cp -r . %{buildroot}/usr/src/documentdb/
# Clean up build artifacts and vendored build trees from the source copy
find %{buildroot}/usr/src/documentdb -name "*.o" -delete
find %{buildroot}/usr/src/documentdb -name "*.so" -delete
find %{buildroot}/usr/src/documentdb -name "*.bc" -delete
rm -rf %{buildroot}/usr/src/documentdb/.git*
rm -rf %{buildroot}/usr/src/documentdb/build
rm -rf %{buildroot}/usr/src/documentdb/_vendored
rm -rf %{buildroot}/usr/src/documentdb/mongo-c-driver-%{libbson_version}
rm -rf %{buildroot}/usr/src/documentdb/intelrdfpmath-%{intelmathlib_version}
rm -rf %{buildroot}/usr/src/documentdb/pg_documentdb_gw/target
rm -rf %{buildroot}/usr/src/documentdb/pg_documentdb_gw/vendor

# ===========================================================================
%files
%license LICENSE NOTICE licenses/
%defattr(-,root,root,-)
/usr/pgsql-%{pg_version}/lib/*.so
/usr/pgsql-%{pg_version}/share/extension/*.control
/usr/pgsql-%{pg_version}/share/extension/*.sql
/usr/src/documentdb
/usr/lib/intelmathlib/LIBRARY/libbid.a
%{_libdir}/libbson-1.0.so
%{_libdir}/libbson-1.0.so.0
%{_libdir}/libbson-1.0.so.0.0.0
%{_libdir}/pkgconfig/libbson-static-1.0.pc

%files -n documentdb-gateway
%license LICENSE NOTICE
%{_bindir}/documentdb_gateway

%files -n documentdb-server
%license LICENSE NOTICE

# ===========================================================================
%changelog
* Mon Mar 09 2026 Shuai Tian <shuaitian@microsoft.com> - 0.111.0-1
- Update to version 0.111.0

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