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
assert_has 'hardcore_video_encode_full'
grep -Fq "printf 'FFmpeg command:'" "$ROOT/lib/video-acceleration.sh"
assert_has 'VIDEO_LOG=$(component_log_path video.log)'
assert_has "Hardware video encoder locked: %s"
assert_lacks 'VIDEO_ENCODER=libsvtav1'
assert_lacks 'VIDEO_ENCODER=libx265'
assert_lacks 'then apply_encoder libsvtav1'
assert_lacks 'then apply_encoder libx265'

# The modular runtime establishes diagnostics and invokes the checked-in engine.
grep -Fq 'hardcore_reporting_start' "$ROOT/lib/reporting.sh"
! grep -Eq 'PATCHER|apply_runtime_patch|build_runtime_core' \
    "$ROOT/lib/planner.sh" "$ROOT/lib/video.sh" "$ROOT/lib/archive.sh"
grep -Fq 'hardcore_archive_static_engine_ready' "$ROOT/lib/archive.sh"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/scheduler.sh"' "$ROOT/hardcore-archive-runner.sh"

printf 'Hardware-only video + persistent diagnostics tests passed.\n'
