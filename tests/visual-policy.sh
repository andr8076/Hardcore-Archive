#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-visual-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

VISUAL_MODULE="$ROOT/lib/visual.sh"
VISUAL_PATCH="$ROOT/lib/hardcore-archive-visual.py"
CORE="$ROOT/lib/hardcore-archive-core.sh"
COPY="$ROOT/lib/hardcore-archive-copy-lane.py"
MEDIA="$ROOT/lib/hardcore-archive-media-fixes.py"
HARDWARE="$ROOT/lib/hardcore-archive-hardware-video.py"
CALIBRATION="$ROOT/lib/hardcore-archive-video-calibration.py"
VAAPI="$ROOT/lib/hardcore-archive-vaapi-device.py"
NESTED="$ROOT/lib/hardcore-archive-nested-diagnostics.py"
CONTAINER="$ROOT/lib/hardcore-archive-container-lane.py"

for required in "$VISUAL_MODULE" "$VISUAL_PATCH" "$CORE" "$COPY" "$MEDIA" "$HARDWARE" "$CALIBRATION" "$VAAPI" "$NESTED" "$CONTAINER"; do
    [[ -f $required ]] || { printf 'Missing visual test dependency: %s\n' "$required" >&2; exit 1; }
done

bash -n "$VISUAL_MODULE"
python3 -m py_compile "$VISUAL_PATCH"

# Launcher behavior: --visual is consumed before the legacy policy sees it, and
# normal invocations explicitly export visual=0 rather than inheriting stale state.
source "$VISUAL_MODULE"
CAPTURED_ARGS=()
hardcore_config_main() {
    CAPTURED_ARGS=("$@")
    return 0
}
hardcore_visual_launcher_main --visual source-dir output.7z
[[ ${HARDCORE_ARCHIVE_VISUAL:-0} == 1 ]]
[[ ${#CAPTURED_ARGS[@]} == 2 ]]
[[ ${CAPTURED_ARGS[0]} == source-dir ]]
[[ ${CAPTURED_ARGS[1]} == output.7z ]]
hardcore_visual_launcher_main source-dir output.7z
[[ ${HARDCORE_ARCHIVE_VISUAL:-1} == 0 ]]

# Apply the same real core chain used by create jobs, including the historically
# fragile video/nested patches, then add visual hooks and the container lane.
python3 "$COPY" "$CORE" "$TMP/copy.sh"
python3 "$MEDIA" "$TMP/copy.sh" "$TMP/media.sh"
python3 "$HARDWARE" "$TMP/media.sh" "$TMP/hardware.sh"
python3 "$CALIBRATION" "$TMP/hardware.sh" "$TMP/calibrated.sh"
python3 "$VAAPI" "$TMP/calibrated.sh" "$TMP/device.sh"
python3 "$NESTED" "$TMP/device.sh" "$TMP/nested.sh"
python3 "$VISUAL_PATCH" "$TMP/nested.sh" "$TMP/visual.sh"
python3 "$CONTAINER" "$TMP/visual.sh" "$TMP/final.sh"
bash -n "$TMP/final.sh"

python3 "$VISUAL_PATCH" "$TMP/visual.sh" "$TMP/visual-twice.sh"
cmp -s "$TMP/visual.sh" "$TMP/visual-twice.sh" || {
    printf 'Visual runtime patch is not idempotent.\n' >&2
    exit 1
}

assert_has() {
    local text=$1
    grep -Fq -- "$text" "$TMP/final.sh" || {
        printf 'Missing visual runtime text: %s\n' "$text" >&2
        exit 1
    }
}

assert_has '# HARDCORE_VISUAL_MODE_V1'
assert_has 'HARDCORE_ARCHIVE_VISUAL:-0'
assert_has 'hardcore_visual_validate'
assert_has 'Hardcore Archive - Video / FFmpeg'
assert_has 'Hardcore Archive - Images'
assert_has 'Hardcore Archive - 7-Zip / archive'
assert_has 'Hardcore Archive - Nested: ${relative}'
assert_has 'Live log viewer. Closing this window does NOT stop the archive worker.'
assert_has 'VIDEO_PIPELINE_PID=$!'
assert_has 'IMAGE_PIPELINE_PID=$!'
assert_has 'pattern '\''Exit status:'\'''
assert_has 'konsole|kitty|gnome-terminal|alacritty|wezterm|foot|xterm'

grep -Fq 'HARDCORE_VISUAL_PATCHER=' "$ROOT/lib/planner.sh"
grep -Fq 'hardcore_visual_apply_runtime_patch' "$ROOT/lib/archive.sh"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/visual.sh"' "$ROOT/hardcore-archive"

printf 'Visual worker-window policy tests passed.\n'
