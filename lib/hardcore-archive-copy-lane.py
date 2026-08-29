#!/usr/bin/env python3
"""Apply the deterministic Copy/LZMA lane refactor to the legacy archive engine.

The giant engine is intentionally retained as a stable legacy source file. The
frontend creates a private runtime copy and this module applies a small set of
strict, one-time source transformations. Every anchor must match exactly once;
otherwise the run is refused rather than silently using the old compression
policy.
"""
from __future__ import annotations

import os
import pathlib
import sys

MARKER = "# HARDCORE_COPY_LANE_PATCH_V1"


def fail(message: str) -> "NoReturn":
    print(f"Error: copy-lane engine patch failed: {message}", file=sys.stderr)
    raise SystemExit(1)


def replace_once(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(f"{label}: expected exactly one engine anchor, found {count}")
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} INPUT_CORE OUTPUT_CORE", file=sys.stderr)
        return 2

    source = pathlib.Path(sys.argv[1])
    destination = pathlib.Path(sys.argv[2])
    text = source.read_text(encoding="utf-8")

    if MARKER in text:
        destination.write_text(text, encoding="utf-8")
        os.chmod(destination, 0o700)
        return 0

    compressed_classifier = r'''

# HARDCORE_COPY_LANE_PATCH_V1
# Files that are already entropy-compressed are preserved byte-for-byte but are
# stored with 7-Zip's Copy method instead of wasting LZMA2 time. Transform
# lanes are classified first, so video/image/nested processing still takes
# precedence whenever it is enabled.
is_already_compressed_path() {
    local lower=${1,,}
    case "$lower" in
        *.7z|*.zip|*.rar|*.cab|*.gz|*.bz2|*.xz|*.zst|*.lz4|*.tgz|*.tbz|*.tbz2|*.txz|*.tzst|\
        *.docx|*.xlsx|*.pptx|*.odt|*.ods|*.odp|*.epub|*.apk|*.jar|*.war|*.whl|*.npz|*.deb|*.rpm|\
        *.mp3|*.aac|*.m4a|*.ogg|*.opus|*.flac|*.wma|*.alac|*.ape|\
        *.webp|*.gif|*.avif|*.heic|*.heif)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}
'''
    text = replace_once(
        text,
        "\narchive_replacement_path() {",
        compressed_classifier + "\narchive_replacement_path() {",
        "compressed-file classifier",
    )

    text = replace_once(
        text,
        "VIDEO_LIST=$(mktemp)\nIMAGE_LIST=$(mktemp)\nNESTED_LIST=$(mktemp)\n",
        "VIDEO_LIST=$(mktemp)\nIMAGE_LIST=$(mktemp)\nNESTED_LIST=$(mktemp)\nCOPY_LIST=$(mktemp)\n",
        "Copy list allocation",
    )
    text = replace_once(
        text,
        'rm -f -- "$VIDEO_LIST" "$IMAGE_LIST" "$NESTED_LIST" "$SNAPSHOT_BEFORE"',
        'rm -f -- "$VIDEO_LIST" "$IMAGE_LIST" "$NESTED_LIST" "$COPY_LIST" "$SNAPSHOT_BEFORE"',
        "Copy list cleanup",
    )

    text = replace_once(
        text,
        "NESTED_BYTES=0\nNONVIDEO_COUNT=0\nNONVIDEO_BYTES=0\n",
        "NESTED_BYTES=0\nCOPY_COUNT=0\nCOPY_BYTES=0\nNONVIDEO_COUNT=0\nNONVIDEO_BYTES=0\n",
        "Copy counters",
    )

    text = replace_once(
        text,
        '''        printf '%s\\n' "$relative_path" >> "$IMAGE_LIST"\n    else\n        NONVIDEO_COUNT=$((NONVIDEO_COUNT + 1))\n        NONVIDEO_BYTES=$((NONVIDEO_BYTES + file_size))\n    fi\n''',
        '''        printf '%s\\n' "$relative_path" >> "$IMAGE_LIST"\n    elif is_already_compressed_path "$relative_path"; then\n        COPY_COUNT=$((COPY_COUNT + 1))\n        COPY_BYTES=$((COPY_BYTES + file_size))\n        printf '%s\\n' "$relative_path" >> "$COPY_LIST"\n    else\n        NONVIDEO_COUNT=$((NONVIDEO_COUNT + 1))\n        NONVIDEO_BYTES=$((NONVIDEO_BYTES + file_size))\n    fi\n''',
        "inventory lane split",
    )

    text = replace_once(
        text,
        '''        is_video_path "$relative_path" && continue\n        is_image_path "$relative_path" && continue\n        remaining=$((target_bytes - $(stat -c '%s' -- "$MC_SAMPLE_FILE")))\n''',
        '''        is_video_path "$relative_path" && continue\n        is_image_path "$relative_path" && continue\n        $NESTED_REPACK && is_nested_archive_path "$relative_path" && continue\n        is_already_compressed_path "$relative_path" && continue\n        remaining=$((target_bytes - $(stat -c '%s' -- "$MC_SAMPLE_FILE")))\n''',
        "match-cycle sample filtering",
    )

    text = replace_once(
        text,
        '''                "-x@${VIDEO_LIST}" \\
                "-x@${IMAGE_LIST}" \\
                "-x@${NESTED_LIST}"\n''',
        '''                "-x@${VIDEO_LIST}" \\
                "-x@${IMAGE_LIST}" \\
                "-x@${NESTED_LIST}" \\
                "-x@${COPY_LIST}"\n''',
        "LZMA Copy-list exclusion",
    )

    copy_function = r'''

add_copy_lane_to_archive() {
    (( COPY_COUNT > 0 )) || return 0
    FAILURE_CONTEXT="copy-lane-storage"
    printf '\nStage 6/8: Storing already-compressed files with Copy mode...\n'
    printf 'Copy lane: %s files / %s\n\n' "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"
    (
        cd -- "$SOURCE_PARENT"
        run_logged_stage "already-compressed Copy storage" "$SEVEN_ZIP_LOG" \
            "$SEVEN_ZIP" a "$TEMP_ARCHIVE" \
                -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                -snl -snh -spd -scsUTF-8 -bsp1 -y \
                "@${COPY_LIST}"
    )
}
'''
    text = replace_once(
        text,
        "\nvideo_archived_relative() {",
        copy_function + "\nvideo_archived_relative() {",
        "Copy-lane archive stage",
    )

    text = replace_once(
        text,
        "fi\n\nif (( IMAGE_COUNT > 0 )); then\n    classify_image_results",
        "fi\n\nadd_copy_lane_to_archive\n\nif (( IMAGE_COUNT > 0 )); then\n    classify_image_results",
        "Copy-lane stage invocation",
    )

    text = replace_once(
        text,
        '''printf 'Files compressed:        %s files / %s\\n' \\
    "$NONVIDEO_COUNT" "$(human_bytes "$NONVIDEO_BYTES")"\n''',
        '''printf 'LZMA2 lane:              %s files / %s\\n' \\
    "$NONVIDEO_COUNT" "$(human_bytes "$NONVIDEO_BYTES")"\nprintf 'Copy lane:               %s files / %s\\n' \\
    "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"\n''',
        "archive-plan lane reporting",
    )

    text = replace_once(
        text,
        '''ESTIMATED_ARCHIVE_BYTES=$(LC_NUMERIC=C awk -v nonvideo="$NONVIDEO_BYTES" -v ratio="$MC_SAMPLE_RATIO" -v video="$VIDEO_BYTES" -v image="$IMAGE_BYTES" 'BEGIN {printf "%.0f", nonvideo*ratio+video+image}')''',
        '''ESTIMATED_ARCHIVE_BYTES=$(LC_NUMERIC=C awk -v nonvideo="$NONVIDEO_BYTES" -v ratio="$MC_SAMPLE_RATIO" -v copy="$COPY_BYTES" -v video="$VIDEO_BYTES" -v image="$IMAGE_BYTES" -v nested="$NESTED_BYTES" 'BEGIN {printf "%.0f", nonvideo*ratio+copy+video+image+nested}')''',
        "archive-size estimate",
    )
    text = text.replace("before video savings", "before transform savings", 1)

    text = replace_once(
        text,
        '''Sparse hole bytes: $SPARSE_HOLE_BYTES\nNested archives repacked: $NESTED_REPACKED_COUNT\n''',
        '''Sparse hole bytes: $SPARSE_HOLE_BYTES\nLZMA2 files: $NONVIDEO_COUNT\nLZMA2 source bytes: $NONVIDEO_BYTES\nCopy-lane files: $COPY_COUNT\nCopy-lane bytes: $COPY_BYTES\nNested archives repacked: $NESTED_REPACKED_COUNT\n''',
        "embedded archive-info lane reporting",
    )

    text = replace_once(
        text,
        '''        printf 'Completeness: passed\\n'\n        printf 'Videos transcoded: %s\\n' "$VIDEO_COMPRESSED_COUNT"\n''',
        '''        printf 'Completeness: passed\\n'\n        printf 'LZMA2 files: %s\\n' "$NONVIDEO_COUNT"\n        printf 'LZMA2 source bytes: %s\\n' "$NONVIDEO_BYTES"\n        printf 'Copy-lane files: %s\\n' "$COPY_COUNT"\n        printf 'Copy-lane bytes: %s\\n' "$COPY_BYTES"\n        printf 'Videos transcoded: %s\\n' "$VIDEO_COMPRESSED_COUNT"\n''',
        "success-report lane reporting",
    )

    text = replace_once(
        text,
        '''printf 'Final dictionary used: %s MiB\\n' "$DICTIONARY_MIB"\nif (( VIDEO_COUNT > 0 )); then\n''',
        '''printf 'Final dictionary used: %s MiB\\n' "$DICTIONARY_MIB"\nprintf 'LZMA2 lane: %s files / %s\\n' "$NONVIDEO_COUNT" "$(human_bytes "$NONVIDEO_BYTES")"\nprintf 'Copy lane:  %s files / %s\\n' "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"\nif (( VIDEO_COUNT > 0 )); then\n''',
        "completion lane reporting",
    )

    text = replace_once(text, 'FAILURE_CONTEXT="nonvideo-compression"', 'FAILURE_CONTEXT="lzma-compression"', "failure context")
    text = replace_once(text, 'Stage 4/8: Compressing non-video files with a %s MiB dictionary...', 'Stage 4/8: Compressing the LZMA2 lane with a %s MiB dictionary...', "stage label")
    text = replace_once(text, 'run_logged_stage "non-video compression"', 'run_logged_stage "LZMA2 compression"', "logged-stage label")

    destination.write_text(text, encoding="utf-8")
    os.chmod(destination, 0o700)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
