#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CORE="$ROOT/lib/hardcore-archive-core.sh"
PATCHER="$ROOT/lib/hardcore-archive-copy-lane.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-copy-lane-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

[[ -f $CORE ]] || { printf 'Missing core: %s\n' "$CORE" >&2; exit 1; }
[[ -f $PATCHER ]] || { printf 'Missing Copy-lane patcher: %s\n' "$PATCHER" >&2; exit 1; }

python3 "$PATCHER" "$CORE" "$TMP/patched-core.sh"
bash -n "$TMP/patched-core.sh"

# Applying the transformation twice must be a no-op; this protects nested or
# future runtime preparation from duplicating lists/stages.
python3 "$PATCHER" "$TMP/patched-core.sh" "$TMP/patched-core-twice.sh"
cmp -s "$TMP/patched-core.sh" "$TMP/patched-core-twice.sh" || {
    printf 'Copy-lane patch is not idempotent.\n' >&2
    exit 1
}

assert_contains() {
    local text=$1
    grep -Fq -- "$text" "$TMP/patched-core.sh" || {
        printf 'Patched engine is missing expected text: %s\n' "$text" >&2
        exit 1
    }
}

assert_contains '# HARDCORE_COPY_LANE_PATCH_V1'
assert_contains 'COPY_LIST=$(mktemp)'
assert_contains 'elif is_already_compressed_path "$relative_path"; then'
assert_contains '"-x@${COPY_LIST}"'
assert_contains 'add_copy_lane_to_archive() {'
assert_contains '"@${COPY_LIST}"'
assert_contains '-t7z -mx=0 -m0=Copy -ms=off -mmt=1'
assert_contains 'LZMA2 lane:'
assert_contains 'Copy lane:'
assert_contains 'is_already_compressed_path "$relative_path" && continue'

python3 - "$TMP/patched-core.sh" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')

# Transform lanes must win before the generic Copy lane in source classification.
video = text.index('if is_video_path "$relative_path"; then')
nested = text.index('elif $NESTED_REPACK && is_nested_archive_path "$relative_path"; then', video)
image = text.index('elif is_image_path "$relative_path"; then', nested)
copy = text.index('elif is_already_compressed_path "$relative_path"; then', image)
ordinary = text.index('NONVIDEO_COUNT=$((NONVIDEO_COUNT + 1))', copy)
assert video < nested < image < copy < ordinary

# Representative types that should never consume the solid LZMA2 lane.
for suffix in ('.zip', '.7z', '.rar', '.xz', '.zst', '.docx', '.xlsx', '.epub',
               '.apk', '.jar', '.whl', '.deb', '.rpm', '.mp3', '.flac', '.opus',
               '.webp', '.avif', '.heic'):
    assert f'*{suffix}' in text, suffix

# Plain TAR and PDF are intentionally not assumed to be incompressible.
classifier = text[text.index('is_already_compressed_path() {'):text.index('archive_replacement_path() {')]
assert '*.tar|' not in classifier and '*.tar)' not in classifier
assert '*.pdf' not in classifier

# One final archive: Copy entries are added to the same TEMP_ARCHIVE created by
# the LZMA2 stage, not to a side archive.
copy_fn = text[text.index('add_copy_lane_to_archive() {'):text.index('video_archived_relative() {')]
assert '"$TEMP_ARCHIVE"' in copy_fn
PY

printf 'Copy/LZMA lane policy tests passed.\n'
