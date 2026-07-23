%define debug_package %{nil}

# The noarch extras (documentdb-common, documentdb-N, documentdb meta) are
# built with rpmbuild directly on the CI Ubuntu runner (see
# oss/.github/workflows/build_rpm_packages.yml), where the systemd-rpm-macros
# package is not available on apt. Self-define the systemd unit/sysusers/tmpfiles
# directory macros when they are not already provided, so they resolve to the
# usr-merged RHEL locations on every build host. On RHEL/Fedora builders
# systemd-rpm-macros defines them first, so the conditional definitions below
# are no-ops there.
%{!?_unitdir: %global _unitdir /usr/lib/systemd/system}
%{!?_sysusersdir: %global _sysusersdir /usr/lib/sysusers.d}
%{!?_tmpfilesdir: %global _tmpfilesdir /usr/lib/tmpfiles.d}

Name:           documentdb-common
Version:        DOCUMENTDB_VERSION
Release:        1%{?dist}
Summary:        DocumentDB stand-alone shared payload (PG-agnostic)
BuildArch:      noarch

License:        MIT
URL:            https://github.com/documentdb/documentdb

# documentdb-common owns documentdb-setup, which delegates to documentdb-tune
# and documentdb-register-gateway (documentdb-postgresql-tools) and drives the
# gateway runtime, so the PG-agnostic runtime dependencies live here (moved
# from the per-major documentdb-N packages). Pin `>= %%{version}` so a release
# qualifier differing across arch/distro builds does not block installs, the
# same rationale the per-major package used.
Requires:       documentdb-gateway >= %{version}
Requires:       documentdb-postgresql-tools >= %{version}
Requires:       jq

# The %pre scriptlet creates the documentdb-local system user via
# sysusers_create_compat (RHEL/Fedora builders, where systemd-rpm-macros
# defines it) or a groupadd/useradd fallback, both of which come from
# shadow-utils.
Requires(pre):  shadow-utils
# Declare systemd-rpm-macros as a BuildRequires on RHEL/Fedora builders, where
# it is the canonical provider of the unit/sysusers/tmpfiles path macros and
# the sysusers_create_compat helper. It is guarded out on the Ubuntu noarch
# build host (see build_rpm_packages.yml), where the package is unavailable on
# apt and the conditional macro definitions near the top of this spec supply
# the only macros the build needs.
%if 0%{?rhel} || 0%{?fedora}
BuildRequires:  systemd-rpm-macros
%endif

%description
Shared, PostgreSQL-major-agnostic payload for the DocumentDB stand-alone
packages: the documentdb-setup wizard, documentdb-local-reset, the systemd
template units (documentdb-local@.target, documentdb-postgresql@.service,
documentdb-gateway-local@.service), the sysusers.d and tmpfiles.d drop-ins,
the helper scripts those units consume, and the sample data. Each per-major
documentdb-N package depends on this package, so the shared payload is owned
exactly once regardless of how many PostgreSQL majors are installed.

%pre
# Create the documentdb-local system user/group from the shipped sysusers.d
# definition so it is created consistently with the DEB packaging and the
# drop-in stays authoritative. This bootstrap moved here from documentdb-N:
# documentdb-common owns the sysusers.d/tmpfiles.d drop-ins, and rpm installs
# it before any documentdb-N that Requires it, so the user and runtime dirs
# exist before a per-major package's scriptlets run. sysusers_create_compat
# (EL9 / Fedora) bakes the equivalent groupadd/useradd from the sysusers.d
# entry at build time. EL8's base systemd-rpm-macros predates that macro, so
# fall back to a direct groupadd/useradd that creates the same system user.
%if %{defined sysusers_create_compat}
%sysusers_create_compat %{_sourcedir}/documentdb-local-sysusers.conf
%else
getent group documentdb-local >/dev/null || groupadd --system documentdb-local
id -u documentdb-local >/dev/null 2>&1 || \
    useradd --system --no-create-home --home-dir /var/lib/documentdb-local \
        --shell /usr/sbin/nologin --gid documentdb-local \
        -c "DocumentDB Local cluster owner" documentdb-local
%endif
install -d -m 0755 -o documentdb-local -g documentdb-local /var/lib/documentdb-local
install -d -m 0755 -o documentdb-local -g documentdb-local /run/documentdb-local
install -d -m 0755 -o documentdb-local -g documentdb-local /var/log/documentdb-local

%install
install -Dpm 0755 %{_sourcedir}/documentdb-setup.sh %{buildroot}/usr/bin/documentdb-setup
install -Dpm 0755 %{_sourcedir}/documentdb-local-reset.sh %{buildroot}/usr/bin/documentdb-local-reset
install -Dpm 0644 %{_sourcedir}/documentdb-local@.target %{buildroot}%{_unitdir}/documentdb-local@.target
install -Dpm 0644 %{_sourcedir}/documentdb-postgresql@.service %{buildroot}%{_unitdir}/documentdb-postgresql@.service
install -Dpm 0644 %{_sourcedir}/documentdb-gateway-local@.service %{buildroot}%{_unitdir}/documentdb-gateway-local@.service
install -Dpm 0644 %{_sourcedir}/documentdb-local-sysusers.conf %{buildroot}%{_sysusersdir}/documentdb-local.conf
install -Dpm 0644 %{_sourcedir}/documentdb-local-tmpfiles.conf %{buildroot}%{_tmpfilesdir}/documentdb-local.conf
install -Dpm 0755 %{_sourcedir}/documentdb_postgresql_service.sh %{buildroot}/usr/share/documentdb/scripts/documentdb_postgresql_service.sh
install -Dpm 0755 %{_sourcedir}/init_documentdb_data.sh %{buildroot}/usr/share/documentdb/scripts/init_documentdb_data.sh
# Install every sample-data file (glob, not an enumerated list) so adding or
# removing a sample file stays in lock-step with the DEB build
# (build-common-deb.sh globs the same directory) instead of silently shipping
# on only one packaging family.
for _sd in %{_sourcedir}/sample-data/*; do
    [ -f "${_sd}" ] || continue
    install -Dpm 0644 "${_sd}" %{buildroot}/usr/share/documentdb/sample-data/"$(basename "${_sd}")"
done

%post
# Template units are handled explicitly instead of with systemd RPM macros:
# the noarch extras are also built on Ubuntu runners where those macros are
# intentionally unavailable, and presetting/enabling a template at package
# install time would violate the design's explicit setup step.
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
fi

%postun
# On remove/erase the shipped template units are unlinked; reload systemd so it
# no longer references the deleted unit files. The documentdb-local system user
# and /var/lib/documentdb-local (which may hold private PostgreSQL data in
# greenfield installs) are intentionally left in place, matching the per-major
# packages' data-preservation behavior.
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
fi

%files
%defattr(-,root,root,-)
%attr(0755,root,root) /usr/bin/documentdb-setup
%attr(0755,root,root) /usr/bin/documentdb-local-reset
%attr(0644,root,root) %{_unitdir}/documentdb-local@.target
%attr(0644,root,root) %{_unitdir}/documentdb-postgresql@.service
%attr(0644,root,root) %{_unitdir}/documentdb-gateway-local@.service
%attr(0644,root,root) %{_sysusersdir}/documentdb-local.conf
%attr(0644,root,root) %{_tmpfilesdir}/documentdb-local.conf
%attr(0755,root,root) /usr/share/documentdb/scripts/documentdb_postgresql_service.sh
%attr(0755,root,root) /usr/share/documentdb/scripts/init_documentdb_data.sh
%attr(0644,root,root) /usr/share/documentdb/sample-data/*

%changelog
* Tue Jun 23 2026 DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com> - %{version}-%{release}
- Initial documentdb-common shared-payload package: the PG-agnostic
  documentdb-setup / documentdb-local-reset CLIs, systemd template units,
  sysusers.d and tmpfiles.d drop-ins, helper scripts, and sample data,
  owned once so multiple per-major documentdb-N packages co-install cleanly.
