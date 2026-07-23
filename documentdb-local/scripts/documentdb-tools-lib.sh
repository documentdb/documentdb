# shellcheck shell=bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# documentdb-tools-lib.sh — shared helpers for the DocumentDB administrator
# tools.
#
# This file is *sourced*, not executed. It single-sources the safety-critical
# managed-block primitives and shared_preload_libraries parsing that were
# previously copy-pasted (with renamed locals) into multiple tools, so the tools
# cannot drift on marker or parser semantics.
#
# Contract — this library is safe to source under `set -u`. The sourcing script
# MUST define the host hooks required by the helpers it calls:
#  * die <msg> — print an error and exit non-zero.
#  * log_verbose <msg> — verbose diagnostic to stderr (no-op unless verbose).
#  * create_temp_in_dir <var> <dir> — create a temp file in <dir>, assign its
#    path to the named <var>, and register it for cleanup on the sourcing
#    script's EXIT trap.
#
# merge_shared_preload_libraries additionally requires HAS_EXTENDED_RUM to be
# set before it is called: "true" when pg_documentdb_extended_rum must be added
# to shared_preload_libraries, "false" otherwise.
# die / log_verbose / create_temp_in_dir remain per-tool because the logging
# idiom and temp-file/cleanup infrastructure are still being unified separately.

# True when systemd is actually usable: the binary alone is not enough —
# containers often ship systemctl with no PID-1 systemd, and calling it
# there just emits "Failed to connect to bus" noise. /run/systemd/system
# exists only when systemd is PID 1. Single-sourced here so the tools
# cannot drift on the probe (they once did: two scripts carried copies
# with different command probes). The gateway maintainer scripts keep
# deliberate inline copies — they run at uninstall time when this file
# may already be gone.
has_working_systemd() {
    [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

trim_whitespace() {
    local value="$1"
    value="${value#"${value%%[![:space:]]*}"}"
    value="${value%"${value##*[![:space:]]}"}"
    printf '%s' "${value}"
}

strip_wrapping_quotes() {
    local value="$1"
    if [[ "${value}" == \'*\' && "${value}" == *\' ]]; then
        value="${value:1:${#value}-2}"
    elif [[ "${value}" == \"*\" && "${value}" == *\" ]]; then
        value="${value:1:${#value}-2}"
    fi
    printf '%s' "${value}"
}

array_contains() {
    local needle="$1"
    shift || true
    local item=""
    # Use ${@+"$@"} instead of "$@" so an empty argument list does not
    # trigger an "unbound variable" error under set -u on bash 4.x.
    for item in ${@+"$@"}; do
        if [[ "${item}" == "${needle}" ]]; then
            return 0
        fi
    done
    return 1
}

# read_shared_preload_libraries_from_stdin: print the last uncommented
# shared_preload_libraries value from the config text on STDIN. Split out from
# read_shared_preload_libraries_from_file so a caller that already has the text
# in a pipe (e.g. a managed-block-stripped stream from strip_managed_block) can
# parse it WITHOUT materializing a temp file — keeping read-only callers
# (documentdb-tune --print / --dry-run) side-effect-free. The awk parser lives
# here only (single-sourced); read_shared_preload_libraries_from_file is a thin
# file wrapper around it.
#
# Match PostgreSQL's postgresql.conf syntax: parameter names are
# case-INsensitive and the "=" between name and value is OPTIONAL
# (whitespace also separates them), so "SHARED_PRELOAD_LIBRARIES 'x'" is a
# valid assignment. The (=|space) boundary after the key keeps a longer
# parameter that merely starts with it from matching. Mirrors
# documentdb-tune's _read_scalar_guc_from_file.
read_shared_preload_libraries_from_stdin() {
    local current_value=""
    current_value="$(
        awk '
            BEGIN { klen = length("shared_preload_libraries") }
            /^[[:space:]]*#/ { next }
            tolower($0) ~ /^[[:space:]]*shared_preload_libraries([[:space:]]*=|[[:space:]])/ {
                v = $0
                sub(/^[[:space:]]*/, "", v)                 # drop leading whitespace
                v = substr(v, klen + 1)                     # drop the key name (any case, exact length)
                sub(/^[[:space:]]*=?[[:space:]]*/, "", v)   # drop the optional "=" and surrounding whitespace
                # Strip the inline "#..." comment that the stock Debian line
                # ships with, honoring PostgreSQL`s rule that # ends the value
                # unless it is inside a quoted string. \047 is a single quote.
                if (v ~ /^\047/) { if (match(v, /^\047[^\047]*\047/)) v = substr(v, RSTART, RLENGTH) }
                else if (v ~ /^"/) { if (match(v, /^"[^"]*"/)) v = substr(v, RSTART, RLENGTH) }
                else { sub(/[[:space:]]*#.*$/, "", v) }
                gsub(/[[:space:]]+$/, "", v)
                print v
            }
        ' | tail -n 1
    )"
    current_value="$(strip_wrapping_quotes "${current_value}")"
    printf '%s' "${current_value}"
}

# read_shared_preload_libraries_from_file <config_path>: thin file wrapper around
# read_shared_preload_libraries_from_stdin. Empty when the file is absent.
read_shared_preload_libraries_from_file() {
    local config_path="$1"
    [[ -f "${config_path}" ]] || return 0
    read_shared_preload_libraries_from_stdin < "${config_path}"
}

merge_shared_preload_libraries() {
    local current_value="$1"
    local item joined=""
    local -a merged=() current_items=()
    local -a required=(
        "pg_cron"
        "pg_documentdb_core"
        "pg_documentdb"
    )
    : "${HAS_EXTENDED_RUM:?merge_shared_preload_libraries requires HAS_EXTENDED_RUM to be 'true' or 'false'}"
    [[ "${HAS_EXTENDED_RUM}" == "true" ]] && required+=("pg_documentdb_extended_rum")

    local cleaned
    cleaned="$(strip_wrapping_quotes "${current_value}")"
    if [[ -n "${cleaned}" ]]; then
        IFS=',' read -r -a current_items <<< "${cleaned}"
        for item in "${current_items[@]}"; do
            item="$(trim_whitespace "${item}")"
            [[ -z "${item}" ]] && continue
            array_contains "${item}" "${merged[@]+"${merged[@]}"}" || merged+=("${item}")
        done
    fi

    for item in "${required[@]}"; do
        array_contains "${item}" "${merged[@]+"${merged[@]}"}" || merged+=("${item}")
    done

    for item in "${merged[@]}"; do
        joined+="${joined:+, }${item}"
    done
    printf '%s' "${joined}"
}

# assert_managed_markers_balanced <file> <start> <end>: fail closed (die) when a
# managed block's start/end marker counts differ — the file is truncated/corrupt
# and must not be edited automatically.
assert_managed_markers_balanced() {
    local target_file="$1" start="$2" end="$3"
    [[ -f "${target_file}" ]] || return 0
    # Validate that the managed markers are balanced AND correctly ordered —
    # each start is closed by a LATER end, with no nesting and no end-before-
    # start — tolerating a trailing CR so a CRLF-encoded block is still
    # recognised. A start==end COUNT alone is insufficient: reversed markers have
    # equal counts yet corrupt a strip (deleting real rules), and a CRLF block
    # that goes unrecognised lingers with stale, possibly auth-relevant rules.
    if ! awk -v s="${start}" -v e="${end}" '
        { line = $0; sub(/\r$/, "", line) }
        line == s { if (open) { bad = 1; exit } open = 1; next }
        line == e { if (!open) { bad = 1; exit } open = 0; next }
        END { exit((bad || open) ? 1 : 0) }
    ' "${target_file}"; then
        die "refusing to strip managed block in ${target_file}: unbalanced or misordered start/end markers (file appears truncated/corrupt). Fix the markers manually and retry."
    fi
}

# strip_managed_block <file> <start> <end>: print <file> with the managed block
# (inclusive of its markers) removed. Asserts marker balance/order first, and
# matches markers tolerating a trailing CR (so a CRLF-encoded block is stripped
# rather than left behind as a stale duplicate). Non-marker lines are printed
# verbatim (their original line endings preserved).
strip_managed_block() {
    local target_file="$1" start="$2" end="$3"
    [[ -f "${target_file}" ]] || return 0
    assert_managed_markers_balanced "${target_file}" "${start}" "${end}"
    awk -v s="${start}" -v e="${end}" '
        { line = $0; sub(/\r$/, "", line) }
        line == s { skip = 1; next }
        line == e { skip = 0; next }
        !skip { print }
    ' "${target_file}"
}

# extract_managed_block_content <file> <start> <end>: print only the content
# between the managed markers (exclusive of the markers), tolerating a trailing
# CR on the marker lines.
extract_managed_block_content() {
    local target_file="$1" start="$2" end="$3"
    [[ -f "${target_file}" ]] || return 0
    awk -v s="${start}" -v e="${end}" '
        { line = $0; sub(/\r$/, "", line) }
        line == s { b = 1; next }
        line == e { b = 0; next }
        b { print }
    ' "${target_file}"
}

# rewrite_with_managed_block <file> <start> <end> <content>: atomically replace
# (or append) the managed block in <file> with <content>. An empty <content>
# removes the block. Temp files are created in the target's directory so the
# final mv is an atomic same-filesystem rename and config contents never leak
# into /tmp.
rewrite_with_managed_block() {
    local target_file="$1" start="$2" end="$3" content="$4"
    local _rwmb_stripped _rwmb_tmp
    local _rwmb_dir
    _rwmb_dir="$(dirname "${target_file}")"

    # Validate marker balance up front: strip_managed_block fails closed
    # (die -> exit) on an unbalanced file. The EXIT trap installed by the
    # sourcing script cleans up any registered temp file on a die/abort, so
    # checking here keeps the abort path side-effect free before any temp
    # file is even created.
    assert_managed_markers_balanced "${target_file}" "${start}" "${end}"

    # Create temp files in the target file's directory so the eventual mv is an
    # atomic same-filesystem rename, and so an interrupted run does not leak
    # config contents into /tmp. create_temp_in_dir registers each path in the
    # sourcing script's global cleanup array (no per-path trap interpolation, so
    # a path containing shell metacharacters cannot break out).
    create_temp_in_dir _rwmb_stripped "${_rwmb_dir}"
    create_temp_in_dir _rwmb_tmp "${_rwmb_dir}"

    strip_managed_block "${target_file}" "${start}" "${end}" > "${_rwmb_stripped}"

    {
        cat "${_rwmb_stripped}"
        if [[ -n "${content}" ]]; then
            [[ -s "${_rwmb_stripped}" ]] && printf '\n'
            printf '%s\n' "${start}"
            printf '%s\n' "${content}"
            printf '%s\n' "${end}"
        fi
    } > "${_rwmb_tmp}"

    if [[ -e "${target_file}" ]]; then
        chown --reference="${target_file}" "${_rwmb_tmp}" 2>/dev/null || true
        chmod --reference="${target_file}" "${_rwmb_tmp}" 2>/dev/null || true
    fi
    mv "${_rwmb_tmp}" "${target_file}"
    rm -f "${_rwmb_stripped}"
}

# prepend_with_managed_block <file> <start> <end> <content>: like
# rewrite_with_managed_block, but inserts the managed block BEFORE the first
# non-comment, non-blank line instead of appending it. This matters for
# pg_hba.conf, where rules are evaluated top-to-bottom and the FIRST match wins,
# so the documentdb rules must precede any pre-existing administrator rules.
# Idempotent (an existing managed block with the same markers is stripped
# first), fails closed on a torn/unbalanced block, uses temp files in the target
# directory for an atomic same-filesystem rename, and preserves the target's
# owner and mode. Single-sourced here so documentdb-setup and
# documentdb-register-gateway cannot drift on this security-sensitive helper.
prepend_with_managed_block() {
    local target_file="$1" start="$2" end="$3" content="$4"
    local _pwmb_stripped _pwmb_tmp _pwmb_block
    local _pwmb_dir
    _pwmb_dir="$(dirname "${target_file}")"

    # Reject a torn/unbalanced managed block before creating any temp file
    # (strip_managed_block also fails closed; this keeps the abort side-effect
    # free), mirroring rewrite_with_managed_block.
    assert_managed_markers_balanced "${target_file}" "${start}" "${end}"

    create_temp_in_dir _pwmb_stripped "${_pwmb_dir}"
    create_temp_in_dir _pwmb_tmp "${_pwmb_dir}"
    create_temp_in_dir _pwmb_block "${_pwmb_dir}"

    strip_managed_block "${target_file}" "${start}" "${end}" > "${_pwmb_stripped}"

    if [[ -z "${content}" ]]; then
        cat "${_pwmb_stripped}" > "${_pwmb_tmp}"
    else
        {
            printf '%s\n' "${start}"
            printf '%s\n' "${content}"
            printf '%s\n' "${end}"
        } > "${_pwmb_block}"

        # Insert the block before the first non-comment, non-blank line; if the
        # file is empty or all comments/blanks, append it at the end.
        awk -v blockfile="${_pwmb_block}" '
            BEGIN { inserted = 0 }
            !inserted && /^[^#]/ && !/^[[:space:]]*$/ {
                while ((getline line < blockfile) > 0) print line
                close(blockfile)
                print ""
                inserted = 1
            }
            { print }
            END {
                if (!inserted) {
                    while ((getline line < blockfile) > 0) print line
                    close(blockfile)
                }
            }
        ' "${_pwmb_stripped}" > "${_pwmb_tmp}"
    fi

    if [[ -e "${target_file}" ]]; then
        # Preserve owner/mode, and FAIL CLOSED if we cannot: a security-sensitive
        # pg_hba.conf must never be left with the temp file's 0600/root mode,
        # which PostgreSQL — running as the DB user — could not read (an auth
        # outage). Use explicit `|| die` (rather than relying on set -e) so the
        # helper fails closed even if a caller invokes it in an `if`/`&&`/`||`
        # context where errexit is disabled. This preserves documentdb-setup's
        # prior preserve_file_metadata behavior and additionally hardens
        # documentdb-register-gateway's HBA path (its prior copy suppressed these
        # errors). Both callers run as root, where the calls succeed; failing
        # closed only bites a genuinely broken environment, where aborting (with
        # the original file intact) beats writing an unreadable HBA.
        chown --reference="${target_file}" "${_pwmb_tmp}" \
            || die "prepend_with_managed_block: cannot preserve ownership of ${target_file}"
        chmod --reference="${target_file}" "${_pwmb_tmp}" \
            || die "prepend_with_managed_block: cannot preserve mode of ${target_file}"
    fi
    mv "${_pwmb_tmp}" "${target_file}"
    rm -f "${_pwmb_stripped}" "${_pwmb_block}"
}

# backup_file <file>: copy <file> to a timestamped sibling backup before an
# in-place edit. No-op when <file> does not exist.
backup_file() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    local timestamp
    timestamp="$(date +%Y%m%d%H%M%S)"
    local backup
    backup="$(mktemp "$(dirname "${file}")/$(basename "${file}").documentdb-backup.${timestamp}.XXXXXX")" \
        || die "Cannot create backup file for ${file}."
    cp -a "${file}" "${backup}"
    log_verbose "Backed up ${file} -> ${backup}"
}

# check_foreign_markers <file>: die if <file> contains managed-block markers
# owned by a tool outside the documentdb-* family (we never edit a file another
# tool manages). Markers from documentdb-setup / -tune / -register-gateway are
# treated as friendly (same package set, never collide on one logical block).
check_foreign_markers() {
    local file="$1"
    [[ -f "${file}" ]] || return 0
    local foreign_count
    # Total managed-block start markers (any tool).
    local total_count
    total_count="$(grep -cE '^\s*#\s*>>>\s+\S+\s+managed\s+' "${file}" 2>/dev/null || true)"
    # Markers owned by sibling tools in the documentdb-* family
    # (documentdb-setup, documentdb-tune, documentdb-register-gateway):
    # we treat these as friendly because all three are shipped by the
    # same package set and never collide on the same logical block.
    local family_count
    family_count="$(grep -cE '^\s*#\s*>>>\s+documentdb-(setup|tune|register-gateway)\s+managed\s+' "${file}" 2>/dev/null || true)"
    # Any managed-block marker that is not part of the documentdb family is
    # foreign. Refuse if even one is present (the family count already excludes
    # our own blocks, so a re-apply over our own markers does not trip this).
    foreign_count=$(( total_count - family_count ))
    if (( foreign_count > 0 )); then
        die "${file} contains managed-block markers from another tool. Refusing to modify."
    fi
}

# documentdb_default_pg_port <major>: print the per-major default PostgreSQL
# port (9700 + major, e.g. 9718 for PG 18) so the private stand-alone instance
# gets a predictable, collision-avoiding port that never lands on 5432. Single-
# sourced so the formula lives in exactly one place.
documentdb_default_pg_port() {
    printf '%s' "$(( 9700 + $1 ))"
}

# documentdb_pg_bindir_candidates <major>: print the candidate PostgreSQL bin
# directories for <major>, most-preferred first — the Debian/Ubuntu layout
# (/usr/lib/postgresql/N/bin) then the RHEL/PGDG layout (/usr/pgsql-N/bin), one
# per line. Callers probe for the specific binary they need (pg_config, psql,
# ...). Single-sourced so the layout list cannot drift across documentdb-tune,
# documentdb-register-gateway, and documentdb-setup.
documentdb_pg_bindir_candidates() {
    local major="$1"
    printf '/usr/lib/postgresql/%s/bin\n/usr/pgsql-%s/bin\n' "${major}" "${major}"
}

# documentdb_detect_extended_rum <sharedir>: set HAS_EXTENDED_RUM to "true" when
# the extended-RUM extension control file is present under <sharedir>, else
# "false". Single-sourced so documentdb-tune and documentdb-setup probe the
# extension identically before feeding HAS_EXTENDED_RUM into
# merge_shared_preload_libraries.
documentdb_detect_extended_rum() {
    local sharedir="$1"
    if [[ -n "${sharedir}" && -f "${sharedir}/extension/documentdb_extended_rum.control" ]]; then
        HAS_EXTENDED_RUM=true
    else
        HAS_EXTENDED_RUM=false
    fi
}

# documentdb_validate_gateway_username <username> [setup_configuration_json]
#
# Reject a username the GATEWAY would refuse at authentication time, before a
# tool creates a role that can never log in. Returns 0 when the name is
# allowed, 1 (with a diagnostic on stderr) when it is not.
#
# Why this exists: documentdb-setup and documentdb-gateway-admin created roles
# without consulting the gateway's own policy, so
# `documentdb-setup --admin-user pgadmin --yes` exited 0, printed
# "SUCCESS: DocumentDB is ready" and a connect command, and left an install
# whose only admin failed every login with "Username is invalid." The
# equivalent check already guarded the container path
# (documentdb_validate_username.sh); this is the packaged-CLI counterpart, so
# both surfaces enforce one policy.
#
# The gateway's SetupConfiguration.json is the authority for
# BlockedRolePrefixes (case-insensitive prefix match, e.g. documentdb / citus /
# pg / internal_role). When that file is absent or unparseable we cannot know
# the policy: warn and allow rather than block an install on a missing config,
# since the gateway still enforces it at authentication time.
documentdb_validate_gateway_username() {
    local username="$1"
    local config="${2:-/etc/documentdb/gateway/SetupConfiguration.json}"

    [[ -n "${username}" ]] || return 0

    if [[ ! -r "${config}" ]]; then
        echo "Warning: gateway configuration '${config}' is not readable; skipping the reserved-prefix check for username '${username}'." >&2
        return 0
    fi
    if ! command -v jq >/dev/null 2>&1; then
        echo "Warning: jq is unavailable; skipping the reserved-prefix check for username '${username}'." >&2
        return 0
    fi

    local prefixes_type
    prefixes_type="$(jq -r '.BlockedRolePrefixes | type' "${config}" 2>/dev/null || true)"
    if [[ "${prefixes_type}" != "array" ]]; then
        echo "Warning: BlockedRolePrefixes missing or malformed in '${config}'; skipping the reserved-prefix check for username '${username}'." >&2
        return 0
    fi

    local -a blocked=()
    mapfile -t blocked < <(jq -r '.BlockedRolePrefixes[]?' "${config}" 2>/dev/null)
    (( ${#blocked[@]} > 0 )) || return 0

    local blocked_list
    blocked_list="$(printf '%s, ' "${blocked[@]}")"
    blocked_list="${blocked_list%, }"

    local username_lower="${username,,}"
    local prefix prefix_lower
    for prefix in "${blocked[@]}"; do
        prefix_lower="${prefix,,}"
        # An empty entry would match every name; the gateway treats it that
        # way too, so surface it as a configuration error rather than
        # silently rejecting every username.
        if [[ -z "${prefix_lower}" ]]; then
            echo "Warning: BlockedRolePrefixes in '${config}' contains an empty entry, which the gateway treats as blocking every username; skipping the check." >&2
            return 0
        fi
        case "${username_lower}" in
            "${prefix_lower}"*)
                echo "Error: username '${username}' begins with the reserved prefix '${prefix}', which the gateway refuses at authentication ('Username is invalid'). Creating it would leave an account that can never log in." >&2
                echo "Choose a username that does not begin with any of: ${blocked_list}." >&2
                return 1
                ;;
        esac
    done
    return 0
}

# ─────────────────────────────────────────────────────────────────────────
# port→PID identity primitives (root-capable, /proc-only)
# ─────────────────────────────────────────────────────────────────────────
#
# Shared by documentdb-setup (find_listener_pid fallback, the nohup-record
# reader, the ownership gates) and documentdb-local-reset (nohup gateway stop).
# ONE definition of each so the two scripts cannot drift.
#
# HOST CONTRACT: a script sourcing these must provide `die` and `log_warn`
# (nohup_gateway_pid_for_port calls log_warn on a reject). documentdb-setup and
# documentdb-local-reset both do.
#
# The wizard historically could not map a port to its owning process without
# lsof or ss, and papered over the gap with a "1" placeholder. Every mutating
# path runs as root, and root can resolve the mapping from /proc: the port's
# LISTEN-socket inode(s) from /proc/net/tcp{,6}, then the /proc/<pid>/fd table
# that holds socket:[inode].

# port_listen_inodes <port> — print the socket inode of every LISTEN socket on
# the port (tcp and tcp6 union: a dual-stack listener holds one of each;
# SO_REUSEPORT holds several). Prints nothing when the port has no listener or
# /proc/net is unreadable. Always returns 0 — emptiness is the signal.
port_listen_inodes() {
    local port="$1" port_hex f
    port_hex="$(printf '%04X' "${port}" 2>/dev/null || true)"
    [[ -n "${port_hex}" ]] || return 0
    for f in /proc/net/tcp /proc/net/tcp6; do
        [[ -r "${f}" ]] || continue
        awk -v p=":${port_hex}" \
            'NR>1 && $4=="0A" && toupper($2) ~ p"$" {print $10}' \
            "${f}" 2>/dev/null || true
    done | sort -u
}

# pid_listens_on_port <pid> <port> → 0 the pid holds a LISTEN socket on the
# port / 1 it definitely does not / 2 unknown (no inode visible, or the fd
# targets could not be read). Callers MUST treat 2 as "no new information".
#
# A definite 1 requires that we actually RESOLVED at least one fd target and
# none matched, OR that a readable fd dir globbed to zero entries (a zombie
# holds nothing) — the readable-empty case is recorded IN the same scan pass,
# never by a second stat at a later instant. In a container without
# CAP_SYS_PTRACE — the very environment this fallback serves — root can list
# another uid's /proc/<pid>/fd but every readlink is denied; inferring "no"
# from all-denied returned a false definite-1, so all-denied is UNKNOWN.
# fd tables are per thread-GROUP; /proc/<pid>/fd is the whole set (no task/
# descent needed).
pid_listens_on_port() {
    local pid="$1" port="$2"
    local inodes ino fd target
    local resolved=0 readable_empty=0
    inodes="$(port_listen_inodes "${port}")"
    [[ -n "${inodes}" ]] || return 2
    if [[ -d "/proc/${pid}/fd" && -r "/proc/${pid}/fd" ]]; then
        local any_entry=0
        for fd in "/proc/${pid}/fd"/*; do
            [[ -e "${fd}" || -L "${fd}" ]] || continue
            any_entry=1
            target="$(readlink "${fd}" 2>/dev/null || true)"
            [[ -n "${target}" ]] || continue
            resolved=$(( resolved + 1 ))
            for ino in ${inodes}; do
                # EXACT match: socket:[12] must never match socket:[123].
                [[ "${target}" == "socket:[${ino}]" ]] && return 0
            done
        done
        (( any_entry == 0 )) && readable_empty=1
    fi
    (( resolved > 0 || readable_empty == 1 )) && return 1
    return 2
}

# ── nohup gateway per-port record ──────────────────────────────────────
#
# The nohup launch (no working systemd) records the launched PID in a per-port
# file, the only reliable port→process map on a host where ss/lsof cannot
# report owners. Scoped by PORT: a host-wide name match also hits another
# major's gateway, so a re-run for one major would collateral-kill another's.
#
# RECORD FORMAT: one line, space-separated: "PID [STARTTIME [BOOT_ID]]".
# STARTTIME is /proc/<pid>/stat field 22 (clock ticks since boot); BOOT_ID is
# /proc/sys/kernel/random/boot_id. The extra fields make a recycled PID
# detectable WITHOUT CAP_SYS_PTRACE (stat is not ptrace-gated), which
# pid_listens_on_port cannot do in the target container. A legacy one-field
# record (PID only) is still honoured — no re-run bricks on an old record.
nohup_gateway_pidfile() {
    printf '/run/documentdb-gateway/gateway-%s.pid' "$1"
}

# proc_starttime <pid> — print /proc/<pid>/stat field 22, parsed robustly.
# comm (field 2) can contain spaces and ')'; nothing after the LAST ')' can,
# so split on ')' and take field 20 of the tail (overall field N = tail N-2;
# starttime = overall 22 = tail 20). Prints nothing on any failure.
proc_starttime() {
    local pid="$1"
    [[ -r "/proc/${pid}/stat" ]] || return 0
    awk '{ n = split($0, a, ")"); split(a[n], f); print f[20] }' \
        "/proc/${pid}/stat" 2>/dev/null | tr -dc '0-9' || true
}

# current_boot_id — the kernel's boot UUID, or nothing if unreadable.
current_boot_id() {
    [[ -r /proc/sys/kernel/random/boot_id ]] || return 0
    tr -d '[:space:]' < /proc/sys/kernel/random/boot_id 2>/dev/null || true
}

# nohup_gateway_record_pid <recordfile> — print the PID (first whitespace
# field of line 1), validated numeric and > 1. Returns 1 (prints nothing)
# otherwise. THE single record-PID parser: a bare `tr -dc 0-9` would
# concatenate PID+STARTTIME+BOOT_ID digits into garbage.
nohup_gateway_record_pid() {
    # first/pid are initialised so a file unlinked BETWEEN the -r test and the
    # open (a concurrent reset/setup rm) leaves them empty — a clean reject —
    # rather than unset, which under the caller's `set -u` would abort the shell
    # instead of returning 1.
    local recordfile="$1" first="" pid=""
    [[ -r "${recordfile}" ]] || return 1
    # 2>/dev/null BEFORE the input redirection: redirections apply left-to-right,
    # so if the file was unlinked since the -r test (a concurrent reset/setup),
    # the open failure is reported to fd 2 only AFTER it points at /dev/null —
    # otherwise bash prints a stray "No such file or directory" to the operator's
    # terminal before the suppression takes effect.
    IFS= read -r first 2>/dev/null < "${recordfile}" || true
    pid="${first%%[![:digit:]]*}"      # leading digit run of field 1
    [[ -n "${pid}" ]] || return 1
    (( 10#${pid} > 1 )) 2>/dev/null || return 1
    printf '%s' "${pid}"
}

# True when <pid> is one of our gateway binaries, judged from the process
# itself. Single definition of "this is our gateway".
gateway_exe_matches() {
    local pid="$1"
    local exe_path="" exe_base="" command_line="" cmd_base=""
    # /proc/PID/exe is preferred (never truncated) but is ptrace-gated.
    if [[ -L "/proc/${pid}/exe" ]]; then
        exe_path="$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)"
        exe_base="$(basename "${exe_path}" 2>/dev/null || true)"
    fi
    # cargo build → documentdb_gateway (underscore); packaged →
    # /usr/bin/documentdb-gateway (hyphen); wrapper/daemon split →
    # documentdb-gateway-daemon. Accept all three.
    case "${exe_base}" in
        documentdb_gateway|documentdb-gateway|documentdb-gateway-daemon) return 0 ;;
    esac
    # Fall back to the command line — untruncated, and readable via ps/cmdline
    # even where /proc/PID/exe is ptrace-denied (the no-CAP_SYS_PTRACE case).
    command_line="$(ps -o args= -p "${pid}" 2>/dev/null || true)"
    cmd_base="$(basename "${command_line%% *}" 2>/dev/null || true)"
    case "${cmd_base}" in
        documentdb_gateway|documentdb-gateway|documentdb-gateway-daemon) return 0 ;;
    esac
    return 1
}

# nohup_gateway_pid_for_port <port> — print the recorded PID for <port> only
# when the record is still trustworthy; otherwise return 1 printing NOTHING to
# stdout (callers key off stdout), logging the reason to stderr.
#
# Identity is confirmed WITHOUT relying on fd visibility:
#   * BOOT_ID recorded and differs from now → the record is from a prior boot;
#     any live PID with that number is a different process → reject.
#   * STARTTIME recorded and differs from the live PID's current starttime →
#     the PID was recycled (a dead gateway's number now on another process,
#     possibly ANOTHER major's gateway that would exe-match) → reject. Within
#     one boot this is DETERMINISTIC: a recycled PID's starttime is strictly
#     later than the original's, so an exact match cannot false-accept.
# pid_listens_on_port is then an ADDITIONAL check: a definite rc 1 rejects;
# rc 0/2 do not override an already-confirmed identity. A legacy one-field
# record keeps today's alive+exe+port behaviour (no new fail-closed brick).
nohup_gateway_pid_for_port() {
    local port="$1"
    # rec_start/rec_boot are initialised to empty: the record read below
    # re-opens the file after nohup_gateway_record_pid already read it, and if a
    # concurrent reset/setup unlinks it in that window the redirection fails and
    # `read` never runs. Empty ⇒ the boot/starttime guards are simply skipped
    # (the pid is still alive+gateway+holds-the-port, i.e. the legacy path);
    # leaving them UNSET would make the `[[ -n ]]` tests below a set -u abort of
    # the whole wizard — silently, at the preflight if-condition call site.
    local pidfile pid rec_start="" rec_boot="" cur_start cur_boot
    pidfile="$(nohup_gateway_pidfile "${port}")"

    pid="$(nohup_gateway_record_pid "${pidfile}")" || return 1
    kill -0 "${pid}" 2>/dev/null || return 1
    gateway_exe_matches "${pid}" || return 1

    # Fields 2 (starttime) and 3 (boot_id) of the record, if present. 2>/dev/null
    # precedes the input redirect so a file unlinked in the TOCTOU window (see
    # nohup_gateway_record_pid) fails the open silently rather than leaking a
    # bash error to the operator; rec_start/rec_boot then stay empty (legacy).
    read -r _ rec_start rec_boot 2>/dev/null < "${pidfile}" || true

    if [[ -n "${rec_boot}" ]]; then
        cur_boot="$(current_boot_id)"
        if [[ -n "${cur_boot}" && "${rec_boot}" != "${cur_boot}" ]]; then
            log_warn "Gateway record ${pidfile} is from a previous boot; PID ${pid} is a different process now — ignoring the stale record."
            return 1
        fi
    fi
    if [[ -n "${rec_start}" ]]; then
        cur_start="$(proc_starttime "${pid}")"
        if [[ -n "${cur_start}" && "${rec_start}" != "${cur_start}" ]]; then
            log_warn "Gateway record ${pidfile} PID ${pid} has a different start time than recorded (recycled or restarted incarnation) — ignoring the stale record."
            return 1
        fi
    fi

    # Additional, when fd targets ARE visible: a definite non-owner rejects.
    if pid_listens_on_port "${pid}" "${port}"; then
        :
    else
        if (( $? == 1 )); then
            log_warn "Recorded gateway PID ${pid} for port ${port} is alive and is a gateway binary but does not hold the port; treating the record as stale (recycled PID) and ignoring it."
            return 1
        fi
    fi

    printf '%s' "${pid}"
}

# postmaster_pid_owns_port <port> [data_dir] — true when <port> is served by
# the PostgreSQL cluster in <data_dir> (default DATA_DIR), from that cluster's
# own postmaster.pid (line 1 = PID, line 4 = port). Ownership by data
# directory, not by "some postgres exists".
postmaster_pid_owns_port() {
    local port="$1"
    local datadir="${2:-${DATA_DIR:-}}"
    local pidfile pid recorded_port

    [[ -n "${datadir}" ]] || return 1
    pidfile="${datadir}/postmaster.pid"
    [[ -r "${pidfile}" ]] || return 1

    pid="$(sed -n '1p' "${pidfile}" 2>/dev/null | tr -dc '0-9')"
    recorded_port="$(sed -n '4p' "${pidfile}" 2>/dev/null | tr -dc '0-9')"
    [[ -n "${pid}" && -n "${recorded_port}" ]] || return 1
    [[ "${recorded_port}" == "${port}" ]] || return 1
    (( 10#${pid} > 1 )) || return 1
    kill -0 "${pid}" 2>/dev/null || return 1

    # Staleness cross-check: a crashed postmaster leaves postmaster.pid; within
    # one boot its PID can recycle. Only a DEFINITE "does not hold the port"
    # (rc 1) rejects; unknown (rc 2) keeps degraded-host parity. (postmaster.pid
    # carries no starttime field, so the fd check is the available guard here.)
    if pid_listens_on_port "${pid}" "${port}"; then
        :
    else
        (( $? == 1 )) && return 1
    fi
    return 0
}

# True when process 1 really IS a postmaster, not init/systemd. find_listener_pid
# returns "1" both for the unknown-owner placeholder and for a genuine pid-1
# listener (normal in a container). Reads /proc/1/comm (readable wherever the
# /proc/net path that mints "1" is), falling back to ps; failing OPEN (ps
# absent → "not postgres") is the wrong direction for a guard over someone
# else's database, so /proc is preferred. comm caps at 15 chars; postgres(8)/
# postmaster(10) fit.
pid1_is_postgres() {
    local comm=""
    if [[ -r /proc/1/comm ]]; then
        comm="$(tr -d '[:space:]' < /proc/1/comm 2>/dev/null || true)"
    fi
    if [[ -z "${comm}" ]]; then
        comm="$(ps -o comm= -p 1 2>/dev/null | tr -d '[:space:]' || true)"
    fi
    [[ "${comm}" == "postgres" || "${comm}" == "postmaster" ]]
}

# resolve_uid_check_target <listener-pid> <port>
#
# Given the pid find_listener_pid reported for <port> (which may be empty, a
# real pid, or the "1" placeholder that means "a listener exists but its owner
# could not be resolved"), decide WHICH pid the caller should stat to compare
# the port owner's UID against the documentdb runtime user. Prints that pid, or
# nothing when there is no safe target (caller then skips the UID check).
#
# Extracted verbatim from two identical call sites — the live-cluster adoption
# path and the greenfield PG-port preflight — so the security-critical "whose
# process is this?" decision cannot drift between them: a future change to how a
# pid-1-placeholder listener is attributed now updates both at once. The die
# messages stay at the call sites because their remedy wording is
# context-specific (adopt-vs-refuse vs pick-another-port).
#
#   real pid (not "1")  -> that pid (empty in -> empty out: no listener, no check)
#   "1" placeholder:
#     postmaster.pid on this port names pid 1 -> "" (it is our own postmaster,
#         reached via the data-dir adoption path; a UID check on pid 1 is wrong)
#     pid 1 definitely holds the port (rc 0)  -> "1"
#     indeterminate (rc 2) AND pid 1 is postgres -> "1"
#     otherwise                               -> "" (genuinely blind; caller
#         keeps its legacy behaviour rather than stat the init process)
resolve_uid_check_target() {
    local pid="$1" port="$2" plp=0
    if [[ "${pid}" != "1" ]]; then
        printf '%s' "${pid}"
        return 0
    fi
    if postmaster_pid_owns_port "${port}"; then
        return 0
    fi
    pid_listens_on_port 1 "${port}" && plp=0 || plp=$?
    if (( plp == 0 )); then
        printf '1'
    elif (( plp == 2 )) && pid1_is_postgres; then
        printf '1'
    fi
    return 0
}
