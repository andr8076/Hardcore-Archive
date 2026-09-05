#!/usr/bin/env bash

[[ ${HARDCORE_INSPECT_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_INSPECT_SH_LOADED=1

hardcore_inspect_die() {
    printf 'Error: %s\n' "$*" >&2
    return 1
}

hardcore_inspect_resolve_7zip() {
    local candidate
    if [[ -n ${SEVEN_ZIP_BIN:-} && -x ${SEVEN_ZIP_BIN:-} ]]; then
        printf '%s\n' "$SEVEN_ZIP_BIN"
        return 0
    fi
    if [[ -n ${SEVEN_ZIP:-} && -x ${SEVEN_ZIP:-} ]]; then
        printf '%s\n' "$SEVEN_ZIP"
        return 0
    fi
    for candidate in 7zz 7z 7za; do
        if command -v "$candidate" >/dev/null 2>&1; then
            command -v "$candidate"
            return 0
        fi
    done
    return 1
}

hardcore_inspect_size() {
    stat -c '%s' -- "$1" 2>/dev/null || stat -f '%z' -- "$1" 2>/dev/null
}

hardcore_inspect_human_bytes() {
    local bytes=$1
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$bytes" 2>/dev/null && return 0
    fi
    awk -v n="$bytes" 'BEGIN {
        split("B KiB MiB GiB TiB PiB",u," "); i=1;
        while (n>=1024 && i<6) { n/=1024; i++ }
        if (i==1) printf "%.0f %s",n,u[i]; else printf "%.1f %s",n,u[i]
    }'
}

hardcore_inspect_main() {
    local archive_input archive seven_zip size files dirs method manifest tmpdir listing brief path
    (( $# == 2 )) && [[ $1 == --inspect ]] || {
        printf 'Usage: hardcore-archive --inspect ARCHIVE.7z\n' >&2
        return 2
    }
    archive_input=$2
    [[ -f $archive_input ]] || { hardcore_inspect_die "Archive does not exist: $archive_input"; return 1; }
    command -v realpath >/dev/null 2>&1 || { hardcore_inspect_die 'Inspection requires realpath.'; return 1; }
    command -v awk >/dev/null 2>&1 || { hardcore_inspect_die 'Inspection requires awk.'; return 1; }
    command -v grep >/dev/null 2>&1 || { hardcore_inspect_die 'Inspection requires grep.'; return 1; }
    command -v stat >/dev/null 2>&1 || { hardcore_inspect_die 'Inspection requires stat.'; return 1; }
    command -v mktemp >/dev/null 2>&1 || { hardcore_inspect_die 'Inspection requires mktemp.'; return 1; }
    seven_zip=$(hardcore_inspect_resolve_7zip) || { hardcore_inspect_die 'Inspection requires 7-Zip (7zz, 7z, or 7za).'; return 1; }
    archive=$(realpath -e -- "$archive_input" 2>/dev/null) || { hardcore_inspect_die "Could not resolve archive path: $archive_input"; return 1; }

    tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-inspect.XXXXXX") || { hardcore_inspect_die 'Could not create inspection workspace.'; return 1; }
    listing="$tmpdir/listing.slt"
    brief="$tmpdir/listing.ba"

    printf 'Inspecting archive:\n  %s\n\n' "$archive"
    if ! "$seven_zip" t "$archive" -bsp1; then
        rm -rf -- "$tmpdir"
        hardcore_inspect_die 'Archive integrity testing failed.'
        return 1
    fi

    # Read each listing completely before parsing it. Do not use an early-exit
    # awk/grep pipeline here: with `set -o pipefail`, the parser can close the
    # pipe after its first match, 7-Zip receives SIGPIPE, and a valid large
    # archive is incorrectly reported as a failed inspection.
    if ! "$seven_zip" l -slt "$archive" >"$listing" 2>/dev/null; then
        rm -rf -- "$tmpdir"
        hardcore_inspect_die 'Could not read the technical archive listing.'
        return 1
    fi
    if ! "$seven_zip" l -ba "$archive" >"$brief" 2>/dev/null; then
        rm -rf -- "$tmpdir"
        hardcore_inspect_die 'Could not read the archive member listing.'
        return 1
    fi

    size=$(hardcore_inspect_size "$archive") || {
        rm -rf -- "$tmpdir"
        hardcore_inspect_die 'Could not determine archive size.'
        return 1
    }
    files=$(awk '/^Folder = -/{n++} END{print n+0}' "$listing")
    dirs=$(awk '/^Folder = \+/{n++} END{print n+0}' "$listing")
    method=$(awk -F' = ' '/^Method = / && !seen {value=$2; seen=1} END{print value}' "$listing")

    printf 'Integrity:             passed\n'
    printf 'Archive size:          %s\n' "$(hardcore_inspect_human_bytes "$size")"
    printf 'File entries:          %s\n' "$files"
    printf 'Directory entries:     %s\n' "$dirs"
    printf 'First method reported: %s\n' "${method:-unknown}"

    if grep -Fq '.hardcore-archive-metadata/archive-info.txt' "$brief"; then
        manifest=$("$seven_zip" x -so -y -spd "$archive" -- '.hardcore-archive-metadata/archive-info.txt' 2>/dev/null || true)
        if [[ -n $manifest ]]; then
            printf '\n===== Archive information =====\n%s\n' "$manifest"
        fi
    fi

    for path in \
        '.hardcore-archive-video-manifest.txt' \
        '.hardcore-archive-image-manifest.txt' \
        '.hardcore-archive-container-manifest.txt' \
        '.hardcore-archive-nested-manifest.txt' \
        '.hardcore-archive-metadata/sparse.tsv'
    do
        if grep -Fq "$path" "$brief"; then
            printf '%-28s present\n' "$path:"
        fi
    done
    if grep -Fq '.hardcore-archive-sha256.txt' "$brief"; then
        printf '\nEmbedded SHA-256 manifest: present\n'
    else
        printf '\nEmbedded SHA-256 manifest: absent\n'
    fi

    rm -rf -- "$tmpdir"
    return 0
}
