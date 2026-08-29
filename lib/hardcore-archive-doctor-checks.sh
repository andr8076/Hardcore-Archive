probe_hardware_encoder() {
    local codec=$1 encoder=$2 out err actual device=''
    out=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-hw.XXXXXX.mkv") || return 1
    err=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-hw.XXXXXX.err") || { rm -f -- "$out"; return 1; }
    local -a cmd=(ffmpeg -hide_banner -v error -nostdin -y)
    case $encoder in
        *_vaapi)
            if [[ $PLATFORM == Linux ]]; then
                case $encoder in av1_vaapi|hevc_vaapi)
                    if linux_has_drm_vendor 0x1002; then device=$(vaapi_device_for_vendor 0x1002 || true)
                    elif linux_has_drm_vendor 0x8086; then device=$(vaapi_device_for_vendor 0x8086 || true)
                    else device=$(vaapi_device_for_vendor '' || true); fi ;;
                esac
            fi
            [[ -n $device ]] && cmd+=( -init_hw_device "vaapi=va:$device" ) || cmd+=( -init_hw_device 'vaapi=va:' )
            cmd+=( -filter_hw_device va -f lavfi -i 'color=c=black:s=128x72:r=30' -t 0.25 -vf 'format=nv12,hwupload' -c:v "$encoder" -qp 33 )
            ;;
        *_nvenc)
            cmd+=( -f lavfi -i 'color=c=black:s=128x72:r=30' -t 0.25 -c:v "$encoder" -cq:v 33 -preset:v p4 ) ;;
        *_qsv)
            cmd+=( -f lavfi -i 'color=c=black:s=128x72:r=30' -t 0.25 -c:v "$encoder" -global_quality:v 33 -preset:v balanced ) ;;
        *_videotoolbox)
            cmd+=( -f lavfi -i 'color=c=black:s=128x72:r=30' -t 0.25 -c:v "$encoder" -q:v 65 -pix_fmt nv12 ) ;;
        *) rm -f -- "$out" "$err"; VIDEO_PROBE_ERROR='unsupported encoder policy'; return 1 ;;
    esac
    cmd+=( -an -sn -dn -f matroska "$out" )
    if ! "${cmd[@]}" >/dev/null 2>"$err"; then VIDEO_PROBE_ERROR=$(tail -n 12 "$err" 2>/dev/null || true); rm -f -- "$out" "$err"; return 1; fi
    actual=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$out" 2>"$err" | head -n1 || true)
    rm -f -- "$out" "$err"
    [[ $actual == "$codec" ]] || { VIDEO_PROBE_ERROR="Hardware probe produced codec '$actual' instead of '$codec'."; return 1; }
    VIDEO_PROBE_ERROR=''
    return 0
}

probe_indicates_av1_hardware_incompatibility() {
    grep -Eqi 'does not support.*av1|av1.*not supported|unsupported device|no usable encoding entrypoint.*av1|unsupported profile|profile.*av1.*not supported|no capable devices' <<< "$1"
}

HARDWARE_VIDEO_ENCODER=''
VIDEO_CODEC_FELL_BACK=false
check_video_capability() {
    [[ $VIDEO_ENABLED == true && $VIDEO_RELEVANT == true ]] || return 0
    local encoder hevc_encoder av1_error
    if ! check_version_command FFmpeg ffmpeg ffmpeg 'Video transcoding requires FFmpeg.' -version; then return 0; fi
    if ! check_version_command FFprobe ffprobe ffmpeg 'Video stream validation requires FFprobe.' -version; then return 0; fi

    if $VIDEO_PREFLIGHT_ENABLED && [[ $QUALITY_CHECK_EFFECTIVE != off ]]; then
        if ! filter_available libvmaf; then
            add_failure UNSUPPORTED 'FFmpeg libvmaf filter' 'Video preflight quality validation is enabled, but this FFmpeg build lacks libvmaf. SSIM fallback is forbidden.' ffmpeg-vmaf
        else add_ready 'Video quality filter: libvmaf'; fi
    fi

    if [[ -n $REQUESTED_VIDEO_ENCODER ]]; then
        if ! encoder_matches_codec "$REQUESTED_VIDEO_ENCODER" "$EFFECTIVE_VIDEO_CODEC"; then
            add_failure UNSUPPORTED "FFmpeg encoder: $REQUESTED_VIDEO_ENCODER" "Only hardware $EFFECTIVE_VIDEO_CODEC encoders are allowed; software encoder fallback is forbidden." ffmpeg
            return 0
        fi
        if ! encoder_available "$REQUESTED_VIDEO_ENCODER"; then
            add_failure UNSUPPORTED "FFmpeg encoder: $REQUESTED_VIDEO_ENCODER" 'FFmpeg is installed but this hardware encoder is not compiled/exposed.' ffmpeg-gpu
            return 0
        fi
        encoder=$REQUESTED_VIDEO_ENCODER
    else
        if ! encoder=$(select_hardware_encoder "$EFFECTIVE_VIDEO_CODEC"); then
            add_failure UNSUPPORTED "Hardware ${EFFECTIVE_VIDEO_CODEC^^} encoder" "FFmpeg is installed but exposes no supported hardware $EFFECTIVE_VIDEO_CODEC encoder." ffmpeg-gpu
            return 0
        fi
    fi

    if probe_hardware_encoder "$EFFECTIVE_VIDEO_CODEC" "$encoder"; then
        HARDWARE_VIDEO_ENCODER=$encoder
        add_ready "Video hardware: ${EFFECTIVE_VIDEO_CODEC^^} via $encoder"
        return 0
    fi

    av1_error=$VIDEO_PROBE_ERROR
    if [[ $EFFECTIVE_VIDEO_CODEC == av1 ]] && probe_indicates_av1_hardware_incompatibility "$av1_error"; then
        if hevc_encoder=$(select_hardware_encoder hevc 2>/dev/null) && [[ -n $hevc_encoder ]] && probe_hardware_encoder hevc "$hevc_encoder"; then
            EFFECTIVE_VIDEO_CODEC=hevc
            HARDWARE_VIDEO_ENCODER=$hevc_encoder
            VIDEO_CODEC_FELL_BACK=true
            add_info "GPU cannot encode AV1; using the only permitted fallback: HEVC via $hevc_encoder."
            add_ready "Video hardware: HEVC via $hevc_encoder"
            return 0
        fi
        VIDEO_PROBE_ERROR=$av1_error
    fi
    add_failure BROKEN "Hardware ${EFFECTIVE_VIDEO_CODEC^^} encode" "FFmpeg advertises $encoder, but a real hardware encode probe failed: ${VIDEO_PROBE_ERROR//$'\n'/ }" ffmpeg-gpu
}

check_image_capabilities() {
    [[ $IMAGE_ENABLED == true && $IMAGE_RELEVANT == true ]] || return 0
    if (( JPEG_COUNT > 0 || NESTED_JPEG_COUNT > 0 || NESTED_DEEP_ARCHIVE_COUNT > 0 )); then
        local ok=true
        check_version_command jpegtran jpegtran jpeg 'JPEG optimization requires jpegtran.' -version || ok=false
        check_version_command djpeg djpeg jpeg 'JPEG verification requires djpeg.' -version || ok=false
        $ok && add_ready 'JPEG lossless optimizer + verifier'
    fi
    if (( PNG_COUNT > 0 || NESTED_PNG_COUNT > 0 || NESTED_DEEP_ARCHIVE_COUNT > 0 )); then
        if command -v oxipng >/dev/null 2>&1; then
            if oxipng --version >/dev/null 2>&1; then add_ready 'PNG optimizer: oxipng'; else add_failure BROKEN OxiPNG 'oxipng is installed but its self-test/version command fails.' oxipng; fi
        elif command -v optipng >/dev/null 2>&1; then
            if optipng -version >/dev/null 2>&1; then add_ready 'PNG optimizer: optipng'; else add_failure BROKEN OptiPNG 'optipng is installed but its self-test/version command fails.' optipng; fi
        else
            add_failure MISSING 'PNG optimizer' 'PNG optimization is enabled for this source, but no supported PNG optimizer is installed. Original-file fallback is forbidden.' oxipng
        fi
    fi
}

check_strict_runtime_capabilities() {
    check_core_command_set || true
    check_7zip || true
    [[ -n $SEVEN_ZIP ]] && inspect_nested_relevance || true
    check_version_command Python python3 python 'Sparse-file and metadata analysis require Python 3.' --version && add_ready 'Python 3'

    if [[ $MC_AUTO_ENABLED == true && $ANALYZE_ONLY == false ]]; then
        check_command 'timeout' timeout coreutils 'Automatic LZMA match-cycle tuning requires timeout.' || true
        check_command 'dd' dd coreutils 'Automatic LZMA match-cycle tuning requires dd.' || true
    fi

    if ! $ALLOW_SLEEP; then
        if [[ $PLATFORM == Darwin ]]; then
            check_command 'caffeinate' caffeinate macos-system 'Sleep protection is active and requires caffeinate.' && add_ready 'Sleep protection: caffeinate'
        else
            if ! command -v systemd-inhibit >/dev/null 2>&1; then add_failure MISSING 'systemd-inhibit' 'Sleep protection is active; --allow-sleep is the only way to deliberately disable this requirement.' systemd
            elif ! systemd-inhibit --list >/dev/null 2>&1; then add_failure BROKEN 'systemd-inhibit' 'systemd-inhibit is installed but cannot communicate with the inhibitor service.' systemd
            else add_ready 'Sleep protection: systemd-inhibit'; fi
        fi
    fi

    check_version_command ACL getfacl acl 'Archive metadata preservation requires getfacl; silently omitting ACLs is forbidden.' --version && add_ready 'ACL metadata preservation'
    if [[ $PLATFORM == Linux ]]; then
        check_version_command findmnt findmnt util-linux 'One-filesystem and mount safety require findmnt; fallback mount detection is forbidden.' --version && add_ready 'Mount detection: findmnt'
        $BATCH_MODE && { check_version_command lsblk lsblk util-linux 'Batch storage-lane scheduling requires lsblk.' --version && add_ready 'Batch storage mapping: lsblk'; }
    fi

    if { [[ $VIDEO_ENABLED == true && $VIDEO_RELEVANT == true ]] || [[ $IMAGE_ENABLED == true && $IMAGE_RELEVANT == true ]] || [[ $NESTED_RELEVANT == true ]]; }; then
        check_version_command setsid setsid util-linux 'Media/nested workers require separate process groups for reliable cancellation.' --version && add_ready 'Worker process groups: setsid'
    fi

    check_image_capabilities
    check_video_capability
}

