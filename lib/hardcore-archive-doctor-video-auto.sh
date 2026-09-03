#!/usr/bin/env bash
# Auto-codec doctor override. Loaded after the stable video probe fix.

# Preserve the original single-codec implementation for explicit av1/hevc mode.
eval "$(declare -f check_video_capability | sed '1s/check_video_capability/check_video_capability_single/')"

HARDWARE_AV1_ENCODER=''
HARDWARE_HEVC_ENCODER=''
HARDWARE_VIDEO_PRIMARY_CODEC=''

check_video_capability() {
    if [[ ${EFFECTIVE_VIDEO_CODEC:-av1} != auto ]]; then
        check_video_capability_single
        [[ -n ${HARDWARE_VIDEO_ENCODER:-} ]] && HARDWARE_VIDEO_PRIMARY_CODEC=$EFFECTIVE_VIDEO_CODEC
        [[ $EFFECTIVE_VIDEO_CODEC == av1 ]] && HARDWARE_AV1_ENCODER=${HARDWARE_VIDEO_ENCODER:-}
        [[ $EFFECTIVE_VIDEO_CODEC == hevc ]] && HARDWARE_HEVC_ENCODER=${HARDWARE_VIDEO_ENCODER:-}
        return 0
    fi

    [[ $VIDEO_ENABLED == true && $VIDEO_RELEVANT == true ]] || return 0
    local encoder codec
    local -a failed_probes=()
    HARDWARE_AV1_ENCODER=''
    HARDWARE_HEVC_ENCODER=''
    HARDWARE_VIDEO_ENCODER=''
    HARDWARE_VIDEO_PRIMARY_CODEC=''

    if ! check_version_command FFmpeg ffmpeg ffmpeg 'Video transcoding requires FFmpeg.' -version; then return 0; fi
    if ! check_version_command FFprobe ffprobe ffmpeg 'Video stream validation requires FFprobe.' -version; then return 0; fi

    if [[ $QUALITY_CHECK_EFFECTIVE == off ]]; then
        add_failure UNSUPPORTED 'Automatic video codec comparison' \
            'VIDEO_CODEC=auto requires VMAF quality measurement so AV1 and HEVC can be compared at the same quality floor. Choose av1/hevc explicitly to disable this requirement.' ffmpeg-vmaf
        return 0
    fi
    if ! filter_available libvmaf; then
        add_failure UNSUPPORTED 'FFmpeg libvmaf filter' \
            'Automatic AV1/HEVC comparison requires libvmaf; comparing codecs without a common quality measurement is forbidden.' ffmpeg-vmaf
        return 0
    fi
    add_ready 'Video quality filter: libvmaf'

    if [[ -n $REQUESTED_VIDEO_ENCODER ]]; then
        if encoder_matches_codec "$REQUESTED_VIDEO_ENCODER" av1; then codec=av1
        elif encoder_matches_codec "$REQUESTED_VIDEO_ENCODER" hevc; then codec=hevc
        else
            add_failure UNSUPPORTED "FFmpeg encoder: $REQUESTED_VIDEO_ENCODER" \
                'Only supported hardware AV1/HEVC encoders are allowed; software encoder fallback is forbidden.' ffmpeg
            return 0
        fi
        if ! encoder_available "$REQUESTED_VIDEO_ENCODER"; then
            add_failure UNSUPPORTED "FFmpeg encoder: $REQUESTED_VIDEO_ENCODER" \
                'FFmpeg is installed but this hardware encoder is not compiled/exposed.' ffmpeg-gpu
            return 0
        fi
        if ! probe_hardware_encoder "$codec" "$REQUESTED_VIDEO_ENCODER"; then
            add_failure BROKEN "Hardware ${codec^^} encode" \
                "FFmpeg advertises $REQUESTED_VIDEO_ENCODER, but a real hardware encode probe failed: ${VIDEO_PROBE_ERROR//$'\n'/ }" ffmpeg-gpu
            return 0
        fi
        HARDWARE_VIDEO_ENCODER=$REQUESTED_VIDEO_ENCODER
        HARDWARE_VIDEO_PRIMARY_CODEC=$codec
        [[ $codec == av1 ]] && HARDWARE_AV1_ENCODER=$REQUESTED_VIDEO_ENCODER || HARDWARE_HEVC_ENCODER=$REQUESTED_VIDEO_ENCODER
        add_ready "Video hardware: ${codec^^} via $REQUESTED_VIDEO_ENCODER (explicit encoder)"
        add_info 'Automatic codec competition reduced to the explicitly requested hardware encoder.'
        return 0
    fi

    for codec in av1 hevc; do
        encoder=''
        if encoder=$(select_hardware_encoder "$codec" 2>/dev/null) && [[ -n $encoder ]]; then
            if probe_hardware_encoder "$codec" "$encoder"; then
                if [[ $codec == av1 ]]; then HARDWARE_AV1_ENCODER=$encoder; else HARDWARE_HEVC_ENCODER=$encoder; fi
                add_ready "Video hardware candidate: ${codec^^} via $encoder"
            else
                # FFmpeg can expose an encoder the installed GPU cannot use
                # (for example AV1 NVENC on a HEVC-only GPU). In auto mode this
                # excludes that candidate, not every working codec. Keep the
                # actual probe error visible; fail below if no candidate works.
                failed_probes+=("${codec^^} via $encoder: ${VIDEO_PROBE_ERROR//$'\n'/ }")
                add_info "Automatic video candidate excluded after runtime probe: ${failed_probes[-1]}"
            fi
        else
            add_info "Automatic video candidate unavailable: ${codec^^} hardware encoder is not exposed on this machine."
        fi
    done

    if [[ -n $HARDWARE_AV1_ENCODER ]]; then
        HARDWARE_VIDEO_PRIMARY_CODEC=av1
        HARDWARE_VIDEO_ENCODER=$HARDWARE_AV1_ENCODER
    elif [[ -n $HARDWARE_HEVC_ENCODER ]]; then
        HARDWARE_VIDEO_PRIMARY_CODEC=hevc
        HARDWARE_VIDEO_ENCODER=$HARDWARE_HEVC_ENCODER
    elif (( ${#FAIL_TYPES[@]} == 0 )); then
        if (( ${#failed_probes[@]} > 0 )); then
            add_failure BROKEN 'Hardware AV1/HEVC encoder' \
                "No automatic hardware candidate passed its runtime probe: ${failed_probes[*]}" ffmpeg-gpu
        else
            add_failure UNSUPPORTED 'Hardware AV1/HEVC encoder' \
                'VIDEO_CODEC=auto is enabled but FFmpeg exposes no supported hardware AV1 or HEVC encoder.' ffmpeg-gpu
        fi
        return 0
    fi

    if [[ -n $HARDWARE_AV1_ENCODER && -n $HARDWARE_HEVC_ENCODER ]]; then
        add_info "Automatic video competition: AV1 ($HARDWARE_AV1_ENCODER) vs HEVC ($HARDWARE_HEVC_ENCODER) per file."
    elif [[ -n $HARDWARE_VIDEO_ENCODER ]]; then
        add_info "Automatic video competition has one usable hardware candidate: ${HARDWARE_VIDEO_PRIMARY_CODEC^^} via $HARDWARE_VIDEO_ENCODER."
    fi
}
