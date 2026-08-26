%define debug_package %{nil}
%define default_pg_major 18

Name:           documentdb
Version:        DOCUMENTDB_VERSION
Release:        1%{?dist}
Summary:        DocumentDB stand-alone meta package (default PG major)
BuildArch:      noarch

License:        MIT
URL:            https://github.com/documentdb/documentdb

# Same rationale as documentdb-N: relax to `>= %%{version}` so the meta
# package isn''t blocked when documentdb-N (noarch) has a different
# release qualifier than this meta on cross-distro builds.
Requires:       documentdb-%{default_pg_major} >= %{version}

%description
Meta package that installs the DocumentDB stand-alone package for the
default PostgreSQL major version (%{default_pg_major}). This is the
recommended install target for new users: sudo dnf install documentdb.

The stand-alone stack depends on PGDG-provided PostgreSQL extension packages
(pgvector, pg_cron, postgis36). On RHEL/Rocky/AlmaLinux, enable the PGDG,
EPEL, and CodeReady Builder (CRB) repositories BEFORE installing so dependency
resolution succeeds (adjust the EL major and arch in the PGDG URL for your
host; use 'powertools' instead of 'crb' on EL8):

  sudo dnf install -y dnf-plugins-core
  sudo dnf install -y https://download.postgresql.org/pub/repos/yum/reporpms/EL-9-x86_64/pgdg-redhat-repo-latest.noarch.rpm
  sudo dnf install -y epel-release
  sudo dnf config-manager --set-enabled crb
  sudo dnf -qy module disable postgresql

To install a specific PG major, use: sudo dnf install documentdb-N

To fully uninstall, run:
  sudo dnf remove documentdb documentdb-%{default_pg_major} documentdb-common \
                  documentdb-gateway documentdb-postgresql-tools

'dnf remove documentdb' alone only removes this meta package; the
per-major stand-alone package, the gateway runtime, and the
administrator tools remain installed.

%install
# No files — this is a pure dependency meta package.

%post
# This meta package creates a wrapper unit and a PartOf drop-in under
# /etc/systemd/system at install time. They are not payload files under
# %%{_unitdir}, so standard systemd RPM macros do not model this alias.
# The DEB meta package's postinst
# creates /etc/systemd/system/documentdb-local.target as the public
# day-2 surface (per packaging-design.md §8). The RPM meta previously
# shipped no files and no scriptlets, so on RPM hosts `dnf install
# documentdb` followed by the documented `systemctl enable --now
# documentdb-local.target` failed because no alias existed.
#
# A plain `Requires=` wrapper unit
# does NOT propagate stop/restart from the wrapper to the per-major
# target. Install a drop-in on the per-major target with
# `PartOf=documentdb-local.target` so stopping the wrapper also stops
# the appliance — full start/stop/restart/status semantics on the
# documented day-2 surface. The DEB meta does the same.
install -d -m 0755 /etc/systemd/system

# Wrapper unit (pulls in the per-major target at start time).
cat > /etc/systemd/system/documentdb-local.target <<DROPIN
[Unit]
Description=DocumentDB Local Appliance (alias to documentdb-local@%{default_pg_major}.target)
Requires=documentdb-local@%{default_pg_major}.target
After=documentdb-local@%{default_pg_major}.target

[Install]
WantedBy=multi-user.target
DROPIN

# Sweep stale meta-owned drop-ins before writing the current one. The
# glob includes the current major too, so reversing this order would
# delete the file we just created.
for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do
    [ -e "$dropin" ] || [ -L "$dropin" ] || continue
    instance=${dropin#/etc/systemd/system/documentdb-local@}
    instance=${instance%.target.d/wrapper-partof.conf}
    case "$instance" in
        ''|*[!0-9]*) continue ;;
    esac
    if grep -Fq '# Managed-by: documentdb-meta-package' "$dropin" 2>/dev/null || \
       { grep -Fq 'Installed by the documentdb meta' "$dropin" 2>/dev/null && \
         grep -Fxq 'PartOf=documentdb-local.target' "$dropin" 2>/dev/null; }; then
        dropin_dir=${dropin%/wrapper-partof.conf}
        rm -f "$dropin" 2>/dev/null || true
        rmdir --ignore-fail-on-non-empty "$dropin_dir" 2>/dev/null || true
    fi
done

# Stop-propagation drop-in on the per-major target. PartOf=
# propagates stop/restart from a parent target to its children, so
# `systemctl stop documentdb-local.target` now actually stops
# documentdb-local@%{default_pg_major}.target too.
install -d -m 0755 /etc/systemd/system/documentdb-local@%{default_pg_major}.target.d
cat > /etc/systemd/system/documentdb-local@%{default_pg_major}.target.d/wrapper-partof.conf <<DROPIN2
[Unit]
# Managed-by: documentdb-meta-package
# Propagate stop/restart from the public documentdb-local.target alias
# down to this per-major instance. Installed by the documentdb meta
# package's post-install scriptlet. Removed on full uninstall.
PartOf=documentdb-local.target
DROPIN2

if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
fi
echo "DocumentDB meta package installed (paved-road: PostgreSQL %{default_pg_major})."
echo ""
echo "Next: sudo documentdb-setup --admin-user admin"
echo "(The wizard prompts for the first admin password, runs initdb / CREATE EXTENSION /"
echo "first-user bootstrap, and enables documentdb-local.target so the stack survives reboot.)"

%postun
# On full removal ($1 == 0 in RPM), remove the alias we installed in the
# post-install scriptlet.
# Co-installed `documentdb` is not a thing (only one meta can exist per
# host), so unconditional removal is safe.
if [ "$1" -eq 0 ]; then
    if command -v systemctl >/dev/null 2>&1; then
        # Disable before deleting the unit; systemctl reads [Install]
        # metadata from the unit file to locate enablement symlinks.
        systemctl disable documentdb-local.target >/dev/null 2>&1 || true
    fi
    rm -f /etc/systemd/system/multi-user.target.wants/documentdb-local.target 2>/dev/null || true
    rm -f /etc/systemd/system/documentdb-local.target 2>/dev/null || true
    # Remove all meta-owned stop-propagation drop-ins, including stale
    # ones left behind by future default-major changes.
    for dropin in /etc/systemd/system/documentdb-local@[0-9]*.target.d/wrapper-partof.conf; do
        [ -e "$dropin" ] || [ -L "$dropin" ] || continue
        instance=${dropin#/etc/systemd/system/documentdb-local@}
        instance=${instance%.target.d/wrapper-partof.conf}
        case "$instance" in
            ''|*[!0-9]*) continue ;;
        esac
        if grep -Fq '# Managed-by: documentdb-meta-package' "$dropin" 2>/dev/null || \
           { grep -Fq 'Installed by the documentdb meta' "$dropin" 2>/dev/null && \
             grep -Fxq 'PartOf=documentdb-local.target' "$dropin" 2>/dev/null; }; then
            dropin_dir=${dropin%/wrapper-partof.conf}
            rm -f "$dropin" 2>/dev/null || true
            rmdir --ignore-fail-on-non-empty "$dropin_dir" 2>/dev/null || true
        fi
    done
    if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
        systemctl daemon-reload 2>/dev/null || true
    fi

    # Remind the operator that removing the meta only removes the alias;
    # the actual stand-alone stack, gateway, and tools are separate
    # packages and remain installed until removed explicitly. Without
    # this an operator running `dnf remove documentdb` expecting a full
    # wipe is surprised to find the gateway service still running.
    remaining_pkgs=""
    for pkg in "documentdb-%{default_pg_major}" \
               "documentdb-common" \
               "documentdb-gateway" \
               "documentdb-postgresql-tools"; do
        if rpm -q "$pkg" >/dev/null 2>&1; then
            remaining_pkgs="${remaining_pkgs} $pkg"
        fi
    done
    if [ -n "${remaining_pkgs}" ]; then
        echo ""
        echo "Note: removing the 'documentdb' meta package only removed the"
        echo "public 'documentdb-local.target' alias. The following packages"
        echo "are still installed on this host:"
        for pkg in ${remaining_pkgs}; do
            echo "  - ${pkg}"
        done
        echo ""
        echo "To fully uninstall DocumentDB, run:"
        echo "  sudo dnf remove${remaining_pkgs}"
        echo ""
        echo "PostgreSQL data directories under /var/lib/documentdb-local/"
        echo "are preserved across remove; use documentdb-local-reset to wipe"
        echo "them when intended."
    fi
fi

%files
# Empty — meta package. The systemd alias is created/removed by the
# scriptlets above (not shipped as a tracked file) because RPM's
# %config(noreplace) semantics would interfere with the dnf-managed
# lifecycle of the alias.

%changelog
* Tue Jun 23 2026 DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com> - %{version}-%{release}
- Initial documentdb meta package for the default PostgreSQL major: pulls
  in documentdb-N and installs the public documentdb-local.target alias.
