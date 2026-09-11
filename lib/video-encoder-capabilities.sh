#!/usr/bin/env bash

# Central video-encoder registry and bounded runtime capability proof.
[[ ${HARDCORE_VIDEO_ENCODER_CAPABILITIES_LOADED:-0} == 1 ]] && return 0
HARDCORE_VIDEO_ENCODER_CAPABILITIES_LOADED=1

HARDCORE_VIDEO_PROBE_SIZE=${HARDCORE_VIDEO_PROBE_SIZE:-640x360}
HARDCORE_VIDEO_PROBE_TIMEOUT=${HARDCORE_VIDEO_PROBE_TIMEOUT:-20}
VIDEO_PROBE_ERROR=${VIDEO_PROBE_ERROR:-}
HARDCORE_VIDEO_CAPABILITY_RUNTIME_ID=${HARDCORE_VIDEO_CAPABILITY_RUNTIME_ID:-}

hardcore_video_encoder_codec() {
    case "$1" in
        av1_vaapi|av1_nvenc|av1_qsv|libsvtav1) printf av1 ;;
        hevc_videotoolbox|hevc_vaapi|hevc_nvenc|hevc_qsv|hevc_qsv_legacy|libx265) printf hevc ;;
        *) return 1 ;;
    esac
}

hardcore_video_encoder_class() {
    case "$1" in
        av1_vaapi|av1_nvenc|av1_qsv|hevc_videotoolbox|hevc_vaapi|hevc_nvenc|hevc_qsv|hevc_qsv_legacy)
            printf hardware ;;
        libsvtav1|libx265)
            printf software ;;
        *) return 1 ;;
    esac
}

hardcore_video_encoder_auto_eligible() {
    [[ $(hardcore_video_encoder_class "$1" 2>/dev/null || true) == hardware ]]
}

hardcore_video_encoder_supported() {
    hardcore_video_encoder_class "$1" >/dev/null 2>&1
}

hardcore_video_command_advertises_encoder() {
    local wanted=$1 table_name=$1
    shift
    [[ $wanted != hevc_qsv_legacy ]] || table_name=hevc_qsv
    "$@" -hide_banner -encoders 2>/dev/null |
        awk -v wanted="$table_name" 'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'
}

hardcore_video_default_ffmpeg_command() {
    local encoder=$1
    HARDCORE_VIDEO_CAPABILITY_COMMAND=(ffmpeg)
    if hardcore_video_command_advertises_encoder "$encoder" "${HARDCORE_VIDEO_CAPABILITY_COMMAND[@]}"; then
        return 0
    fi
    if [[ $(hardcore_video_encoder_class "$encoder" 2>/dev/null || true) == software &&
          -x ${HARDCORE_ARCHIVE_SYSTEM_FFMPEG:-} ]] &&
       hardcore_video_command_advertises_encoder "$encoder" "$HARDCORE_ARCHIVE_SYSTEM_FFMPEG"; then
        HARDCORE_VIDEO_CAPABILITY_COMMAND=("$HARDCORE_ARCHIVE_SYSTEM_FFMPEG")
        return 0
    fi
    return 1
}

hardcore_video_probe_run_bounded() {
    local seconds=$1; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout --signal=TERM --kill-after=2s "${seconds}s" "$@"
        return $?
    fi
    if command -v gtimeout >/dev/null 2>&1; then
        gtimeout --signal=TERM --kill-after=2s "${seconds}s" "$@"
        return $?
    fi

    local command_pid watchdog_pid rc
    "$@" & command_pid=$!
    (
        sleep "$seconds"
        kill -TERM "$command_pid" 2>/dev/null || exit 0
        sleep 2
        kill -KILL "$command_pid" 2>/dev/null || true
    ) & watchdog_pid=$!
    if wait "$command_pid"; then rc=0; else rc=$?; fi
    kill "$watchdog_pid" 2>/dev/null || true
    wait "$watchdog_pid" 2>/dev/null || true
    return "$rc"
}

hardcore_video_probe_command() {
    local encoder=$1 binary
    if declare -F hardcore_video_encoder_command >/dev/null 2>&1; then
        hardcore_video_encoder_command "$encoder" || return 1
        HARDCORE_VIDEO_CAPABILITY_COMMAND=("${HARDCORE_VIDEO_ENCODER_COMMAND[@]}")
        HARDCORE_VIDEO_CAPABILITY_FFMPEG_ENCODER=$HARDCORE_VIDEO_FFMPEG_ENCODER
    else
        hardcore_video_default_ffmpeg_command "$encoder" || return 1
        HARDCORE_VIDEO_CAPABILITY_FFMPEG_ENCODER=$encoder
    fi
    binary=${HARDCORE_VIDEO_CAPABILITY_COMMAND[0]}
    if [[ $binary == env ]]; then
        HARDCORE_VIDEO_CAPABILITY_RUNTIME_ID=${HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME_ID:-isolated-runtime}
    elif declare -F hardcore_runtime_identity >/dev/null 2>&1; then
        HARDCORE_VIDEO_CAPABILITY_RUNTIME_ID=$(hardcore_runtime_identity "$binary" 2>/dev/null || printf '%s' "$binary")
    else
        HARDCORE_VIDEO_CAPABILITY_RUNTIME_ID=$binary
    fi
}

hardcore_video_encoder_capability_probe() {
    local codec=$1 encoder=$2 device=${3:-} tmp out err actual rc=0 ignored_line
    local expected class
    local -a command=() decode_command=()
    VIDEO_PROBE_ERROR=''

    expected=$(hardcore_video_encoder_codec "$encoder" 2>/dev/null || true)
    class=$(hardcore_video_encoder_class "$encoder" 2>/dev/null || true)
    if [[ -z $expected || -z $class || $expected != "$codec" ]]; then
        VIDEO_PROBE_ERROR="Unsupported encoder/codec policy: $encoder cannot encode $codec."
        return 1
    fi
    if ! hardcore_video_probe_command "$encoder"; then
        VIDEO_PROBE_ERROR="No available FFmpeg runtime advertises the supported encoder '$encoder'."
        return 1
    fi
    if ! hardcore_video_command_advertises_encoder "$encoder" "${HARDCORE_VIDEO_CAPABILITY_COMMAND[@]}"; then
        VIDEO_PROBE_ERROR="The selected FFmpeg runtime does not advertise '$encoder'."
        return 1
    fi

    tmp=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-video-probe.XXXXXX") || {
        VIDEO_PROBE_ERROR='Could not create the encoder probe directory.'
        return 1
    }
    out="$tmp/output.mkv"
    err="$tmp/ffmpeg.err"
    command=("${HARDCORE_VIDEO_CAPABILITY_COMMAND[@]}" -hide_banner -v warning -nostdin -y)
    case "$encoder" in
        *_vaapi)
            command+=( -init_hw_device "vaapi=va:${device:-${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}}" -filter_hw_device va
                -f lavfi -i "color=c=black:s=${HARDCORE_VIDEO_PROBE_SIZE}:r=30" -frames:v 8
                -vf 'format=nv12,hwupload' -c:v "$HARDCORE_VIDEO_CAPABILITY_FFMPEG_ENCODER"
                -rc_mode CQP -global_quality:v "$([[ $codec == hevc ]] && printf 28 || printf 33)" ) ;;
        *_nvenc)
            command+=( -f lavfi -i "color=c=black:s=${HARDCORE_VIDEO_PROBE_SIZE}:r=30" -frames:v 8
                -c:v "$HARDCORE_VIDEO_CAPABILITY_FFMPEG_ENCODER" -gpu:v "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}"
                -cq:v 33 -preset:v p4 ) ;;
        hevc_qsv_legacy)
            command+=( -f lavfi -i "color=c=black:s=${HARDCORE_VIDEO_PROBE_SIZE}:r=30" -frames:v 8
                -c:v "$HARDCORE_VIDEO_CAPABILITY_FFMPEG_ENCODER" -load_plugin hevc_hw -low_power 0
                -global_quality:v 28 -preset:v medium ) ;;
        *_qsv)
            command+=( -f lavfi -i "color=c=black:s=${HARDCORE_VIDEO_PROBE_SIZE}:r=30" -frames:v 8
                -c:v "$HARDCORE_VIDEO_CAPABILITY_FFMPEG_ENCODER" -global_quality:v 33 -preset:v medium ) ;;
        *_videotoolbox)
            command+=( -f lavfi -i "color=c=black:s=${HARDCORE_VIDEO_PROBE_SIZE}:r=30" -frames:v 8
                -c:v "$HARDCORE_VIDEO_CAPABILITY_FFMPEG_ENCODER" -q:v 65 -pix_fmt nv12 ) ;;
        libsvtav1)
            command+=( -f lavfi -i "color=c=black:s=${HARDCORE_VIDEO_PROBE_SIZE}:r=30" -frames:v 8
                -c:v libsvtav1 -crf:v 35 -preset:v 10 -pix_fmt yuv420p ) ;;
        libx265)
            command+=( -f lavfi -i "color=c=black:s=${HARDCORE_VIDEO_PROBE_SIZE}:r=30" -frames:v 8
                -c:v libx265 -crf:v 28 -preset:v ultrafast -pix_fmt yuv420p ) ;;
    esac
    command+=( -an -sn -dn -f matroska "$out" )

    if hardcore_video_probe_run_bounded "$HARDCORE_VIDEO_PROBE_TIMEOUT" "${command[@]}" >/dev/null 2>"$err"; then
        rc=0
    else
        rc=$?
        VIDEO_PROBE_ERROR=$(tail -n 12 "$err" 2>/dev/null || true)
        [[ -n $VIDEO_PROBE_ERROR ]] || VIDEO_PROBE_ERROR="Encoder process failed or timed out (status $rc)."
        rm -rf -- "$tmp"
        return 1
    fi
    if [[ ! -s $out ]]; then
        VIDEO_PROBE_ERROR='Encoder exited successfully but produced an empty output.'
        rm -rf -- "$tmp"
        return 1
    fi
    ignored_line=$(awk '/AVOption .* has not been used for any stream|No quality level set; using default/ {print; exit}' "$err" 2>/dev/null || true)
    if [[ -n $ignored_line ]]; then
        VIDEO_PROBE_ERROR="FFmpeg ignored required encoder options: $ignored_line"
        rm -rf -- "$tmp"
        return 1
    fi
    actual=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$out" 2>"$err" | head -n1 || true)
    if [[ $actual != "$codec" ]]; then
        VIDEO_PROBE_ERROR="Encoder probe produced codec '${actual:-none}' instead of '$codec'."
        rm -rf -- "$tmp"
        return 1
    fi
    decode_command=(ffmpeg -hide_banner -v error -nostdin -i "$out" -map '0:V:0' -f null -)
    if ! hardcore_video_probe_run_bounded "$HARDCORE_VIDEO_PROBE_TIMEOUT" "${decode_command[@]}" >/dev/null 2>"$err"; then
        VIDEO_PROBE_ERROR="Encoder output failed a complete decode: $(tail -n 12 "$err" 2>/dev/null || true)"
        rm -rf -- "$tmp"
        return 1
    fi
    rm -rf -- "$tmp"
    VIDEO_PROBE_ERROR=''
    return 0
}

probe_video_encoder_capability() {
    hardcore_video_encoder_capability_probe "$@"
}

probe_hardware_encoder() {
    hardcore_video_encoder_auto_eligible "$2" || {
        VIDEO_PROBE_ERROR="Encoder '$2' is software/manual-only and cannot be probed as AUTO hardware."
        return 1
    }
    probe_video_encoder_capability "$@"
}

probe_software_encoder() {
    [[ $(hardcore_video_encoder_class "$2" 2>/dev/null || true) == software ]] || {
        VIDEO_PROBE_ERROR="Encoder '$2' is not a supported software/manual-only encoder."
        return 1
    }
    probe_video_encoder_capability "$@"
}
