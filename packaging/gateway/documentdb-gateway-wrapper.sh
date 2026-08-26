#!/bin/bash
# documentdb-gateway — thin wrapper that sources the per-major or global
# gateway.env before exec'ing the daemon binary. Manual --check must use the
# env file as the authoritative source, and root-shell invocations must
# downgrade to documentdb-gateway so peer auth succeeds. The systemd units
# already handle both pieces; this wrapper makes manual CLI invocations behave
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
            # refusing every other key (PATH, LD_PRELOAD, IFS,...) stops a
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
# On a multi-major host the caller
# (typically documentdb-setup) already sourced THE right per-major env
# before invoking us. If we auto-load /etc/documentdb/local/*/gateway.env
# we'd pick the FIRST alphabetically and clobber the caller's choice
# (e.g. install PG17 then PG18: setup18 sources its env, exec's wrapper,
# wrapper picks 17/gateway.env first, overwrites DOCUMENTDB_PG_URL_FILE
# and DOCUMENTDB_LISTEN_ADDR → daemon binds the wrong port).
# Guard: skip auto-load only when the caller already set
# DOCUMENTDB_PG_URL_FILE. The unsupported inline DOCUMENTDB_PG_URL is
# deliberately NOT treated as "already configured" here; it is rejected
# after this returns (see _reject_inline_pg_url). Keying the short-circuit
# off it would let an unsupported value silently suppress env-file loading.
_load_env() {
    if [[ -n "${DOCUMENTDB_PG_URL_FILE:-}" ]]; then
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

# Refuse rather than guess when the per-major glob above is ambiguous.
#
# Taking the first lexical match silently resolved a genuine ambiguity: on
# a host with PG 17 and 18 both registered, a manual root `documentdb-gateway
# --check` (or `run`) loaded 17's env and probed/bound 17's instance while
# the operator meant 18 — the exact hazard the comment above describes, and
# with _load_env's output discarded there was not even a hint. The sibling
# documentdb-gateway-admin already detects this case and refuses with a
# "specify the instance" error; behave the same way.
#
# Deliberately a SEPARATE function from _load_env so its diagnostics survive:
# the _load_env call site discards stdout and stderr.
#
# Scope: only the auto-load path, and only for commands that need a resolved
# instance (see the dispatch below -- --version is exempt). Anything arriving
# with DOCUMENTDB_PG_URL_FILE already set short-circuits: the
# documentdb-gateway-local@N template unit pins it through an
# instance-specific EnvironmentFile=, and callers like documentdb-setup source
# the right per-major env before exec'ing us.
#
# The plain documentdb-gateway.service (the Workflow B surface) uses
# EnvironmentFile=-/etc/documentdb/gateway/gateway.env, which is NOT required
# to define DOCUMENTDB_PG_URL_FILE -- the shipped sample has it commented out.
# On a host that also has two or more per-major envs registered, that unit
# therefore reaches this check and fails to start. That is intended: the
# auto-load below searches the per-major glob BEFORE the global file, so the
# previous behavior was to silently connect the Workflow B gateway to some
# per-major instance's PostgreSQL. A start-time error naming the candidates is
# recoverable; a gateway quietly serving the wrong database is not.
_refuse_ambiguous_env() {
    [[ -z "${DOCUMENTDB_PG_URL_FILE:-}" ]] || return 0

    local -a matches=()
    local env_file
    for env_file in /etc/documentdb/local/*/gateway.env; do
        [[ -f "${env_file}" ]] || continue
        matches+=("${env_file}")
    done

    (( ${#matches[@]} > 1 )) || return 0

    echo "documentdb-gateway: multiple registered PostgreSQL instances found; refusing to guess which one to use:" >&2
    for env_file in "${matches[@]}"; do
        echo "  - ${env_file}" >&2
    done
    echo "documentdb-gateway: set DOCUMENTDB_PG_URL_FILE explicitly (e.g. 'DOCUMENTDB_PG_URL_FILE=/var/lib/documentdb-local/<N>/gateway/pg-url documentdb-gateway --check'), or manage the instance through systemd: 'systemctl start documentdb-gateway-local@<N>.service'." >&2
    exit 1
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
        # Do NOT forward the config as "env KEY=VALUE" argv: a DOCUMENTDB_*
        # value could embed a secret, and runuser stays alive (PAM fork+wait) as root
        # for the daemon's lifetime, so any KEY=VALUE on its command line would
        # leak the secret to unprivileged users via ps / /proc/<pid>/cmdline.
        # The real input filter is _source_env_if_present (DOCUMENTDB_*-only, no
        # shell evaluation). Plain "runuser -u" is also portable to EL8, whose
        # runuser (util-linux 2.32) lacks --whitelist-environment.
        exec runuser -u "${GW_OS_USER}" -- "${DAEMON}" "$@"
    fi
    exec "${DAEMON}" "$@"
}

# Fail closed on the unsupported inline DOCUMENTDB_PG_URL variable. The
# daemon reads only DOCUMENTDB_PG_URL_FILE (a path to a 0640 connection
# file); it never reads an inline DOCUMENTDB_PG_URL. Honoring one would
# silently misconfigure the daemon (no connection file -> no PostgreSQL
# endpoint) and leak any embedded password to unprivileged users via
# /proc/<pid>/environ. This is invoked AFTER _load_env so it rejects an
# inline value from ANY source -- the caller's environment or a
# hand-edited gateway.env (_source_env_if_present exports every
# DOCUMENTDB_* key). The value itself is never echoed.
_reject_inline_pg_url() {
    if [[ -n "${DOCUMENTDB_PG_URL:-}" ]]; then
        echo "documentdb-gateway: DOCUMENTDB_PG_URL is not supported. Write the connection string to a file and point DOCUMENTDB_PG_URL_FILE at it instead (an inline URL is ignored by the daemon and could leak a password via /proc/<pid>/environ)." >&2
        exit 1
    fi
}

# Resolve configuration before dispatch, then fail closed on an inline
# DOCUMENTDB_PG_URL. systemd path: env is already provided by
# EnvironmentFile= (DOCUMENTDB_PG_URL_FILE set), so _load_env
# short-circuits and the runuser downgrade is skipped. No-systemd path
# (containers, manual dev): _load_env sources the per-major (or global)
# gateway.env and _maybe_runuser_down downgrades before exec. The
# rejection runs once the environment is fully assembled, so it also
# catches a value smuggled in through gateway.env, not just one in the
# caller's own environment.
# Metadata-only commands report on the build and exit without touching
# PostgreSQL, so there is no instance to be ambiguous about — they must
# keep working on a multi-major host. The set mirrors the daemon's own
# metadata surface (the version/help flags accepted by parse_cli_from_args
# in oss/pg_documentdb_gw/documentdb_gateway/src/cli.rs); everything else —
# run, --check, the Docker JSON-config pass-through — needs a resolved
# instance and gets the ambiguity check.
case "${1:-}" in
    --version|-V|--help|-h)
        : # metadata-only: skip the instance-ambiguity check
        ;;
    *)
        _refuse_ambiguous_env
        ;;
esac
_load_env >/dev/null 2>&1 || true
_reject_inline_pg_url

# All dispatch paths launch the daemon with the caller's argv unchanged
# (run / --check / --version / --help / no-arg / JSON-config pass-through);
# per-command handling happens in the daemon itself.
_maybe_runuser_down "$@"
