#!/usr/bin/env bash

# Hardware-video runtime policy boundary.
[[ ${HARDCORE_VIDEO_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_VIDEO_SH_LOADED=1

hardcore_video_apply_runtime_patch() {
    local input_core=$1 output_core=$2
    local hardware_core="${output_core}.hardware.$$"

    if ! python3 "$HARDCORE_HARDWARE_VIDEO_PATCHER" "$input_core" "$hardware_core"; then
        rm -f -- "$hardware_core"
        printf 'Error: refusing to start with a video engine that can fall back to CPU encoding.\n' >&2
        return 3
    fi
    if ! python3 "$HARDCORE_VIDEO_CALIBRATION_PATCHER" "$hardware_core" "$output_core"; then
        rm -f -- "$hardware_core" "$output_core"
        printf 'Error: refusing to start with stale AV1 VAAPI calibration/preflight policy.\n' >&2
        return 3
    fi
    rm -f -- "$hardware_core"
}
