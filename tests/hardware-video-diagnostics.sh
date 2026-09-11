#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CORE="$ROOT/lib/hardcore-archive-core.sh"
VIDEO_HELPER="$ROOT/lib/hardcore-archive-video-helper.sh"
VIDEO_ACCEL="$ROOT/lib/video-acceleration.sh"
CAPABILITIES="$ROOT/lib/video-encoder-capabilities.sh"
for source_file in "$CORE" "$VIDEO_HELPER" "$VIDEO_ACCEL" "$CAPABILITIES"; do
    [[ -f $source_file ]] || { printf 'Missing static production source: %s\n' "$source_file" >&2; exit 1; }
    bash -n "$source_file"
done

assert_has() {
    local text=$1
    grep -Fq -- "$text" "$CORE" || grep -Fq -- "$text" "$VIDEO_HELPER" || \
        grep -Fq -- "$text" "$VIDEO_ACCEL" || grep -Fq -- "$text" "$CAPABILITIES" || {
        printf 'Missing static engine text: %s\n' "$text" >&2
        exit 1
    }
}
assert_lacks() {
    local text=$1
    ! grep -Fq -- "$text" "$CORE" && ! grep -Fq -- "$text" "$VIDEO_HELPER" && ! grep -Fq -- "$text" "$VIDEO_ACCEL" || {
        printf 'Forbidden CPU fallback remains: %s\n' "$text" >&2
        exit 1
    }
}

assert_has '# HARDCORE_VIDEO_ENCODER_CLASS_POLICY_V1'
assert_has 'inherited+=(--video-encoder "$VIDEO_ENCODER")'
assert_has 'hardcore_video_encode_full'
grep -Fq "printf 'FFmpeg command:'" "$VIDEO_ACCEL"
assert_has 'VIDEO_LOG=$(component_log_path video.log)'
assert_has "Hardware video encoder locked: %s"
assert_has "Manual software video encoder locked: %s; AUTO remains hardware-only."
assert_lacks 'then apply_encoder libsvtav1'
assert_lacks 'then apply_encoder libx265'

source "$CAPABILITIES"
[[ $(hardcore_video_encoder_class libsvtav1) == software ]]
[[ $(hardcore_video_encoder_class libx265) == software ]]
! hardcore_video_encoder_auto_eligible libsvtav1
! hardcore_video_encoder_auto_eligible libx265
hardcore_video_encoder_auto_eligible av1_qsv

# The modular runtime establishes diagnostics and invokes the checked-in engine.
grep -Fq 'hardcore_reporting_start' "$ROOT/lib/reporting.sh"
! grep -Eq 'PATCHER|apply_runtime_patch|build_runtime_core' \
    "$ROOT/lib/planner.sh" "$ROOT/lib/video.sh" "$ROOT/lib/archive.sh"
grep -Fq 'hardcore_archive_static_engine_ready' "$ROOT/lib/archive.sh"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/scheduler.sh"' "$ROOT/hardcore-archive-runner.sh"

printf 'Hardware AUTO/manual software video + persistent diagnostics tests passed.\n'
