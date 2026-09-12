#!/usr/bin/env bash

# AV1 capability ownership belongs to the AV1Encode dependency. HEVC and its
# optional legacy Intel runtime retain Hardcore Archive's existing probes.
[[ ${HARDCORE_DOCTOR_AV1ENCODE_LOADED:-0} == 1 ]] && return 0
HARDCORE_DOCTOR_AV1ENCODE_LOADED=1

source "$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/av1encode-dependency.sh"

eval "$(declare -f probe_hardware_encoder | sed '1s/probe_hardware_encoder/probe_hardware_encoder_without_av1encode/')"
eval "$(declare -f probe_software_encoder | sed '1s/probe_software_encoder/probe_software_encoder_without_av1encode/')"

hardcore_doctor_probe_av1encode() {
    local encoder=$1 expected_class=$2
    if ! hardcore_av1encode_probe "$encoder"; then
        VIDEO_PROBE_ERROR=$HARDCORE_AV1ENCODE_ERROR
        return 1
    fi
    if [[ $HARDCORE_AV1ENCODE_SELECTED_ENCODER != "$encoder" ||
          $HARDCORE_AV1ENCODE_SELECTED_CLASS != "$expected_class" ]]; then
        VIDEO_PROBE_ERROR="AV1Encode reported '$encoder' as class '${HARDCORE_AV1ENCODE_SELECTED_CLASS:-unknown}', expected '$expected_class'."
        return 1
    fi
    HARDCORE_VIDEO_CAPABILITY_RUNTIME_ID="av1encode-${HARDCORE_AV1ENCODE_TOOL_VERSION:-unknown}"
    VIDEO_PROBE_ERROR=''
}

probe_hardware_encoder() {
    local codec=$1 encoder=$2
    if [[ $codec == av1 ]]; then
        [[ $(hardcore_video_encoder_class "$encoder" 2>/dev/null || true) == hardware ]] || {
            VIDEO_PROBE_ERROR="Encoder '$encoder' is software/manual-only and cannot be selected by AUTO."
            return 1
        }
        hardcore_doctor_probe_av1encode "$encoder" hardware
        return $?
    fi
    probe_hardware_encoder_without_av1encode "$@"
}

probe_software_encoder() {
    local codec=$1 encoder=$2
    if [[ $codec == av1 ]]; then
        [[ $encoder == libsvtav1 ]] || {
            VIDEO_PROBE_ERROR="Encoder '$encoder' is not AV1Encode's supported manual software encoder."
            return 1
        }
        hardcore_doctor_probe_av1encode "$encoder" software
        return $?
    fi
    probe_software_encoder_without_av1encode "$@"
}
