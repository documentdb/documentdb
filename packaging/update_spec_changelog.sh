#!/usr/bin/env bash
set -euo pipefail

usage() {
    cat <<EOF
Usage: $0 <documentdb_version>

documentdb_version may be in either '0.106-0' or '0.106.0' form.
The script extracts sections from CHANGELOG.md starting at the
specified version header and including that version and all earlier
(older) versions, then replaces the %changelog block in
packaging/rpm/spec/documentdb.spec with the extracted markdown.
EOF
}

if [[ ${#@} -ne 1 ]]; then
    usage
    exit 2
fi

INPUT_VER="$1"

# normalize to dashed form if dotted provided (0.106.0 -> 0.106-0)
if [[ "$INPUT_VER" =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
    VER_DASH="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}-${BASH_REMATCH[3]}"
else
    VER_DASH="$INPUT_VER"
fi

CHANGELOG=CHANGELOG.md
SPEC=packaging/rpm/spec/documentdb.spec

if [ ! -f "$CHANGELOG" ]; then
    echo "ERROR: $CHANGELOG not found" >&2
    exit 1
fi

if [ ! -f "$SPEC" ]; then
    echo "ERROR: $SPEC not found" >&2
    exit 1
fi

echo "Updating $SPEC with changelog from $CHANGELOG starting at version: $VER_DASH (inclusive) and including earlier versions"

# For RPM, Version must not contain hyphens. Split VER_DASH into version and release
# e.g. 0.105-0 -> ver=0.105 rel=0
RPM_VER="${VER_DASH%%-*}"
RPM_REL="${VER_DASH#*-}"
if [[ "$RPM_VER" == "$VER_DASH" ]]; then
    # no dash found; keep release as 1
    RPM_REL="1"
fi

# Update Version and Release fields in the spec so rpmbuild sees valid values
spec_tmp_ver=$(mktemp)
awk -v ver="$RPM_VER" -v rel="$RPM_REL" 'BEGIN{v=ver;r=rel} /^Version:/{printf "Version:        %s\n", v; next} /^Release:/{printf "Release:        %s%%{?dist}\n", r; next} {print}' "$SPEC" > "$spec_tmp_ver"
mv "$spec_tmp_ver" "$SPEC"


# Find header lines that look like: ### documentdb v0.106-0 ...
# We'll search for the header that contains the target version and then
# extract from that header through EOF (so target + older entries).

# First, check for and fix typos in CHANGELOG.md (e.g., v1.107-0 should be v0.107-0)
echo "Checking for version typos in $CHANGELOG..."
if grep -q "^### .*v1\.[0-9]\+-[0-9]\+" "$CHANGELOG"; then
    echo "Found typo(s) with v1.XXX-X versions. Fixing to v0.XXX-X..."
    # Create a backup
    cp "$CHANGELOG" "$CHANGELOG.backup"
    # Fix the typo: replace v1.XXX-X with v0.XXX-X in headers
    sed -i -E 's/(^### .*v)1\.([0-9]+-[0-9]+)/\10.\2/g' "$CHANGELOG"
    echo "Fixed typos in $CHANGELOG (backup saved as $CHANGELOG.backup)"
fi

target_header_line=""
# Find the first header line that documents this exact version. Use a fixed-string
# match so the version's '.' and '-' are not treated as regex metacharacters.
target_header_line=$(grep -n '^### ' "$CHANGELOG" | grep -m1 -F "v${VER_DASH}" | cut -d: -f1 || true)

# Returns success when version $1 is strictly newer than version $2. Versions use
# the 'X.Y-Z' form; the dash is normalized to a dot so `sort -V` orders them.
version_is_newer() {
    local a="${1//-/.}" b="${2//-/.}"
    [[ "$a" != "$b" ]] && [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)" == "$a" ]]
}

synthesize_version=""
if [[ -z "$target_header_line" ]]; then
    # The build version is not documented in CHANGELOG.md. Synthesize a top entry
    # for it ONLY when we can confirm it is a genuine new release -- i.e. strictly
    # newer than the newest documented version (e.g. during a release sync before
    # its entry is added). If the newest documented version cannot be determined,
    # or the build version is not strictly newer (older, equal, a typo, or a
    # header written in an unexpected format), fail loudly rather than ship a
    # mislabeled, out-of-order, or history-less package.
    top_header=$(grep -n -m1 '^### ' "$CHANGELOG" || true)
    # Extract the first 'v<version>' token from the header (the line still carries
    # grep -n's 'LINENUM:' prefix). Anchoring to the first token avoids picking up
    # a later ' v...' token such as '(Preview v2)'.
    top_version=$(printf '%s' "$top_header" | sed -n 's/^[0-9]*:###[[:space:]][^0-9]*v\([0-9][^ (]*\).*/\1/p')
    if [[ -z "$top_version" ]] || ! version_is_newer "$VER_DASH" "$top_version"; then
        echo "ERROR: Version v$VER_DASH is not documented in $CHANGELOG and could not be confirmed newer than the latest documented version${top_version:+ v$top_version}" >&2
        exit 1
    fi
    echo "WARNING: v$VER_DASH not found in $CHANGELOG but is newer than the latest documented version v$top_version -- synthesizing a placeholder entry" >&2
    synthesize_version="$VER_DASH"
    # Existing sections (newest first) go below the synthetic entry, starting at
    # the first section header (reusing the scan above) so any preamble is skipped.
    target_header_line=${top_header%%:*}
fi

start_line=$target_header_line

end_line=$(wc -l < "$CHANGELOG")

echo "Extracting lines $start_line..$end_line from $CHANGELOG"
temp_changelog=$(mktemp)
trap 'rm -f "$temp_changelog"' EXIT
{
    if [[ -n "$synthesize_version" ]]; then
        printf '### documentdb v%s (Unreleased) ###\n' "$synthesize_version"
    fi
    sed -n "${start_line},${end_line}p" "$CHANGELOG"
} > "$temp_changelog"

# Determine packager (try git config, else default)
GIT_NAME=$(git config user.name 2>/dev/null || true)
GIT_EMAIL=$(git config user.email 2>/dev/null || true)
if [[ -n "$GIT_NAME" && -n "$GIT_EMAIL" ]]; then
    PACKAGER="$GIT_NAME <$GIT_EMAIL>"
else
    PACKAGER="documentdb packager <packaging@documentdb.local>"
fi

# Convert extracted markdown into RPM %changelog format.
# We expect sections that start with '###' containing 'v<version>' and
# optionally a date in parentheses like '(July 28, 2025)'. For Unreleased
# entries we'll use today's date.
new_changelog_block="%changelog\n"
debian_changelog=""

DEB_TEMP=$(mktemp)
trap 'rm -f "$temp_changelog" "$DEB_TEMP"' EXIT
current_ver=""
current_date_raw=""
items=()
flush_section() {
    if [[ -z "$current_ver" ]]; then
        return
    fi
    # Determine date to use
    if [[ -n "$current_date_raw" && "$current_date_raw" != "Unreleased" ]]; then
        # sanitize ordinal suffixes (1st, 2nd, 3rd, 4th etc) so date -d can parse
        san_date=$(printf '%s' "$current_date_raw" | sed -E 's/([0-9]{1,2})(st|nd|rd|th)/\1/g')
        # try to parse e.g. 'July 28, 2025' via date
        if parsed_date=$(date -d "$san_date" -u +"%a %b %d %Y" 2>/dev/null); then
            date_str="$parsed_date"
        else
            date_str=$(date -u +"%a %b %d %Y")
        fi
    else
        date_str=$(date -u +"%a %b %d %Y")
    fi

    new_changelog_block+="* ${date_str} ${PACKAGER} - ${current_ver}\n"
    if [[ ${#items[@]} -eq 0 ]]; then
        new_changelog_block+="- No details provided.\n"
    else
        for it in "${items[@]}"; do
            # make sure each item is a single line starting with '- '
            new_changelog_block+="- ${it}\n"
        done
    fi
    new_changelog_block+=$'\n'

    # Also build Debian changelog entry
    # Debian date format: 'Mon, 28 Jul 2025 12:00:00 +0000'
    # Parse and sanitize the header date from CHANGELOG.md; fallback to today if parsing fails
    if [[ -n "$current_date_raw" && "$current_date_raw" != "Unreleased" ]]; then
        san_date=$(printf '%s' "$current_date_raw" | sed -E 's/([0-9]{1,2})(st|nd|rd|th)/\1/g')
        if deb_date=$(date -d "$san_date" -u +"%a, %d %b %Y 12:00:00 +0000" 2>/dev/null); then
            date_rfc="$deb_date"
        else
            date_rfc=$(date -u +"%a, %d %b %Y %T +0000")
        fi
    else
        date_rfc=$(date -u +"%a, %d %b %Y %T +0000")
    fi

    # Debian changelog needs a blank line after the header, then
    # each change line indented by two spaces and starting with '* '.
    # Then a blank line and the trailer line.
    printf '%s\n' "documentdb (${current_ver}) unstable; urgency=medium" >> "$DEB_TEMP"
    printf '%s\n' "" >> "$DEB_TEMP"
    if [[ ${#items[@]} -eq 0 ]]; then
        printf '  * %s\n' "No details provided." >> "$DEB_TEMP"
    else
        for it in "${items[@]}"; do
            printf '  * %s\n' "$it" >> "$DEB_TEMP"
        done
    fi
    printf '%s\n' "" >> "$DEB_TEMP"
    printf ' -- %s  %s\n\n' "$PACKAGER" "$date_rfc" >> "$DEB_TEMP"

    # reset
    items=()
    current_ver=""
    current_date_raw=""
}

# Read the extracted changelog and parse sections
while IFS= read -r line; do
    # header lines start with '###'
    if [[ "$line" =~ ^### ]]; then
        # If we already have a section, flush it
        if [[ -n "$current_ver" ]]; then
            flush_section
        fi
        # Extract version: look for 'v' followed by digits.digits- digits (e.g. v0.105-0 or v1.108-0)
        if [[ "$line" =~ v([0-9]+\.[0-9]+-[0-9]+) ]]; then
            current_ver="${BASH_REMATCH[1]}"
        else
            # fallback: capture anything after 'v' up to a space or '('
            current_ver=$(printf '%s' "$line" | sed -n 's/.*v\([^ (][^ (]*\).*/\1/p' || true)
            if [[ -z "$current_ver" ]]; then
                current_ver="unknown"
            fi
        fi

        # Extract parenthesized date, if present (use sed for portability)
        current_date_raw=$(printf '%s' "$line" | sed -n 's/.*(\([^)]*\)).*/\1/p' || true)
        if [[ -z "$current_date_raw" ]]; then
            current_date_raw=""
        fi
        continue
    fi

    # Collect list items: lines starting with '*' or '-' or plain text.
    if [[ "$line" =~ ^[[:space:]]*([*\-])[[:space:]]*(.*) ]]; then
        items+=("${BASH_REMATCH[2]}")
    else
        # Non-list lines: if not empty, treat as an item
        if [[ -n "$line" ]]; then
            # Trim leading/trailing whitespace
            trimmed="$line"
            trimmed="${trimmed## }"
            trimmed="${trimmed%% }"
            items+=("$trimmed")
        fi
    fi
done < "$temp_changelog"

# Flush last section
flush_section

# Replace %changelog section in spec: from line starting with '%changelog' to EOF
# Write to a temp file and move into place to avoid partial writes
spec_tmp=$(mktemp)
awk -v repl="$new_changelog_block" 'BEGIN{ins=0} /^%changelog/{print repl; ins=1; next} { if(ins==0) print }' "$SPEC" > "$spec_tmp"
mv "$spec_tmp" "$SPEC"

echo "Updated $SPEC"
echo "Done."

# Write generated Debian changelog from temp file if present
DEB_FILE_PACKAGING="packaging/deb/changelog"
DEB_FILE_DEBIAN="debian/changelog"
if [[ -s "$DEB_TEMP" ]]; then
    # Update the packaging copy
    cat "$DEB_TEMP" > "$DEB_FILE_PACKAGING"
    echo "Updated $DEB_FILE_PACKAGING"
    # Also update the in-source debian/changelog if present (used inside container builds)
    if [[ -d "debian" ]]; then
        cat "$DEB_TEMP" > "$DEB_FILE_DEBIAN"
        echo "Updated $DEB_FILE_DEBIAN"
    fi
fi