# shellcheck shell=bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# lib/toast.sh: default_toast_compression for the PostgreSQL this container starts.
#
# Sourced by emulator_entrypoint.sh; defines functions only.

resolve_toast_request() {
    # TOAST compression request. Resolved and validated here, outside the
    # PostgreSQL-start branch, so a bad value is rejected in every mode; the same
    # value is already fatal in the default mode. Same reason TLS_MODE is checked
    # here. toast_requested keeps the RAW request so the failure branches below can
    # tell an explicit choice (fail loudly) from the built-in default (degrade
    # quietly), which is the documentdb-tune contract.
    # Validated in validate_settings; the default is applied here rather than in the generic
    # pass because an explicit request fails loudly where the default degrades.
    toast_requested="${DOCUMENTDB_TOAST_COMPRESSION:-}"
    toast_explicit=false
    if setting_is_explicit DOCUMENTDB_TOAST_COMPRESSION; then
        toast_explicit=true
    fi
    toast_compression="${toast_requested:-$(documentdb_local_setting_default DOCUMENTDB_TOAST_COMPRESSION)}"

    # No server to configure here, so say the request is dropped instead of
    # dropping it silently. A warning, not an error: the variable is often set once
    # for a whole compose stack, and killing a gateway-only service over another
    # server's setting would be hostile. "default" means leave the setting alone,
    # which is already what happens.
    if [ "$START_POSTGRESQL" != "true" ] && [ "$toast_explicit" = "true" ] \
            && [ "$toast_requested" != "default" ]; then
        echo "Warning: --toast-compression / DOCUMENTDB_TOAST_COMPRESSION=$toast_requested is ignored because this container is not starting PostgreSQL; set default_toast_compression on that external PostgreSQL instance instead." >&2
    fi
}

# Outside the data volume: a fragment that outlives the container defeats
# the rollback design. DATA_PATH is operator-settable and never normalized,
# so a purely lexical compare is defeated by a trailing slash, by "..", or
# by a symlink. Canonicalization alone is not enough either, since it fails
# when a parent directory does not exist. Test both forms and reject if
# either says "inside", so the check can only ever tighten.
toast_path_inside() {
    # Strip trailing slashes first: "/data/" would make the pattern
    # "/data//*", which matches nothing. A root of only slashes becomes "",
    # giving "/*", which correctly treats every absolute path as inside.
    local root="$1"
    while [ "$root" != "${root%/}" ]; do root="${root%/}"; done
    # The root is "inside" itself. Without this, TOAST_COMPRESSION_CONF
    # equal to DATA_PATH passed the guard, and `mv tmp "$DATA_PATH"`
    # SUCCEEDS against a directory by moving the temp file into it, so the
    # write reported success while stranding the fragment in the volume
    # under a different name and registering an include on the directory.
    [ "$2" = "$root" ] && return 0
    case "$2" in "$root"/*) return 0 ;; esac
    return 1
}

# `cd` + `pwd -P` rather than `readlink -f`: it is POSIX, and it resolves a
# final component that does not exist yet, which is the normal case for the
# fragment and which BSD readlink -f refuses.
toast_canon_file() {
    local dir base
    dir="$(dirname "$1")"
    base="$(basename "$1")"
    dir="$(cd "$dir" 2>/dev/null && pwd -P)"
    [ -n "$dir" ] || return 1
    case "$dir" in
        /) printf '/%s\n' "$base" ;;
        *) printf '%s/%s\n' "$dir" "$base" ;;
    esac
}

# toast_write_fragment <line>: atomically replace the fragment with one
# line. Temp + mv because a partial fragment (short write, disk full) is a
# syntax error, fatal at the next boot once the include exists. On failure
# the fragment is REMOVED so the include dangles and the server default
# applies. Returns 0 on success, 1 on clean failure (nothing left behind),
# 2 when even the removal failed and a stale value could still apply.
toast_write_fragment() {
    if printf '%s\n' "$1" > "$TOAST_COMPRESSION_CONF.documentdb-tmp" 2>/dev/null \
            && mv "$TOAST_COMPRESSION_CONF.documentdb-tmp" "$TOAST_COMPRESSION_CONF" 2>/dev/null; then
        return 0
    fi
    rm -f "$TOAST_COMPRESSION_CONF.documentdb-tmp" "$TOAST_COMPRESSION_CONF" 2>/dev/null
    if [ -e "$TOAST_COMPRESSION_CONF" ]; then
        return 2
    fi
    return 1
}

toast_check_fragment_path() {
    # TOAST compression for this image's PostgreSQL. Applied here rather than in
    # the shared server-start scripts so dev and test servers keep the PG
    # default. The fragment lives under GATEWAY_HOME: owner-writable (a fixed
    # /tmp path could be pre-created by another uid to inject GUCs) and
    # image-ephemeral, so after an image rollback the include line just dangles.
    TOAST_COMPRESSION_CONF="${TOAST_COMPRESSION_CONF:-$GATEWAY_HOME/documentdb_toast_compression.conf}"
    # Guardrail for an operator-supplied path; accidents, not adversaries (the
    # operator already controls mounts and postgresql.conf). Runs before
    # PostgreSQL starts, so an exit here has nothing to stop.
    #
    # Absolute is checked on the RAW value and first, because the
    # canonicalization below would turn a relative path into an absolute one
    # and hide the mistake: we write relative to CWD but PostgreSQL resolves
    # the include relative to the data dir, so a relative path never applies.
    case "$TOAST_COMPRESSION_CONF" in
        /*) ;;
        *)
            echo "Error: TOAST_COMPRESSION_CONF must be an absolute path (got '$TOAST_COMPRESSION_CONF'); a relative path is written relative to the entrypoint's working directory but resolved by PostgreSQL relative to the data directory, so it would silently never apply." >&2
            exit 1;;
    esac
    toast_data_canon="$(cd "$DATA_PATH" 2>/dev/null && pwd -P)"
    toast_conf_canon="$(toast_canon_file "$TOAST_COMPRESSION_CONF" || true)"
    if toast_path_inside "$DATA_PATH" "$TOAST_COMPRESSION_CONF" \
            || { [ -n "$toast_data_canon" ] && [ -n "$toast_conf_canon" ] \
                && toast_path_inside "$toast_data_canon" "$toast_conf_canon"; }; then
        echo "Error: TOAST_COMPRESSION_CONF must not point inside the data directory ($DATA_PATH); the fragment is designed to be container-ephemeral." >&2
        exit 1
    fi
    # A directory anywhere is equally unusable: `mv tmp somedir` succeeds by
    # moving the temp file INTO it, so the write would report success while the
    # fragment landed under a name nothing reads, and the include would point
    # at a directory. Checked after containment so the more specific data-dir
    # message wins when the path is both.
    if [ -d "$TOAST_COMPRESSION_CONF" ]; then
        echo "Error: TOAST_COMPRESSION_CONF must name a file, but '$TOAST_COMPRESSION_CONF' is a directory." >&2
        exit 1
    fi
    case "$TOAST_COMPRESSION_CONF" in
        *\'*|*\\*|*$'\n'*)
            echo "Error: TOAST_COMPRESSION_CONF must not contain single quotes, backslashes, or newlines." >&2
            exit 1;;
    esac
}

toast_probe_lz4_offline() {
    # Never persist lz4 on the offline probe alone. pg_config is trusted only
    # for a definitive "no" (fail or degrade before the server starts); "yes"
    # and "unknown" both defer to the live server's pg_settings answer after
    # startup. A wrong "yes" written pre-start would FATAL the postmaster on
    # every later boot once the include line is in the volume, and no
    # post-start code could repair it: the fragment is rewritten before the
    # server starts on the very boot that would need the fix.
    toast_pending_lz4=false
    toast_offline_verdict=""
    if [ "$toast_compression" = "lz4" ]; then
        # start_oss_server launches the postmaster from the versioned bindir
        # (GetPostgresPath in utils.sh), never from PATH, so ask those binaries
        # first. PATH is only a fallback, and is what the tests stub.
        toast_pg_config=""
        for toast_pg_bindir in \
                "/usr/lib/postgresql/${PG_MAJOR_ASSUMED}/bin" \
                "/usr/pgsql-${PG_MAJOR_ASSUMED}/bin"; do
            if [ -x "$toast_pg_bindir/pg_config" ]; then
                toast_pg_config="$toast_pg_bindir/pg_config"
                break
            fi
        done
        if [ -z "$toast_pg_config" ]; then
            # PATH is trusted only when its major matches the server we start
            # (documentdb-tools-lib gates the same way): a foreign build's
            # --with-lz4 could approve a value this server rejects, which is
            # FATAL on every later boot once the include is in the volume. A
            # failed --version or a mismatch stays "unknown" and defers to the
            # runtime probe below.
            toast_path_pg_config="$(command -v pg_config 2>/dev/null || true)"
            if [ -n "$toast_path_pg_config" ]; then
                # A dying pg_config's partial print must not pass the gate.
                toast_path_version=""
                if ! toast_path_version="$("$toast_path_pg_config" --version 2>/dev/null)"; then
                    toast_path_version=""
                fi
                toast_path_major="${toast_path_version#* }"      # "PostgreSQL 17.2" -> "17.2"
                toast_path_major="${toast_path_major%%[!0-9]*}"  # "17.2" / "18devel" -> "17" / "18"
                if [ -n "$toast_path_major" ] && [ "$toast_path_major" = "${PG_MAJOR_ASSUMED}" ]; then
                    toast_pg_config="$toast_path_pg_config"
                fi
            fi
        fi
        # --configure is meaningful only for autoconf builds. Meson compiles the
        # string in EMPTY, so an empty report means "cannot verify", not "no".
        toast_configure_args=""
        if [ -n "$toast_pg_config" ]; then
            # A partial print from a failed pg_config must not authorize lz4.
            if ! toast_configure_args="$("$toast_pg_config" --configure 2>/dev/null)"; then
                toast_configure_args=""
            fi
        fi
        toast_lz4_support=unknown
        if [ -n "$(printf '%s' "$toast_configure_args" | tr -d '[:space:]')" ]; then
            case "$toast_configure_args" in
                *--with-lz4*) toast_lz4_support=yes ;;
                *)            toast_lz4_support=no ;;
            esac
        fi
        if [ "$toast_lz4_support" = "no" ]; then
            if [ "$toast_explicit" = "true" ]; then
                echo "Error: DOCUMENTDB_TOAST_COMPRESSION=lz4 was requested, but this PostgreSQL build has no lz4 support (pg_config --configure reports no --with-lz4). Use pglz or default." >&2
                exit 1
            fi
            echo "Warning: PostgreSQL was not built with lz4 support (pg_config --configure reports no --with-lz4); leaving default_toast_compression unset." >&2
            toast_compression="default"
        else
            # yes or unknown: stay inert until the live server confirms.
            toast_offline_verdict="$toast_lz4_support"
            toast_pending_lz4=true
            toast_compression="default"
        fi
    fi
}

toast_write_initial_fragment() {
    # Rewritten on every start, inert form included, so a changed request never
    # leaves the previous value in effect. toast_fragment_value is the value due
    # NOW ("" for the inert comment); a pending lz4 stays "" and is written by
    # the post-start upgrade once the live server confirms it.
    if [ "$toast_compression" = "default" ]; then
        toast_fragment_value=""
        toast_fragment_line='# default_toast_compression left to the PostgreSQL default'
    else
        toast_fragment_value="$toast_compression"
        toast_fragment_line="default_toast_compression = '$toast_compression'"
    fi
    toast_write_fragment "$toast_fragment_line"
    toast_write_status=$?
    if [ "$toast_write_status" -ne 0 ]; then
        if [ "$toast_write_status" -eq 2 ]; then
            echo "Error: could not rewrite the TOAST compression fragment at $TOAST_COMPRESSION_CONF, and a previous boot's fragment could not be removed; refusing to start with a possibly stale default_toast_compression." >&2
            exit 1
        fi
        # Clean failure: nothing on disk, the include dangles, server default
        # applies. Abort only for an explicit value due NOW (pglz). A pending
        # lz4 keeps its state; the post-start upgrade retries and its own
        # failure path enforces the explicit-request contract. Explicit
        # "default" is already honored by the dangling include.
        if [ "$toast_explicit" = "true" ] && [ -n "$toast_fragment_value" ]; then
            echo "Error: could not write the TOAST compression fragment at $TOAST_COMPRESSION_CONF for the requested DOCUMENTDB_TOAST_COMPRESSION=$toast_fragment_value." >&2
            exit 1
        fi
        echo "Warning: could not write the TOAST compression fragment at $TOAST_COMPRESSION_CONF; leaving default_toast_compression to the server default." >&2
    fi
}

toast_resolve_pg_conf() {
    # Repair volumes stamped by earlier iterations of this change. Pre-start
    # because an old-path hard include would stop this very startup:
    #  - hard `include` (from start_oss_server -f): fatal whenever the fragment
    #    is missing (rollback, or a changed path). The tolerant
    #    include_if_exists form is re-added after startup.
    #  - include_if_exists still aimed at the old world-writable /tmp default.
    # Resolve postgresql.conf through symlinks once and edit the target: a
    # temp+mv on the LINK would replace the link with a regular file, while
    # temp+mv on the TARGET keeps the link and stays atomic. DATA_PATH is
    # operator-settable and split layouts symlink the conf out of the data dir.
    # An unresolvable link skips all conf maintenance with a warning.
    toast_pg_conf="$DATA_PATH/postgresql.conf"
    toast_conf_editable=true
    if [ -L "$toast_pg_conf" ]; then
        toast_pg_conf_target="$(readlink -f "$toast_pg_conf" 2>/dev/null || true)"
        if [ -n "$toast_pg_conf_target" ] && [ -e "$toast_pg_conf_target" ]; then
            echo "postgresql.conf is a symlink; TOAST compression maintenance follows it to $toast_pg_conf_target."
            toast_pg_conf="$toast_pg_conf_target"
        else
            toast_conf_editable=false
            echo "Warning: $DATA_PATH/postgresql.conf is a symlink that cannot be resolved; skipping TOAST compression include maintenance. Manage default_toast_compression in your own configuration." >&2
        fi
    fi
}

toast_repair_stale_includes() {
    toast_stale_lines=("include '$TOAST_COMPRESSION_CONF'" "include '/tmp/documentdb_toast_compression.conf'")
    if [ "$TOAST_COMPRESSION_CONF" != "/tmp/documentdb_toast_compression.conf" ]; then
        toast_stale_lines+=("include_if_exists = '/tmp/documentdb_toast_compression.conf'")
    fi
    for toast_stale_line in "${toast_stale_lines[@]}"; do
        if [ "$toast_conf_editable" = "true" ] \
                && grep -qxF "$toast_stale_line" "$toast_pg_conf" 2>/dev/null; then
            echo "Removing stale TOAST compression include from postgresql.conf: $toast_stale_line"
            # Warn, don't abort: only the old-path hard include is fatal to this
            # boot, and that surfaces at startup anyway. grep -v exits 1 when it
            # selects nothing, which for a conf holding only the stale include
            # is the correct empty rewrite, so 0 and 1 are both success. The
            # [ -e ] guard keeps a failed redirection (also 1) out of that path.
            toast_rewrite_ok=false
            grep -vxF "$toast_stale_line" "$toast_pg_conf" > "$toast_pg_conf.documentdb-tmp"
            toast_grep_status=$?
            if [ "$toast_grep_status" -le 1 ] && [ -e "$toast_pg_conf.documentdb-tmp" ]; then
                # The temp carries the boot umask; restore the original mode
                # (initdb: 0600, or 0640 with group access) so the mv cannot
                # widen it. --reference is GNU-only, hence the fallback.
                if { chmod --reference="$toast_pg_conf" "$toast_pg_conf.documentdb-tmp" 2>/dev/null \
                        || chmod 600 "$toast_pg_conf.documentdb-tmp"; } \
                        && mv "$toast_pg_conf.documentdb-tmp" "$toast_pg_conf"; then
                    toast_rewrite_ok=true
                fi
            fi
            if [ "$toast_rewrite_ok" != "true" ]; then
                rm -f "$toast_pg_conf.documentdb-tmp"
                echo "Warning: could not rewrite postgresql.conf to remove a stale TOAST compression include ($toast_stale_line); rolling this volume back to an older image may fail to start." >&2
            fi
        fi
    done
}

# Before PostgreSQL starts.
toast_prepare_fragment() {
    toast_check_fragment_path
    toast_probe_lz4_offline
    toast_write_initial_fragment
    toast_resolve_pg_conf
    toast_repair_stale_includes
}

toast_probe_lz4_runtime() {
    # TOAST fragment registration and the deferred lz4 verdict. The postmaster
    # is running from here on, so failures exit through cleanup(), which also
    # stops the log streamers.
    #
    # Every psql here takes its SQL from -c and pins stdin to /dev/null. psql
    # never reads stdin, but handing an arbitrary fd 0 to children is a hygiene
    # leak and the unit-test psql stubs drain stdin, so an inherited
    # never-closing stdin would hang them.
    toast_reload_needed=false
    if [ "$toast_pending_lz4" = "true" ]; then
        # Authoritative: pg_settings lists lz4 among this GUC's enum values
        # exactly when the binary was built with lz4 (USE_LZ4), which answers
        # even where pg_config is silent (meson). The probe ALWAYS runs, even
        # when the readiness gate said not-accepting or unknown, because the gate
        # pings TCP while psql may reach the unix socket. A failed psql is
        # retried briefly; a probe that never answered is UNCONFIRMED, never
        # "no". Only output from a psql that exited 0 is trusted.
        toast_lz4_runtime=""
        toast_probe_attempt=0
        while :; do
            if toast_lz4_runtime="$(psql -p "$POSTGRESQL_PORT" -U "$OWNER" -d postgres -X -tA \
                    -c "SELECT 'lz4' = ANY(enumvals) FROM pg_settings WHERE name = 'default_toast_compression'" < /dev/null 2>/dev/null)"; then
                break
            fi
            toast_lz4_runtime=""
            toast_probe_attempt=$((toast_probe_attempt + 1))
            if [ "$toast_probe_attempt" -ge 5 ]; then
                break
            fi
            sleep 1
        done
        case "$toast_lz4_runtime" in
            t)
                toast_write_fragment "default_toast_compression = 'lz4'"
                toast_write_status=$?
                if [ "$toast_write_status" -eq 0 ]; then
                    toast_reload_needed=true
                elif [ "$toast_write_status" -eq 2 ]; then
                    echo "Error: could not rewrite the TOAST compression fragment at $TOAST_COMPRESSION_CONF, and the previous fragment could not be removed; shutting down rather than leave a possibly stale default_toast_compression." >&2
                    exit 1
                elif [ "$toast_explicit" = "true" ]; then
                    echo "Error: could not write the TOAST compression fragment at $TOAST_COMPRESSION_CONF for the requested DOCUMENTDB_TOAST_COMPRESSION=lz4." >&2
                    exit 1
                else
                    echo "Warning: could not write the TOAST compression fragment at $TOAST_COMPRESSION_CONF; leaving default_toast_compression to the server default." >&2
                fi
                ;;
            f)
                # Definitive: the running binary has no lz4.
                if [ "$toast_offline_verdict" = "yes" ]; then
                    if [ "$toast_explicit" = "true" ]; then
                        echo "Error: DOCUMENTDB_TOAST_COMPRESSION=lz4 was requested, but the server lists no lz4 entry for default_toast_compression — the offline pg_config verdict was wrong for this build. Use pglz or default." >&2
                        exit 1
                    fi
                    echo "Warning: the server lists no lz4 entry for default_toast_compression (the offline pg_config verdict was wrong for this build); leaving default_toast_compression unset." >&2
                else
                    if [ "$toast_explicit" = "true" ]; then
                        echo "Error: DOCUMENTDB_TOAST_COMPRESSION=lz4 was requested, but this PostgreSQL build has no lz4 support (the server lists no lz4 entry for default_toast_compression). Use pglz or default." >&2
                        exit 1
                    fi
                    echo "Warning: PostgreSQL was not built with lz4 support (the server lists no lz4 entry for default_toast_compression); leaving default_toast_compression unset." >&2
                fi
                ;;
            *)
                # Unconfirmed: the probe never answered. The gate's verdict
                # picks the severity. Server confirmed accepting means an
                # unanswered probe is a real anomaly, so an explicit request
                # fails loudly in both offline-verdict cells. Without that
                # confirmation (gate timed out, or no pg_isready), no evidence
                # is treated leniently for explicit and implicit alike: stay
                # inert this boot, warn, retry next start. A server that is
                # truly sick still fails the boot at the getParameter stub
                # right after, with the correct blame.
                if [ "$toast_pg_accepting" != "true" ]; then
                    if [ "$toast_explicit" = "true" ]; then
                        echo "Warning: PostgreSQL readiness could not be confirmed, so lz4 support cannot be confirmed this boot; the requested DOCUMENTDB_TOAST_COMPRESSION=lz4 is NOT in effect this boot — the server default applies, and the next start retries." >&2
                    else
                        echo "Warning: PostgreSQL readiness could not be confirmed, so lz4 support cannot be confirmed this boot; leaving the server default in effect and retrying at the next start." >&2
                    fi
                elif [ "$toast_explicit" = "true" ]; then
                    if [ "$toast_offline_verdict" = "yes" ]; then
                        echo "Error: DOCUMENTDB_TOAST_COMPRESSION=lz4 was requested, but the server could not confirm lz4 support for default_toast_compression (the probe query failed although the server accepts connections). Check the PostgreSQL logs, or use pglz or default." >&2
                    else
                        echo "Error: DOCUMENTDB_TOAST_COMPRESSION=lz4 was requested, but lz4 support cannot be verified for this PostgreSQL build (pg_config reports no configure flags, and the server probe failed). Use pglz or default, or set default_toast_compression yourself via a mounted configuration." >&2
                    fi
                    exit 1
                elif [ "$toast_offline_verdict" = "yes" ]; then
                    echo "Warning: the server could not confirm lz4 support for default_toast_compression this boot; leaving the server default in effect and retrying at the next start." >&2
                else
                    echo "Warning: Cannot verify lz4 support for this PostgreSQL build (no configure flags reported, and the server probe failed); leaving default_toast_compression unset." >&2
                fi
                ;;
        esac
    fi
}

toast_register_include() {
    # include_if_exists, appended once. Never start_oss_server -f, whose hard
    # `include` makes a missing fragment fatal at startup, so a rolled-back
    # image could not boot the volume. Append-only is sound because a stale
    # include's target can never exist: the path is fixed per container,
    # data-volume paths are refused above, and image-fs fragments die with the
    # container. The presence check matches an ACTIVE line (leading whitespace
    # and trailing comment tolerated, leading # not). A commented-out copy is
    # respected as a deliberate disable, but not silently: it warns, and the
    # explicit-request check below turns it into a failure for a non-default
    # request.
    TOAST_INCLUDE_LINE="include_if_exists = '$TOAST_COMPRESSION_CONF'"
    toast_conf_escaped="$(printf '%s' "$TOAST_COMPRESSION_CONF" | sed -e 's/[][\.*^$(){}?+|]/\\&/g')"
    toast_include_active_re="^[[:space:]]*include_if_exists[[:space:]]*=[[:space:]]*'${toast_conf_escaped}'[[:space:]]*(#.*)?$"
    toast_include_registered=false
    if [ "$toast_conf_editable" != "true" ]; then
        echo "Warning: skipping TOAST compression registration: $DATA_PATH/postgresql.conf could not be resolved." >&2
    elif [ ! -f "$toast_pg_conf" ]; then
        # Never fabricate a postgresql.conf consisting only of our include: a
        # data directory without one is not a server this entrypoint booted,
        # and the file would be created at the boot umask, not initdb's 0600.
        echo "Warning: $toast_pg_conf not found; cannot register the TOAST compression fragment, so default_toast_compression stays at the server default." >&2
    elif grep -qE "$toast_include_active_re" "$toast_pg_conf" 2>/dev/null; then
        toast_include_registered=true
    elif grep -qF "$TOAST_INCLUDE_LINE" "$toast_pg_conf" 2>/dev/null; then
        echo "Warning: $toast_pg_conf contains the TOAST compression include only in commented-out form; respecting the disable — default_toast_compression stays at the server default." >&2
    else
        echo "Registering TOAST compression fragment in postgresql.conf..."
        # Atomic rewrite, like the repair above: a short append (disk full)
        # would leave a truncated include line in the PERSISTENT volume,
        # corrupting postgresql.conf for every later boot. awk '1'
        # newline-terminates the last line so a conf ending without one cannot
        # swallow the include (mawk ships in the ubuntu base). On failure the
        # conf is untouched and the next boot retries.
        toast_append_ok=false
        if awk '1' "$toast_pg_conf" > "$toast_pg_conf.documentdb-tmp" 2>/dev/null \
                && printf '%s\n' "$TOAST_INCLUDE_LINE" >> "$toast_pg_conf.documentdb-tmp" 2>/dev/null; then
            if { chmod --reference="$toast_pg_conf" "$toast_pg_conf.documentdb-tmp" 2>/dev/null \
                    || chmod 600 "$toast_pg_conf.documentdb-tmp"; } \
                    && mv "$toast_pg_conf.documentdb-tmp" "$toast_pg_conf"; then
                toast_append_ok=true
            fi
        fi
        if [ "$toast_append_ok" = "true" ]; then
            toast_include_registered=true
            toast_reload_needed=true
        else
            rm -f "$toast_pg_conf.documentdb-tmp"
            echo "Warning: could not register the TOAST compression fragment in $toast_pg_conf; default_toast_compression stays at the server default (the next boot will retry)." >&2
        fi
    fi
    # One contract for every not-registered branch above: an explicit
    # non-default request whose include is not in place can never take effect,
    # so fail loudly. The built-in default and explicit "default" continue on
    # the warnings already printed.
    if [ "$toast_include_registered" != "true" ] && [ "$toast_explicit" = "true" ] \
            && [ "$toast_requested" != "default" ]; then
        echo "Error: the TOAST compression include could not be registered in $toast_pg_conf, so the requested DOCUMENTDB_TOAST_COMPRESSION=$toast_requested cannot take effect." >&2
        exit 1
    fi
}

toast_reload_if_needed() {
    # Reload if the include was just added, or if the probe upgraded the
    # fragment post-start (an include predating this boot was read while the
    # fragment was still inert). The GUC is not startup-only, so a reload
    # applies it fully.
    if [ "$toast_reload_needed" = "true" ]; then
        if ! psql -p "$POSTGRESQL_PORT" -U "$OWNER" -d postgres -X -tA \
                -c "SELECT pg_reload_conf()" < /dev/null >/dev/null 2>&1; then
            echo "Warning: could not reload PostgreSQL configuration; the TOAST compression setting takes effect at the next successful start." >&2
        fi
    fi
}

# After PostgreSQL accepts connections.
toast_apply_after_start() {
    toast_probe_lz4_runtime
    toast_register_include
    toast_reload_if_needed
}
