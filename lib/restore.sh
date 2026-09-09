#!/usr/bin/env bash

# Production restore module.
#
# Initialization order / contract:
#   * This file is safe to source before the core has initialized runtime state;
#     it defines functions and resolves only its own checked-in helper path.
#   * dependency_preflight_restore is invoked after CLI parsing has selected
#     restore mode. It uses the core dependency collector, platform sleep
#     helpers, PLATFORM_ID, ALLOW_SLEEP, SLEEP_PROTECTION_ACTIVE and SEVEN_ZIP.
#   * restore_existing_archive is invoked only after that preflight succeeds. It
#     requires POSITIONAL, SEVEN_ZIP, METADATA_HELPER, MIB, die and human_bytes.
#   * The final destination commit uses the checked-in atomic helper beside this
#     module: renameat2(RENAME_NOREPLACE) on Linux and
#     renamex_np(RENAME_EXCL) on macOS. There is no non-atomic fallback.
#
# Return / cleanup contract:
#   * Successful restore returns 0 after a verified atomic destination commit.
#   * Fatal validation/extraction/metadata/enumeration/commit failures retain the
#     historical die() path and therefore exit non-zero without replacing a
#     destination.
#   * Restore owns RESTORE_TEMP, RESTORE_ENUMERATION_FILE, and RESTORE_LOCK_*
#     resources. Its EXIT and signal traps remove uncommitted temporary data,
#     release the restore lock, and preserve the historical 129/130/143 signal
#     statuses.
#   * The source archive is read-only throughout this module.
#
# hardcore_archive_internal_root_name and remove_hardcore_archive_internal_entries
# intentionally live here as the shared internal-entry policy used by create,
# nested normalization, and restore cleanup. Keeping one definition prevents the
# producer and restorer from disagreeing about reserved archive paths.
[[ ${HARDCORE_RESTORE_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_RESTORE_SH_LOADED=1
HARDCORE_RESTORE_MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
HARDCORE_RESTORE_ATOMIC_COMMIT_HELPER=${HARDCORE_ARCHIVE_RESTORE_ATOMIC_COMMIT_HELPER:-"$HARDCORE_RESTORE_MODULE_DIR/hardcore-archive-atomic-commit.py"}

hardcore_restore_command_selected() {
    local arg
    for arg in "$@"; do
        [[ $arg == --restore ]] && return 0
    done
    return 1
}

dependency_archive_has_path() {
    local archive=$1 path=$2
    "$SEVEN_ZIP" l -ba "$archive" "$path" 2>/dev/null | grep -Fq "$path"
}

dependency_archive_manifest_has_data() {
    local archive=$1 path=$2 pattern=$3
    "$SEVEN_ZIP" x -so -y -spd "$archive" -- "$path" 2>/dev/null | grep -Eq "$pattern"
}

dependency_preflight_restore() {
    local archive_input=${1:-} archive=''
    dependency_reset
    dependency_require_portable_command_contract
    dependency_resolve_7zip
    dependency_require_command awk 'Parses embedded verification and metadata manifests.'
    dependency_require_command grep 'Locates and validates embedded manifests.'
    dependency_require_command find 'Enumerates the verified top-level restore layout without trusting archive names.'
    dependency_require_command stat 'Reads archive and restored-file properties.'
    dependency_require_command realpath 'Canonicalizes archive paths and restore parent paths safely.'
    dependency_require_command mktemp 'Creates isolated temporary restore staging directories.'
    dependency_require_command python3 'Performs safe listing checks, metadata work, sparse restoration, and atomic no-replace commit.'
    dependency_require_command sha256sum 'Verifies restored file contents against the embedded hash manifest.'
    dependency_require_command mv 'Builds the final restore layout only inside private staging.'
    dependency_require_command rm 'Removes only temporary restore data after completion or failure.'
    dependency_require_command rmdir 'Reuses a verified single-directory tree as the prepared commit root.'
    dependency_require_command mkdir 'Creates the restore destination parent and staging directories.'
    dependency_require_command flock 'Protects the restore workflow from conflicting archive operations.'

    if [[ -f $archive_input ]]; then
        archive=$(realpath -e -- "$archive_input" 2>/dev/null || true)
    fi
    # Sparse restoration is implemented in Python by rebuilding only recorded
    # data extents, so it works on APFS and common Linux sparse filesystems
    # without Linux-specific fallocate hole punching.
    dependency_abort_if_critical

    dependency_reset
    if [[ -n $archive && -n ${SEVEN_ZIP:-} ]]; then
        if dependency_archive_has_path "$archive" '.hardcore-archive-metadata/acl.txt' && \
           dependency_archive_manifest_has_data "$archive" '.hardcore-archive-metadata/acl.txt' \
               '^# hardcore-archive acl darwin-'; then
            if [[ $PLATFORM_ID != macos ]]; then
                dependency_add_critical 'native macOS ACL restoration' \
                    'This archive contains macOS ACL metadata; restore it on macOS. Translating access controls to POSIX ACLs is unsafe.'
            fi
        elif dependency_archive_has_path "$archive" '.hardcore-archive-metadata/acl.txt' && \
           dependency_archive_manifest_has_data "$archive" '.hardcore-archive-metadata/acl.txt' \
               '^(default:|(user|group):[^:]+:|mask::)'; then
            if [[ $PLATFORM_ID == macos ]]; then
                dependency_add_critical 'POSIX ACL restoration' \
                    'The archive contains extended Linux/POSIX ACLs; macOS cannot safely restore these access controls.'
            else
                dependency_require_command setfacl \
                    'The archive contains extended POSIX ACLs; restore fails closed rather than silently dropping access controls.'
            fi
        fi
    fi
    if ! $ALLOW_SLEEP && ! $SLEEP_PROTECTION_ACTIVE && ! platform_sleep_tool_available; then
        dependency_add_optional "$(platform_sleep_tool_label)" \
            'Prevents the operating system from sleeping during archive testing and restoration.'
    fi
    dependency_abort_if_critical
    dependency_confirm_optional
}

apply_sparse_manifest() {
    local root=$1 manifest
    manifest="$root/.hardcore-archive-metadata/sparse.tsv"
    [[ -s $manifest ]] || return 0
    command -v python3 >/dev/null 2>&1 || \
        die "Critical dependency disappeared after preflight: python3"
    python3 - "$root" "$manifest" <<'PYSPARSERESTORE'
import os, shutil, sys, tempfile
root=os.path.realpath(sys.argv[1]); manifest=sys.argv[2]
entries={}
with open(manifest,'r',encoding='utf-8',errors='surrogateescape') as f:
    header=f.readline().rstrip('\n')
    if header != 'path\tlogical_size\tstart\tlength':
        raise ValueError('invalid sparse metadata header')
    for line_number,line in enumerate(f,2):
        line=line.rstrip('\n')
        if not line: continue
        try:
            rel, logical, start, length=line.split('\t',3)
            logical=int(logical); start=int(start); length=int(length)
        except Exception as exc:
            raise ValueError(f'invalid sparse metadata row {line_number}') from exc
        if logical < 0 or start < 0 or length <= 0 or start + length > logical:
            raise ValueError(f'invalid sparse range on row {line_number}')
        entries.setdefault((rel,logical),[]).append((start,start+length))

def copy_range(src,dst,start,end):
    src.seek(start); dst.seek(start); remaining=end-start
    while remaining:
        block=src.read(min(8*1024*1024,remaining))
        if not block: raise IOError('unexpected end of sparse source')
        dst.write(block); remaining-=len(block)

for (rel,logical),holes in entries.items():
    path=os.path.realpath(os.path.join(root,rel))
    if not (path == root or path.startswith(root+os.sep)) or not os.path.isfile(path):
        raise ValueError(f'unsafe or missing sparse metadata path: {rel!r}')
    holes=sorted((max(0,a),min(logical,b)) for a,b in holes if b>a)
    merged=[]
    for a,b in holes:
        if merged and a <= merged[-1][1]: merged[-1]=(merged[-1][0],max(merged[-1][1],b))
        else: merged.append((a,b))
    directory=os.path.dirname(path)
    fd,tmp=tempfile.mkstemp(prefix='.hardcore-sparse-',dir=directory)
    try:
        with open(path,'rb',buffering=0) as src, os.fdopen(fd,'w+b',buffering=0) as dst:
            os.ftruncate(dst.fileno(),logical)
            pos=0
            for a,b in merged:
                if a>pos: copy_range(src,dst,pos,a)
                pos=max(pos,b)
            if pos<logical: copy_range(src,dst,pos,logical)
            dst.flush(); os.fsync(dst.fileno())
        shutil.copystat(path,tmp,follow_symlinks=False)
        os.replace(tmp,path)
    except Exception as exc:
        try: os.unlink(tmp)
        except OSError: pass
        raise RuntimeError(f'could not restore sparse layout for {rel}: {exc}') from exc
PYSPARSERESTORE
}

cleanup_restore() {
    local exit_status=$?
    if [[ -n ${RESTORE_ENUMERATION_FILE:-} ]]; then
        rm -f -- "$RESTORE_ENUMERATION_FILE" 2>/dev/null || true
    fi
    if [[ -n ${RESTORE_TEMP:-} && -d $RESTORE_TEMP && ${RESTORE_COMMITTED:-false} != true ]]; then
        rm -rf --one-file-system -- "$RESTORE_TEMP" 2>/dev/null || true
    fi
    if [[ -n ${RESTORE_LOCK_FD:-} ]]; then
        flock -u "$RESTORE_LOCK_FD" 2>/dev/null || true
        eval "exec ${RESTORE_LOCK_FD}>&-" 2>/dev/null || true
    fi
    [[ -z ${RESTORE_LOCK_FILE:-} ]] || rm -f -- "$RESTORE_LOCK_FILE" 2>/dev/null || true
    return "$exit_status"
}

restore_prepare_commit_tree() {
    local root=$1 listing=$2 ready entry
    local -a entries=()

    [[ -n $listing ]] || return 1
    case $listing in
        "$root"|"$root"/*)
            printf 'Restore enumeration listing must remain outside staging: %s\n' "$listing" >&2
            return 1
            ;;
    esac

    # Capture a complete NUL-delimited snapshot first. Process substitution is
    # deliberately avoided: find's status must authorize all later layout work.
    # A zero-byte file plus status 0 means a legitimately empty restore; any
    # nonzero status rejects even valid partial output before entries are moved.
    if ! find "$root" -mindepth 1 -maxdepth 1 -print0 > "$listing"; then
        printf 'Restore staging directory enumeration failed; refusing partial results.\n' >&2
        return 1
    fi

    while IFS= read -r -d '' entry; do
        entries+=("$entry")
    done < "$listing"

    # The listing is restore-owned and outside root so it can never become part
    # of the payload. Remove it before preparing the final layout; the EXIT trap
    # remains a fallback if enumeration or cleanup fails.
    rm -f -- "$listing" || return 1

    ready=$(mktemp -d "$root/.hardcore-restore-ready.XXXXXX") || return 1
    if (( ${#entries[@]} == 1 )) && [[ -d ${entries[0]} ]]; then
        rmdir "$ready" || return 1
        mv -- "${entries[0]}" "$ready" || return 1
    else
        for entry in "${entries[@]}"; do
            mv -- "$entry" "$ready/" || return 1
        done
    fi
    printf '%s\n' "$ready"
}

restore_atomic_commit_prepared() {
    local prepared=$1 destination=$2
    [[ -f $HARDCORE_RESTORE_ATOMIC_COMMIT_HELPER ]] || {
        printf 'Required atomic restore commit helper is missing: %s\n' \
            "$HARDCORE_RESTORE_ATOMIC_COMMIT_HELPER" >&2
        return 1
    }
    python3 "$HARDCORE_RESTORE_ATOMIC_COMMIT_HELPER" "$prepared" "$destination"
}

hardcore_archive_internal_root_name() {
    case $1 in
        .hardcore-archive-metadata|\
        .hardcore-archive-sha256.txt|\
        .hardcore-archive-video-manifest.txt|\
        .hardcore-archive-image-manifest.txt|\
        .hardcore-archive-container-manifest.txt|\
        .hardcore-archive-nested-manifest.txt) return 0 ;;
        *) return 1 ;;
    esac
}

remove_hardcore_archive_internal_entries() {
    local root=$1 name
    [[ -n $root && -d $root && $root != / ]] || \
        die "Refusing to clean internal entries from an unsafe directory: ${root:-empty}"
    for name in \
        .hardcore-archive-metadata \
        .hardcore-archive-sha256.txt \
        .hardcore-archive-video-manifest.txt \
        .hardcore-archive-image-manifest.txt \
        .hardcore-archive-container-manifest.txt \
        .hardcore-archive-nested-manifest.txt
    do
        rm -rf --one-file-system -- "$root/$name"
    done
}

restore_existing_archive() {
    local archive_input=${POSITIONAL[0]} destination_input=${POSITIONAL[1]:-} archive stem destination destination_request parent temp hashfile ready
    local listed_size free required lockfile
    [[ -f $archive_input ]] || die "Archive does not exist: $archive_input"
    archive=$(realpath -e -- "$archive_input")
    stem=$(basename -- "$archive")
    stem=${stem%.7z}
    if [[ -n $destination_input ]]; then
        destination_request=$destination_input
    else
        destination_request="$(dirname -- "$archive")/$stem"
    fi

    # Resolve existing parent components, but deliberately do not dereference the
    # final destination name. A dangling symlink is still an existing destination
    # entry and must be rejected rather than followed to its missing target.
    parent=$(realpath -m -- "$(dirname -- "$destination_request")")
    destination="$parent/$(basename -- "$destination_request")"
    if [[ -e $destination || -L $destination ]]; then
        die "Restore destination already exists: $destination"
    fi
    mkdir -p -- "$parent"
    [[ -f $HARDCORE_RESTORE_ATOMIC_COMMIT_HELPER ]] || \
        die "Trusted atomic restore commit helper is missing: $HARDCORE_RESTORE_ATOMIC_COMMIT_HELPER"

    RESTORE_TEMP=""
    RESTORE_ENUMERATION_FILE=""
    RESTORE_LOCK_FILE=""
    RESTORE_COMMITTED=false
    trap cleanup_restore EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    lockfile="${destination}.restore.lock"
    # Do not truncate or remove a lock belonging to another restore process.
    exec {RESTORE_LOCK_FD}>>"$lockfile"
    flock -n "$RESTORE_LOCK_FD" || die "Another restore process is already targeting: $destination"
    RESTORE_LOCK_FILE=$lockfile
    printf 'PID=%s\nStarted=%s\nArchive=%s\n' "$$" "$(date --iso-8601=seconds)" "$archive" > "$RESTORE_LOCK_FILE"

    printf 'Testing archive before restore...\n'
    "$SEVEN_ZIP" t "$archive" -bsp1 || die "Archive integrity testing failed; nothing was restored."

    # -ba omits the archive header (whose Path is the absolute archive filename).
    # Validate every member, including the first; use this same listing for the
    # space estimate. A failed/partial listing must never authorize extraction.
    if ! listed_size=$("$SEVEN_ZIP" l -slt -ba "$archive" | python3 -c '
import sys
bad=[]
size=0
for line in sys.stdin:
    if line.startswith("Size = "):
        value=line[7:].rstrip("\r\n")
        if not value.isascii() or not value.isdecimal():
            sys.exit("Invalid archive member size")
        size+=int(value)
    if not line.startswith("Path = "): continue
    path=line[7:].rstrip("\r\n")
    norm=path.replace("\\","/")
    if not path or norm.startswith("/") or (len(norm)>=2 and norm[1]==":") or any(p==".." for p in norm.split("/")):
        bad.append(path)
if bad:
    print("Unsafe archive paths detected:", file=sys.stderr)
    for p in bad[:20]: print("  "+p, file=sys.stderr)
    sys.exit(1)
print(size)
'); then
        die "Restore refused because the archive listing failed or contains unsafe paths or sizes."
    fi

    free=$(df -PB1 -- "$parent" | awk 'NR==2 {print $4}')
    required=$((listed_size + listed_size / 20 + 256 * MIB))
    (( free >= required )) || die "Insufficient restore space: need approximately $(human_bytes "$required"), but only $(human_bytes "$free") is free."

    temp=$(mktemp -d "$parent/.${stem}.restore.XXXXXX")
    RESTORE_TEMP=$temp
    RESTORE_COMMITTED=false
    printf 'Extracting into temporary destination...\n'
    "$SEVEN_ZIP" x -y -spd -o"$temp" "$archive" || die "Archive extraction failed."

    hashfile="$temp/.hardcore-archive-sha256.txt"
    if [[ -s $hashfile ]]; then
        printf 'Verifying extracted file hashes...\n'
        (cd -- "$temp" && sha256sum -c --quiet '.hardcore-archive-sha256.txt') || die "Restored content hash verification failed."
    fi

    apply_sparse_manifest "$temp"

    # Apply metadata with installed, trusted code. ACL paths are sanitized
    # before setfacl sees them; no code or path from the archive is trusted.
    [[ -n $METADATA_HELPER && -f $METADATA_HELPER ]] || \
        die "Trusted metadata restore helper is missing: ${METADATA_HELPER:-unset}"
    python3 "$METADATA_HELPER" \
        --root "$temp" \
        --metadata-dir "$temp/.hardcore-archive-metadata" || \
        die "Safe metadata restoration failed. Nothing was committed."

    # Sparse reconstruction changes allocation only, not content; verify again.
    if [[ -s $hashfile ]]; then
        printf 'Verifying hashes after sparse and metadata restoration...\n'
        (cd -- "$temp" && sha256sum -c --quiet '.hardcore-archive-sha256.txt') || die "Final restored content verification failed."
    fi

    # Remove only the exact private entries created by Hardcore Archive. A
    # blanket prefix filter would silently discard legitimate user content such
    # as a top-level directory named .hardcore-archive-photos.
    remove_hardcore_archive_internal_entries "$temp"

    # Enumerate to a sibling file outside the staging root. That file is tracked
    # by cleanup_restore so a failed find, signal, or later preparation error can
    # never leak it or allow it to become part of the restored payload.
    RESTORE_ENUMERATION_FILE=$(mktemp "$parent/.${stem}.restore.entries.XXXXXX") || \
        die "Could not create the restore staging enumeration file."

    # Build the complete user-visible destination tree only after enumeration
    # has completed successfully. For a single directory, reuse that directory
    # itself so its restored root metadata is preserved. Single-file, empty, and
    # multi-entry archives are wrapped in a staging directory, matching the
    # historical layout.
    ready=$(restore_prepare_commit_tree "$temp" "$RESTORE_ENUMERATION_FILE") || \
        die "Could not completely enumerate and prepare the verified restore layout for atomic commit."
    RESTORE_ENUMERATION_FILE=""

    # This is the only operation that publishes the destination name. It must be
    # one kernel/filesystem operation that fails if *any* entry (file, directory,
    # symlink, including dangling symlinks) occupies the destination at that
    # instant. Never replace this with an existence check followed by ordinary mv.
    restore_atomic_commit_prepared "$ready" "$destination" || \
        die "Verified restore could not be committed without replacing an existing destination."

    sync "$destination" 2>/dev/null || true
    RESTORE_COMMITTED=true
    rm -rf --one-file-system -- "$temp"
    RESTORE_TEMP=""
    flock -u "$RESTORE_LOCK_FD" 2>/dev/null || true
    eval "exec ${RESTORE_LOCK_FD}>&-" 2>/dev/null || true
    RESTORE_LOCK_FD=""
    rm -f -- "$RESTORE_LOCK_FILE"
    RESTORE_LOCK_FILE=""
    printf '\nRestore completed successfully:\n  %s\n' "$destination"
}
