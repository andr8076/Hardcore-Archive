#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-video-auto-policy.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT

POLICY="$ROOT/hardcore-archive-runner-policy.sh"
BASE_PATCH="$ROOT/lib/hardcore-archive-policy-updates.py"
AUTO_PATCH="$ROOT/lib/hardcore-archive-video-auto-policy.py"
DOCTOR_BASE="$ROOT/lib/hardcore-archive-doctor-base.sh"
DOCTOR_CHECKS="$ROOT/lib/hardcore-archive-doctor-checks.sh"
DOCTOR_FIX="$ROOT/lib/hardcore-archive-doctor-video-fix.sh"
DOCTOR_AUTO="$ROOT/lib/hardcore-archive-doctor-video-auto.sh"

for f in "$POLICY" "$BASE_PATCH" "$AUTO_PATCH" "$DOCTOR_BASE" "$DOCTOR_CHECKS" "$DOCTOR_FIX" "$DOCTOR_AUTO"; do
    [[ -f $f ]] || { printf 'Missing auto-codec test dependency: %s\n' "$f" >&2; exit 1; }
done
python3 -m py_compile "$BASE_PATCH" "$AUTO_PATCH"
bash -n "$DOCTOR_AUTO"
python3 "$BASE_PATCH" "$POLICY" "$TMP/base.sh"
python3 "$AUTO_PATCH" "$TMP/base.sh" "$TMP/auto.sh"
bash -n "$TMP/auto.sh"
python3 "$AUTO_PATCH" "$TMP/auto.sh" "$TMP/auto-twice.sh"
cmp -s "$TMP/auto.sh" "$TMP/auto-twice.sh" || { printf 'Auto-codec policy patch is not idempotent.\n' >&2; exit 1; }

grep -Fxq 'VIDEO_CODEC=auto' "$ROOT/config"
grep -Fq '# HARDCORE_VIDEO_CODEC_AUTO_POLICY_V1' "$TMP/auto.sh"
grep -Fq 'auto|av1|hevc' "$TMP/auto.sh"
grep -Fq 'HARDCORE_ARCHIVE_VIDEO_CODEC_AUTO=1' "$TMP/auto.sh"
grep -Fq 'HARDCORE_ARCHIVE_AUTO_AV1_ENCODER' "$TMP/auto.sh"
grep -Fq 'HARDCORE_ARCHIVE_AUTO_HEVC_ENCODER' "$TMP/auto.sh"
grep -Fq 'Hardware video policy: AUTO' "$TMP/auto.sh"

# Exercise the auto doctor decision logic without needing real GPU hardware.
PLATFORM=Linux
VIDEO_ENABLED=true
VIDEO_RELEVANT=true
VIDEO_PREFLIGHT_ENABLED=true
QUALITY_CHECK_EFFECTIVE=auto
EFFECTIVE_VIDEO_CODEC=auto
REQUESTED_VIDEO_ENCODER=''
# shellcheck source=/dev/null
source "$DOCTOR_BASE"
# shellcheck source=/dev/null
source "$DOCTOR_CHECKS"
# shellcheck source=/dev/null
source "$DOCTOR_FIX"
# shellcheck source=/dev/null
source "$DOCTOR_AUTO"
check_version_command() { return 0; }
filter_available() { return 0; }
select_hardware_encoder() { [[ $1 == av1 ]] && printf av1_vaapi || printf hevc_vaapi; }
probe_hardware_encoder() { VIDEO_PROBE_ERROR=''; return 0; }
check_video_capability
[[ $HARDWARE_AV1_ENCODER == av1_vaapi ]]
[[ $HARDWARE_HEVC_ENCODER == hevc_vaapi ]]
[[ $HARDWARE_VIDEO_PRIMARY_CODEC == av1 ]]
[[ $HARDWARE_VIDEO_ENCODER == av1_vaapi ]]

# A machine with only HEVC remains valid in auto mode; absence is not a hidden
# fallback, it is simply the only candidate the hardware exposes.
FAIL_TYPES=(); FAIL_CAPS=(); FAIL_DETAILS=(); FAIL_REPAIR_KEYS=(); FAIL_REPAIR_CMDS=(); READY_LINES=(); INFO_LINES=()
HARDWARE_AV1_ENCODER=''; HARDWARE_HEVC_ENCODER=''; HARDWARE_VIDEO_ENCODER=''; HARDWARE_VIDEO_PRIMARY_CODEC=''
select_hardware_encoder() { [[ $1 == hevc ]] && { printf hevc_vaapi; return 0; }; return 1; }
check_video_capability
[[ -z $HARDWARE_AV1_ENCODER ]]
[[ $HARDWARE_HEVC_ENCODER == hevc_vaapi ]]
[[ $HARDWARE_VIDEO_PRIMARY_CODEC == hevc ]]
[[ $HARDWARE_VIDEO_ENCODER == hevc_vaapi ]]
(( ${#FAIL_TYPES[@]} == 0 ))

printf 'Automatic AV1/HEVC policy tests passed.\n'
