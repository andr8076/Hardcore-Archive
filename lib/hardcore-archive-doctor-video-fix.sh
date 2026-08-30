#!/usr/bin/env bash
# Loaded after the main doctor checks. This overrides only the hardware video
# probe so FFmpeg 9 VA-API quality control is both requested correctly and
# verified instead of silently accepting ignored encoder options.
probe_hardware_encoder() {
    local codec=$1 encoder=$2 out err actual device='' quality=33 ignored_line
    out=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-hw.XXXXXX.mkv") || return 1
    err=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-hw.XXXXXX.err") || { rm -f -- "$out"; return 1; }
    local -a cmd=(ffmpeg -hide_banner -v warning -nostdin -y)
    case $encoder in
        *_vaapi)
            if [[ $PLATFORM == Linux ]]; then
                case $encoder in av1_vaapi|hevc_vaapi)
                    if linux_has_drm_vendor 0x1002; then device=$(vaapi_device_for_vendor 0x1002 || true)
                    elif linux_has_drm_vendor 0x8086; then device=$(vaapi_device_for_vendor 0x8086 || true)
                    else device=$(vaapi_device_for_vendor '' || true); fi ;;
                esac
            fi
            [[ $encoder == hevc_vaapi ]] && quality=28
            [[ -n $device ]] && cmd+=( -init_hw_device "vaapi=va:$device" ) || cmd+=( -init_hw_device 'vaapi=va:' )
            cmd+=( -filter_hw_device va -f lavfi -i 'color=c=black:s=128x72:r=30' -t 0.25 -vf 'format=nv12,hwupload' -c:v "$encoder" -rc_mode CQP -global_quality:v "$quality" )
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
    if ! "${cmd[@]}" >/dev/null 2>"$err"; then
        VIDEO_PROBE_ERROR=$(tail -n 12 "$err" 2>/dev/null || true)
        rm -f -- "$out" "$err"
        return 1
    fi
    ignored_line=$(awk '/AVOption .* has not been used for any stream|No quality level set; using default/ {print; exit}' "$err" 2>/dev/null || true)
    if [[ -n $ignored_line ]]; then
        VIDEO_PROBE_ERROR="FFmpeg ignored required encoder quality options: $ignored_line"
        rm -f -- "$out" "$err"
        return 1
    fi
    actual=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$out" 2>"$err" | head -n1 || true)
    rm -f -- "$out" "$err"
    [[ $actual == "$codec" ]] || { VIDEO_PROBE_ERROR="Hardware probe produced codec '$actual' instead of '$codec'."; return 1; }
    VIDEO_PROBE_ERROR=''
    return 0
}
