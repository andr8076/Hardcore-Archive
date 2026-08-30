#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-hw-video-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

python3 "$ROOT/lib/hardcore-archive-copy-lane.py" \
    "$ROOT/lib/hardcore-archive-core.sh" "$TMP/copy.sh"
python3 "$ROOT/lib/hardcore-archive-media-fixes.py" \
    "$TMP/copy.sh" "$TMP/media.sh"
python3 "$ROOT/lib/hardcore-archive-hardware-video.py" \
    "$TMP/media.sh" "$TMP/hardware.sh"
python3 "$ROOT/lib/hardcore-archive-hardware-video.py" \
    "$TMP/hardware.sh" "$TMP/hardware-twice.sh"

bash -n "$TMP/hardware.sh"
cmp -s "$TMP/hardware.sh" "$TMP/hardware-twice.sh" || {
    printf 'Hardware-video patch is not idempotent.\n' >&2
    exit 1
}

assert_has() {
    local text=$1
    grep -Fq -- "$text" "$TMP/hardware.sh" || {
        printf 'Missing patched engine text: %s\n' "$text" >&2
        exit 1
    }
}
assert_lacks() {
    local text=$1
    ! grep -Fq -- "$text" "$TMP/hardware.sh" || {
        printf 'Forbidden CPU fallback remains: %s\n' "$text" >&2
        exit 1
    }
}

assert_has '# HARDCORE_HARDWARE_ONLY_VIDEO_V1'
assert_has 'video_encoder_is_hardware "$VIDEO_ENCODER"'
assert_has 'inherited+=(--video-encoder "$VIDEO_ENCODER")'
assert_has "printf 'FFmpeg command:'"
assert_has 'HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/video.log'
assert_has "Hardware video encoder locked: %s"
assert_lacks 'VIDEO_ENCODER=libsvtav1'
assert_lacks 'VIDEO_ENCODER=libx265'
assert_lacks 'then apply_encoder libsvtav1'
assert_lacks 'then apply_encoder libx265'

# The public runtime runner must establish the persistent transcript before the
# create engine starts and must apply the hardware enforcement patch.
grep -Fq 'Persistent run log:' "$ROOT/hardcore-archive-runner.sh"
grep -Fq 'HARDWARE_VIDEO_PATCHER=' "$ROOT/hardcore-archive-runner.sh"
grep -Fq 'refusing to start with a video engine that can fall back to CPU encoding' "$ROOT/hardcore-archive-runner.sh"

printf 'Hardware-only video + persistent diagnostics tests passed.\n'
