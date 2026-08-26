%define debug_package %{nil}

Name:           documentdb-postgresql-tools
Version:        DOCUMENTDB_VERSION
Release:        1%{?dist}
Summary:        PostgreSQL administrator helpers for DocumentDB
BuildArch:      noarch

License:        MIT
URL:            https://github.com/documentdb/documentdb

# Suggests (not Requires/Recommends) the per-major extension and the gateway
# runtime: this package is administrator scaffolding useful even before those
# packages are installed (e.g., previewing the managed fragment via --dry-run).
# jq is a hard Requires because documentdb-gateway-admin invokes it
# unconditionally for create-user, drop-user, and reset-password (BSON-as-
# JSON construction). Without this, a Workflow B install of just the tools
# package would die at runtime with "jq: command not found".
Requires:       jq
Suggests:       documentdb-gateway

%description
PostgreSQL administrator helpers for making PostgreSQL instances
DocumentDB-ready and for registering a DocumentDB gateway against one of
them. Ships:

  - documentdb-tune              postgresql.conf managed-block writer
                                 (Debian per-instance documentdb.conf,
                                 RHEL/explicit-pgdata managed block).
  - documentdb-createcluster     Debian/Ubuntu helper that wraps
                                 pg_createcluster + documentdb-tune in
                                 one step.
  - documentdb-register-gateway  one-shot PG-side gateway registration:
                                 pg_hba.conf + pg_ident.conf managed
                                 blocks, gateway PG role creation, and
                                 the per-major connection URL file +
                                 gateway env fragment.
  - documentdb-gateway-admin     scripted user/role management against a
                                 DocumentDB-enabled PostgreSQL instance
                                 (create-user, drop-user, list-users,
                                 reset-password, check).

See packaging-design.md §4.2 for the design boundary: this package owns
all PostgreSQL-side mutations on behalf of administrators; the
documentdb-gateway runtime package is intentionally lean.

%install
install -Dpm 0755 %{_sourcedir}/documentdb-tune.sh %{buildroot}/usr/bin/documentdb-tune
install -Dpm 0755 %{_sourcedir}/documentdb-createcluster.sh %{buildroot}/usr/bin/documentdb-createcluster
install -Dpm 0755 %{_sourcedir}/documentdb-register-gateway.sh %{buildroot}/usr/bin/documentdb-register-gateway
install -Dpm 0755 %{_sourcedir}/documentdb-gateway-admin.sh %{buildroot}/usr/bin/documentdb-gateway-admin
# Shared managed-block / config-mutation library, sourced by documentdb-tune
# and documentdb-register-gateway (single-source so they cannot drift).
install -Dpm 0644 %{_sourcedir}/documentdb-tools-lib.sh %{buildroot}/usr/share/documentdb/scripts/documentdb-tools-lib.sh
# Note: the /etc/postgresql-common/createcluster.d/99-documentdb.conf hook is
# intentionally NOT installed on RHEL. Per packaging-design.md §4.2 and §8 it
# is a Debian/Ubuntu-only mechanism (RHEL has no postgresql-common /
# createcluster.d directory), and shipping the file here would create a
# non-functional /etc/postgresql-common/ tree that nothing reads. The DEB
# build (oss/packaging/postgresql-tools/build-postgresql-tools-deb.sh) is
# the only path that installs the hook.
# Inert config sample (PostgreSQL .sample convention; see packaging-design.md §4.2)
install -Dpm 0644 %{_sourcedir}/documentdb.conf.sample %{buildroot}/usr/share/doc/%{name}/examples/documentdb.conf.sample

%post
echo "DocumentDB PostgreSQL administrator tools installed."
echo "Available commands:"
echo "  documentdb-tune --pg-version N --cluster C --yes"
echo "  documentdb-register-gateway --target-postgres-instance N/C --yes"

%files
%defattr(-,root,root,-)
%attr(0755,root,root) /usr/bin/documentdb-tune
%attr(0755,root,root) /usr/bin/documentdb-createcluster
%attr(0755,root,root) /usr/bin/documentdb-register-gateway
%attr(0755,root,root) /usr/bin/documentdb-gateway-admin
%attr(0644,root,root) /usr/share/documentdb/scripts/documentdb-tools-lib.sh
# /etc/postgresql-common/createcluster.d/99-documentdb.conf is intentionally
# omitted here — see the comment in the install section above.
%doc %attr(0644,root,root) /usr/share/doc/%{name}/examples/documentdb.conf.sample

%changelog
* Mon Jun 15 2026 DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com> - %{version}-%{release}
- Initial documentdb-postgresql-tools package: administrator helper scripts
  (documentdb-tune, documentdb-createcluster, documentdb-register-gateway,
  documentdb-gateway-admin) that make a PostgreSQL instance DocumentDB-ready
  and register a gateway against it.
