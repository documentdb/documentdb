#!/bin/bash
#
# documentdb_prepare_data_directory.sh
#
# Decide how the PostgreSQL data directory should be brought up, and prepare it
# (issue #480).
#
# The image ships a fully-initialized cluster at $DOCUMENTDB_PGDATA_TEMPLATE
# (initdb + CREATE EXTENSION already done at image build time), marked with a
# `.documentdb-local/baked_template` file, so first boot can skip that
# fsync-heavy work entirely. Docker populates a fresh /data volume from the
# image, so anonymous and named volumes get the template for free; an empty
# custom --data-path is instantiated by copying it here.
#
# The marker is consumed on the boot that adopts the template, so later boots
# treat the directory as ordinary user data and runtime flags can never wipe it.
#
# PRISTINENESS must be PROVEN, not inferred: an OLDER image's entrypoint does
# not know about the marker and therefore does not consume it, so a volume
# seeded by this image but then booted (and filled with data) by an older one
# still carries it -- and incidental signals like the server log are not
# reliable (restored backups commonly exclude logs, and logs can be deleted).
# The proof is the marker's CONTENT: at image build time the marker records the
# cluster's control-data fingerprint -- database system identifier, database
# cluster state, and latest checkpoint location from pg_controldata. No single
# field covers every "the cluster ran" case (a clean startup does not advance
# the checkpoint, and a checkpoint can restore the state string), but together
# they do: the baked state is "shut down", so a cluster killed mid-run reads
# "in production" (state mismatch) and a cleanly stopped cluster wrote a
# shutdown checkpoint (checkpoint mismatch). The live fingerprint must equal
# the recorded marker BYTE FOR BYTE; a match proves the cluster never ran and
# holds no user data. Only that proof may trigger a destructive
# re-initialization; anything unprovable (a server log present, a fingerprint
# missing or truncated, pg_controldata unavailable or mismatched) fails CLOSED
# and the directory is treated as user data.
#
# Accepted residuals: the marker lives inside the user-writable data
# directory, so an actor who can already write the data files could forge a
# matching marker -- that grants nothing they do not already have (they could
# delete the files directly). Concurrent first boots race the marker
# benignly: every losing side degrades to treat-as-user-data, and
# PostgreSQL's own postmaster.pid lock prevents two servers sharing a
# directory.
#
# Usage: documentdb_prepare_data_directory.sh <data_path>
#
# Environment:
#   DISABLE_EXTENDED_RUM       "true" when the operator asked for extended RUM
#                              to be off. The baked template is built WITH it,
#                              so this conflicts with adopting the template.
#   DOCUMENTDB_PGDATA_TEMPLATE Path of the image-baked template (default /data).
#
# Exit codes (the caller acts on these; anything else is a hard failure):
#   0   Nothing more to do -- the directory was adopted, populated from the
#       template, or is ordinary user data. Start the server normally.
#   10  A PROVEN-pristine baked template conflicts with the requested options
#       or with this image's PostgreSQL major version; the caller must force a
#       clean re-initialization (start_oss_server.sh -c).

set -u

data_path="${1:?usage: documentdb_prepare_data_directory.sh <data_path>}"
# Normalize away trailing slashes so path-equality checks (e.g. against the
# template path) compare like with like; keep a bare "/" intact.
while [ "${#data_path}" -gt 1 ] && [ "${data_path%/}" != "$data_path" ]; do
    data_path="${data_path%/}"
done
template_path="${DOCUMENTDB_PGDATA_TEMPLATE:-/data}"
template_marker_rel=".documentdb-local/baked_template"
needs_reinit=false

# consume_marker <data_dir>: drop the template marker so later boots treat the
# directory as ordinary user data. A failure is only a warning -- the
# fingerprint pristineness proof keeps a lingering marker from ever wiping
# used data.
consume_marker() {
    if ! rm -f "$1/$template_marker_rel" 2>/dev/null; then
        echo "Warning: could not remove the template marker $1/$template_marker_rel."
    fi
    # Drop the now-empty container directory too; PGDATA should not carry a
    # stray empty dir for the cluster's whole life. rmdir refuses non-empty.
    rmdir "$1/${template_marker_rel%/*}" 2>/dev/null || true
}

# find_pg_controldata: locate the pg_controldata binary. Empty result (status
# 1) means pristineness cannot be verified, which the callers treat as "not
# pristine" (fail closed).
find_pg_controldata() {
    local candidate
    if command -v pg_controldata >/dev/null 2>&1; then
        command -v pg_controldata
        return 0
    fi
    if command -v pg_ctl >/dev/null 2>&1; then
        candidate="$(dirname "$(command -v pg_ctl)")/pg_controldata"
        if [ -x "$candidate" ]; then
            echo "$candidate"
            return 0
        fi
    fi
    candidate=$(ls -1 /usr/lib/postgresql/*/bin/pg_controldata 2>/dev/null | sort -V | tail -n 1)
    if [ -n "$candidate" ]; then
        echo "$candidate"
        return 0
    fi
    return 1
}

# The exact fields the bake step records, in pg_controldata's own output
# order. Keep in sync with Dockerfile_documentdb_local's marker-generation
# pipeline.
template_fingerprint_regex='^(Database system identifier|Database cluster state|Latest checkpoint location): '

# live_fingerprint <dir>: print the fingerprint the bake step would record for
# <dir>'s cluster right now (same pipeline, same C locale, same whitespace
# normalization). The final sed canonicalizes the checkpoint LSN's zero
# padding: PostgreSQL master switched the LSN render from %X/%X to %X/%08X,
# so without it a marker written by one major and read by the next would fail
# the byte-equality proof for rendering reasons alone -- turning the healable
# wrong-major case into a permanent "cannot be verified" wedge. Nonzero /
# empty output means "cannot compute".
live_fingerprint() {
    local dir="$1"
    local controldata_bin
    controldata_bin=$(find_pg_controldata) || return 1
    LC_ALL=C "$controldata_bin" "$dir" 2>/dev/null | \
        sed -E 's/[[:space:]]+/ /g; s/ $//' | \
        grep -E "$template_fingerprint_regex" | \
        sed -E 's|^(Latest checkpoint location: [0-9A-F]+/)0*([0-9A-F])|\1\2|'
}

# template_is_pristine <dir>: prove <dir> is the untouched baked template by
# requiring the recomputed live fingerprint to equal the marker byte for byte
# (modulo trailing newlines). Whole-value equality -- rather than parsing the
# marker line by line -- means a truncated, duplicated, reordered, or
# partially-unreadable marker can never pass with fewer fields actually
# compared. Every unprovable case returns nonzero and the caller treats the
# directory as user data.
template_is_pristine() {
    local dir="$1"
    local marker="$dir/$template_marker_rel"
    local live recorded
    # A server log means the cluster ran; cheap first-pass rejection.
    if [ -f "$dir/pglog.log" ]; then
        return 1
    fi
    live=$(live_fingerprint "$dir") || return 1
    # All three fields must be present; a future PostgreSQL renaming one must
    # fail closed, not silently weaken the proof.
    [ "$(printf '%s\n' "$live" | wc -l)" -eq 3 ] || return 1
    recorded=$(cat "$marker" 2>/dev/null) || return 1
    [ -n "$recorded" ] || return 1
    [ "$recorded" = "$live" ]
}

# binary_pg_major: the PostgreSQL major version of this image's tooling, from
# `pg_controldata --version` (e.g. "pg_controldata (PostgreSQL) 17.4" -> 17).
# Nonzero / empty means "cannot determine".
binary_pg_major() {
    local controldata_bin out
    controldata_bin=$(find_pg_controldata) || return 1
    out=$(LC_ALL=C "$controldata_bin" --version 2>/dev/null | \
        sed -nE 's/.*\(PostgreSQL\) ([0-9]+).*/\1/p' | head -n 1)
    [ -n "$out" ] || return 1
    printf '%s\n' "$out"
}

if [ -f "$data_path/$template_marker_rel" ]; then
    # data_pg_major stays empty unless PG_VERSION is readable AND numeric, so
    # a garbage file can never be echoed back as "a PostgreSQL <garbage>
    # cluster". The brace group keeps a permission error on the redirect from
    # leaking to the console.
    data_pg_major=""
    if [ -f "$data_path/PG_VERSION" ]; then
        data_pg_major=$({ tr -d '[:space:]' < "$data_path/PG_VERSION"; } 2>/dev/null)
        case "$data_pg_major" in
            ''|*[!0-9]*) data_pg_major="" ;;
        esac
    fi
    image_pg_major=$(binary_pg_major) || image_pg_major=""
    if [ -f "$data_path/pglog.log" ]; then
        # Marker AND a server log: this volume was booted without the marker
        # being consumed, so it holds real user data and nothing is being
        # adopted. Say so plainly -- claiming a template adoption here would
        # misreport exactly the upgrade/downgrade case the marker lifecycle
        # exists to survive.
        echo "Existing data directory carries a stale pre-initialized template marker (e.g. an older image booted this volume, or the marker could not be removed on an earlier boot); treating it as user data."
    elif ! template_is_pristine "$data_path"; then
        # No server log, but the fingerprint proof failed: a restored backup
        # that excluded logs, a deleted log, a hand-created marker, or an
        # unreadable control file. None of these prove the directory is
        # untouched, so fail closed -- it is user data.
        echo "Existing data directory carries a pre-initialized template marker that cannot be verified against the cluster's control data (e.g. a restored backup without server logs); treating it as user data."
    elif [ -z "$data_pg_major" ]; then
        # The proof passed but PG_VERSION is missing, unreadable, or not a
        # version number: a partially copied template. There is nothing to
        # adopt -- and claiming "fast start" here would mislead right before
        # the server bootstrap rejects the directory.
        echo "Pre-initialized template is incomplete (missing or invalid PG_VERSION); treating it as user data."
    elif [ -n "$image_pg_major" ] && \
         [ "$data_pg_major" != "$image_pg_major" ]; then
        # A PROVEN-pristine template of a different PostgreSQL major (a volume
        # seeded by one image tag but first booted by another). Adopting it
        # would wedge the volume on "database files are incompatible with
        # server" forever; the proof says no user data exists, so the safe fix
        # is a clean re-initialization for this image's version. If either
        # major is indeterminate we fall through and adopt, which is
        # non-destructive.
        echo "Re-initializing data directory: the pre-initialized template holds a PostgreSQL ${data_pg_major} cluster but this image runs PostgreSQL ${image_pg_major}."
        needs_reinit=true
    elif [ "${DISABLE_EXTENDED_RUM:-false}" = "true" ]; then
        # The fingerprint proof above established the cluster never ran, so
        # there is no user data and re-initializing with the requested options
        # is safe (this is the pre-template fresh-boot path).
        echo "Re-initializing data directory: --disable-extended-rum requested but the pre-initialized template was built with extended RUM enabled."
        needs_reinit=true
    else
        echo "Adopting pre-initialized data directory template (fast start)."
    fi
    consume_marker "$data_path"
elif [ "$data_path" != "$template_path" ] && \
     [ -f "$template_path/$template_marker_rel" ] && \
     [ ! -f "$data_path/PG_VERSION" ] && \
     [ -z "$(ls -A "$data_path" 2>/dev/null)" ] && \
     [ "${DISABLE_EXTENDED_RUM:-false}" != "true" ] && \
     template_is_pristine "$template_path"; then
    # A custom, still-empty data path: instantiate it from the pristine baked
    # template instead of running full initialization.
    echo "Populating empty data directory $data_path from the pre-initialized template."
    if cp -a "$template_path/." "$data_path/"; then
        # cp -a propagates the template directory's own mode onto data_path,
        # which can silently undo the 0750 the entrypoint just guaranteed
        # (PostgreSQL refuses a data directory more permissive than 0750).
        chmod 750 "$data_path" 2>/dev/null || true
        consume_marker "$data_path"
    else
        # A partial copy would wedge this directory on every later boot
        # (non-empty, possibly with PG_VERSION present), so roll back to empty
        # and let the caller run full initialization. The directory was
        # verified empty right before the copy, so only copied content is
        # removed.
        echo "Warning: populating $data_path from the template failed; falling back to full initialization."
        rm -rf "${data_path:?}"/* "${data_path:?}"/.[!.]* 2>/dev/null
    fi
elif [ "$data_path" = "$template_path" ] && \
     [ ! -f "$data_path/PG_VERSION" ] && \
     [ -z "$(ls -A "$data_path" 2>/dev/null)" ]; then
    # Docker populates named/anonymous volumes from the image, but a
    # bind-mounted host directory shadows the baked template and arrives
    # empty. Tell the user why this boot is slower than the advertised fast
    # start instead of silently falling through to full initialization.
    echo "Data directory $data_path is empty and was not populated from the image template (host bind mounts are not populated by Docker); running full initialization, so this first boot will be slower."
fi

if [ "${DISABLE_EXTENDED_RUM:-false}" = "true" ] && [ "$needs_reinit" = "false" ] \
        && [ -f "$data_path/PG_VERSION" ]; then
    # Deliberately not "the flag is ignored": whatever was selected when this
    # directory was initialized is still in effect -- including a previous boot
    # that this very flag re-initialized. Only *changing* it is impossible, so
    # a restart of a container that did re-initialize must not be told its
    # setting was dropped.
    echo "Note: the extended RUM setting is fixed when a data directory is initialized and cannot be changed for an existing one; whichever setting that directory was initialized with stays in effect. Start with a fresh data volume to change it."
fi

if [ "$needs_reinit" = "true" ]; then
    exit 10
fi
exit 0
