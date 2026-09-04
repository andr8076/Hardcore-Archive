#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CORE="$ROOT/lib/hardcore-archive-core.sh"
PATCHER="$ROOT/lib/hardcore-archive-copy-lane.py"
HELPER="$ROOT/lib/hardcore-archive-compressibility.py"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-copy-lane-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

[[ -f $CORE ]] || { printf 'Missing core: %s\n' "$CORE" >&2; exit 1; }
[[ -f $PATCHER ]] || { printf 'Missing Copy-lane patcher: %s\n' "$PATCHER" >&2; exit 1; }
[[ -f $HELPER ]] || { printf 'Missing compressibility helper: %s\n' "$HELPER" >&2; exit 1; }

python3 "$PATCHER" "$CORE" "$TMP/patched-core.sh"
bash -n "$TMP/patched-core.sh"

# Applying the development transformation twice must be a no-op. Production
# uses the already-generated static core; this protects regeneration from
# duplicating lists, counters, or archive stages.
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
assert_contains '# HARDCORE_COPY_LANE_PATCH_V2'
assert_contains 'COMPRESSIBILITY_CANDIDATES=$(mktemp)'
assert_contains 'COMPRESSIBILITY_RESULT_MANIFEST=$(mktemp)'
assert_contains 'HARDCORE_ARCHIVE_COMPRESSIBILITY_HELPER'
assert_contains 'CONTENT_COPY_PATHS["$relative_path"]=1'
assert_contains 'is_already_compressed_path "$relative_path" && continue'
assert_contains '"-x@${COPY_LIST}"'
assert_contains 'add_copy_lane_to_archive() {'
assert_contains '"@${COPY_LIST}"'
assert_contains '-t7z -mx=0 -m0=Copy -ms=off -mmt=1'
assert_contains 'LZMA2 lane:'
assert_contains 'Copy lane:'
assert_contains 'filenames do not decide the generic lane'

python3 - "$TMP/patched-core.sh" "$HELPER" <<'PY'
import pathlib, sys
text = pathlib.Path(sys.argv[1]).read_text(encoding='utf-8')
helper = pathlib.Path(sys.argv[2]).read_text(encoding='utf-8')

# Transform lanes must win before ordinary files are handed to the sampled
# content classifier.
video = text.index('if is_video_path "$relative_path"; then')
nested = text.index('elif $NESTED_REPACK && is_nested_archive_path "$relative_path"; then', video)
image = text.index('elif is_image_path "$relative_path"; then', nested)
container = text.index('elif $CONTAINER_REPACK && is_format_preserving_container_path "$relative_path"; then', image)
generic = text.index('GENERIC_CANDIDATE_COUNT=$((GENERIC_CANDIDATE_COUNT + 1))', container)
assert video < nested < image < container < generic

# Generic Copy routing must no longer contain an extension table. Membership is
# determined only by the result of the content sampler.
classifier_start = text.index('# HARDCORE_COPY_LANE_PATCH_V2')
classifier_end = text.index('archive_replacement_path() {', classifier_start)
classifier = text[classifier_start:classifier_end]
assert 'CONTENT_COPY_PATHS' in classifier
for suffix in ('*.zip', '*.7z', '*.mp3', '*.flac', '*.webp', '*.docx'):
    assert suffix not in classifier, suffix

# The helper performs bounded LZMA2 sampling and deliberately keeps small or
# uncertain files on LZMA2.
assert 'MIN_ANALYZE_BYTES = 256 * 1024' in helper
assert 'WINDOW_BYTES = 128 * 1024' in helper
assert 'lzma.FILTER_LZMA2' in helper
assert 'sample-incompressible' in helper
assert 'small-file' in helper

# One final archive: Copy entries are added to the same TEMP_ARCHIVE created by
# the LZMA2 stage, not to a side archive.
copy_fn = text[text.index('add_copy_lane_to_archive() {'):text.index('video_archived_relative() {')]
assert '"$TEMP_ARCHIVE"' in copy_fn
PY

printf 'Content-aware Copy/LZMA lane policy tests passed.\n'
