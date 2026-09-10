#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

run_case() (
    local modern=$1 legacy=$2
    declare -a FAIL_TYPES=() FAIL_CAPS=() FAIL_DETAILS=() FAIL_REPAIR_KEYS=()
    declare -a READY_LINES=() INFO_LINES=()
    declare -a HARDCORE_ENCODER_MENU_CODEC=() HARDCORE_ENCODER_MENU_ENCODER=()
    declare -a HARDCORE_ENCODER_MENU_DEVICE=() HARDCORE_ENCODER_MENU_LABEL=()
    declare -a HARDCORE_ENCODER_MENU_FAILED=() HARDCORE_ENCODER_MENU_CPU=()
    EFFECTIVE_VIDEO_CODEC=auto
    REQUESTED_VIDEO_ENCODER=''
    HARDWARE_AV1_ENCODER=''
    HARDWARE_HEVC_ENCODER=''
    HARDWARE_VIDEO_ENCODER=''
    HARDWARE_VIDEO_PRIMARY_CODEC=''
    LEGACY_PROBES=0

    add_ready() { READY_LINES+=("$1"); }
    add_info() { INFO_LINES+=("$1"); }
    add_failure() {
        FAIL_TYPES+=("$1"); FAIL_CAPS+=("$2"); FAIL_DETAILS+=("$3"); FAIL_REPAIR_KEYS+=("${4:-}")
    }
    encoder_available() { return 1; }
    encoder_matches_codec() { return 1; }
    probe_hardware_encoder() { return 1; }
    hardcore_encoder_menu_collect() {
        if [[ $modern == ready ]]; then
            HARDCORE_ENCODER_MENU_CODEC+=(hevc)
            HARDCORE_ENCODER_MENU_ENCODER+=(hevc_vaapi)
            HARDCORE_ENCODER_MENU_DEVICE+=(/dev/dri/renderD128)
            HARDCORE_ENCODER_MENU_LABEL+=('VAAPI')
        fi
    }
    hardcore_encoder_codec() { return 1; }
    hardcore_encoder_backend_label() { return 1; }
    check_video_capability() {
        if [[ $modern == ready ]]; then
            HARDWARE_HEVC_ENCODER=hevc_vaapi
            HARDWARE_VIDEO_ENCODER=hevc_vaapi
            HARDWARE_VIDEO_PRIMARY_CODEC=hevc
            add_ready 'Video hardware candidate: HEVC via hevc_vaapi'
        else
            add_failure BROKEN 'Hardware AV1/HEVC encoder' 'No modern hardware candidate passed.' ffmpeg-gpu
        fi
    }
    linux_has_drm_vendor() { [[ $1 == 0x8086 ]]; }

    source "$ROOT/lib/hardcore-archive-doctor-intel-legacy.sh"
    hardcore_intel_legacy_probe() {
        LEGACY_PROBES=$((LEGACY_PROBES + 1))
        case $legacy in
            ready)
                HARDCORE_INTEL_LEGACY_RUNTIME_ID=intel-msdk-legacy-test-ihd-test
                HARDCORE_INTEL_LEGACY_RUNTIME_RESOLVED=/runtime/intel-legacy
                HARDCORE_INTEL_LEGACY_VA_DRIVER_RESOLVED=/runtime/intel-legacy/lib/dri
                return 0
                ;;
            absent) HARDCORE_INTEL_LEGACY_ERROR='optional Intel legacy compatibility runtime was not found' ;;
            broken) HARDCORE_INTEL_LEGACY_ERROR='real HEVC encode failed (status 1)' ;;
        esac
        return 1
    }
    hardcore_intel_legacy_select() {
        [[ -n ${HARDCORE_INTEL_LEGACY_RUNTIME_ID:-} ]] || return 1
        HARDCORE_ARCHIVE_VIDEO_ENCODER_RUNTIME_ID=$HARDCORE_INTEL_LEGACY_RUNTIME_ID
        HARDCORE_ARCHIVE_VIDEO_ENCODER_RUNTIME_KIND=intel-media-sdk-legacy
    }

    check_video_capability
    printf 'encoder=%s\n' "${HARDWARE_VIDEO_ENCODER:-}"
    printf 'codec=%s\n' "${HARDWARE_VIDEO_PRIMARY_CODEC:-}"
    printf 'legacy_probes=%s\n' "$LEGACY_PROBES"
    printf 'failures=%s\n' "${#FAIL_TYPES[@]}"
    printf 'runtime=%s\n' "${HARDCORE_ARCHIVE_VIDEO_ENCODER_RUNTIME_ID:-}"
    printf 'ready=%s\n' "${READY_LINES[*]:-}"
    printf 'info=%s\n' "${INFO_LINES[*]:-}"
)

assert_has() {
    local output=$1 expected=$2
    grep -Fqx -- "$expected" <<< "$output" || {
        printf 'Expected line not found: %s\n%s\n' "$expected" "$output" >&2
        exit 1
    }
}
assert_contains() {
    local output=$1 expected=$2
    grep -Fq -- "$expected" <<< "$output" || {
        printf 'Expected text not found: %s\n%s\n' "$expected" "$output" >&2
        exit 1
    }
}

# A/E: modern hardware wins and the obsolete runtime is not touched.
out=$(run_case ready ready)
assert_has "$out" 'encoder=hevc_vaapi'
assert_has "$out" 'legacy_probes=0'
assert_has "$out" 'runtime='

# B: P530-style modern failure plus a genuine legacy success is AUTO hardware.
out=$(run_case failed ready)
assert_has "$out" 'encoder=hevc_qsv_legacy'
assert_has "$out" 'codec=hevc'
assert_has "$out" 'legacy_probes=1'
assert_has "$out" 'failures=0'
assert_has "$out" 'runtime=intel-msdk-legacy-test-ihd-test'
assert_contains "$out" 'HEVC via Intel legacy compatibility runtime'

# C: files alone are insufficient; a failed real encode excludes the candidate.
out=$(run_case failed broken)
assert_has "$out" 'encoder='
assert_has "$out" 'failures=1'
assert_contains "$out" 'real HEVC encode failed'

# D: absence is clean, diagnostic, and cannot create a software AUTO fallback.
out=$(run_case failed absent)
assert_has "$out" 'encoder='
assert_has "$out" 'failures=1'
assert_contains "$out" 'optional Intel legacy compatibility runtime was not found'
! grep -Eq '^encoder=(libx265|libsvtav1|libaom-av1|librav1e)$' <<< "$out"

printf 'Intel legacy candidate-selection tests passed.\n'
