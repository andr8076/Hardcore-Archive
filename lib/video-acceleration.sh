#!/usr/bin/env bash

# State belongs to one video helper, not to the parent archive or other files.
# Export functions so batch/nested helper shells use this checked-in module.
hardcore_video_accel_init() {
    [[ ${HARDCORE_VIDEO_ACCEL_INITIALIZED:-0} == 1 ]] && return 0
    declare -gA HARDCORE_VIDEO_PIPELINES=() HARDCORE_VIDEO_DOWNLOAD_FORMATS=() HARDCORE_VIDEO_START_MODES=()
    HARDCORE_VIDEO_ACCEL_INITIALIZED=1
}

hardcore_video_accel_mode() {
    hardcore_video_accel_init
    printf '%s' "${HARDCORE_VIDEO_PIPELINES[$1]:-cpu}"
}

hardcore_video_accel_prepare() {
    local encoder=$1 pixel_format mode=cpu download=''
    hardcore_video_accel_init
    [[ -z ${HARDCORE_VIDEO_PIPELINES[$encoder]:-} ]] || return 0
    HARDCORE_VIDEO_PIPELINES[$encoder]=cpu
    HARDCORE_VIDEO_START_MODES[$encoder]=cpu
    [[ ${HARDCORE_ARCHIVE_VIDEO_ACCELERATION:-auto} == auto ]] || return 0
    case "$encoder" in *_vaapi|*_nvenc) ;; *) return 0 ;; esac
    pixel_format=$(ffprobe -v error -select_streams V:0 -show_entries stream=pix_fmt \
        -of default=nw=1:nk=1 "$input" 2>/dev/null) || pixel_format=''
    case "$pixel_format" in
        yuv420p|yuvj420p|nv12) download=nv12 ;;
        yuv420p10le|p010le) download=p010le ;;
        *) printf 'GPU preprocessing: source pixel format %s uses CPU compatibility path.\n' "${pixel_format:-unknown}"; return 0 ;;
    esac
    HARDCORE_VIDEO_DOWNLOAD_FORMATS[$encoder]=$download
    # A usable encoder does not imply a usable decoder or scaler. Actual
    # calibration samples test the complete path; failures demote it below.
    mode=hybrid
    if [[ ${apply_denoise:-false} != true && ${quality_check:-off} != off && ${HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS:-auto} == auto ]]; then
        case "$encoder" in
            *_vaapi) has_filter scale_vaapi && mode=gpu ;;
            *_nvenc) has_filter scale_cuda && mode=gpu ;;
        esac
    fi
    HARDCORE_VIDEO_PIPELINES[$encoder]=$mode
    HARDCORE_VIDEO_START_MODES[$encoder]=$mode
    hardcore_video_accel_describe "$encoder"
}

hardcore_video_accel_describe() {
    local encoder=$1 mode
    mode=$(hardcore_video_accel_mode "$encoder")
    case "$mode" in
        gpu) printf 'Video preprocessing via %s: GPU decoding and GPU scaling/format conversion.\n' "$encoder" ;;
        hybrid) printf 'Video preprocessing via %s: GPU decoding, CPU filtering.\n' "$encoder" ;;
        cpu) printf 'Video preprocessing via %s: CPU decoding and filtering; hardware encoding retained.\n' "$encoder" ;;
    esac
}

hardcore_video_accel_demote() {
    local encoder=$1 mode
    mode=$(hardcore_video_accel_mode "$encoder")
    case "$mode" in
        gpu) HARDCORE_VIDEO_PIPELINES[$encoder]=hybrid ;;
        hybrid) HARDCORE_VIDEO_PIPELINES[$encoder]=cpu ;;
        *) return 1 ;;
    esac
    printf 'Preprocessing attempt failed; retrying a compatible path and recalibrating.\n'
    hardcore_video_accel_describe "$encoder"
}

hardcore_video_accel_force_cpu() {
    local encoder=$1
    [[ $(hardcore_video_accel_mode "$encoder") != cpu ]] || return 1
    HARDCORE_VIDEO_PIPELINES[$encoder]=cpu
    HARDCORE_VIDEO_START_MODES[$encoder]=cpu
    printf 'Accelerated full-video attempt failed; retrying with CPU preprocessing and fresh calibration.\n'
    hardcore_video_accel_describe "$encoder"
}

hardcore_video_accel_signature() {
    local encoder=$1 mode
    hardcore_video_accel_init
    mode=$(hardcore_video_accel_mode "$encoder")
    printf 'video-preprocessing-v1:%s:%s:%s' "$mode" \
        "${HARDCORE_VIDEO_DOWNLOAD_FORMATS[$encoder]:-}" "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}"
}

# Separate from quality records: remembers which already-compared path to
# revalidate. Source identity, raw profile, encoder/build/device and software
# filters come from the existing per-video key. Policy changes reopen selection.
hardcore_video_selection_prepare() {
    local codec=$1 encoder=$2 start_mode=$3 key saved_mode
    local CAL_CACHE_FILE='' CAL_FILE_CACHE_FILE=''
    HARDCORE_VIDEO_SELECTION_FILE=''
    saved_mode=$(hardcore_video_accel_mode "$encoder")
    HARDCORE_VIDEO_PIPELINES[$encoder]=cpu
    calibration_cache_prepare "$codec" "$encoder"
    HARDCORE_VIDEO_PIPELINES[$encoder]=$saved_mode
    [[ -n $CAL_FILE_CACHE_FILE ]] || return 0
    key=$(printf '%s\0' 'preprocessing-selection-v1' "$CAL_FILE_CACHE_FILE" "$start_mode" \
        "${HARDCORE_ARCHIVE_VIDEO_ACCELERATION:-auto}" "${HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS:-auto}" \
        "$min_savings_percent" "$estimated_output_audio_bps" "$original_size" "$duration" |
        sha256sum | awk '{print $1}') || return 0
    [[ $key =~ ^[a-f0-9]{64}$ ]] || return 0
    HARDCORE_VIDEO_SELECTION_FILE="${CAL_FILE_CACHE_FILE%/*}/selection-$key"
}

hardcore_video_selection_read() {
    local version kind mode timestamp extra size now file=${HARDCORE_VIDEO_SELECTION_FILE:-}
    [[ -n $file && -f $file && ! -L $file && -O $file ]] || return 1
    size=$(stat -c '%s' -- "$file" 2>/dev/null) || return 1
    (( size > 0 && size <= 128 )) || return 1
    IFS=$'\t' read -r version kind mode timestamp extra < "$file" || return 1
    [[ $version == v1 && $kind =~ ^(boundary|rejected)$ && $mode =~ ^(gpu|hybrid|cpu)$ &&
       $timestamp =~ ^[1-9][0-9]{0,10}$ && -z $extra ]] || return 1
    [[ $kind != rejected || $mode == cpu ]] || return 1
    [[ $(<"$file") == "$version"$'\t'"$kind"$'\t'"$mode"$'\t'"$timestamp" ]] || return 1
    now=$(date +%s) || return 1
    # Do not refresh this timestamp on cache hits: periodically reopen the
    # alternatives even if the source never changes.
    (( timestamp <= now && now - timestamp <= 2592000 )) || return 1
    printf '%s\t%s' "$kind" "$mode"
}

hardcore_video_selection_write() {
    local kind=$1 mode=$2 file=${HARDCORE_VIDEO_SELECTION_FILE:-} temporary_cache timestamp
    [[ -n $file && ! -L $file && -d ${file%/*} && ! -L ${file%/*} && -O ${file%/*} ]] || return 0
    [[ ! -e $file || ( -f $file && -O $file ) ]] || return 0
    timestamp=$(date +%s) || return 0
    temporary_cache=$(mktemp "${file}.XXXXXX" 2>/dev/null) || return 0
    if ! printf 'v1\t%s\t%s\t%s\n' "$kind" "$mode" "$timestamp" > "$temporary_cache" ||
       ! mv -fT -- "$temporary_cache" "$file" 2>/dev/null; then
        rm -f -- "$temporary_cache"
    fi
    return 0
}

hardcore_video_selection_forget() {
    local file=${HARDCORE_VIDEO_SELECTION_FILE:-}
    [[ -n $file && -f $file && ! -L $file && -O $file ]] || return 0
    rm -f -- "$file"
}

# Only called for independently quality-valid candidates with equal predicted
# compression. Time one identical, bounded window per finalist, excluding VMAF.
# This is an encode benchmark, never substitute evidence for a quality check.
hardcore_video_speed_probe() {
    local codec=$1 encoder=$2 quality=$3 mode length start file began ended actual rc=0
    local -a CAL_COMMAND=()
    HARDCORE_VIDEO_PROBE_NS=''
    mode=$(hardcore_video_accel_mode "$encoder")
    length=$(LC_NUMERIC=C awk -v d="$duration" 'BEGIN {if(d>12)d=12; printf "%.3f",d}')
    start=$(LC_NUMERIC=C awk -v d="$duration" -v l="$length" 'BEGIN {printf "%.3f",(d-l)/2}')
    file="${output_dir}/.${output_name}.speed-${codec}-${mode}.$$.mkv"
    preflight_files+=("$file")
    rm -f -- "$file"
    calibration_candidate_command "$encoder" "$quality" "$start" "$length" "$file" || return 1
    began=$(python3 -c 'import time; print(time.monotonic_ns())') || return 1
    "${CAL_COMMAND[@]}" || rc=$?
    ended=$(python3 -c 'import time; print(time.monotonic_ns())') || rc=1
    actual=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$file" 2>/dev/null) || rc=1
    [[ -s $file && $actual =~ ^[0-9]+([.][0-9]+)?$ ]] || rc=1
    rm -f -- "$file"
    (( rc == 0 )) || return 1
    LC_NUMERIC=C awk -v a="$actual" -v l="$length" 'BEGIN {d=a-l; if(d<0)d=-d; exit !(a>0 && d<=0.5)}' || return 1
    [[ $began =~ ^[0-9]{1,18}$ && $ended =~ ^[0-9]{1,18}$ ]] && (( ended > began )) || return 1
    HARDCORE_VIDEO_PROBE_NS=$((ended - began))
    printf 'Preprocessing speed probe: %s, %ss video, %ss encoding.\n' "$mode" "$length" \
        "$(LC_NUMERIC=C awk -v ns="$HARDCORE_VIDEO_PROBE_NS" 'BEGIN {printf "%.3f",ns/1000000000}')"
}

# Device options are global; decoding options must precede the source -i.
hardcore_video_accel_arguments() {
    local encoder=$1 mode
    hardcore_video_accel_init
    mode=$(hardcore_video_accel_mode "$encoder")
    HARDCORE_VIDEO_DEVICE_ARGS=()
    HARDCORE_VIDEO_INPUT_ARGS=()
    HARDCORE_VIDEO_OUTPUT_ARGS=()
    case "$encoder" in
        *_vaapi)
            HARDCORE_VIDEO_DEVICE_ARGS=(-init_hw_device "vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" -filter_hw_device va)
            [[ $mode == cpu ]] || HARDCORE_VIDEO_INPUT_ARGS=(-hwaccel vaapi -hwaccel_device va -hwaccel_output_format vaapi)
            ;;
        *_nvenc)
            HARDCORE_VIDEO_OUTPUT_ARGS=(-gpu:v "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}")
            if [[ $mode != cpu ]]; then
                HARDCORE_VIDEO_DEVICE_ARGS=(-init_hw_device "cuda=ha:${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}" -filter_hw_device ha)
                HARDCORE_VIDEO_INPUT_ARGS=(-hwaccel cuda -hwaccel_device ha -hwaccel_output_format cuda)
            fi
            [[ $mode == gpu ]] || HARDCORE_VIDEO_OUTPUT_ARGS+=(-pix_fmt:v p010le)
            ;;
        *) HARDCORE_VIDEO_OUTPUT_ARGS=(-pix_fmt:v "${video_pix_fmt:-p010le}") ;;
    esac
    # libdav1d may be the default AV1 decoder; the native decoder exposes
    # VAAPI/NVDEC acceleration. Remove this override on CPU fallback.
    if [[ $mode != cpu && ${source_video_codec:-} == av1 ]]; then
        HARDCORE_VIDEO_INPUT_ARGS+=(-c:v av1)
    fi
}

hardcore_video_accel_filter() {
    local encoder=$1 mode size format
    local -a filters=()
    hardcore_video_accel_init
    mode=$(hardcore_video_accel_mode "$encoder")
    if [[ $mode == gpu ]]; then
        size=''
        [[ ${apply_scaling:-false} != true ]] || size="w=-2:h=${TARGET_HEIGHT}:"
        case "$encoder" in
            *_vaapi) filters+=("scale_vaapi=${size}format=nv12:mode=hq") ;;
            *_nvenc) filters+=("scale_cuda=${size}format=p010le:interp_algo=lanczos:passthrough=0") ;;
        esac
    else
        if [[ $mode == hybrid ]]; then
            format=${HARDCORE_VIDEO_DOWNLOAD_FORMATS[$encoder]}
            filters+=(hwdownload "format=$format")
        fi
        [[ ${apply_denoise:-false} != true ]] || filters+=("$DENOISE_FILTER")
        [[ ${apply_scaling:-false} != true ]] || filters+=("scale=-2:${TARGET_HEIGHT}:flags=lanczos")
        [[ $encoder != *_vaapi ]] || filters+=(format=nv12 hwupload)
    fi
    CAL_FILTER_CHAIN=''
    ((${#filters[@]} == 0)) || CAL_FILTER_CHAIN=$(IFS=,; printf '%s' "${filters[*]}")
    return 0
}

hardcore_video_build_full_command() {
    hardcore_video_accel_arguments "$video_encoder"
    hardcore_video_accel_filter "$video_encoder"
    command=(ffmpeg -hide_banner -nostdin -y "${HARDCORE_VIDEO_DEVICE_ARGS[@]}"
        "${HARDCORE_VIDEO_INPUT_ARGS[@]}" -i "$input"
        -map '0:V:0' -map '0:a?' -map '0:s?' -map '0:t?'
        -map_metadata 0 -map_chapters 0
        -c:v "$video_encoder" "${encoder_args[@]}" "${HARDCORE_VIDEO_OUTPUT_ARGS[@]}"
        -c:s copy -c:t copy -max_muxing_queue_size 4096)
    [[ -z $CAL_FILTER_CHAIN ]] || command+=(-vf "$CAL_FILTER_CHAIN")
    command+=("${audio_args[@]}" "$temporary")
}

hardcore_video_encode_attempt() {
    local actual_codec output_duration duration_difference
    local -a command=()
    hardcore_video_build_full_command
    hardcore_video_accel_describe "$video_encoder"
    printf 'FFmpeg command:'
    printf ' %q' "${command[@]}"
    printf '\nStarting FFmpeg\n'
    hardcore_timed video_encoding "${command[@]}" || return 1
    actual_codec=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name \
        -of default=nw=1:nk=1 "$temporary" | head -n1) || return 1
    [[ $actual_codec == "$expected_codec" ]] || { printf 'Codec validation failed.\n'; return 1; }
    output_duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$temporary" | head -n1) || return 1
    [[ $output_duration =~ ^[0-9]+([.][0-9]+)?$ ]] || { printf 'Output duration unavailable.\n'; return 1; }
    duration_difference=$(LC_NUMERIC=C awk -v original="${duration:-0}" -v output="$output_duration" \
        'BEGIN {d=original-output; if(d<0)d=-d; printf "%.6f",d}')
    if LC_NUMERIC=C awk -v difference="$duration_difference" 'BEGIN {exit !(difference>2.0)}'; then
        printf 'Output duration validation failed.\n'; return 1
    fi
    # Keep an independent software decode audit even when the encode path is
    # accelerated. Decoder errors are fatal; a damaged output is never kept.
    printf '\nEncoding completed. Running full decode validation (CPU)...\n'
    hardcore_timed video_decode_validation ffmpeg -v error -xerror -nostdin -i "$temporary" \
        -map '0:V:0' -map '0:a?' -f null -
}

hardcore_video_encode_full() {
    local attempt=0
    hardcore_video_accel_prepare "$video_encoder"
    while (( attempt < 3 )); do
        attempt=$((attempt + 1))
        rm -f -- "$temporary"
        if hardcore_video_encode_attempt; then return 0; fi
        rm -f -- "$temporary"
        # At most one full retry for each of AUTO's two hardware encoders.
        # Never reuse GPU-filter calibration after changing preprocessing.
        (( attempt < 3 )) && hardcore_video_accel_force_cpu "$video_encoder" || return 1
        calibrate_and_choose_video_codec || return 1
        run_video_preflight || return 1
    done
    return 1
}

export -f hardcore_video_accel_init hardcore_video_accel_mode hardcore_video_accel_prepare
export -f hardcore_video_accel_describe hardcore_video_accel_demote hardcore_video_accel_force_cpu
export -f hardcore_video_accel_signature hardcore_video_accel_arguments hardcore_video_accel_filter
export -f hardcore_video_selection_prepare hardcore_video_selection_read hardcore_video_selection_write hardcore_video_selection_forget hardcore_video_speed_probe
export -f hardcore_video_build_full_command hardcore_video_encode_attempt hardcore_video_encode_full
