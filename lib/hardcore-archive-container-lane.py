#!/usr/bin/env python3
"""Patch the runtime engine with format-preserving application-container repack."""
from __future__ import annotations
import os
import pathlib
import sys

MARKER = "# HARDCORE_CONTAINER_REPACK_PATCH_V1"


def fail(label: str, count: int) -> None:
    print(f"Error: container-repack engine patch failed: {label}: expected one anchor, found {count}", file=sys.stderr)
    raise SystemExit(1)


def repl(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(label, count)
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} INPUT_CORE OUTPUT_CORE", file=sys.stderr)
        return 2
    src, dst = map(pathlib.Path, sys.argv[1:])
    text = src.read_text(encoding="utf-8")
    if MARKER in text:
        dst.write_text(text, encoding="utf-8")
        os.chmod(dst, 0o700)
        return 0

    text = repl(text,
"""# HARDCORE_COPY_LANE_PATCH_V1
# Files that are already entropy-compressed are preserved byte-for-byte but are
# stored with 7-Zip's Copy method instead of wasting LZMA2 time. Transform
# lanes are classified first, so video/image/nested processing still takes
# precedence whenever it is enabled.
is_already_compressed_path() {""",
"""# HARDCORE_COPY_LANE_PATCH_V1
# HARDCORE_CONTAINER_REPACK_PATCH_V1
CONTAINER_REPACK=${HARDCORE_ARCHIVE_CONTAINER_REPACK:-true}
CONTAINER_HELPER=${HARDCORE_ARCHIVE_CONTAINER_HELPER:-}
is_format_preserving_container_path() {
    local lower=${1,,}
    case "$lower" in
        *.docx|*.xlsx|*.pptx|*.odt|*.ods|*.odp|*.epub|*.npz|*.whl|*.jar|*.war) return 0 ;;
        *) return 1 ;;
    esac
}
# Files that are already entropy-compressed are preserved byte-for-byte but are
# stored with 7-Zip's Copy method instead of wasting LZMA2 time. Transform
# lanes are classified first, so video/image/nested/container processing still
# takes precedence whenever it is enabled.
is_already_compressed_path() {""",
"container classifier")

    text = repl(text,
"""VIDEO_LIST=$(mktemp)
IMAGE_LIST=$(mktemp)
NESTED_LIST=$(mktemp)
COPY_LIST=$(mktemp)
SNAPSHOT_BEFORE=$(mktemp)""",
"""VIDEO_LIST=$(mktemp)
IMAGE_LIST=$(mktemp)
NESTED_LIST=$(mktemp)
CONTAINER_LIST=$(mktemp)
CONTAINER_RESULT_MANIFEST=$(mktemp)
CONTAINER_REPACKED_LIST=$(mktemp)
CONTAINER_FALLBACK_LIST=$(mktemp)
COPY_LIST=$(mktemp)
SNAPSHOT_BEFORE=$(mktemp)""",
"container temp lists")

    text = repl(text,
        'NESTED_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-nested-manifest.txt"',
        'NESTED_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-nested-manifest.txt"\nCONTAINER_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-container-manifest.txt"',
        "container manifest path")

    text = repl(text,
'''rm -f -- "$VIDEO_LIST" "$IMAGE_LIST" "$NESTED_LIST" "$COPY_LIST" "$SNAPSHOT_BEFORE"''',
'''rm -f -- "$VIDEO_LIST" "$IMAGE_LIST" "$NESTED_LIST" "$CONTAINER_LIST" "$COPY_LIST" "$SNAPSHOT_BEFORE"''',
"container list cleanup")
    text = repl(text,
'''        "$NESTED_RESULT_MANIFEST" "$NESTED_REPACKED_LIST" "$NESTED_FALLBACK_LIST" \\
        "${MC_TUNING_LOG:-}"''',
'''        "$NESTED_RESULT_MANIFEST" "$NESTED_REPACKED_LIST" "$NESTED_FALLBACK_LIST" \\
        "$CONTAINER_RESULT_MANIFEST" "$CONTAINER_REPACKED_LIST" "$CONTAINER_FALLBACK_LIST" \\
        "${MC_TUNING_LOG:-}"''',
"container result cleanup")
    text = repl(text,
'''    if [[ -n ${NESTED_STAGE_PARENT:-} && -d $NESTED_STAGE_PARENT ]]; then
        rm -rf --one-file-system -- "$NESTED_STAGE_PARENT"
    fi''',
'''    if [[ -n ${CONTAINER_STAGE_PARENT:-} && -d $CONTAINER_STAGE_PARENT ]]; then
        rm -rf --one-file-system -- "$CONTAINER_STAGE_PARENT"
    fi
    if [[ -n ${NESTED_STAGE_PARENT:-} && -d $NESTED_STAGE_PARENT ]]; then
        rm -rf --one-file-system -- "$NESTED_STAGE_PARENT"
    fi''',
"container stage cleanup")

    text = repl(text,
"""NESTED_BYTES=0
COPY_COUNT=0
COPY_BYTES=0
NONVIDEO_COUNT=0""",
"""NESTED_BYTES=0
CONTAINER_COUNT=0
CONTAINER_BYTES=0
CONTAINER_REPACKED_COUNT=0
CONTAINER_FALLBACK_COUNT=0
CONTAINER_REPACKED_BYTES=0
CONTAINER_FALLBACK_BYTES=0
CONTAINER_SAVED_BYTES=0
CONTAINER_STAGE_PARENT=''
COPY_COUNT=0
COPY_BYTES=0
NONVIDEO_COUNT=0""",
"container counters")

    text = repl(text,
'''        printf '%s\\n' "$relative_path" >> "$IMAGE_LIST"
    elif is_already_compressed_path "$relative_path"; then''',
'''        printf '%s\\n' "$relative_path" >> "$IMAGE_LIST"
    elif $CONTAINER_REPACK && is_format_preserving_container_path "$relative_path"; then
        CONTAINER_COUNT=$((CONTAINER_COUNT + 1))
        CONTAINER_BYTES=$((CONTAINER_BYTES + file_size))
        printf '%s\\n' "$relative_path" >> "$CONTAINER_LIST"
    elif is_already_compressed_path "$relative_path"; then''',
"container inventory split")

    text = repl(text,
'''        $NESTED_REPACK && is_nested_archive_path "$relative_path" && continue
        is_already_compressed_path "$relative_path" && continue''',
'''        $NESTED_REPACK && is_nested_archive_path "$relative_path" && continue
        $CONTAINER_REPACK && is_format_preserving_container_path "$relative_path" && continue
        is_already_compressed_path "$relative_path" && continue''',
"container tuning exclusion")

    text = repl(text,
'''                "-x@${NESTED_LIST}" \\
                "-x@${COPY_LIST}"''',
'''                "-x@${NESTED_LIST}" \\
                "-x@${CONTAINER_LIST}" \\
                "-x@${COPY_LIST}"''',
"container LZMA exclusion")

    text = repl(text,
'''if (( IMAGE_COUNT > 0 )); then
    MINIMUM_STAGING_BYTES=$((MINIMUM_STAGING_BYTES + IMAGE_BYTES + LARGEST_IMAGE_BYTES))
fi
choose_work_root''',
'''if (( IMAGE_COUNT > 0 )); then
    MINIMUM_STAGING_BYTES=$((MINIMUM_STAGING_BYTES + IMAGE_BYTES + LARGEST_IMAGE_BYTES))
fi
if $CONTAINER_REPACK && (( CONTAINER_COUNT > 0 )); then
    MINIMUM_STAGING_BYTES=$((MINIMUM_STAGING_BYTES + CONTAINER_BYTES))
fi
choose_work_root''',
"container staging capacity")

    container_functions = r'''

process_format_preserving_containers() {
    (( CONTAINER_COUNT > 0 )) || return 0
    $CONTAINER_REPACK || return 0
    [[ -n $CONTAINER_HELPER && -f $CONTAINER_HELPER ]] || \
        die "Format-preserving container repack is enabled, but its helper is missing: ${CONTAINER_HELPER:-unset}"

    FAILURE_CONTEXT="container-repack"
    printf '\nStage 6/8: Repacking format-preserving application containers...\n'
    printf 'Container candidates: %s files / %s\n' "$CONTAINER_COUNT" "$(human_bytes "$CONTAINER_BYTES")"
    CONTAINER_STAGE_PARENT=$(mktemp -d -p "$WORK_ROOT" containers.XXXXXX)
    : > "$CONTAINER_RESULT_MANIFEST"
    : > "$CONTAINER_REPACKED_LIST"
    : > "$CONTAINER_FALLBACK_LIST"

    if ! python3 "$CONTAINER_HELPER" \
        --source-parent "$SOURCE_PARENT" \
        --stage-parent "$CONTAINER_STAGE_PARENT" \
        --list "$CONTAINER_LIST" \
        --result "$CONTAINER_RESULT_MANIFEST"; then
        die "The format-preserving container helper reported an internal processing failure. Originals were not silently substituted."
    fi

    local action original archived original_size candidate_size archived_size reason
    local actual candidate_display accounted=0
    while IFS=$'\t' read -r action original archived original_size candidate_size archived_size reason; do
        [[ -n $original ]] || continue
        accounted=$((accounted + 1))
        [[ $original_size =~ ^[0-9]+$ && $candidate_size =~ ^[0-9]+$ && $archived_size =~ ^[0-9]+$ ]] || \
            die "Invalid container-repack result row for: $original"
        case $action in
            repacked)
                [[ $archived == "$original" ]] || die "Container repack changed the restored path: $original -> $archived"
                [[ -f $CONTAINER_STAGE_PARENT/$archived ]] || die "Validated container candidate disappeared: $archived"
                actual=$(stat -c '%s' -- "$CONTAINER_STAGE_PARENT/$archived")
                (( actual == candidate_size && actual == archived_size && actual < original_size )) || \
                    die "Container candidate size/accounting changed after validation: $original"
                printf '%s\n' "$archived" >> "$CONTAINER_REPACKED_LIST"
                CONTAINER_REPACKED_COUNT=$((CONTAINER_REPACKED_COUNT + 1))
                CONTAINER_REPACKED_BYTES=$((CONTAINER_REPACKED_BYTES + actual))
                CONTAINER_SAVED_BYTES=$((CONTAINER_SAVED_BYTES + original_size - actual))
                ;;
            original)
                [[ $archived == "$original" && $archived_size == "$original_size" ]] || \
                    die "Invalid original-container fallback accounting: $original"
                actual=$(stat -c '%s' -- "$SOURCE_PARENT/$original")
                (( actual == original_size )) || die "Source container changed during repack: $original"
                printf '%s\n' "$original" >> "$CONTAINER_FALLBACK_LIST"
                CONTAINER_FALLBACK_COUNT=$((CONTAINER_FALLBACK_COUNT + 1))
                CONTAINER_FALLBACK_BYTES=$((CONTAINER_FALLBACK_BYTES + original_size))
                ;;
            *) die "Unknown container-repack action '$action' for: $original" ;;
        esac
        if (( candidate_size > 0 )); then candidate_display=$(human_bytes "$candidate_size"); else candidate_display='not produced'; fi
        printf 'Container decision: %s | original %s | candidate %s | %s (%s)\n' \
            "$original" "$(human_bytes "$original_size")" "$candidate_display" \
            "$([[ $action == repacked ]] && printf 'REPACKED' || printf 'PRESERVED')" "$reason"
    done < "$CONTAINER_RESULT_MANIFEST"

    (( accounted == CONTAINER_COUNT )) || \
        die "Container repack accounted for $accounted of $CONTAINER_COUNT candidate files."

    if [[ -s $CONTAINER_REPACKED_LIST ]]; then
        ( cd -- "$CONTAINER_STAGE_PARENT" && \
            run_logged_stage "repacked-container storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -snl -snh -spd -scsUTF-8 -bsp1 -y "@${CONTAINER_REPACKED_LIST}" )
    fi
    if [[ -s $CONTAINER_FALLBACK_LIST ]]; then
        ( cd -- "$SOURCE_PARENT" && \
            run_logged_stage "original-container storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -snl -snh -spd -scsUTF-8 -bsp1 -y "@${CONTAINER_FALLBACK_LIST}" )
    fi

    {
        printf 'Hardcore Archive format-preserving container manifest\n'
        printf 'Script version: %s\n' "$SCRIPT_VERSION"
        printf 'Original container bytes: %s\n' "$CONTAINER_BYTES"
        printf 'Saved container bytes: %s\n' "$CONTAINER_SAVED_BYTES"
        printf '\nColumns: action<TAB>original path<TAB>archived path<TAB>original bytes<TAB>candidate bytes<TAB>archived bytes<TAB>reason\n'
        cat -- "$CONTAINER_RESULT_MANIFEST"
    } > "$CONTAINER_MANIFEST_FILE"
    ( cd -- "$ARCHIVE_MANIFEST_STAGE" && \
        run_logged_stage "container manifest storage" "$SEVEN_ZIP_LOG" \
            "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                -spd -scsUTF-8 -bsp1 -y '.hardcore-archive-container-manifest.txt' )
}
'''
    text = repl(text,
"""add_copy_lane_to_archive() {""",
container_functions + "\nadd_copy_lane_to_archive() {",
"container processing function")

    text = repl(text,
"""add_copy_lane_to_archive

if (( IMAGE_COUNT > 0 )); then""",
"""process_format_preserving_containers
add_copy_lane_to_archive

if (( IMAGE_COUNT > 0 )); then""",
"container stage invocation")

    text = repl(text,
'''printf 'LZMA2 lane:              %s files / %s\\n' \\
    "$NONVIDEO_COUNT" "$(human_bytes "$NONVIDEO_BYTES")"
printf 'Copy lane:               %s files / %s\\n' \\
    "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"''',
'''printf 'LZMA2 lane:              %s files / %s\\n' \\
    "$NONVIDEO_COUNT" "$(human_bytes "$NONVIDEO_BYTES")"
printf 'Container repack lane:   %s files / %s\\n' \\
    "$CONTAINER_COUNT" "$(human_bytes "$CONTAINER_BYTES")"
printf 'Copy lane:               %s files / %s\\n' \\
    "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"''',
"container plan reporting")

    text = repl(text,
'''ESTIMATED_ARCHIVE_BYTES=$(LC_NUMERIC=C awk -v nonvideo="$NONVIDEO_BYTES" -v ratio="$MC_SAMPLE_RATIO" -v copy="$COPY_BYTES" -v video="$VIDEO_BYTES" -v image="$IMAGE_BYTES" -v nested="$NESTED_BYTES" 'BEGIN {printf "%.0f", nonvideo*ratio+copy+video+image+nested}')''',
'''ESTIMATED_ARCHIVE_BYTES=$(LC_NUMERIC=C awk -v nonvideo="$NONVIDEO_BYTES" -v ratio="$MC_SAMPLE_RATIO" -v copy="$COPY_BYTES" -v container="$CONTAINER_BYTES" -v video="$VIDEO_BYTES" -v image="$IMAGE_BYTES" -v nested="$NESTED_BYTES" 'BEGIN {printf "%.0f", nonvideo*ratio+copy+container+video+image+nested}')''',
"container size estimate")

    text = repl(text,
'''Copy-lane bytes: $COPY_BYTES
Nested archives repacked: $NESTED_REPACKED_COUNT''',
'''Copy-lane bytes: $COPY_BYTES
Format-preserving containers: $CONTAINER_COUNT
Containers repacked: $CONTAINER_REPACKED_COUNT
Container bytes saved: $CONTAINER_SAVED_BYTES
Nested archives repacked: $NESTED_REPACKED_COUNT''',
"container archive info")

    text = repl(text,
'''        printf 'Copy-lane bytes: %s\\n' "$COPY_BYTES"
        printf 'Videos transcoded: %s\\n' "$VIDEO_COMPRESSED_COUNT"''',
'''        printf 'Copy-lane bytes: %s\\n' "$COPY_BYTES"
        printf 'Containers repacked: %s\\n' "$CONTAINER_REPACKED_COUNT"
        printf 'Containers preserved: %s\\n' "$CONTAINER_FALLBACK_COUNT"
        printf 'Container bytes saved: %s\\n' "$CONTAINER_SAVED_BYTES"
        printf 'Videos transcoded: %s\\n' "$VIDEO_COMPRESSED_COUNT"''',
"container success summary")

    text = repl(text,
'''printf 'Copy lane:  %s files / %s\\n' "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"
if (( VIDEO_COUNT > 0 )); then''',
'''printf 'Container lane: %s files / %s; repacked %s; saved %s\\n' \\
    "$CONTAINER_COUNT" "$(human_bytes "$CONTAINER_BYTES")" "$CONTAINER_REPACKED_COUNT" "$(human_bytes "$CONTAINER_SAVED_BYTES")"
printf 'Copy lane:  %s files / %s\\n' "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"
if (( VIDEO_COUNT > 0 )); then''',
"container completion summary")

    text = repl(text,
'''        $NESTED_REPACK && is_nested_archive_path "$relative" && continue
        printf '%s\\n' "$relative" >> "$EXPECTED_PATHS"''',
'''        $NESTED_REPACK && is_nested_archive_path "$relative" && continue
        $CONTAINER_REPACK && is_format_preserving_container_path "$relative" && continue
        printf '%s\\n' "$relative" >> "$EXPECTED_PATHS"''',
"container expected-path exclusion")

    container_hash_reader = r'''

    while IFS=$'\t' read -r action original archived original_size candidate_size archived_size reason; do
        [[ -n $archived ]] || continue
        printf '%s\n' "$archived" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            if [[ $action == repacked ]]; then data_path="$CONTAINER_STAGE_PARENT/$archived"; else data_path="$SOURCE_PARENT/$original"; fi
            hash=$(sha256sum -- "$data_path" | awk '{print $1}')
            printf '%s  %s\n' "$hash" "$archived" >> "$HASH_MANIFEST"
        fi
    done < "$CONTAINER_RESULT_MANIFEST"
'''
    text = repl(text,
'''    while IFS=$'\\t' read -r action original archived original_size candidate_size archived_size reason; do
        [[ -n $archived ]] || continue
        printf '%s\\n' "$archived" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            if [[ $action == repacked ]]; then data_path="$NESTED_STAGE_PARENT/$archived"; else data_path="$SOURCE_PARENT/$original"; fi''',
container_hash_reader + '''
    while IFS=$'\\t' read -r action original archived original_size candidate_size archived_size reason; do
        [[ -n $archived ]] || continue
        printf '%s\\n' "$archived" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            if [[ $action == repacked ]]; then data_path="$NESTED_STAGE_PARENT/$archived"; else data_path="$SOURCE_PARENT/$original"; fi''',
"container hash reader")

    text = repl(text,
'''    (( IMAGE_COUNT > 0 )) && \\
        printf '%s\\n' '.hardcore-archive-image-manifest.txt' >> "$EXPECTED_PATHS"
    (( NESTED_COUNT > 0 )) &&''',
'''    (( IMAGE_COUNT > 0 )) && \\
        printf '%s\\n' '.hardcore-archive-image-manifest.txt' >> "$EXPECTED_PATHS"
    (( CONTAINER_COUNT > 0 )) && \\
        printf '%s\\n' '.hardcore-archive-container-manifest.txt' >> "$EXPECTED_PATHS"
    (( NESTED_COUNT > 0 )) &&''',
"container expected manifest")

    report = r'''        if [[ -s $CONTAINER_RESULT_MANIFEST ]]; then
            printf '\n===== Container repack decisions =====\n'
            printf 'action\toriginal path\tarchived path\toriginal bytes\tcandidate bytes\tarchived bytes\treason\n'
            cat -- "$CONTAINER_RESULT_MANIFEST"
        fi
'''
    nested_report_anchor = "        if [[ -s $NESTED_RESULT_MANIFEST ]]; then\n            printf '\\n===== Nested archive decisions =====\\n'"
    text = repl(text,
        nested_report_anchor,
        report + nested_report_anchor,
        "container success decisions")

    text = repl(text,
'''for path in '.hardcore-archive-video-manifest.txt' '.hardcore-archive-image-manifest.txt' '.hardcore-archive-nested-manifest.txt' '.hardcore-archive-metadata/sparse.tsv'; do''',
'''for path in '.hardcore-archive-video-manifest.txt' '.hardcore-archive-image-manifest.txt' '.hardcore-archive-container-manifest.txt' '.hardcore-archive-nested-manifest.txt' '.hardcore-archive-metadata/sparse.tsv'; do''',
"inspect container manifest")

    dst.write_text(text, encoding="utf-8")
    os.chmod(dst, 0o700)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
