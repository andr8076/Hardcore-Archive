#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TARGET_HEIGHT=1080
DENOISE_FILTER='hqdn3d=1.2:1.0:3.0:2.5'
source "$ROOT/lib/video-acceleration.sh"
hardcore_video_accel_init

hardcore_video_encoder_command() {
    [[ $1 == hevc_qsv_legacy ]] || return 1
    HARDCORE_VIDEO_ENCODER_COMMAND=(
        env INTEL_MEDIA_RUNTIME=MSDK
        LD_LIBRARY_PATH=/runtime/intel-legacy/lib
        LIBVA_DRIVERS_PATH=/runtime/intel-legacy/lib/dri
        LIBVA_DRIVER_NAME=iHD
        /runtime/intel-legacy/bin/ffmpeg
    )
    HARDCORE_VIDEO_FFMPEG_ENCODER=hevc_qsv
}
ffprobe() {
    local previous='' argument
    for argument in "$@"; do
        if [[ $previous == -select_streams ]]; then
            [[ $argument == V ]] && { printf '0\n'; return 0; }
            [[ $argument == v ]] && { printf '0\n1\n'; return 0; }
        fi
        previous=$argument
    done
    return 1
}

input=/source/input.mov
temporary=/stage/output.mkv
video_encoder=hevc_qsv_legacy
encoder_args=(-load_plugin hevc_hw -low_power 0 -global_quality:v 28 -preset:v medium)
audio_args=(-c:a:0 copy)
CAL_FILTER_CHAIN=''
apply_scaling=true
apply_denoise=false
video_pix_fmt=nv12
HARDCORE_VIDEO_PIPELINES[hevc_qsv_legacy]=cpu

hardcore_video_build_full_command
serialized=$(printf '%q ' "${command[@]}")
[[ ${command[0]} == env ]]
[[ $serialized == *'/runtime/intel-legacy/bin/ffmpeg'* ]]
[[ $serialized == *'INTEL_MEDIA_RUNTIME=MSDK'* ]]
[[ $serialized == *'LIBVA_DRIVERS_PATH=/runtime/intel-legacy/lib/dri'* ]]
[[ $serialized == *'-c:v:0 hevc_qsv'* ]]
[[ $serialized == *'-load_plugin hevc_hw'* ]]
[[ $serialized == *'-low_power 0'* ]]
[[ $serialized == *'-map_metadata 0'* ]]
[[ $serialized == *'-map_chapters 0'* ]]
[[ $serialized == *'-map 0:a\?'* ]]
[[ $serialized == *'-map 0:s\?'* ]]
[[ $serialized == *'-map 0:d\?'* ]]
[[ $serialized == *'-c:a:0 copy'* ]]
[[ $serialized == *'scale=-2:1080:flags=lanczos'* ]]

printf 'Intel legacy production-command tests passed.\n'
