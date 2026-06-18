%define debug_package %{nil}

Name:           documentdb-gateway
Version:        DOCUMENTDB_VERSION
Release:        1%{?dist}
Summary:        DocumentDB Gateway - wire protocol daemon

License:        MIT AND Apache-2.0
URL:            https://github.com/documentdb/documentdb

# Reviewer-flagged (Sonnet iter 7): jq is NOT a gateway runtime dep —
# only documentdb-gateway-admin uses it, and that ships in
# documentdb-postgresql-tools. Per packaging-design.md §4.3 the gateway
# package has "no product-specific runtime dependency beyond the OS/
# runtime libraries that the binary links to". openssl stays because
# the gateway's TLS auto-gen flow shells out to it when
# DOCUMENTDB_TLS_AUTO_GENERATE=true.
Requires:       openssl
# %pre creates the documentdb-gateway system user via groupadd/useradd
# (directly on EL8, or through the build-time-baked sysusers_create_compat
# macro on EL9), both of which come from shadow-utils.
Requires(pre):  shadow-utils
# Deliberate deviation from packaging-design.md section 4.3 (which specifies
# per-major postgresql-N-documentdb): captured here so section 4.3 can be
# updated to match and stay the source of truth for parts 2-4 of the series.
# Reviewer-flagged (Sonnet iter 9): the gateway binary is PG-major-agnostic,
# but the previous Suggests: postgresql18-documentdb misled operators on
# PG 15/16/17 hosts (dnf would suggest the wrong package). The %post
# message below points the operator at the right per-major extension
# explicitly. Suggest only the PG-agnostic tools package so dnf's
# behavior is correct across all majors. Matches the iter-8 fix that
# removed the same pattern from documentdb-postgresql-tools.
Suggests:       documentdb-postgresql-tools

# systemd-rpm-macros provides the _unitdir / _sysusersdir / _tmpfilesdir
# path macros (and the systemd_* / sysusers_create_compat scriptlet helpers)
# used below. It ships in the RHEL/Fedora build environments.
BuildRequires:  systemd-rpm-macros

%description
The DocumentDB Gateway provides wire-protocol compatibility for DocumentDB,
enabling connections from compatible clients and drivers. This is a lean
runtime package; install documentdb (or documentdb-N for a specific
PostgreSQL major) for the full stand-alone experience.

%pre
# Create the documentdb-gateway system user/group from the shipped
# sysusers.d definition so it is created consistently with the DEB
# packaging and the drop-in stays authoritative. sysusers_create_compat
# (EL9 / Fedora) bakes the equivalent groupadd/useradd from the sysusers.d
# entry at build time. EL8's base systemd-rpm-macros predates that macro
# (it is EPEL-only there), so fall back to a direct useradd that creates
# the same system user as the sysusers.d entry.
%if %{defined sysusers_create_compat}
%sysusers_create_compat %{_sourcedir}/documentdb-gateway-sysusers.conf
%else
getent group documentdb-gateway >/dev/null || groupadd --system documentdb-gateway
id -u documentdb-gateway >/dev/null 2>&1 || \
    useradd --system --no-create-home --home-dir /nonexistent \
        --shell /usr/sbin/nologin --gid documentdb-gateway \
        -c "DocumentDB Gateway" documentdb-gateway
%endif
install -d -m 0750 -o documentdb-gateway -g documentdb-gateway /var/lib/documentdb-gateway
install -d -m 0750 -o documentdb-gateway -g documentdb-gateway /run/documentdb-gateway

%install
install -Dpm 0644 %{_sourcedir}/LICENSE_Apache-2.0 %{buildroot}%{_licensedir}/%{name}/LICENSE_Apache-2.0
install -Dpm 0644 %{_sourcedir}/LICENSE_MIT %{buildroot}%{_licensedir}/%{name}/LICENSE_MIT
# Deliberate deviation from packaging-design.md section 4.3 (which specifies a
# single binary at /usr/bin): the split daemon+wrapper layout below should be
# reflected back into section 4.3 so the doc stays the source of truth.
# Real-user E2E flagged (Gap #5 from cross-platform coverage round):
# DEB ships the daemon at /usr/lib/documentdb-gateway/documentdb-gateway-daemon
# with a thin wrapper at /usr/bin/documentdb-gateway that auto-loads
# the per-major or global gateway.env and runuser-downgrades to the
# documentdb-gateway OS user when invoked from a root shell outside
# systemd. RPM previously installed the raw ELF directly at /usr/bin/
# meaning `documentdb-gateway --check` from a root shell on RHEL had
# the JSON-only behavior (no env file, no peer-auth user downgrade).
# Mirror the DEB layout so manual CLI parity holds across both
# packaging families.
install -Dpm 0755 %{_sourcedir}/documentdb_gateway %{buildroot}/usr/lib/documentdb-gateway/documentdb-gateway-daemon
install -d %{buildroot}/usr/bin
# Install the shared wrapper (single source of truth; the DEB build
# installs the same file). Staged into SOURCES by the gateway Dockerfiles.
install -Dpm 0755 %{_sourcedir}/documentdb-gateway-wrapper.sh %{buildroot}/usr/bin/documentdb-gateway
install -Dpm 0644 %{_sourcedir}/documentdb-gateway.service %{buildroot}%{_unitdir}/documentdb-gateway.service
install -Dpm 0644 %{_sourcedir}/documentdb-gateway-sysusers.conf %{buildroot}%{_sysusersdir}/documentdb-gateway.conf
install -Dpm 0644 %{_sourcedir}/documentdb-gateway-tmpfiles.conf %{buildroot}%{_tmpfilesdir}/documentdb-gateway.conf
# Per packaging-design.md §4.3, ship the env sample under /usr/share/doc/...
# (PostgreSQL convention); EnvironmentFile=- in the unit makes the live
# /etc/documentdb/gateway/gateway.env optional. SetupConfiguration.json
# is still shipped at the historical /etc/documentdb/gateway/ path for
# back-compat with pre-Phase-3 deployments.
install -Dpm 0644 %{_sourcedir}/gateway.env %{buildroot}/usr/share/doc/%{name}/examples/gateway.env.sample
# Reviewer-flagged (external review iter 18): strip dev-tree
# PostgresPort/GatewayListenPort/PostgresDataUserPassword fields so the
# packaged JSON does not contradict the per-major port promise or the
# Track 1 passwordless policy. Done via the shared strip-setup-config.sh
# helper (single source of truth, also used by build-gateway-deb.sh;
# staged into SOURCES by the rhel-8/rhel-9 Dockerfiles) so the stripped
# field set stays identical across packaging families. The helper
# re-serializes the JSON, so the result is always valid.
install -d %{buildroot}/etc/documentdb/gateway
bash %{_sourcedir}/strip-setup-config.sh \
    %{_sourcedir}/SetupConfiguration.json %{buildroot}/etc/documentdb/gateway/SetupConfiguration.json
chmod 0644 %{buildroot}/etc/documentdb/gateway/SetupConfiguration.json

%post
# Apply the systemd preset for the gateway service and reload units on the
# initial install (replaces a hand-written daemon-reload).
%systemd_post documentdb-gateway.service
echo "DocumentDB Gateway installed."
echo ""
echo "Configuration is taken from the environment first; the systemd unit"
echo "reads /etc/documentdb/gateway/gateway.env if it exists. To customize:"
echo "  sudo install -d -m 0755 /etc/documentdb/gateway"
echo "  sudo install -m 0640 -o root -g documentdb-gateway \\"
echo "                       /usr/share/doc/documentdb-gateway/examples/gateway.env.sample \\"
echo "                       /etc/documentdb/gateway/gateway.env"
echo "  sudoedit /etc/documentdb/gateway/gateway.env"
echo ""
echo "Next: choose one workflow."
echo "  * Workflow C (recommended): sudo dnf install documentdb && sudo documentdb-setup --admin-user admin"
echo "  * Workflow B (gateway on top of an existing PG, replace <N> with the PG major such as 18):"
echo "      sudo dnf install postgresql<N>-documentdb documentdb-postgresql-tools && \\"
echo "        sudo documentdb-tune --pg-version <N> --pgdata /var/lib/pgsql/<N>/data --yes && \\"
echo "        sudo systemctl restart postgresql-<N> && \\"
echo "        sudo -u postgres psql -c 'CREATE EXTENSION documentdb CASCADE;' && \\"
echo "        sudo documentdb-register-gateway --target-postgres-instance <N>/main --admin-user admin --yes && \\"
echo "        sudo systemctl reload postgresql-<N> && \\"
echo "        sudo systemctl enable --now documentdb-gateway"
echo "  See /usr/share/doc/documentdb-gateway/ and the packaging-design.md \"User workflows\" section."

%preun
%systemd_preun documentdb-gateway.service
# On full erase ($1 == 0) also stop any active stand-alone per-major
# gateway-local@N.service instances. They exec the same
# /usr/bin/documentdb-gateway binary this package owns, so erasing while
# they run would orphan them (the binary and /run state are removed in the
# postun scriptlet). The main documentdb-gateway.service is handled by the
# macro above. Mirrors the DEB prerm
# (oss/documentdb-local/maintainer-scripts/gateway/prerm) and the posttrans
# restart loop below.
if [ "$1" -eq 0 ] && [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; then
    for unit in $(systemctl list-units 'documentdb-gateway-local@*.service' \
            --state=active --plain --no-legend 2>/dev/null \
            | awk '{print $1}'); do
        systemctl stop "${unit}" 2>/dev/null || true
    done
fi

%postun
%systemd_postun_with_restart documentdb-gateway.service
# Full uninstall ($1 == 0): clean up gateway-owned runtime state only.
# Per packaging-design.md §4.3, the gateway runtime package is runtime-
# only: it MUST NOT mutate PostgreSQL-side state (pg_hba.conf,
# pg_ident.conf, postgresql.conf, gateway PG role). That cleanup belongs
# to documentdb-postgresql-tools (operator-invoked via
# documentdb-register-gateway --restore) and to documentdb-N's %postun
# (Issue 8 from the second-pass review). We only sweep the gateway's
# own /run/documentdb-gateway tmpfs state and the env file at
# /etc/documentdb/gateway/gateway.env.
#
# This full-erase cleanup intentionally mirrors the `purge` case of the DEB
# postrm (oss/documentdb-local/maintainer-scripts/gateway/postrm). A shared
# helper script is deliberately NOT factored out: both run at uninstall
# time, after the package's own files have already been removed (so a
# packaged helper would no longer be on disk), and the DEB (postrm
# purge/remove arguments) and RPM (%postun $1 count) maintainer-script
# models differ. Keep the two copies in sync.
if [ "$1" -eq 0 ]; then
    rm -rf /run/documentdb-gateway 2>/dev/null || true
    # Remove auto-generated TLS material and other persistent state under
    # /var/lib/documentdb-gateway, the admin env file, and the dedicated
    # system user/group on full erase, so a complete uninstall does not
    # leave gateway-owned private keys or accounts behind.
    rm -rf /var/lib/documentdb-gateway 2>/dev/null || true
    rm -f /etc/documentdb/gateway/gateway.env 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty /etc/documentdb/gateway 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty /etc/documentdb 2>/dev/null || true
    if getent passwd documentdb-gateway >/dev/null 2>&1; then
        userdel documentdb-gateway 2>/dev/null || true
    fi
    if getent group documentdb-gateway >/dev/null 2>&1; then
        groupdel documentdb-gateway 2>/dev/null || true
    fi
fi

%posttrans
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
    # The main documentdb-gateway.service is restarted on upgrade by the
    # systemd_postun_with_restart macro (in the postun scriptlet). Restart
    # the active stand-alone per-major gateway-local@N.service
    # instances. They use the same /usr/bin/documentdb-gateway binary as
    # the plain unit, so an upgrade of this RPM that doesn't restart them
    # leaves them running the old binary. The DEB postinst does the same
    # (see oss/documentdb-local/maintainer-scripts/gateway/postinst). The
    # lockstep release model in §4.4 makes solo gateway upgrades rare but
    # the design's §6 "Restart active gateway service on upgrade" still
    # requires the gateway side to be refreshed.
    for unit in $(systemctl list-units 'documentdb-gateway-local@*.service' \
            --state=active --plain --no-legend 2>/dev/null \
            | awk '{print $1}'); do
        if ! systemctl restart "${unit}"; then
            echo "WARNING: Failed to restart ${unit} after package transaction." >&2
        fi
    done
fi

%files
%defattr(-,root,root,-)
%license %{_licensedir}/%{name}/LICENSE_Apache-2.0
%license %{_licensedir}/%{name}/LICENSE_MIT
/usr/bin/documentdb-gateway
%dir /usr/lib/documentdb-gateway
/usr/lib/documentdb-gateway/documentdb-gateway-daemon
%{_unitdir}/documentdb-gateway.service
%{_sysusersdir}/documentdb-gateway.conf
%{_tmpfilesdir}/documentdb-gateway.conf
%doc /usr/share/doc/%{name}/examples/gateway.env.sample
%config(noreplace) /etc/documentdb/gateway/SetupConfiguration.json

%changelog
* Mon Jun 15 2026 DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com> - %{version}-%{release}
- Initial documentdb-gateway package: wire-protocol gateway daemon with
  systemd integration (service unit, sysusers.d and tmpfiles.d drop-ins),
  environment-driven configuration, and a dedicated documentdb-gateway
  system user.
