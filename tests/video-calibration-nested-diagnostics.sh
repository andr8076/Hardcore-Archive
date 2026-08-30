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
NESTED_DIAG="$ROOT/lib/hardcore-archive-nested-diagnostics.py"

for required in "$CORE" "$COPY" "$MEDIA" "$HARDWARE" "$CALIBRATION" "$NESTED_DIAG"; do
    [[ -f $required ]] || { printf 'Missing test dependency: %s\n' "$required" >&2; exit 1; }
done

python3 -m py_compile "$CALIBRATION" "$NESTED_DIAG"
python3 "$COPY" "$CORE" "$TMP/copy.sh"
python3 "$MEDIA" "$TMP/copy.sh" "$TMP/media.sh"
python3 "$HARDWARE" "$TMP/media.sh" "$TMP/hardware.sh"
python3 "$CALIBRATION" "$TMP/hardware.sh" "$TMP/calibrated.sh"
python3 "$NESTED_DIAG" "$TMP/calibrated.sh" "$TMP/final.sh"
bash -n "$TMP/final.sh"

python3 "$CALIBRATION" "$TMP/calibrated.sh" "$TMP/calibrated-twice.sh"
cmp -s "$TMP/calibrated.sh" "$TMP/calibrated-twice.sh" || {
    printf 'AV1 calibration patch is not idempotent.\n' >&2
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

assert_has '# HARDCORE_AV1_VAAPI_CALIBRATION_V1'
assert_has 'local low=1 high=255 mid best_qidx=0 best_video_bps=0'
assert_has 'Searching q_idx 1..255 for worst-sample VMAF >= %s.'
assert_has 'Highest quality-valid q_idx: %s; predicted saving: %s%%.'
assert_has 'Selected AV1 VAAPI q_idx %s.'
assert_has 'video_crf="CQP q_idx ${best_qidx} (calibrated)"'
assert_has 'predicted<=-20'
assert_has 'Preflight predicts severe expansion'
assert_has 'out_range=tv,format=yuv420p[ref]'
assert_has 'out_range=tv,format=yuv420p[dist]'
assert_lacks 'video_crf="CQP ${AV1_CRF}"; video_preset='"'"'N/A'"'"'; video_pix_fmt='"'"'vaapi'"'"''

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
grep -Fq 'HARDCORE_NESTED_DIAGNOSTICS_PATCHER=' "$ROOT/lib/planner.sh"
grep -Fq 'HARDCORE_VIDEO_CALIBRATION_PATCHER' "$ROOT/lib/video.sh"
grep -Fq 'hardcore_nested_apply_diagnostics_patch' "$ROOT/lib/archive.sh"

printf 'AV1 calibration + nested child diagnostics tests passed.\n'
