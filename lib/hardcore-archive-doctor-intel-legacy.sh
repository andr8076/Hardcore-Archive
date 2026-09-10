#!/usr/bin/env bash

# Add the optional legacy Intel candidate after every modern backend has had an
# opportunity to pass its normal real-encode probe.
[[ ${HARDCORE_DOCTOR_INTEL_LEGACY_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_DOCTOR_INTEL_LEGACY_SH_LOADED=1

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/intel-legacy-video.sh"

eval "$(declare -f encoder_available | sed '1s/encoder_available/encoder_available_without_intel_legacy/')"
eval "$(declare -f encoder_matches_codec | sed '1s/encoder_matches_codec/encoder_matches_codec_without_intel_legacy/')"
eval "$(declare -f probe_hardware_encoder | sed '1s/probe_hardware_encoder/probe_hardware_encoder_without_intel_legacy/')"
eval "$(declare -f check_video_capability | sed '1s/check_video_capability/check_video_capability_without_intel_legacy/')"
eval "$(declare -f hardcore_encoder_menu_collect | sed '1s/hardcore_encoder_menu_collect/hardcore_encoder_menu_collect_without_intel_legacy/')"
eval "$(declare -f hardcore_encoder_codec | sed '1s/hardcore_encoder_codec/hardcore_encoder_codec_without_intel_legacy/')"
eval "$(declare -f hardcore_encoder_backend_label | sed '1s/hardcore_encoder_backend_label/hardcore_encoder_backend_label_without_intel_legacy/')"

encoder_available() {
    [[ $1 == hevc_qsv_legacy ]] && { hardcore_intel_legacy_discover >/dev/null 2>&1; return $?; }
    encoder_available_without_intel_legacy "$@"
}

encoder_matches_codec() {
    [[ $1 == hevc_qsv_legacy && $2 == hevc ]] && return 0
    encoder_matches_codec_without_intel_legacy "$@"
}

hardcore_encoder_codec() {
    [[ $1 == hevc_qsv_legacy ]] && { printf hevc; return 0; }
    hardcore_encoder_codec_without_intel_legacy "$@"
}

hardcore_encoder_backend_label() {
    [[ $1 == hevc_qsv_legacy ]] && { printf 'Intel QSV (legacy Media SDK compatibility runtime)'; return 0; }
    hardcore_encoder_backend_label_without_intel_legacy "$@"
}

probe_hardware_encoder() {
    if [[ $2 == hevc_qsv_legacy ]]; then
        if hardcore_intel_legacy_probe; then
            hardcore_intel_legacy_select
            VIDEO_PROBE_ERROR=''
            return 0
        fi
        VIDEO_PROBE_ERROR=$HARDCORE_INTEL_LEGACY_ERROR
        return 1
    fi
    probe_hardware_encoder_without_intel_legacy "$@"
}

check_video_capability() {
    local before_fail=${#FAIL_TYPES[@]} before_ready=${#READY_LINES[@]} before_info=${#INFO_LINES[@]}
    check_video_capability_without_intel_legacy

    if [[ ${REQUESTED_VIDEO_ENCODER:-} == hevc_qsv_legacy ]]; then
        if [[ ${HARDWARE_VIDEO_ENCODER:-} == hevc_qsv_legacy ]]; then
            READY_LINES[-1]='Video hardware: HEVC via Intel legacy compatibility runtime (explicit encoder)'
            add_info "Legacy runtime identity: ${HARDCORE_ARCHIVE_VIDEO_ENCODER_RUNTIME_ID:-unknown}."
        elif (( ${#FAIL_TYPES[@]} > before_fail )) &&
             [[ ${FAIL_CAPS[-1]} == 'FFmpeg encoder: hevc_qsv_legacy' || ${FAIL_CAPS[-1]} == 'Hardware HEVC encode' ]]; then
            FAIL_CAPS[-1]='Intel legacy compatibility runtime'
            FAIL_DETAILS[-1]="The optional compatibility candidate is unavailable or failed its real HEVC probe: ${VIDEO_PROBE_ERROR:-${HARDCORE_INTEL_LEGACY_ERROR:-runtime not found}}"
            FAIL_REPAIR_KEYS[-1]=''
        fi
        return 0
    fi

    # Explicit selection is handled by the normal path through the overrides
    # above. AUTO reaches this point only when modern hardware produced no
    # candidate and exactly one hardware-capability failure was recorded.
    [[ ${EFFECTIVE_VIDEO_CODEC:-} == auto && -z ${REQUESTED_VIDEO_ENCODER:-} ]] || return 0
    [[ -z ${HARDWARE_AV1_ENCODER:-} && -z ${HARDWARE_HEVC_ENCODER:-} ]] || return 0
    (( ${#FAIL_TYPES[@]} == before_fail + 1 )) || return 0
    [[ ${FAIL_CAPS[-1]} == 'Hardware AV1/HEVC encoder' ]] || return 0

    if probe_hardware_encoder hevc hevc_qsv_legacy; then
        FAIL_TYPES=("${FAIL_TYPES[@]:0:before_fail}")
        FAIL_CAPS=("${FAIL_CAPS[@]:0:before_fail}")
        FAIL_DETAILS=("${FAIL_DETAILS[@]:0:before_fail}")
        FAIL_REPAIR_KEYS=("${FAIL_REPAIR_KEYS[@]:0:before_fail}")
        HARDWARE_AV1_ENCODER=''
        HARDWARE_HEVC_ENCODER=hevc_qsv_legacy
        HARDWARE_VIDEO_ENCODER=hevc_qsv_legacy
        HARDWARE_VIDEO_PRIMARY_CODEC=hevc
        add_ready 'Video hardware: HEVC via Intel legacy compatibility runtime'
        add_info 'Modern hardware AV1/HEVC probing found no usable candidate; validated legacy Media SDK compatibility runtime is being used.'
        add_info "Legacy runtime identity: ${HARDCORE_ARCHIVE_VIDEO_ENCODER_RUNTIME_ID:-unknown}."
    else
        FAIL_DETAILS[-1]="${FAIL_DETAILS[-1]} Optional Intel legacy compatibility candidate was excluded: ${VIDEO_PROBE_ERROR//$'\n'/ }."
        FAIL_REPAIR_KEYS[-1]=''
        add_info "Optional Intel legacy compatibility runtime unavailable or unusable: ${VIDEO_PROBE_ERROR//$'\n'/ }"
    fi
}

hardcore_encoder_menu_collect() {
    hardcore_encoder_menu_collect_without_intel_legacy
    ((${#HARDCORE_ENCODER_MENU_ENCODER[@]} == 0)) || return 0
    linux_has_drm_vendor 0x8086 || return 0
    if probe_hardware_encoder hevc hevc_qsv_legacy; then
        HARDCORE_ENCODER_MENU_CODEC+=(hevc)
        HARDCORE_ENCODER_MENU_ENCODER+=(hevc_qsv_legacy)
        HARDCORE_ENCODER_MENU_DEVICE+=('')
        HARDCORE_ENCODER_MENU_LABEL+=('Intel QSV (legacy Media SDK compatibility runtime)')
    elif [[ -n ${HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME:-} ]]; then
        HARDCORE_ENCODER_MENU_FAILED+=("HEVC hevc_qsv_legacy — ${VIDEO_PROBE_ERROR//$'\n'/ }")
    fi
}
