#!/usr/bin/env bash
# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# Prints which floating image tags (latest, X.Y, stable) a release moves,
# space-separated; nothing means none. Each tag moves only when VERSION is the
# newest release in its scope, judged by the repo's vX.Y-Z tags (RCs ignored),
# so re-running an older release can't pull a tag back.
#
#   floating-image-tags.sh --repo URL --ref REF [--stable-series X.Y] VERSION
#
#   VERSION          the release being published, X.Y.Z; a release candidate moves nothing
#   --ref            the git ref the run started from; anything but VERSION's vX.Y-Z tag moves nothing
#   --stable-series  the series `stable` follows; blank = stable never moves
set -euo pipefail

die() { echo "floating-image-tags: $*" >&2; exit 1; }

repo="" ref="" ref_given=false stable_series="" version=""
while [ $# -gt 0 ]; do
    case "$1" in
        --repo) [ $# -ge 2 ] || die "$1 needs a value"; repo="$2"; shift 2 ;;
        --ref) [ $# -ge 2 ] || die "$1 needs a value"; ref="$2"; ref_given=true; shift 2 ;;
        --stable-series) [ $# -ge 2 ] || die "$1 needs a value"; stable_series="$2"; shift 2 ;;
        -*) die "unknown option $1" ;;
        *) [ -z "$version" ] || die "unexpected argument $1"; version="$1"; shift ;;
    esac
done

case "$version" in
    *[~-][rR][cC]*) echo "floating-image-tags: $version is a release candidate; no floating tag moves" >&2; exit 0 ;;
esac
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || die "VERSION must be X.Y.Z, got '$version'"
[ -z "$stable_series" ] || [[ "$stable_series" =~ ^[0-9]+\.[0-9]+$ ]] \
    || die "--stable-series must be X.Y, got '$stable_series'"
series="${version%.*}"

"$ref_given" || die "--ref is required"
# Only the release's own tag binds VERSION to that tag; any other ref takes it from an input or the control file.
release_tag="v$series-${version##*.}"
if [ "$ref" != "refs/tags/$release_tag" ]; then
    echo "floating-image-tags: '$ref' is not the release tag $release_tag; no floating tag moves" >&2
    echo ""
    exit 0
fi
[ -n "$repo" ] || die "--repo is required"
# The images are already published by now, so retry a network blip; a failed
# lookup must still fail the caller, never read as "no releases yet".
for attempt in 1 2 3; do
    refs=$(git ls-remote --tags --refs "$repo" 'v*') && break
    [ "$attempt" -lt 3 ] || die "could not list release tags of $repo"
    sleep "${FLOATING_TAGS_RETRY_DELAY:-10}"
done
releases=$(printf '%s\n' "$refs" | sed -n 's|^[0-9a-f]*[[:space:]]refs/tags/v\([0-9][0-9]*\.[0-9][0-9]*\)-\([0-9][0-9]*\)$|\1.\2|p')

newest=$(printf '%s\n' "$releases" "$version" | sort -V | tail -n1)
newest_in_series=$(printf '%s\n' "$releases" "$version" | awk -v p="$series." 'index($0, p) == 1' | sort -V | tail -n1)

tags=""
if [ "$newest" = "$version" ]; then tags="latest"; fi
if [ "$newest_in_series" = "$version" ]; then
    tags="$tags $series"
    if [ "$series" = "$stable_series" ]; then tags="$tags stable"; fi
fi
tags="${tags# }"
echo "floating-image-tags: $version; newest release $newest, newest $series.x $newest_in_series; moving: ${tags:-none}" >&2
echo "$tags"
