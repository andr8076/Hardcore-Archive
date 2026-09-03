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

# FFmpeg can expose AV1 NVENC even when the installed GPU cannot encode AV1.
# A failed automatic candidate must not make a working alternative fatal.
reset_auto_doctor() {
    FAIL_TYPES=(); FAIL_CAPS=(); FAIL_DETAILS=(); FAIL_REPAIR_KEYS=(); FAIL_REPAIR_CMDS=()
    READY_LINES=(); INFO_LINES=(); REPAIR_KEY_SEEN=()
    EFFECTIVE_VIDEO_CODEC=auto
    QUALITY_CHECK_EFFECTIVE=auto
    REQUESTED_VIDEO_ENCODER=''
}
select_hardware_encoder() { printf '%s_nvenc' "$1"; }
encoder_available() { return 0; }
probe_hardware_encoder() {
    if [[ $1 == "$BROKEN_CODEC" || $BROKEN_CODEC == both ]]; then
        VIDEO_PROBE_ERROR="$1 is not supported by this device"
        return 1
    fi
    VIDEO_PROBE_ERROR=''
    return 0
}
for BROKEN_CODEC in av1 hevc; do
    reset_auto_doctor
    check_video_capability
    (( ${#FAIL_TYPES[@]} == 0 ))
    if [[ $BROKEN_CODEC == av1 ]]; then
        [[ -z $HARDWARE_AV1_ENCODER && $HARDWARE_HEVC_ENCODER == hevc_nvenc ]]
        [[ $HARDWARE_VIDEO_PRIMARY_CODEC == hevc && $HARDWARE_VIDEO_ENCODER == hevc_nvenc ]]
    else
        [[ -z $HARDWARE_HEVC_ENCODER && $HARDWARE_AV1_ENCODER == av1_nvenc ]]
        [[ $HARDWARE_VIDEO_PRIMARY_CODEC == av1 && $HARDWARE_VIDEO_ENCODER == av1_nvenc ]]
    fi
    [[ ${INFO_LINES[*]} == *'excluded after runtime probe'* ]]
    [[ ${INFO_LINES[*]} == *'not supported by this device'* ]]
done

# No stale successful candidate may survive a later all-failed probe.
reset_auto_doctor
BROKEN_CODEC=both
check_video_capability
(( ${#FAIL_TYPES[@]} == 1 ))
[[ ${FAIL_TYPES[0]} == BROKEN && ${FAIL_DETAILS[0]} == *av1_nvenc* && ${FAIL_DETAILS[0]} == *hevc_nvenc* ]]
[[ -z $HARDWARE_VIDEO_ENCODER && -z $HARDWARE_VIDEO_PRIMARY_CODEC ]]
[[ -z $HARDWARE_AV1_ENCODER && -z $HARDWARE_HEVC_ENCODER ]]

reset_auto_doctor
select_hardware_encoder() { return 1; }
check_video_capability
(( ${#FAIL_TYPES[@]} == 1 ))
[[ ${FAIL_TYPES[0]} == UNSUPPORTED ]]

# Missing VMAF and quality-off are not opportunities to skip quality checks.
select_hardware_encoder() { printf '%s_nvenc' "$1"; }
BROKEN_CODEC=none
reset_auto_doctor
filter_available() { return 1; }
check_video_capability
(( ${#FAIL_TYPES[@]} == 1 ))
[[ ${FAIL_CAPS[0]} == 'FFmpeg libvmaf filter' && -z $HARDWARE_VIDEO_ENCODER ]]
filter_available() { return 0; }
reset_auto_doctor
QUALITY_CHECK_EFFECTIVE=off
check_video_capability
(( ${#FAIL_TYPES[@]} == 1 ))
[[ ${FAIL_CAPS[0]} == 'Automatic video codec comparison' && -z $HARDWARE_VIDEO_ENCODER ]]

# Explicit encoder requests still fail rather than silently choosing another.
reset_auto_doctor
REQUESTED_VIDEO_ENCODER=av1_nvenc
BROKEN_CODEC=av1
check_video_capability
(( ${#FAIL_TYPES[@]} == 1 ))
[[ ${FAIL_TYPES[0]} == BROKEN && -z $HARDWARE_VIDEO_ENCODER ]]

printf 'Automatic AV1/HEVC policy tests passed.\n'
