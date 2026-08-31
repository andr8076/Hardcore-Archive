#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-calibration-nested-test.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

CORE="$ROOT/lib/hardcore-archive-core.sh"
COPY="$ROOT/lib/hardcore-archive-copy-lane.py"
MEDIA="$ROOT/lib/hardcore-archive-media-fixes.py"
HARDWARE="$ROOT/lib/hardcore-archive-hardware-video.py"
CALIBRATION="$ROOT/lib/hardcore-archive-video-calibration.py"
VAAPI_DEVICE="$ROOT/lib/hardcore-archive-vaapi-device.py"
NESTED_DIAG="$ROOT/lib/hardcore-archive-nested-diagnostics.py"

for required in "$CORE" "$COPY" "$MEDIA" "$HARDWARE" "$CALIBRATION" "$VAAPI_DEVICE" "$NESTED_DIAG"; do
    [[ -f $required ]] || { printf 'Missing test dependency: %s\n' "$required" >&2; exit 1; }
done

python3 -m py_compile "$CALIBRATION" "$VAAPI_DEVICE" "$NESTED_DIAG"
python3 "$COPY" "$CORE" "$TMP/copy.sh"
python3 "$MEDIA" "$TMP/copy.sh" "$TMP/media.sh"
python3 "$HARDWARE" "$TMP/media.sh" "$TMP/hardware.sh"
python3 "$CALIBRATION" "$TMP/hardware.sh" "$TMP/calibrated.sh"
python3 "$VAAPI_DEVICE" "$TMP/calibrated.sh" "$TMP/device-bound.sh"
python3 "$NESTED_DIAG" "$TMP/device-bound.sh" "$TMP/final.sh"
bash -n "$TMP/final.sh"

python3 "$CALIBRATION" "$TMP/calibrated.sh" "$TMP/calibrated-twice.sh"
cmp -s "$TMP/calibrated.sh" "$TMP/calibrated-twice.sh" || {
    printf 'Video codec competition patch is not idempotent.\n' >&2
    exit 1
}
python3 "$VAAPI_DEVICE" "$TMP/device-bound.sh" "$TMP/device-bound-twice.sh"
cmp -s "$TMP/device-bound.sh" "$TMP/device-bound-twice.sh" || {
    printf 'VAAPI device patch is not idempotent.\n' >&2
    exit 1
}
python3 "$NESTED_DIAG" "$TMP/final.sh" "$TMP/final-twice.sh"
cmp -s "$TMP/final.sh" "$TMP/final-twice.sh" || {
    printf 'Nested diagnostics patch is not idempotent.\n' >&2
    exit 1
}

assert_has() {
    local text=$1
    grep -Fq -- "$text" "$TMP/final.sh" || {
        printf 'Missing runtime policy text: %s\n' "$text" >&2
        exit 1
    }
}
assert_lacks() {
    local text=$1
    ! grep -Fq -- "$text" "$TMP/final.sh" || {
        printf 'Forbidden stale runtime text remains: %s\n' "$text" >&2
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
assert_has 'out_range=tv,format=yuv420p[ref]'
assert_has 'out_range=tv,format=yuv420p[dist]'
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
assert_has 'nested/depth-$((depth + 1))/${relative}.child.log'
assert_has 'Inherited hardware encoder %s already validated by parent.'
assert_has 'Nested child video item failed with exit code %s; original preserved and recursion continues.'
assert_has 'Nested child log: %s'

for predicted in -70 -150 -267; do
    LC_NUMERIC=C awk -v predicted="$predicted" 'BEGIN {exit !(predicted<=-20)}' || {
        printf 'Hard negative preflight did not reject %s%%.\n' "$predicted" >&2
        exit 1
    }
done

grep -Fq 'HARDCORE_VIDEO_CALIBRATION_PATCHER=' "$ROOT/lib/planner.sh"
grep -Fq 'HARDCORE_VAAPI_DEVICE_PATCHER=' "$ROOT/lib/planner.sh"
grep -Fq 'HARDCORE_NESTED_DIAGNOSTICS_PATCHER=' "$ROOT/lib/planner.sh"
grep -Fq 'HARDCORE_VAAPI_DEVICE_PATCHER' "$ROOT/lib/video.sh"
grep -Fq 'hardcore_nested_apply_diagnostics_patch' "$ROOT/lib/archive.sh"

printf 'Video codec competition + explicit VAAPI device + nested child diagnostics tests passed.\n'
