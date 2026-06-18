#!/bin/bash
# documentdb-gateway — thin wrapper that sources the per-major or global
# gateway.env before exec'ing the daemon binary. Fixes Gap #6 (manual
# --check using stale JSON config when the env file is the authoritative
# source) and Gap #16-adjacent (peer-auth failing because the wrapper
# ran as root instead of documentdb-gateway). The systemd units already
# handle both pieces; this wrapper makes manual CLI invocations behave
# the same way.
#
# This file is the single source of truth for the wrapper: it is installed
# verbatim at /usr/bin/documentdb-gateway by BOTH the DEB build
# (oss/packaging/gateway/build-gateway-deb.sh) and the RPM spec
# (oss/packaging/rpm/spec/documentdb-gateway.spec), so the logic lives in
# exactly one place.

set -e
DAEMON="/usr/lib/documentdb-gateway/documentdb-gateway-daemon"
GW_OS_USER="documentdb-gateway"

_source_env_if_present() {
    local f="$1"
    [[ -r "${f}" ]] || return 1

    # Parse strictly as systemd EnvironmentFile-style KEY=VALUE lines; do
    # NOT execute the file as a shell script. gateway.env is also consumed
    # by systemd's EnvironmentFile= (which never runs shell), so shell
    # metacharacters or command substitutions in a value must be treated as
    # literal data here rather than executed - this wrapper runs as root
    # before the runuser downgrade.
    #
    # NOTE: trimming and quote-stripping use regex rather than bash '%'-based
    # suffix/prefix parameter expansions. That keeps this wrapper safe to
    # embed verbatim in packaging that performs its own macro expansion (e.g.
    # an RPM spec scriptlet, which would otherwise rewrite doubled
    # percent-signs and silently corrupt the parsing).
    local _ef_line _ef_key _ef_val
    while IFS= read -r _ef_line || [[ -n "${_ef_line}" ]]; do
        _ef_line="${_ef_line//$'\r'/}"
        if [[ "${_ef_line}" =~ ^[[:space:]]*$ || "${_ef_line}" =~ ^[[:space:]]*# ]]; then
            continue
        fi
        if [[ "${_ef_line}" =~ ^[[:space:]]*(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
            _ef_key="${BASH_REMATCH[2]}"
            # Only export the gateway's own DOCUMENTDB_* configuration keys.
            # This wrapper runs as root before the runuser downgrade, so
            # refusing every other key (PATH, LD_PRELOAD, IFS, ...) stops a
            # hostile or mistaken env file from steering root-side execution.
            # This is the security boundary for the untrusted env file; the
            # daemon then inherits these DOCUMENTDB_* vars (along with the
            # trusted root caller's own environment) through the plain
            # "runuser -u" privilege drop below.
            if [[ "${_ef_key}" != DOCUMENTDB_* ]]; then
                continue
            fi
            _ef_val="${BASH_REMATCH[3]}"
            # Trim surrounding whitespace (regex), then strip one layer of
            # matching surrounding quotes.
            if [[ "${_ef_val}" =~ ^[[:space:]]*(.*[^[:space:]])[[:space:]]*$ ]]; then
                _ef_val="${BASH_REMATCH[1]}"
            else
                _ef_val=""
            fi
            if [[ "${_ef_val}" =~ ^\"(.*)\"$ ]]; then
                _ef_val="${BASH_REMATCH[1]}"
            elif [[ "${_ef_val}" =~ ^\'(.*)\'$ ]]; then
                _ef_val="${BASH_REMATCH[1]}"
            fi
            export "${_ef_key}=${_ef_val}"
        fi
    done < "${f}"
    return 0
}

# Pick up env from the first matching source (most-specific wins).
# Advanced-user E2E flagged (Gap #2): on a multi-major host the caller
# (typically documentdb-setup) already sourced THE right per-major env
# before invoking us. If we auto-load /etc/documentdb/local/*/gateway.env
# we'd pick the FIRST alphabetically and clobber the caller's choice
# (e.g. install PG17 then PG18: setup18 sources its env, exec's wrapper,
# wrapper picks 17/gateway.env first, overwrites DOCUMENTDB_PG_URL_FILE
# and DOCUMENTDB_LISTEN_ADDR → daemon binds the wrong port).
# Guard: skip auto-load when the caller already set DOCUMENTDB_PG_URL_FILE
# or DOCUMENTDB_PG_URL.
_load_env() {
    if [[ -n "${DOCUMENTDB_PG_URL_FILE:-}" || -n "${DOCUMENTDB_PG_URL:-}" ]]; then
        # Caller already configured us; trust them.
        return 0
    fi
    local env_file
    for env_file in /etc/documentdb/local/*/gateway.env; do
        [[ -f "${env_file}" ]] || continue
        _source_env_if_present "${env_file}" && return 0
    done
    _source_env_if_present /etc/documentdb/gateway/gateway.env && return 0
    return 1
}

# Re-exec self as the gateway OS user so peer-auth via the documentdb-
# gateway-map ident map succeeds. Only applies when we are currently
# root AND the documentdb-gateway user exists AND we are NOT already
# running under systemd (which already set User=documentdb-gateway).
_under_systemd() {
    [[ "${INVOCATION_ID:-}" != "" ]]
}

_maybe_runuser_down() {
    if [[ "$(id -u)" -eq 0 ]] \
            && id -u "${GW_OS_USER}" >/dev/null 2>&1 \
            && ! _under_systemd; then
        # Drop privileges to the gateway OS user so the daemon's peer-auth via
        # the documentdb-gateway-map ident map succeeds. The daemon reads its
        # configuration from the environment, which runuser preserves across the
        # privilege drop, so nothing is passed on the command line.
        #
        # Do NOT forward the config as "env KEY=VALUE" argv: DOCUMENTDB_PG_URL
        # may embed a password, and runuser stays alive (PAM fork+wait) as root
        # for the daemon's lifetime, so any KEY=VALUE on its command line would
        # leak the secret to unprivileged users via ps / /proc/<pid>/cmdline.
        # The real input filter is _source_env_if_present (DOCUMENTDB_*-only, no
        # shell evaluation). Plain "runuser -u" is also portable to EL8, whose
        # runuser (util-linux 2.32) lacks --whitelist-environment.
        exec runuser -u "${GW_OS_USER}" -- "${DAEMON}" "$@"
    fi
    exec "${DAEMON}" "$@"
}

case "${1:-}" in
    run)
        # systemd path: env loaded by EnvironmentFile=, user set by
        # User=documentdb-gateway → just exec the daemon.
        # No-systemd path (containers, manual dev): we need to load env
        # AND downgrade ourselves before exec'ing the daemon, otherwise
        # peer auth as root fails. _maybe_runuser_down handles both.
        _load_env >/dev/null 2>&1 || true
        shift
        _maybe_runuser_down run "$@"
        ;;
    --check|--version)
        _load_env >/dev/null 2>&1 || true
        _maybe_runuser_down "$@"
        ;;
    "")
        _load_env >/dev/null 2>&1 || true
        _maybe_runuser_down
        ;;
    *)
        # Pass-through (e.g., Docker compat path that runs the daemon
        # with a JSON config arg). Load env + downgrade.
        _load_env >/dev/null 2>&1 || true
        _maybe_runuser_down "$@"
        ;;
esac
