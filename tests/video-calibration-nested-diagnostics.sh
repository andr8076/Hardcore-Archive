#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
CORE="$ROOT/lib/hardcore-archive-core.sh"
VIDEO_HELPER="$ROOT/lib/hardcore-archive-video-helper.sh"
[[ -f $CORE ]] || { printf 'Missing static core: %s\n' "$CORE" >&2; exit 1; }
[[ -f $VIDEO_HELPER ]] || { printf 'Missing static video helper: %s\n' "$VIDEO_HELPER" >&2; exit 1; }
bash -n "$CORE"
bash -n "$VIDEO_HELPER"

assert_has() {
    local text=$1
    grep -Fq -- "$text" "$CORE" || grep -Fq -- "$text" "$VIDEO_HELPER" || {
        printf 'Missing static engine policy text: %s\n' "$text" >&2
        exit 1
    }
}
assert_lacks() {
    local text=$1
    ! grep -Fq -- "$text" "$CORE" && ! grep -Fq -- "$text" "$VIDEO_HELPER" || {
        printf 'Forbidden stale static engine text remains: %s\n' "$text" >&2
        exit 1
    }
}

assert_has '# HARDCORE_VIDEO_CODEC_COMPETITION_V2'
assert_has "av1_vaapi) printf '1 255 q_idx'"
assert_has "hevc_vaapi) printf '1 51 QP'"
assert_has 'calibrate_hardware_candidate()'
assert_has 'Automatic codec competition'
assert_has 'Winner: AV1, because its quality-valid candidate is predicted smaller.'
assert_has 'Winner: HEVC, because its quality-valid candidate is predicted smaller.'
assert_has 'HARDCORE_ARCHIVE_AUTO_AV1_ENCODER'
assert_has 'HARDCORE_ARCHIVE_AUTO_HEVC_ENCODER'
assert_has 'predicted<=-20'
assert_has 'Preflight predicts severe expansion'
assert_has 'in_range=auto:out_range=tv,setsar=1'
assert_has 'pad=${eval_width}:${eval_height}:(ow-iw)/2:(oh-ih)/2:color=black'
assert_has 'setsar=1,format=yuv420p'
assert_has "QUALITY_VMAF_POLICY_VERSION='source-display-v1'"
assert_lacks 'out_range=tv,format=yuv420p[ref]'
assert_lacks 'out_range=tv,format=yuv420p[dist]'
assert_lacks 'video_crf="CQP ${AV1_CRF}"; video_preset='"'"'N/A'"'"'; video_pix_fmt='"'"'vaapi'"'"''
assert_lacks 'video_crf="CQP ${HEVC_CRF}"; video_preset='"'"'N/A'"'"'; video_pix_fmt='"'"'vaapi'"'"''

assert_has '# HARDCORE_EXPLICIT_VAAPI_DEVICE_V1'
assert_has 'vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}'
assert_lacks '"vaapi=va:"'
assert_lacks "'vaapi=va:'"
assert_has 'video_vaapi_device=%s'

assert_has '# HARDCORE_NESTED_CHILD_DIAGNOSTICS_V1'
assert_has 'HARDCORE_ARCHIVE_NESTED_CHILD=1'
assert_has 'HARDCORE_ARCHIVE_HARDWARE_ENCODER_LOCKED="${VIDEO_ENCODER:-}"'
assert_has 'nested/depth-$((depth + 1))/${relative}/run.log'
assert_has 'Inherited hardware encoder %s already validated by parent.'
assert_has 'Nested child video item failed with exit code %s; original preserved and recursion continues.'
assert_has 'Nested child log: %s'

for predicted in -70 -150 -267; do
    LC_NUMERIC=C awk -v predicted="$predicted" 'BEGIN {exit !(predicted<=-20)}' || {
        printf 'Hard negative preflight did not reject %s%%.\n' "$predicted" >&2
        exit 1
    }
done

! grep -Eq 'PATCHER|apply_runtime_patch|build_runtime_core' \
    "$ROOT/lib/planner.sh" "$ROOT/lib/video.sh" "$ROOT/lib/nested.sh" "$ROOT/lib/archive.sh"

printf 'Video codec competition + explicit VAAPI device + nested child diagnostics tests passed.\n'
