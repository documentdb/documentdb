%global pg_version POSTGRES_VERSION
%define debug_package %{nil}

Name:           documentdb-%{pg_version}
Version:        DOCUMENTDB_VERSION
Release:        1%{?dist}
Summary:        DocumentDB stand-alone package for PostgreSQL %{pg_version}
BuildArch:      noarch

License:        MIT
URL:            https://github.com/documentdb/documentdb

Requires:       (postgresql%{pg_version}-server or percona-postgresql%{pg_version}-server)
Requires:       postgresql%{pg_version}-documentdb >= %{version}
# The PG-agnostic shared payload (documentdb-setup, documentdb-local-reset, the
# systemd template units, the sysusers.d/tmpfiles.d drop-ins, the helper
# scripts, and the sample data) plus the gateway/tools runtime it depends on
# are owned by documentdb-common. documentdb-N ships no shared files itself, so
# multiple per-major packages install without a file-ownership conflict. Pin
# `>= %%{version}` so a release qualifier differing across arch/distro builds
# does not block installs, the same rationale used for the other Track 1 deps.
Requires:       documentdb-common >= %{version}

%description
DocumentDB stand-alone package for PostgreSQL %{pg_version}. Makes
DocumentDB work on this machine with a single command. This per-major package
pins PostgreSQL %{pg_version} and its DocumentDB extension and owns the
per-major systemd instance lifecycle; the shared PG-agnostic payload is
provided by documentdb-common.

%install
# documentdb-N ships no payload files: the shared payload lives in
# documentdb-common. This package is a per-major dependency + maintainer-script
# owner — per-major systemd instance management (%preun/%posttrans) and
# per-major state cleanup (%postun) below.

%post
# The PG-agnostic sysusers/tmpfiles bootstrap and the unit daemon-reload live
# in documentdb-common (a dependency, installed first). This per-major scriptlet
# only advertises the next setup step, or on upgrade what finishes it: scriptlets
# never restart PostgreSQL (§7). Mirrors the DEB postinst.
state_dir="/etc/documentdb/local/%{pg_version}"
restart_step="" update_step=""
if [ "$1" -ge 2 ] && [ -f "${state_dir}/setup.conf" ]; then
    # Only printed, inside single quotes; close and reopen around any ' in the path.
    data_dir="$(grep -E '^DATA_DIR=' "${state_dir}/setup.conf" | head -n 1 | cut -d= -f2- | sed "s/'/'\"'\"'/g")"
    pg_port="$(grep -E '^PG_PORT=' "${state_dir}/setup.conf" | head -n 1 | cut -d= -f2-)"
    if [ -d /run/systemd/system ]; then
        restart_step="sudo systemctl restart documentdb-local@%{pg_version}.target  # set up with --no-enable? restart documentdb-postgresql@%{pg_version}.service instead"
    else
        restart_step="sudo -u documentdb-local /usr/pgsql-%{pg_version}/bin/pg_ctl -D '${data_dir}' -l '${data_dir}/pglog.log' restart"
    fi
    # Setup does not read these back from setup.conf, so name them.
    update_step="sudo documentdb-setup --pg-version %{pg_version}${data_dir:+ --data-dir '${data_dir}'}${pg_port:+ --pg-port ${pg_port}}  # add --no-enable if you used it; runs ALTER EXTENSION ... UPDATE and keeps the admin users and their passwords"
elif [ "$1" -ge 2 ] && [ -f "${state_dir}/brownfield.conf" ]; then
    restart_step="Restart the PostgreSQL %{pg_version} server DocumentDB is attached to."
    update_step="In its postgres database: ALTER EXTENSION documentdb_core UPDATE; ALTER EXTENSION documentdb UPDATE; (and documentdb_extended_rum, if installed)"
fi
if [ -n "${restart_step}" ]; then
    # $1 >= 2 is any install over an earlier one: RPM does not say which way it went.
    echo "DocumentDB for PostgreSQL %{pg_version} %{version} replaced an earlier install. After an upgrade,"
    echo "PostgreSQL keeps the old build loaded and the extensions their old version until you finish it:"
    echo "  1. ${restart_step}"
    echo "  2. ${update_step}"
elif [ "$1" -eq 1 ]; then
    echo "DocumentDB stand-alone package for PostgreSQL %{pg_version} installed."
    echo ""
    echo "Next: sudo documentdb-setup --admin-user admin --pg-version %{pg_version}"
    echo "(The wizard prompts for the first admin password, runs initdb / CREATE EXTENSION /"
    echo "first-user bootstrap, and enables documentdb-local@%{pg_version}.target so the stack survives reboot.)"
fi

%preun
# On erase, stop and disable only this major's concrete target instance.
# Standard macros cannot express this template-instance ownership boundary.
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    if [ "$1" -eq 0 ]; then
        systemctl stop "documentdb-local@%{pg_version}.target" || true
        systemctl disable "documentdb-local@%{pg_version}.target" || true
    fi
elif [ "$1" -eq 0 ]; then
    # No systemd: documentdb-setup started this major's gateway under nohup and
    # PostgreSQL with pg_ctl. Stop both; like the systemd branch, warn rather
    # than block the erase. Mirrors the DEB prerm.
    lib=/usr/share/documentdb/scripts/documentdb-tools-lib.sh
    if [ -r "${lib}" ]; then
        bash -c 'die() { echo "$*" >&2; exit 1; }; log_warn() { echo "$*" >&2; }; . "$1"; documentdb_stop_local_major "$2"' \
                _ "${lib}" "%{pg_version}" || {
            echo "documentdb-%{pg_version}: warning: DocumentDB for PostgreSQL %{pg_version} is still running from the erased files; stop it." >&2
        }
    else
        echo "documentdb-%{pg_version}: ${lib} is missing; cannot stop a gateway or PostgreSQL started without systemd." >&2
    fi
fi

%postun
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
fi

# Full uninstall ($1 == 0 in RPM): strip the documentdb-setup managed
# blocks from the underlying PG instance's config files. The gateway
# runtime package used to do this
# work which violated its runtime-only boundary; ownership now lives
# here with the stand-alone package that orchestrated the writes in
# the first place.
if [ "$1" -eq 0 ]; then
    documentdb_strip_managed_block() {
        target_file="$1"
        block_start="$2"
        block_end="$3"
        [ -f "${target_file}" ] || return 0
        grep -Fqx "${block_start}" "${target_file}" 2>/dev/null || return 0
        if ! grep -Fqx "${block_end}" "${target_file}" 2>/dev/null; then
            echo "documentdb-%{pg_version} %%postun: refusing to strip managed block in ${target_file}: end marker missing." >&2
            return 0
        fi
        temp_file="$(mktemp "${target_file}.documentdb-cleanup.XXXXXX")" || return 0
        if ! awk -v start="${block_start}" -v end="${block_end}" '
                $0 == start { skip = 1; next }
                $0 == end   { skip = 0; next }
                !skip       { print }
            ' "${target_file}" > "${temp_file}"; then
            rm -f "${temp_file}"
            return 0
        fi
        chown --reference="${target_file}" "${temp_file}" 2>/dev/null || true
        chmod --reference="${target_file}" "${temp_file}" 2>/dev/null || true
        mv "${temp_file}" "${target_file}"
    }

    # Strip the standalone-side managed blocks the wizard / delegated
    # tools wrote. State file names: setup.conf (greenfield),
    # brownfield.conf (brownfield).
    for sf in /etc/documentdb/local/%{pg_version}/setup.conf \
              /etc/documentdb/local/%{pg_version}/brownfield.conf \
              /etc/documentdb/local/%{pg_version}/gateway-setup.state; do
        [ -r "${sf}" ] || continue
        hba_file="$(grep -E '^HBA_FILE=' "${sf}" | head -1 | cut -d= -f2- || true)"
        ident_file="$(grep -E '^IDENT_FILE=' "${sf}" | head -1 | cut -d= -f2- || true)"
        config_file="$(grep -E '^CONFIG_FILE=' "${sf}" | head -1 | cut -d= -f2- || true)"
        # setup.conf is the only record of a custom --data-dir; name it before it goes.
        data_dir="$(grep -E '^DATA_DIR=' "${sf}" | head -1 | cut -d= -f2- || true)"
        if [ "${sf##*/}" = setup.conf ] && [ -n "${data_dir}" ] \
                && [ "${data_dir}" != "/var/lib/documentdb-local/%{pg_version}/data" ] && [ -f "${data_dir}/PG_VERSION" ]; then
            data_dir_q="$(printf '%s' "${data_dir}" | sed "s/'/'\"'\"'/g")"
            echo "Kept the PostgreSQL data in ${data_dir}. To reuse it, run documentdb-setup --pg-version %{pg_version} --data-dir '${data_dir_q}'; to delete it, remove that directory (documentdb-local-reset no longer knows it)."
        fi
        [ -n "${hba_file}" ] && documentdb_strip_managed_block "${hba_file}" \
            "# >>> documentdb-setup managed hba >>>" \
            "# <<< documentdb-setup managed hba <<<"
        [ -n "${ident_file}" ] && documentdb_strip_managed_block "${ident_file}" \
            "# >>> documentdb-setup managed pg_ident >>>" \
            "# <<< documentdb-setup managed pg_ident <<<"
        [ -n "${config_file}" ] && documentdb_strip_managed_block "${config_file}" \
            "# >>> documentdb-setup managed configuration >>>" \
            "# <<< documentdb-setup managed configuration <<<"
        [ -n "${config_file}" ] && documentdb_strip_managed_block "${config_file}" \
            "# >>> documentdb-setup managed listen >>>" \
            "# <<< documentdb-setup managed listen <<<"
        # RPM targets RHEL, where PostgreSQL has no /etc/postgresql/<V>/<C>
        # layout and documentdb-tune writes the documentdb-setup managed
        # markers in place (already stripped above). This Debian-shaped branch
        # is therefore a defensive no-op kept only for cross-format parity with
        # older generated packages; the DEB postrm now cleans the Debian tune
        # fragment itself because documentdb-tune may be unavailable at purge.
        if [ -n "${config_file}" ] && command -v documentdb-tune >/dev/null 2>&1; then
            tune_pgver="$(echo "${config_file}" | sed -n -E 's#^/etc/postgresql/([0-9]+)/([^/]+)/postgresql\.conf$#\1#p')"
            tune_cluster="$(echo "${config_file}" | sed -n -E 's#^/etc/postgresql/([0-9]+)/([^/]+)/postgresql\.conf$#\2#p')"
            if [ -n "${tune_pgver}" ] && [ -n "${tune_cluster}" ]; then
                documentdb-tune --restore --pg-version "${tune_pgver}" --cluster "${tune_cluster}" >/dev/null 2>&1 || true
            fi
        fi
        # Strip per-major gateway.env fragment + remove the connection
        # URL file from tmpfs.
        state_dir="$(dirname "${sf}")"
        env_file="${state_dir}/gateway.env"
        if [ -f "${env_file}" ]; then
            documentdb_strip_managed_block "${env_file}" \
                "# >>> documentdb-register-gateway managed env >>>" \
                "# <<< documentdb-register-gateway managed env <<<"
            grep -q '[^[:space:]]' "${env_file}" 2>/dev/null || rm -f "${env_file}" 2>/dev/null || true
        fi
        rm -f "${sf}" 2>/dev/null || true
        # Pg-url moved from tmpfs /run
        # to persistent /var/lib so it survives reboot. Clean BOTH paths
        # For upgrade-safe cleanup from legacy installs.
        rm -f "/run/documentdb-local/%{pg_version}/gateway/pg-url" 2>/dev/null || true
        rm -f "/var/lib/documentdb-local/%{pg_version}/gateway/pg-url" 2>/dev/null || true
        rmdir --ignore-fail-on-non-empty "${state_dir}" 2>/dev/null || true
    done

    # Unconditional per-major sweeps for orphaned artifacts. The per-state-
    # file loop above short-circuits when the state file is already gone
    # (e.g. an earlier --restore removed it but did not clean these), so we
    # repeat the cleanup unconditionally here. The %{pg_version} macro
    # scopes the sweep to this package's major, matching the package's
    # Ownership boundary.
    #
    # Brownfield drop-in cleanup: the wizard writes a per-instance systemd
    # drop-in at
    # /etc/systemd/system/documentdb-gateway-local@%{pg_version}.service.d/brownfield.conf
    # when adopting an existing PG (see packaging-design.md §4.4).
    dropin_dir="/etc/systemd/system/documentdb-gateway-local@%{pg_version}.service.d"
    rm -f "${dropin_dir}/brownfield.conf" 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty "${dropin_dir}" 2>/dev/null || true

    # Per-major gateway env fragment (loaded by documentdb-gateway-local@N).
    per_major_env="/etc/documentdb/local/%{pg_version}/gateway.env"
    if [ -f "${per_major_env}" ]; then
        documentdb_strip_managed_block "${per_major_env}" \
            "# >>> documentdb-register-gateway managed env >>>" \
            "# <<< documentdb-register-gateway managed env <<<"
        grep -q '[^[:space:]]' "${per_major_env}" 2>/dev/null || rm -f "${per_major_env}" 2>/dev/null || true
    fi
    rmdir --ignore-fail-on-non-empty "/etc/documentdb/local/%{pg_version}" 2>/dev/null || true

    # Per-major connection-URL files. Clean BOTH the legacy tmpfs path
    # (legacy) and the current persistent path so upgrades don't leak.
    rm -f "/run/documentdb-local/%{pg_version}/gateway/pg-url" 2>/dev/null || true
    rm -f "/var/lib/documentdb-local/%{pg_version}/gateway/pg-url" 2>/dev/null || true

    # The legacy host-level state file
    # /etc/documentdb/documentdb-postgresql.env (written by
    # documentdb-setup's read_persisted_managed_data_dir flow) was
    # never cleaned on uninstall. It's shared across all majors, so we
    # only remove it when no other documentdb-N package's per-major
    # state remains. Matches the DEB postrm logic.
    if [ -f "/etc/documentdb/documentdb-postgresql.env" ]; then
        other_majors_remain=false
        for other_state in /etc/documentdb/local/*/setup.conf \
                           /etc/documentdb/local/*/brownfield.conf; do
            if [ -r "${other_state}" ]; then
                other_majors_remain=true
                break
            fi
        done
        if [ "${other_majors_remain}" = "false" ]; then
            rm -f /etc/documentdb/documentdb-postgresql.env
        fi
    fi

    rmdir --ignore-fail-on-non-empty /etc/documentdb/local 2>/dev/null || true
    rmdir --ignore-fail-on-non-empty /etc/documentdb 2>/dev/null || true
fi

%posttrans
if { [ -d /run/systemd/system ] && command -v systemctl >/dev/null 2>&1; }; then
    systemctl daemon-reload 2>/dev/null || true
    # Restart only the active per-major gateway instance after a transaction.
    # Do not restart the target: in greenfield mode that would also bounce the
    # PostgreSQL service via PartOf=.
    # Per packaging-design.md §6 "Restart active gateway service on
    # upgrade: documentdb-N install: Yes (gateway side only)": restart
    # only the per-major templated gateway-local instance, NOT the
    # per-major target — restarting the target would also bounce the
    # underlying PostgreSQL service (greenfield via PartOf=) which §7
    # prohibits ("Maintainer scripts restart PostgreSQL: Never"). If
    # the gateway unit isn't active we leave state untouched, matching
    # Citus/pgvector convention.
    if systemctl is-active --quiet "documentdb-gateway-local@%{pg_version}.service"; then
        if ! systemctl restart "documentdb-gateway-local@%{pg_version}.service"; then
            echo "WARNING: failed to restart documentdb-gateway-local@%{pg_version}.service after package transaction." >&2
        fi
    fi
fi

%files
# documentdb-N ships no payload files — the shared payload is owned by
# documentdb-common. This package exists for its per-major dependency edges
# (postgresql-N + extension + documentdb-common) and its per-major
# maintainer scriptlets (%post/%preun/%postun/%posttrans above).

%changelog
* Tue Jun 23 2026 DocumentDB Packaging <documentdb-packaging-maintainers@microsoft.com> - %{version}-%{release}
- documentdb-N is now a per-major dependency package: the shared, PG-agnostic
  payload (documentdb-setup, systemd template units, sysusers.d/tmpfiles.d
  drop-ins, helper scripts, sample data) moved to documentdb-common, which
  this package depends on. Removing one major no longer removes shared files a
  surviving major needs.
- Retains the per-major systemd instance lifecycle and per-major state cleanup
  in its scriptlets.
