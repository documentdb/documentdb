#!/bin/bash
# Copyright (c) Microsoft Corporation.
# SPDX-License-Identifier: MIT

# "PID START_TIME" (postmaster.pid lines 1 and 3), which tells two postmasters apart.
# initdb's standalone backends write a negative PID; they are not postmasters.
postmaster_identity() {
    local pid start
    pid="$(sed -n 1p "$1" 2>/dev/null | tr -d '[:space:]')"
    start="$(sed -n 3p "$1" 2>/dev/null | tr -dc 0-9)"
    case "$pid" in '' | *[!0-9]*) return 1 ;; esac
    [ -n "$start" ] && printf '%s %s\n' "$pid" "$start"
}

postmaster_owner_file() {
    printf '%s/.documentdb-local/postmaster-owner' "$1"
}

# "PID START_TIME" of the postmaster in $1/postmaster.pid, but only when this
# process holds the directory lock and that postmaster inherited the lock fd. A
# pidfile from an image without the lock never qualifies (ADO PR 2267891).
vouched_postmaster() {
    local owner
    [ "$1" -ef /proc/self/fd/200 ] && flock -n 200 || return 1
    owner="$(postmaster_identity "$1/postmaster.pid")" || return 1
    [ "$1" -ef "/proc/${owner%% *}/fd/200" ] || return 1
    printf '%s\n' "$owner"
}

# Record the vouched postmaster so a later claim that finds the lock free knows
# it is gone. Returns 1 when nothing could be recorded.
record_postmaster_owner() {
    local owner file
    file="$(postmaster_owner_file "$1")"
    if ! owner="$(vouched_postmaster "$1")"; then
        # Recorded while it started and died since: the next start still recovers.
        owner="$(postmaster_identity "$1/postmaster.pid")" && [ "$owner" = "$(cat "$file" 2>/dev/null)" ] && return 0
        echo "Warning: not recording the postmaster in $file: this process does not hold the lock on $1, or $1/postmaster.pid is incomplete, or its postmaster did not inherit the lock. After an unclean stop this volume will need DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID=true to start." >&2
        return 1
    fi
    # fsync the record like the pidfile is, or a host crash right after start loses it.
    if ! { mkdir -p "${file%/*}" && printf '%s\n' "$owner" >"$file.tmp" && sync "$file.tmp" \
            && mv -f "$file.tmp" "$file" && sync "${file%/*}"; } 2>/dev/null; then
        echo "Warning: cannot record the postmaster in $file; after an unclean stop this volume will need DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID=true to start." >&2
        return 1
    fi
}

claim_data_directory() {
    local pidfile="$1/postmaster.pid" pid owner notice
    if [ ! -d "$1" ]; then
        echo "Error: data directory $1 does not exist or is inaccessible." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
        exit 1
    fi
    if [ ! -r "$1" ] || [ ! -x "$1" ]; then
        if [ "$(id -u)" -eq 0 ]; then
            echo "Error: cannot access data directory $1." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
            exit 1
        fi
        exec sudo -E bash "${BASH_SOURCE[0]}" "$1" "${BASH_SOURCE[1]}" "$PATH" "$(id -G)"
    fi
    if ! [ "$1" -ef /proc/self/fd/200 ]; then
        exec 200<"$1" || exit 1
    fi
    flock -n 200 || {
        echo "Error: another DocumentDB container is already using the data directory $1. Refusing to start: two PostgreSQL instances on one data directory would corrupt it, and taking it over would shut the running container's database down too. Give this container its own volume, or stop the container already serving $1." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
        exit 1
    }
    [ -f "$pidfile" ] || return 0
    pid="$(sed -n 1p "$pidfile" 2>/dev/null | tr -dc 0-9)"
    owner="$(postmaster_identity "$pidfile")" || owner=""  # a truncated pidfile must still reach the override under errexit
    if [ -n "$owner" ] && [ "$owner" = "$(cat "$(postmaster_owner_file "$1")" 2>/dev/null)" ]; then
        # That postmaster held this lock, and the lock is free, so it is gone.
        notice="Warning: removing $pidfile (PID ${pid}) left by an unclean stop of the previous container; PostgreSQL will run crash recovery."
        if [ "${DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID:-false}" = "true" ]; then
            notice="$notice DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID=true was not needed for this; unset it, it stays in force on every later start."
        fi
    elif [ "${DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID:-false}" = "true" ]; then
        notice="Warning: removing $pidfile because DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID=true bypassed the in-use check; PostgreSQL may need crash recovery. Unset the variable once this container is up, it stays in force on every later start."
    else
        echo "Error: $pidfile exists (PID ${pid:-unknown}) and another container may still be serving this data directory, including one running an older image that takes no lock. Refusing to start. Stop every other container using $1, then create or recreate this container with DOCUMENTDB_FORCE_REMOVE_STALE_POSTMASTER_PID=true (docker start cannot add it) to remove the file and start." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
        exit 1
    fi
    if [ ! -w "$1" ]; then
        chmod u+w "$1" 2>/dev/null || sudo chmod u+w "$1" || {
            echo "Error: cannot make $1 writable to remove stale $pidfile." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
            exit 1
        }
    fi
    echo "$notice" | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2
    rm -f "$pidfile" || { echo "Error: cannot remove stale $pidfile." | tee -a "${ENTRYPOINT_LOG:-/dev/null}" >&2; exit 1; }
}

if [[ "${BASH_SOURCE[0]}" != "$0" ]]; then
    return 0
fi

set -euo pipefail
data_path="${1:?}"
entrypoint="${2:?}"
original_path="${3:?}"
original_groups="${4:?}"
runtime_uid="${SUDO_UID:?}"
runtime_gid="${SUDO_GID:?}"
runtime_user="${SUDO_USER:?}"

claim_data_directory "$data_path"
if [ "$(stat -c '%u' "$data_path")" != "$runtime_uid" ]; then
    chown "$runtime_uid:$runtime_gid" "$data_path"
    export DOCUMENTDB_FORCE_OWNERSHIP_REPAIR=true
fi
chmod u+rwx "$data_path"
exec setpriv --reuid="$runtime_uid" --regid="$runtime_gid" --groups="${original_groups// /,}" \
    env PATH="$original_path" USER="$runtime_user" LOGNAME="$runtime_user" \
    bash "$entrypoint"
