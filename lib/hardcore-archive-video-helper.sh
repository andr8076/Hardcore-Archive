#!/usr/bin/env bash
set -o pipefail

readonly TARGET_HEIGHT=1080
readonly AV1_CRF=33
readonly AV1_PRESET=2
readonly HEVC_CRF=28
readonly HEVC_PRESET=slow
readonly DENOISE_FILTER='hqdn3d=1.2:1.0:3.0:2.5'
readonly SCRIPT_VERSION='2026-09-07-integrated-video-r5'

codec_choice='av1'
force_encoder=''
min_savings_percent='0'
assume_yes=false
keep_larger=false
automatic_audio=true
allow_scaling=true
allow_denoise=true
video_preflight=true
quality_check=auto
quality_vmaf_threshold=''
quality_ssim_threshold=0.985
video_quality_validation=${HARDCORE_ARCHIVE_VIDEO_QUALITY_VALIDATION:-sampled}
video_quality_sample_seconds=${HARDCORE_ARCHIVE_VIDEO_QUALITY_SAMPLE_SECONDS:-4}
video_quality_interval_seconds=${HARDCORE_ARCHIVE_VIDEO_QUALITY_INTERVAL_SECONDS:-300}
video_quality_min_samples=${HARDCORE_ARCHIVE_VIDEO_QUALITY_MIN_SAMPLES:-5}
video_quality_max_samples=${HARDCORE_ARCHIVE_VIDEO_QUALITY_MAX_SAMPLES:-16}
video_quality_complexity_samples=${HARDCORE_ARCHIVE_VIDEO_QUALITY_COMPLEXITY_SAMPLES:-2}
video_quality_low_percentile=${HARDCORE_ARCHIVE_VIDEO_QUALITY_LOW_PERCENTILE:-10}
video_quality_percentile_delta=${HARDCORE_ARCHIVE_VIDEO_QUALITY_PERCENTILE_DELTA:-4}
video_quality_sustained_delta=${HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_DELTA:-6}
video_quality_sustained_seconds=${HARDCORE_ARCHIVE_VIDEO_QUALITY_SUSTAINED_SECONDS:-1}
video_quality_retries=${HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRIES:-1}
video_quality_retry_step=${HARDCORE_ARCHIVE_VIDEO_QUALITY_RETRY_STEP:-2}
preflight_sample_seconds=12
preflight_min_duration=60
preflight_min_size=$((128 * 1024 * 1024))
preflight_files=()
replace_original=false
batch_mode=false
inhibit_pid=''

usage() {
    cat <<'USAGE'
Usage:
  compress-video [options] INPUT [OUTPUT.mkv]
  compress-video --batch [options] DIRECTORY

Options:
  --batch           Recursively process supported videos in DIRECTORY.
  --av1             Use AV1. Default.
  --hevc, --h265    Use H.265/HEVC.
  --list-encoders   List all successfully probed encoders on this system and exit.
  --encoder NAME    Force a specific encoder (e.g., hevc_videotoolbox). Bypasses auto-select.
  --yes, -y         Accept automatic recommendations and confirmations.
  --replace         Replace each source after successful validation.
                    Non-MKV input becomes NAME.mkv; MKV keeps its name.
  --keep-larger     Keep a valid result even if it is not smaller.
  --no-audio        Copy all audio streams unchanged.
  --no-scale        Never reduce resolution.
  --no-denoise      Never apply denoising.
  --min-savings P   Keep the transcode only if it saves at least P percent.
  --quality-vmaf V  Minimum accepted VMAF score (required).
  --no-preflight    Do not test representative segments before a full encode.
  --quality-check M  Sample-quality policy: auto, off, or required.
  --version         Show the script version.
  --help, -h        Show this help.
USAGE
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
[[ -n ${HARDCORE_ARCHIVE_VIDEO_QUALITY_FINAL_SH:-} && -f ${HARDCORE_ARCHIVE_VIDEO_QUALITY_FINAL_SH:-} ]] || die 'Completed-video quality runner is unavailable.'
source "$HARDCORE_ARCHIVE_VIDEO_QUALITY_FINAL_SH"
has_command() { command -v "$1" >/dev/null 2>&1; }
# HARDCORE_MEDIA_NESTED_FIX_V1
has_encoder() { ffmpeg -hide_banner -encoders 2>/dev/null | awk -v wanted="$1" 'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'; }
has_filter() { ffmpeg -hide_banner -filters 2>/dev/null | awk -v wanted="$1" 'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'; }
human_size() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }

prevent_sleep() {
    [[ "${_IS_CHILD_PROCESS:-0}" == "1" ]] && return 0
    export _IS_CHILD_PROCESS=1

    if has_command systemd-inhibit; then
        systemd-inhibit --what=sleep:idle --who="compress-video" --why="Video encoding in progress" sleep 31536000 >/dev/null 2>&1 &
        inhibit_pid=$!
    elif has_command caffeinate; then
        caffeinate -i -m sleep 31536000 >/dev/null 2>&1 &
        inhibit_pid=$!
    elif has_command gnome-session-inhibit; then
        gnome-session-inhibit --inhibit suspend:idle sleep 31536000 >/dev/null 2>&1 &
        inhibit_pid=$!
    fi

    if [[ -n "$inhibit_pid" ]]; then
        disown "$inhibit_pid" 2>/dev/null || true
    fi
}

probe_encoder_synthetic() {
    local enc="$1"
    shift 1
    has_encoder "$enc" || return 1

    local va_probe=()
    [[ "$enc" == *_vaapi ]] && va_probe=("-init_hw_device" "vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" "-filter_hw_device" "va" "-vf" "format=nv12,hwupload")

    ffmpeg -hide_banner -v error "${va_probe[@]}" -f lavfi -i color=c=black:s=1280x720:r=24 -vframes 1 \
        -c:v "$enc" "$@" -f null - >/dev/null 2>&1
}

do_list_encoders() {
    for required in ffmpeg; do has_command "$required" || die "Missing command: $required"; done
    printf "Probing system for working encoders (Synthetic 720p Test)...\n\n"

    printf "AV1 Encoders:\n"
    probe_encoder_synthetic av1_vaapi -rc_mode CQP -global_quality:v 33 && printf "  av1_vaapi          (AMD/Mesa VA-API Linux Hardware)\n"
    probe_encoder_synthetic av1_nvenc -cq:v 33 -preset:v p4 && printf "  av1_nvenc          (NVIDIA NVENC)\n"
    probe_encoder_synthetic av1_qsv -global_quality:v 33 -preset:v balanced && printf "  av1_qsv            (Intel QSV)\n"
    has_encoder libsvtav1 && printf "  libsvtav1          (Software SVT-AV1)\n"

    printf "\nHEVC / H.265 Encoders:\n"
    probe_encoder_synthetic hevc_videotoolbox -q:v 65 -pix_fmt nv12 && printf "  hevc_videotoolbox  (Apple VideoToolbox Hardware)\n"
    probe_encoder_synthetic hevc_vaapi -rc_mode CQP -global_quality:v 28 && printf "  hevc_vaapi         (AMD/Mesa VA-API Linux Hardware)\n"
    probe_encoder_synthetic hevc_nvenc -cq:v 28 -preset:v p4 && printf "  hevc_nvenc         (NVIDIA NVENC)\n"
    probe_encoder_synthetic hevc_qsv -global_quality:v 28 -preset:v balanced && printf "  hevc_qsv           (Intel QSV)\n"
    has_encoder libx265 && printf "  libx265            (Software x265)\n"

    printf "\nUsage: compress-video --encoder <name> INPUT\n"
}

apply_encoder() {
    local enc="$1"
    video_encoder="$enc"
    case "$enc" in
        av1_vaapi)
            expected_codec='av1'; output_suffix='av1'; video_codec_label='AV1 / VA-API (Hardware)'
            # HARDCORE_VIDEO_CODEC_COMPETITION_V2
            video_crf="CQP q_idx 128 (pre-calibration)"; video_preset='N/A'; video_pix_fmt='vaapi'
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "128")
            ;;
        hevc_videotoolbox)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / Apple VideoToolbox (Hardware)'
            video_crf='Quality 65'; video_preset='N/A'; video_pix_fmt='nv12'
            encoder_args=("-q:v" "65")
            ;;
        hevc_vaapi)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / VA-API (Hardware)'
            video_crf="CQP QP 26 (pre-calibration)"; video_preset='N/A'; video_pix_fmt='vaapi'
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "26")
            ;;
        av1_nvenc)
            expected_codec='av1'; output_suffix='av1'; video_codec_label='AV1 / NVIDIA NVENC (Hardware)'
            video_crf="CQ ${AV1_CRF}"; video_preset='p4'; video_pix_fmt='p010le'
            encoder_args=("-cq:v" "$AV1_CRF" "-preset:v" "p4")
            ;;
        av1_qsv)
            expected_codec='av1'; output_suffix='av1'; video_codec_label='AV1 / Intel QSV (Hardware)'
            video_crf="ICQ ${AV1_CRF}"; video_preset='balanced'; video_pix_fmt='p010le'
            encoder_args=("-global_quality:v" "$AV1_CRF" "-preset:v" "balanced")
            ;;
        libsvtav1)
            expected_codec='av1'; output_suffix='av1'; video_codec_label='AV1 / SVT-AV1 (Software)'
            video_crf="CRF ${AV1_CRF}"; video_preset="$AV1_PRESET"; video_pix_fmt='yuv420p10le'
            encoder_args=("-crf:v" "$AV1_CRF" "-preset:v" "$AV1_PRESET")
            ;;
        hevc_nvenc)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / NVIDIA NVENC (Hardware)'
            video_crf="CQ ${HEVC_CRF}"; video_preset='p4'; video_pix_fmt='p010le'
            encoder_args=("-cq:v" "$HEVC_CRF" "-preset:v" "p4")
            ;;
        hevc_qsv)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / Intel QSV (Hardware)'
            video_crf="ICQ ${HEVC_CRF}"; video_preset='balanced'; video_pix_fmt='p010le'
            encoder_args=("-global_quality:v" "$HEVC_CRF" "-preset:v" "balanced")
            ;;
        libx265)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / x265 (Software)'
            video_crf="CRF ${HEVC_CRF}"; video_preset="$HEVC_PRESET"; video_pix_fmt='yuv420p10le'
            encoder_args=("-crf:v" "$HEVC_CRF" "-preset:v" "$HEVC_PRESET")
            ;;
        *)
            die "Unknown or unsupported encoder: $enc. Use --list-encoders to see valid options."
            ;;
    esac
}

determine_encoder() {
    local sample="$1"
    local test_out
    test_out="$(dirname -- "$sample")/.probe_test_$$.mkv"
    probe_temporary="$test_out"

    test_real_encode() {
        local enc="$1" expected="$2"
        shift 2
        printf "  Testing %-20s " "$enc..."

        if ! has_encoder "$enc"; then
            printf "Not available.\n"
            return 1
        fi

        local va_args=()
        if [[ "$enc" == *_vaapi ]]; then
            va_args=("-init_hw_device" "vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" "-filter_hw_device" "va" "-vf" "format=nv12,hwupload")
        elif [[ "$enc" == *_nvenc ]]; then
            va_args=(-gpu:v "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}")
        fi

        if ffmpeg -hide_banner -v error -y -t 2 -i "$sample" "${va_args[@]}" -map '0:V:0' \
            -c:v "$enc" "$@" -an -sn -f matroska "$test_out" >/dev/null 2>&1; then

            local actual_c
            actual_c=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$test_out" 2>/dev/null | head -n1)
            rm -f -- "$test_out"

            if [[ "$actual_c" == "$expected" ]]; then
                printf "Success!\n"
                return 0
            else
                printf "Failed (Output codec mismatch: %s).\n" "${actual_c:-None}"
                return 1
            fi
        else
            rm -f -- "$test_out"
            printf "Failed (Hardware/FFmpeg error).\n"
            return 1
        fi
    }

    printf '\nValidating encoder against real file constraints:\n  %s\n' "$(basename -- "$sample")"

    if [[ -n "$force_encoder" ]]; then
        case "$force_encoder" in
            av1_vaapi|av1_nvenc|av1_qsv|hevc_videotoolbox|hevc_vaapi|hevc_nvenc|hevc_qsv) ;;
            *) die "Software/non-hardware video encoder '$force_encoder' is forbidden. Hardware encoding is mandatory." ;;
        esac
        apply_encoder "$force_encoder"
        if [[ "$force_encoder" != libsvtav1 && "$force_encoder" != libx265 ]]; then
            if [[ ${HARDCORE_ARCHIVE_HARDWARE_ENCODER_LOCKED:-} == "$force_encoder" ]]; then
                printf "  Inherited hardware encoder %s already validated by parent.\n" "$force_encoder"
            else
                test_real_encode "$force_encoder" "$expected_codec" "${encoder_args[@]}" || die "Forced encoder '$force_encoder' crashed on the real file test."
            fi
        else
            has_encoder "$force_encoder" || die "Software encoder '$force_encoder' is missing."
            printf "  Forced software encoder %s accepted.\n" "$force_encoder"
        fi
    else
        case "$codec_choice" in
            av1)
                if test_real_encode av1_vaapi av1 -rc_mode CQP -global_quality:v "$AV1_CRF"; then apply_encoder av1_vaapi
                elif test_real_encode av1_nvenc av1 -cq:v "$AV1_CRF" -preset:v p4; then apply_encoder av1_nvenc
                elif test_real_encode av1_qsv av1 -global_quality:v "$AV1_CRF" -preset:v balanced; then apply_encoder av1_qsv
                else die 'No compatible hardware AV1 encoder successfully processed the sample file.'
                fi
                ;;
            hevc)
                if test_real_encode hevc_videotoolbox hevc -q:v 65 -pix_fmt nv12; then apply_encoder hevc_videotoolbox
                elif test_real_encode hevc_vaapi hevc -rc_mode CQP -global_quality:v "$HEVC_CRF"; then apply_encoder hevc_vaapi
                elif test_real_encode hevc_nvenc hevc -cq:v "$HEVC_CRF" -preset:v p4; then apply_encoder hevc_nvenc
                elif test_real_encode hevc_qsv hevc -global_quality:v "$HEVC_CRF" -preset:v balanced; then apply_encoder hevc_qsv
                else die 'No compatible hardware HEVC encoder successfully processed the sample file.'
                fi
                ;;
        esac
    fi
    probe_temporary=""
}

format_duration() {
    LC_NUMERIC=C awk -v seconds="${1:-0}" 'BEGIN {
        if (seconds == "" || seconds !~ /^[0-9]+([.][0-9]+)?$/) { print "Unknown"; exit }
        total=int(seconds+0.5); printf "%02d:%02d:%02d", int(total/3600), int((total%3600)/60), total%60
    }'
}

ask_yes_no() {
    local question="$1" default="${2:-n}" answer=''
    while true; do
        if [[ "$default" == y ]]; then
            read -r -p "$question [Y/n]: " answer; answer="${answer:-y}"
        else
            read -r -p "$question [y/N]: " answer; answer="${answer:-n}"
        fi
        case "${answer,,}" in y|yes) return 0;; n|no) return 1;; *) printf 'Please enter yes or no.\n';; esac
    done
}

calculate_scaled_width() {
    LC_NUMERIC=C awk -v width="$1" -v height="$2" -v target="$TARGET_HEIGHT" 'BEGIN {
        scaled=width*target/height; scaled=int((scaled/2)+0.5)*2; if (scaled<2) scaled=2; print scaled
    }'
}

stream_count_file() {
    local selector=$1 file=$2
    ffprobe -v error -select_streams "$selector" -show_entries stream=index -of csv=p=0 "$file" |
        sed '/^[[:space:]]*$/d' | wc -l
}

stream_count() {
    stream_count_file "$1" "$input"
}

cleanup() {
    local preflight_file
    if [[ -n "${temporary:-}" && -f "$temporary" ]]; then rm -f -- "$temporary"; fi
    if [[ -n "${probe_temporary:-}" && -f "$probe_temporary" ]]; then rm -f -- "$probe_temporary"; fi
    for preflight_file in "${preflight_files[@]:-}"; do
        [[ -n "$preflight_file" ]] && rm -f -- "$preflight_file"
    done
    if [[ -n "${inhibit_pid:-}" ]] && kill -0 "$inhibit_pid" 2>/dev/null; then
        kill "$inhibit_pid" 2>/dev/null || true
    fi
    if [[ -n ${RESTORE_TEMP:-} && -d ${RESTORE_TEMP:-} && ${RESTORE_COMMITTED:-false} != true ]]; then
        rm -rf --one-file-system -- "$RESTORE_TEMP" 2>/dev/null || true
    fi
    if [[ -n ${RESTORE_LOCK_FD:-} ]]; then
        flock -u "$RESTORE_LOCK_FD" 2>/dev/null || true
        eval "exec ${RESTORE_LOCK_FD}>&-" 2>/dev/null || true
    fi
    [[ -n ${RESTORE_LOCK_FILE:-} ]] && rm -f -- "$RESTORE_LOCK_FILE" 2>/dev/null || true
    local batch_pid
    for batch_pid in "${BATCH_CHILD_PIDS[@]:-}"; do
        [[ -n $batch_pid ]] && kill "$batch_pid" 2>/dev/null || true
    done
    for batch_pid in "${BATCH_CHILD_PIDS[@]:-}"; do
        [[ -n $batch_pid ]] && wait "$batch_pid" 2>/dev/null || true
    done
    [[ -n ${BATCH_ROOT_STAGE_PARENT:-} && -d ${BATCH_ROOT_STAGE_PARENT:-} ]] && rm -rf --one-file-system -- "$BATCH_ROOT_STAGE_PARENT" 2>/dev/null || true
    if [[ -n ${BATCH_LOCK_FD_GLOBAL:-} ]]; then flock -u "$BATCH_LOCK_FD_GLOBAL" 2>/dev/null || true; fi
    [[ -n ${BATCH_LOCK_FILE_GLOBAL:-} ]] && rm -f -- "$BATCH_LOCK_FILE_GLOBAL" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

cleanup_orphaned_partials() {
    local target_dir="$1"
    local recursive="${2:-false}"
    local find_args=("-maxdepth" "1")

    [[ "$recursive" == true ]] && find_args=()

    while IFS= read -r -d '' file; do
        if [[ "$(basename -- "$file")" =~ \.partial\.([0-9]+)\.mkv$ || "$(basename -- "$file")" =~ \.probe_test_([0-9]+)\.mkv$ ]]; then
            local pid="${BASH_REMATCH[1]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                printf "Cleaning up orphaned file from a previous crash: %s\n" "$(basename -- "$file")"
                rm -f -- "$file"
            fi
        fi
    done < <(find "$target_dir" "${find_args[@]}" -type f \( -name ".*.partial.*.mkv" -o -name ".*.probe_test_*.mkv" \) -print0 2>/dev/null)
}

positional=()
while (($#)); do
    case "$1" in
        --list-encoders) do_list_encoders; exit 0;;
        --encoder) force_encoder="$2"; shift;;
        --batch) batch_mode=true;;
        --av1) codec_choice='av1';;
        --hevc|--h265) codec_choice='hevc';;
        --yes|-y) assume_yes=true;;
        --replace) replace_original=true;;
        --keep-larger) keep_larger=true;;
        --no-audio) automatic_audio=false;;
        --no-scale) allow_scaling=false;;
        --no-denoise) allow_denoise=false;;
        --no-preflight) video_preflight=false;;
        --quality-check)
            (($# >= 2)) || die '--quality-check requires auto, off, or required.'
            quality_check=${2,,}; shift
            ;;
        --quality-vmaf)
            (($# >= 2)) || die '--quality-vmaf requires a number.'
            quality_vmaf_threshold=$2; shift
            ;;
        --quality-vmaf=*) quality_vmaf_threshold=${1#*=};;
        --quality-ssim)
            (($# >= 2)) || die '--quality-ssim requires a number.'
            quality_ssim_threshold=$2; shift
            ;;
        --min-savings)
            (($# >= 2)) || die '--min-savings requires a percentage.'
            min_savings_percent=$2
            shift
            ;;
        --min-savings=*) min_savings_percent=${1#*=};;
        --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0;;
        --help|-h) usage; exit 0;;
        --) shift; positional+=("$@"); break;;
        -*) die "Unknown option: $1";;
        *) positional+=("$1");;
    esac
    shift
done

if [[ "$batch_mode" == true ]]; then
    ((${#positional[@]} == 1)) || { usage >&2; exit 2; }
    batch_root="${positional[0]}"
    [[ -d "$batch_root" ]] || die "Batch input is not a directory: $batch_root"
    requested_output=''
else
    ((${#positional[@]} >= 1 && ${#positional[@]} <= 2)) || { usage >&2; exit 2; }
    input="${positional[0]}"
    requested_output="${positional[1]:-}"
    [[ -f "$input" ]] || die "Input does not exist: $input"
    if [[ "$replace_original" == true && -n "$requested_output" ]]; then
        die '--replace chooses the destination automatically; do not provide OUTPUT.'
    fi
fi

for required in ffmpeg ffprobe awk grep sed stat numfmt realpath chmod find; do has_command "$required" || die "Missing command: $required"; done
[[ $min_savings_percent =~ ^[0-9]+([.][0-9]+)?$ ]] || die '--min-savings must be a non-negative number.'
LC_NUMERIC=C awk -v p="$min_savings_percent" 'BEGIN {exit !(p >= 0 && p <= 100)}' || die '--min-savings must be between 0 and 100.'
case "$quality_check" in auto|off|required) ;; *) die '--quality-check must be auto, off, or required.' ;; esac
[[ $quality_vmaf_threshold =~ ^[0-9]+([.][0-9]+)?$ ]] || die '--quality-vmaf must be numeric and explicitly supplied.'
LC_NUMERIC=C awk -v v="$quality_vmaf_threshold" 'BEGIN {exit !(v >= 0 && v <= 100)}' || die '--quality-vmaf must be 0..100.'
LC_NUMERIC=C awk -v v="$quality_ssim_threshold" 'BEGIN {exit !(v >= 0 && v <= 1)}' || die '--quality-ssim must be 0..1.'

prevent_sleep

encoder_args=()
video_pix_fmt='yuv420p10le'

run_batch() {
    local root="$1" script_path file filename lower_name stem target
    local total success=0 failed=0 skipped=0 unchanged=0 rc index=0
    local -a files=() child_args=()
    local -A replacement_targets=()

    script_path=$(realpath -e -- "$0") || die 'Could not resolve the script path.'

    while IFS= read -r -d '' file; do
        filename=$(basename -- "$file")
        lower_name="${filename,,}"
        case "$lower_name" in
            .*\.partial.*|.*\.probe_test_*|*-compressed-av1.mkv|*-compressed-hevc.mkv) continue;;
        esac
        files+=("$file")
    done < <(
        find -L "$root" -type f \
            \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.m4v' \
               -o -iname '*.avi' -o -iname '*.webm' -o -iname '*.wmv' -o -iname '*.flv' \
               -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.m2ts' -o -iname '*.mts' \
               -o -iname '*.ts' -o -iname '*.vob' -o -iname '*.ogv' -o -iname '*.3gp' \
               -o -iname '*.3g2' -o -iname '*.asf' \) -print0
    )

    total=${#files[@]}
    if (( total == 0 )); then
        printf 'No supported video files were found under:\n  %s\n' "$root"
        return 0
    fi

    cleanup_orphaned_partials "$root" true
    determine_encoder "${files[0]}"

    printf '\nBatch plan\n'
    printf '%s\n' '════════════════════════════════════════════════════════════'
    printf 'Directory:          %s\n' "$root"
    printf 'Videos found:       %s\n' "$total"
    printf 'Traversal:          Recursive\n'
    printf 'Processing:         Sequential\n'
    printf 'Video codec:        %s\n' "$video_codec_label"
    if [[ "$replace_original" == true ]]; then
        printf 'Source handling:    Replace after validation\n'
    else
        printf 'Source handling:    Preserve originals\n'
    fi
    printf 'Existing outputs:   Skip safely\n'
    printf 'Per-file choices:   Automatic recommendations\n'
    printf '%s\n' '════════════════════════════════════════════════════════════'

    if [[ "$assume_yes" != true ]]; then
        ask_yes_no "Process $total video files?" y || { printf 'Cancelled.\n'; return 0; }
    fi

    child_args+=(--yes)
    child_args+=(--encoder "$video_encoder")
    [[ "$replace_original" == true ]] && child_args+=(--replace)
    [[ "$keep_larger" == true ]] && child_args+=(--keep-larger)
    [[ "$automatic_audio" != true ]] && child_args+=(--no-audio)
    [[ "$keep_larger" == true ]] && child_args+=(--keep-larger)
    [[ "$allow_scaling" != true ]] && child_args+=(--no-scale)
    [[ "$allow_denoise" != true ]] && child_args+=(--no-denoise)
    [[ "$video_preflight" != true ]] && child_args+=(--no-preflight)
    child_args+=(--quality-check "$quality_check" --quality-vmaf "$quality_vmaf_threshold")
    child_args+=(--min-savings "$min_savings_percent")

    for file in "${files[@]}"; do
        ((index++))
        filename=$(basename -- "$file")
        lower_name="${filename,,}"
        stem="$filename"
        if [[ "$filename" == *.* && "$filename" != .* ]]; then
            stem="${filename%.*}"
        fi

        if [[ "$replace_original" == true ]]; then
            if [[ "$lower_name" == *.mkv ]]; then
                target="$file"
            else
                target="$(dirname -- "$file")/${stem}.mkv"
            fi
        else
            target="$(dirname -- "$file")/${stem}-compressed-${output_suffix}.mkv"
        fi

        source_canonical=$(realpath -e -- "$file") || {
            printf '\n[%s/%s] SKIP: Could not resolve: %s\n' "$index" "$total" "$file"
            ((skipped++))
            continue
        }
        target_canonical=$(realpath -m -- "$target") || {
            printf '\n[%s/%s] SKIP: Could not resolve destination: %s\n' "$index" "$total" "$target"
            ((skipped++))
            continue
        }

        if [[ "$replace_original" == true ]]; then
            if [[ "$source_canonical" != "$target_canonical" && -e "$target" ]]; then
                printf '\n[%s/%s] SKIP: Replacement destination already exists:\n  Source: %s\n  Existing: %s\n' \
                    "$index" "$total" "$file" "$target"
                ((skipped++))
                continue
            fi
            if [[ -n "${replacement_targets[$target_canonical]:-}" && "${replacement_targets[$target_canonical]}" != "$source_canonical" ]]; then
                printf '\n[%s/%s] SKIP: Another source maps to the same replacement name:\n  %s\n' \
                    "$index" "$total" "$target"
                ((skipped++))
                continue
            fi
            replacement_targets[$target_canonical]="$source_canonical"
        elif [[ -e "$target" ]]; then
            printf '\n[%s/%s] SKIP: Output already exists:\n  %s\n' "$index" "$total" "$target"
            ((skipped++))
            continue
        fi

        printf '\n\n[%s/%s] Processing\n  %s\n' "$index" "$total" "$file"

        export _IS_CHILD_PROCESS=1
        if "${BASH:-bash}" "$script_path" "${child_args[@]}" "$file"; then
            ((success++))
        else
            rc=$?
            if (( rc == 3 )); then
                ((unchanged++))
            elif [[ ${HARDCORE_ARCHIVE_NESTED_CHILD:-0} == 1 ]]; then
                ((unchanged++))
                printf 'Nested child video item failed with exit code %s; original preserved and recursion continues.\n' "$rc" >&2
            else
                ((failed++))
                printf 'Batch item failed with exit code %s; continuing.\n' "$rc" >&2
            fi
        fi
    done

    printf '\nBatch summary\n'
    printf '%s\n' '════════════════════════════════════════════════════════════'
    printf 'Found:              %s\n' "$total"
    printf 'Completed:          %s\n' "$success"
    printf 'Unchanged:          %s\n' "$unchanged"
    printf 'Skipped:            %s\n' "$skipped"
    printf 'Failed:             %s\n' "$failed"
    printf '%s\n' '════════════════════════════════════════════════════════════'

    (( failed == 0 ))
}

if [[ "$batch_mode" == true ]]; then
    run_batch "$batch_root"
    exit $?
fi

determine_encoder "$input"

printf '\nAnalysing:\n  %s\n\n' "$input"

width=$(ffprobe -v error -select_streams V:0 -show_entries stream=width -of default=nw=1:nk=1 "$input" | head -n1)
height=$(ffprobe -v error -select_streams V:0 -show_entries stream=height -of default=nw=1:nk=1 "$input" | head -n1)
source_video_codec=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$input" | head -n1)
pixel_format=$(ffprobe -v error -select_streams V:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$input" | head -n1)
frame_rate=$(ffprobe -v error -select_streams V:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$input" | head -n1)
duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$input" | head -n1)
format_bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=nw=1:nk=1 "$input" | head -n1)
format_name=$(ffprobe -v error -show_entries format=format_long_name -of default=nw=1:nk=1 "$input" | head -n1)
color_transfer=$(ffprobe -v error -select_streams V:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$input" | head -n1)
color_primaries=$(ffprobe -v error -select_streams V:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$input" | head -n1)

[[ "$width" =~ ^[0-9]+$ ]] || die 'Could not determine source width.'
[[ "$height" =~ ^[0-9]+$ ]] || die 'Could not determine source height.'
original_size=$(stat -Lc '%s' -- "$input") || die 'Could not determine source size.'
video_stream_count=$(stream_count V)
all_video_stream_count=$(stream_count v)
audio_count=$(stream_count a)
subtitle_count=$(stream_count s)
attachment_count=$(stream_count t)
data_stream_count=$(stream_count d)

if (( video_stream_count < 1 )); then
    printf 'No primary video stream is available for conversion; original preserved unchanged.\n'
    exit 3
fi

hdr_detected=false
case "$color_transfer" in smpte2084|arib-std-b67) hdr_detected=true;; esac
[[ "$color_primaries" == bt2020 ]] && hdr_detected=true

bitrate_display='Unknown'
if [[ "$format_bitrate" =~ ^[0-9]+$ ]]; then
    bitrate_display=$(LC_NUMERIC=C awk -v bitrate="$format_bitrate" 'BEGIN {printf "%.2f Mbit/s", bitrate/1000000}')
fi

printf 'Source analysis\n'
printf '%s\n' '────────────────────────────────────────────────────────────'
printf 'File size:         %s\n' "$(human_size "$original_size")"
printf 'Container:         %s\n' "${format_name:-Unknown}"
printf 'Duration:          %s\n' "$(format_duration "$duration")"
printf 'Video codec:       %s\n' "${source_video_codec:-Unknown}"
printf 'Resolution:        %sx%s\n' "$width" "$height"
printf 'Pixel format:      %s\n' "${pixel_format:-Unknown}"
printf 'Frame rate:        %s\n' "${frame_rate:-Unknown}"
printf 'Total bitrate:     %s\n' "$bitrate_display"
printf 'Video streams:     %s\n' "$video_stream_count"
printf 'All video streams: %s\n' "$all_video_stream_count"
printf 'Audio streams:     %s\n' "$audio_count"
printf 'Subtitle streams:  %s\n' "$subtitle_count"
printf 'Attachments:       %s\n' "$attachment_count"
printf 'HDR detected:      %s\n' "$hdr_detected"

apply_scaling=false
output_width="$width"
output_height="$height"
scaling_reason="Keep ${width}x${height}"

if [[ "$allow_scaling" == true && "$height" -gt "$TARGET_HEIGHT" ]]; then
    proposed_width=$(calculate_scaled_width "$width" "$height")
    should_offer_scaling=false
    if (( original_size >= 2*1024*1024*1024 )); then
        should_offer_scaling=true
    elif (( original_size >= 500*1024*1024 && height > 1440 )); then
        should_offer_scaling=true
    fi

    if [[ "$should_offer_scaling" == true ]]; then
        printf '\nResolution recommendation\n'
        printf '%s\n' '────────────────────────────────────────────────────────────'
        printf 'Current:            %sx%s\n' "$width" "$height"
        printf 'Proposed:           %sx%s\n' "$proposed_width" "$TARGET_HEIGHT"
        if [[ "$assume_yes" == true ]] || ask_yes_no "Reduce ${width}x${height} to ${proposed_width}x${TARGET_HEIGHT}?" y; then
            apply_scaling=true
            output_width="$proposed_width"
            output_height="$TARGET_HEIGHT"
            scaling_reason="${width}x${height} → ${proposed_width}x${TARGET_HEIGHT}"
        fi
    fi
fi

apply_denoise=false
offer_denoise=false
denoise_reason='Disabled'
if [[ "$allow_denoise" == true ]] && has_filter hqdn3d; then
    case "$source_video_codec" in
        mpeg1video|mpeg2video|mpeg4|wmv1|wmv2) offer_denoise=true;;
    esac
    if [[ "$format_bitrate" =~ ^[0-9]+$ ]] && (( height <= 720 && format_bitrate >= 12000000 )); then
        offer_denoise=true
    fi
fi

if [[ "$offer_denoise" == true ]]; then
    printf '\nDenoising recommendation\n'
    printf '%s\n' '────────────────────────────────────────────────────────────'
    if [[ "$assume_yes" == true ]] || ask_yes_no 'Apply mild denoising?' n; then
        apply_denoise=true
        denoise_reason='Mild HQDN3D'
    fi
fi

audio_args=()
audio_plan=()
audio_stream_number=0
estimated_output_audio_bps=0
opus_available=false
has_encoder libopus && opus_available=true

if (( audio_count > 0 )); then
    while IFS='|' read -r codec channels bitrate; do
        [[ -n "$codec" ]] || continue
        [[ "$channels" =~ ^[0-9]+$ ]] || channels=2
        [[ "$bitrate" =~ ^[0-9]+$ ]] || bitrate=0
        convert_audio=false
        case "$channels" in
            1) target_bitrate='80k'; target_bps=80000;;
            2) target_bitrate='128k'; target_bps=128000;;
            3|4) target_bitrate='192k'; target_bps=192000;;
            5|6) target_bitrate='256k'; target_bps=256000;;
            *) target_bitrate='320k'; target_bps=320000;;
        esac

        if [[ "$automatic_audio" == true && "$opus_available" == true ]]; then
            case "$codec" in
                opus) convert_audio=false;;
                pcm_*|flac|truehd|dts) convert_audio=true;;
                aac) (( bitrate == 0 || bitrate > target_bps*5/4 )) && convert_audio=true;;
                *) (( bitrate > target_bps*3/2 )) && convert_audio=true;;
            esac
        fi

        if [[ "$convert_audio" == true ]]; then
            audio_args+=("-c:a:${audio_stream_number}" libopus "-b:a:${audio_stream_number}" "$target_bitrate" "-vbr:a:${audio_stream_number}" on)
            audio_plan+=("Track $((audio_stream_number+1)): ${codec} → Opus ${target_bitrate}")
            estimated_output_audio_bps=$((estimated_output_audio_bps + target_bps))
        else
            audio_args+=("-c:a:${audio_stream_number}" copy)
            audio_plan+=("Track $((audio_stream_number+1)): copy ${codec}")
            if (( bitrate > 0 )); then
                estimated_output_audio_bps=$((estimated_output_audio_bps + bitrate))
            else
                estimated_output_audio_bps=$((estimated_output_audio_bps + 192000))
            fi
        fi
        ((audio_stream_number++))
    done < <(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels,bit_rate -of compact=p=0:nk=1 "$input")
fi

input_dir=$(dirname -- "$input")
input_filename=$(basename -- "$input")
input_stem="$input_filename"
if [[ "$input_filename" == *.* && "$input_filename" != .* ]]; then
    input_stem="${input_filename%.*}"
fi

if [[ "$replace_original" == true ]]; then
    if [[ "${input_filename,,}" == *.mkv ]]; then output="$input"; else output="${input_dir}/${input_stem}.mkv"; fi
elif [[ -n "$requested_output" ]]; then
    output="$requested_output"
else
    output="${input_dir}/${input_stem}-compressed-${output_suffix}.mkv"
fi

input_canonical=$(realpath -e -- "$input") || die 'Could not resolve the input path.'
output_canonical=$(realpath -m -- "$output") || die 'Could not resolve the output path.'
same_output_as_input=false
[[ "$input_canonical" == "$output_canonical" ]] && same_output_as_input=true

output_dir=$(dirname -- "$output")
output_name=$(basename -- "$output")
mkdir -p -- "$output_dir" || die "Could not create output directory: $output_dir"

cleanup_orphaned_partials "$output_dir" false
temporary="${output_dir}/.${output_name}.partial.$$.mkv"

# --- Advanced VA-API Hybrid Filtering ---
# Software processing must happen before uploading to the GPU space.
# Scaling on VA-API handles the format conversions seamlessly.
video_filters=()
if [[ "$video_encoder" == *_vaapi ]]; then
    [[ "$apply_denoise" == true ]] && video_filters+=("$DENOISE_FILTER")
    if [[ "$apply_scaling" == true ]]; then
        video_filters+=("scale=-2:${TARGET_HEIGHT}:flags=lanczos")
    fi
    video_filters+=("format=nv12" "hwupload")
else
    # Regular software/NVENC filtering path
    [[ "$apply_denoise" == true ]] && video_filters+=("$DENOISE_FILTER")
    [[ "$apply_scaling" == true ]] && video_filters+=("scale=-2:${TARGET_HEIGHT}:flags=lanczos")
fi

filter_chain=''
((${#video_filters[@]} > 0)) && filter_chain=$(IFS=,; printf '%s' "${video_filters[*]}")

MEASURED_QUALITY_KIND=''
MEASURED_QUALITY_SCORE=''
QUALITY_WORKER_THREADS=''
QUALITY_VMAF_AVAILABLE=''
QUALITY_VMAF_POLICY_VERSION='source-display-v1'

quality_worker_threads() {
    local requested=${HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS:-auto} available
    if [[ $requested != auto && ! $requested =~ ^([1-9]|[1-5][0-9]|6[0-4])$ ]]; then
        printf 'Error: VIDEO_QUALITY_THREADS must be auto or an integer from 1 to 64.\n' >&2
        return 1
    fi
    available=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
    [[ $available =~ ^[1-9][0-9]{0,5}$ ]] || available=1
    if [[ $requested == auto ]]; then
        requested=$available
        (( requested > 8 )) && requested=8
    fi
    (( requested > available )) && requested=$available
    printf '%s' "$requested"
}

quality_round_even() {
    LC_NUMERIC=C awk -v value="$1" 'BEGIN {
        if (value <= 0) exit 1
        rounded=int(value/2+0.5)*2
        if (rounded < 2) rounded=2
        printf "%.0f", rounded
    }'
}

# Return the square-pixel display canvas represented by coded dimensions, SAR,
# and display rotation. FFmpeg autorotates by default, so 90/270-degree display
# rotation also inverts the pixel aspect ratio when deriving the viewed frame.
quality_display_geometry() {
    local coded_width=$1 coded_height=$2 sar=${3:-1:1} rotation=${4:-0}
    local sar_num=1 sar_den=1 display_width display_height
    [[ $coded_width =~ ^[1-9][0-9]*$ && $coded_height =~ ^[1-9][0-9]*$ ]] || return 1
    if [[ $sar =~ ^([1-9][0-9]*):([1-9][0-9]*)$ ]]; then
        sar_num=${BASH_REMATCH[1]}
        sar_den=${BASH_REMATCH[2]}
    fi
    [[ $rotation =~ ^-?[0-9]+$ ]] || rotation=0
    rotation=$(( (rotation % 360 + 360) % 360 ))
    # First construct the viewed square-pixel raster, then rotate that canvas.
    # For example 720x576 at SAR 16:15 is 768x576, or 576x768 when rotated 90°.
    display_width=$(LC_NUMERIC=C awk -v w="$coded_width" -v n="$sar_num" -v d="$sar_den" \
        'BEGIN {printf "%.9f", w*n/d}')
    display_height=$coded_height
    if (( rotation == 90 || rotation == 270 )); then
        local swapped=$display_width
        display_width=$display_height
        display_height=$swapped
    fi
    display_width=$(quality_round_even "$display_width") || return 1
    display_height=$(quality_round_even "$display_height") || return 1
    printf '%s\t%s' "$display_width" "$display_height"
}

quality_source_display_geometry() {
    local dimensions coded_width coded_height sar rotation
    dimensions=$(ffprobe -v error -select_streams V:0 -show_entries stream=width,height \
        -of csv=p=0:s=x "$input" 2>/dev/null | head -n1) || return 1
    IFS=x read -r coded_width coded_height <<< "$dimensions"
    [[ $coded_width =~ ^[1-9][0-9]*$ && $coded_height =~ ^[1-9][0-9]*$ ]] || return 1
    sar=$(ffprobe -v error -select_streams V:0 -show_entries stream=sample_aspect_ratio \
        -of default=nw=1:nk=1 "$input" 2>/dev/null | head -n1 || true)
    rotation=$(ffprobe -v error -select_streams V:0 -show_entries stream_side_data=rotation \
        -of default=nw=1:nk=1 "$input" 2>/dev/null | head -n1 || true)
    quality_display_geometry "$coded_width" "$coded_height" "$sar" "$rotation"
}

# Keep the existing VMAF v0 score family so the configured floor is not
# silently reinterpreted. Use the official 4K/1.5H legacy model for UHD-or-
# larger source display canvases; otherwise retain the standard 1080p/3H model.
quality_vmaf_model_for_canvas() {
    local width=$1 height=$2 long_side short_side
    [[ $width =~ ^[1-9][0-9]*$ && $height =~ ^[1-9][0-9]*$ ]] || return 1
    if (( width >= height )); then
        long_side=$width; short_side=$height
    else
        long_side=$height; short_side=$width
    fi
    if (( long_side >= 3840 && short_side >= 2160 )); then
        printf 'vmaf_4k_v0.6.1\t4K/1.5H'
    else
        printf 'vmaf_v0.6.1\t1080p/3H'
    fi
}

# Both streams use the same display normalization: convert SAR to square
# pixels, fit without stretching, pad any DAR mismatch, use limited-range
# yuv420p, and compare on the source display canvas. Smaller candidates are
# therefore bicubic-upscaled instead of shrinking the reference to hide lost
# resolution. The identical chain also keeps color/range conversion symmetric.
quality_vmaf_filter_graph() {
    local eval_width=$1 eval_height=$2 log_file=$3 threads=$4 model=$5 ratio normalize fit
    ratio="${eval_width}/${eval_height}"
    normalize="scale=w='max(2,trunc(iw*if(eq(sar,0),1,sar)/2)*2)':h='max(2,trunc(ih/2)*2)':flags=bicubic:in_range=auto:out_range=tv,setsar=1"
    fit="scale=w='if(gt(a,${ratio}),${eval_width},-2)':h='if(gt(a,${ratio}),-2,${eval_height})':flags=bicubic:in_range=tv:out_range=tv,pad=${eval_width}:${eval_height}:(ow-iw)/2:(oh-ih)/2:color=black,setsar=1,format=yuv420p"
    printf '%s' "[0:v:0]settb=AVTB,setpts=PTS-STARTPTS,${normalize},${fit}[ref];[1:v:0]settb=AVTB,setpts=PTS-STARTPTS,${normalize},${fit}[dist];[dist][ref]libvmaf=model='version=${model}':log_fmt=json:log_path=${log_file}:n_threads=${threads}:n_subsample=1:ts_sync_mode=nearest"
}

measure_preflight_quality() {
    local start=$1 length=$2 encoded=$3 geometry eval_width eval_height
    local model_info model model_condition log_file score started filter_graph
    MEASURED_QUALITY_KIND=''
    MEASURED_QUALITY_SCORE=''
    [[ $quality_check != off ]] || return 1

    geometry=$(quality_source_display_geometry) || return 1
    IFS=$'\t' read -r eval_width eval_height <<< "$geometry"
    model_info=$(quality_vmaf_model_for_canvas "$eval_width" "$eval_height") || return 1
    IFS=$'\t' read -r model model_condition <<< "$model_info"

    if [[ -z $QUALITY_WORKER_THREADS ]]; then
        QUALITY_WORKER_THREADS=$(quality_worker_threads) || return 1
    fi
    if [[ -z $QUALITY_VMAF_AVAILABLE ]]; then
        if has_filter libvmaf; then QUALITY_VMAF_AVAILABLE=true; else QUALITY_VMAF_AVAILABLE=false; fi
    fi
    if [[ $QUALITY_VMAF_AVAILABLE == true ]]; then
        log_file="${encoded}.vmaf.json"
        preflight_files+=("$log_file")
        rm -f -- "$log_file"
        printf '\nVMAF scoring: source-display %sx%s, %s (%s), %s CPU worker(s), every sample frame...\n' \
            "$eval_width" "$eval_height" "$model" "$model_condition" "$QUALITY_WORKER_THREADS"
        filter_graph=$(quality_vmaf_filter_graph "$eval_width" "$eval_height" "$log_file" \
            "$QUALITY_WORKER_THREADS" "$model") || return 1
        started=$SECONDS
        # Keep the existing timestamp policy: Matroska sample timestamps can
        # round to milliseconds, so use a common AVTB and nearest framesync.
        # No fps conversion or subsampling is introduced.
        if ffmpeg -hide_banner -v error -nostdin \
            -ss "$start" -t "$length" -i "$input" -i "$encoded" \
            -filter_complex "$filter_graph" \
            -an -f null - >/dev/null 2>&1; then
            printf 'VMAF scoring finished in %ss.\n' "$((SECONDS - started))"
            score=$(python3 - "$log_file" <<'PYVMAF'
import json, math, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as handle:
        value = float(json.load(handle)['pooled_metrics']['vmaf']['mean'])
    if math.isfinite(value) and 0.0 <= value <= 100.0:
        print(f'{value:.6f}')
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
    pass
PYVMAF
)
            if [[ $score =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                MEASURED_QUALITY_KIND=VMAF
                MEASURED_QUALITY_SCORE=$score
                return 0
            fi
        else
            printf 'VMAF scoring failed after %ss.\n' "$((SECONDS - started))"
        fi
    fi

    # Strict quality policy: model/VMAF failure preserves the original; SSIM
    # is never substituted and the configured VMAF threshold is never lowered.
    return 1
}


HARDCORE_AUTO_CODEC_MODE=${HARDCORE_ARCHIVE_VIDEO_CODEC_AUTO:-0}
HARDCORE_AUTO_AV1_ENCODER=${HARDCORE_ARCHIVE_AUTO_AV1_ENCODER:-}
HARDCORE_AUTO_HEVC_ENCODER=${HARDCORE_ARCHIVE_AUTO_HEVC_ENCODER:-}
CAL_MIN_VMAF=''
CAL_AVG_VIDEO_BPS=''
CAL_WORST_POSITION=''
CAL_BEST_QUALITY=''
CAL_PREDICTED_SAVINGS=''
CAL_REQUIRED_SAVINGS=''
CAL_REASON=''
CAL_QUALITY_LABEL=''
CAL_SELECTED_VALIDATED=false
CAL_CACHE_FILE=''
CAL_FILE_CACHE_FILE=''

# Cache entries are hints, never evidence that a different file meets VMAF.
# Version this key when sampling, VMAF normalization or encoder policy changes.
calibration_cache_profile() {
    # Camera average rates vary with clip duration (e.g. 59.9386 vs 60.0053).
    # Group nearby nominal rates, keeping average and declared rates separate
    # and retaining every other profile field. Actual encode timing is untouched.
    python3 - "$1" <<'PYCALPROFILE'
from fractions import Fraction
import re
import sys

fields = []
try:
    for field in sys.argv[1].split("|"):
        name, separator, value = field.partition("=")
        if name in ("avg_frame_rate", "r_frame_rate"):
            if not separator or not re.fullmatch(r"[0-9]{1,12}(?:/[0-9]{1,12})?", value):
                raise ValueError("invalid frame rate")
            rate = Fraction(value)
            if not 0 < rate <= 1000:
                raise ValueError("invalid frame rate")
            nominal = (2 * rate.numerator + rate.denominator) // (2 * rate.denominator)
            if nominal and abs(rate - nominal) <= Fraction(nominal, 100):
                value = f"nominal-{nominal}"
            else:
                value = f"exact-{rate}"
            field = f"{name}={value}"
        fields.append(field)
except (ValueError, ZeroDivisionError):
    # Bad probe data disables reuse, not the current file's full calibration.
    sys.exit(1)
print("|".join(fields))
PYCALPROFILE
}

calibration_cache_prepare() {
    local codec=$1 encoder=$2 directory profile raw_profile ffmpeg_build key identity file_key
    local CAL_FILTER_CHAIN=''
    CAL_CACHE_FILE=''
    CAL_FILE_CACHE_FILE=''
    [[ ${HARDCORE_ARCHIVE_CALIBRATION_CACHE:-true} == true ]] || return 0
    directory=${HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR:-}
    [[ -n $directory ]] || return 0
    profile=$(ffprobe -v error -select_streams V:0 -show_entries \
        stream=codec_name,profile,width,height,pix_fmt,bits_per_raw_sample,avg_frame_rate,r_frame_rate,field_order,sample_aspect_ratio,color_range,color_space,color_transfer,color_primaries \
        -of compact=p=0:nk=0 "$input" 2>/dev/null) || return 0
    [[ -n $profile ]] || return 0
    raw_profile=$profile
    profile=$(calibration_cache_profile "$profile") || return 0
    ffmpeg_build=$(ffmpeg -version 2>/dev/null) || return 0
    [[ -n $ffmpeg_build ]] || return 0
    calibration_build_filter_chain "$encoder"
    key=$(printf '%s\0' 'calibration-v4-source-display-resolution-bicubic-sar-nearest-vmaf-model' \
        "$codec" "$encoder" "${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" \
        "$profile" "$ffmpeg_build" "$CAL_FILTER_CHAIN" \
        "$quality_vmaf_threshold" "$(hardcore_video_accel_signature "$encoder")" | sha256sum | awk '{print $1}') || return 0
    [[ $key =~ ^[a-f0-9]{64}$ ]] || return 0
    (umask 077; mkdir -p -- "$directory") 2>/dev/null || return 0
    [[ -d $directory && ! -L $directory && -O $directory && -w $directory ]] || return 0
    CAL_CACHE_FILE="$directory/$key"
    identity=$(hardcore_calibration_identity "$input" 2>/dev/null) || return 0
    [[ $identity =~ ^[a-f0-9]{64}$ ]] || return 0
    file_key=$(printf '%s\0' 'per-video-calibration-v1' "$key" "$raw_profile" "$identity" |
        sha256sum | awk '{print $1}') || return 0
    [[ $file_key =~ ^[a-f0-9]{64}$ ]] || return 0
    CAL_FILE_CACHE_FILE="$directory/video-$file_key"
}

calibration_cache_read() {
    local low=$1 high=$2 version quality timestamp extra now size
    local CAL_CACHE_FILE=${3-$CAL_CACHE_FILE}
    [[ -n $CAL_CACHE_FILE && -f $CAL_CACHE_FILE && ! -L $CAL_CACHE_FILE && -O $CAL_CACHE_FILE ]] || return 1
    size=$(stat -c '%s' -- "$CAL_CACHE_FILE" 2>/dev/null) || return 1
    (( size > 0 && size <= 128 )) || return 1
    IFS=$'\t' read -r version quality timestamp extra < "$CAL_CACHE_FILE" || return 1
    [[ $version == v1 && -z $extra && $quality =~ ^[1-9][0-9]{0,2}$ && $timestamp =~ ^[1-9][0-9]{0,10}$ ]] || return 1
    (( quality >= low && quality <= high )) || return 1
    now=$(date +%s) || return 1
    # Expire after 30 days; future timestamps and malformed entries are misses.
    (( timestamp <= now && now - timestamp <= 2592000 )) || return 1
    printf '%s' "$quality"
}

calibration_cache_write() {
    local quality=$1 temporary_cache timestamp
    local CAL_CACHE_FILE=${2-$CAL_CACHE_FILE}
    [[ -n $CAL_CACHE_FILE ]] || return 0
    timestamp=$(date +%s) || return 0
    temporary_cache=$(mktemp "${CAL_CACHE_FILE}.XXXXXX" 2>/dev/null) || return 0
    if ! printf 'v1\t%s\t%s\n' "$quality" "$timestamp" > "$temporary_cache" || \
       ! mv -fT -- "$temporary_cache" "$CAL_CACHE_FILE" 2>/dev/null; then
        rm -f -- "$temporary_cache"
    fi
    return 0
}

# Only v2 per-video records certify that a boundary was searched for this file.
# Legacy v1 records remain useful starting hints, including pinned group hits.
calibration_video_cache_read() {
    local low=$1 high=$2 version kind quality timestamp position bps extra size now
    [[ -n $CAL_FILE_CACHE_FILE && -f $CAL_FILE_CACHE_FILE && ! -L $CAL_FILE_CACHE_FILE && -O $CAL_FILE_CACHE_FILE ]] || return 1
    size=$(stat -c '%s' -- "$CAL_FILE_CACHE_FILE" 2>/dev/null) || return 1
    (( size > 0 && size <= 128 )) || return 1
    IFS=$'\t' read -r version kind quality timestamp position bps extra < "$CAL_FILE_CACHE_FILE" || return 1
    [[ $version == v2 && -z $extra && $kind =~ ^(boundary|rejected)$ &&
       $quality =~ ^[1-9][0-9]{0,2}$ && $timestamp =~ ^[1-9][0-9]{0,10}$ &&
       $position =~ ^0\.(10|50|90)$ && $bps =~ ^[1-9][0-9]{0,14}$ ]] || return 1
    (( quality >= low && quality <= high )) || return 1
    # Rejection must have been witnessed at the encoder's highest quality.
    [[ $kind != rejected ]] || (( quality == low )) || return 1
    now=$(date +%s) || return 1
    (( timestamp <= now && now - timestamp <= 2592000 )) || return 1
    printf '%s\t%s\t%s\t%s' "$kind" "$quality" "$position" "$bps"
}

calibration_video_cache_write() {
    local kind=$1 quality=$2 position=$3 bps=$4 temporary_cache timestamp
    [[ -n $CAL_FILE_CACHE_FILE ]] || return 0
    timestamp=$(date +%s) || return 0
    temporary_cache=$(mktemp "${CAL_FILE_CACHE_FILE}.XXXXXX" 2>/dev/null) || return 0
    if ! printf 'v2\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$quality" "$timestamp" "$position" "$bps" > "$temporary_cache" || \
       ! mv -fT -- "$temporary_cache" "$CAL_FILE_CACHE_FILE" 2>/dev/null; then
        rm -f -- "$temporary_cache"
    fi
    return 0
}

calibration_predict_savings() {
    local video_bps=$1 source_bps=$2 predicted_bps
    predicted_bps=$(LC_NUMERIC=C awk -v video="$video_bps" -v audio="$estimated_output_audio_bps" \
        'BEGIN {printf "%.0f",(video+audio)*1.015}')
    CAL_PREDICTED_SAVINGS=$(LC_NUMERIC=C awk -v source="$source_bps" -v output="$predicted_bps" \
        'BEGIN {if(source<=0){print 0; exit} printf "%.2f",(source-output)*100/source}')
}

calibration_score_passes() {
    LC_NUMERIC=C awk -v v="$CAL_MIN_VMAF" -v threshold="$quality_vmaf_threshold" \
        'BEGIN {exit !(v>=threshold)}'
}

calibration_savings_pass() {
    LC_NUMERIC=C awk -v saving="$CAL_PREDICTED_SAVINGS" -v required="$CAL_REQUIRED_SAVINGS" \
        'BEGIN {exit !(saving>=required)}'
}

# Heuristic: three failed trials spanning at least four quality steps, with
# <=0.25 total VMAF variation and still >=5 points below the requested floor.
# It only rejects a candidate (preserving the original); it never accepts one.
calibration_has_plateau() {
    [[ ${HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT:-true} == true ]] || return 1
    LC_NUMERIC=C awk -v q1="$1" -v q2="$2" -v q3="$3" \
        -v v1="$4" -v v2="$5" -v v3="$6" -v target="$quality_vmaf_threshold" 'BEGIN {
        maximum=v1; if(v2>maximum)maximum=v2; if(v3>maximum)maximum=v3;
        minimum=v1; if(v2<minimum)minimum=v2; if(v3<minimum)minimum=v3;
        exit !(q1>q2 && q2>q3 && q1-q3>=4 && maximum<=target-5 && maximum-minimum<=0.25)
    }'
}

calibration_encoder_supported() {
    case "$1" in
        av1_vaapi|hevc_vaapi|av1_nvenc|hevc_nvenc|av1_qsv|hevc_qsv) return 0 ;;
        *) return 1 ;;
    esac
}

calibration_quality_range() {
    case "$1" in
        av1_vaapi) printf '1 255 q_idx' ;;
        hevc_vaapi) printf '1 51 QP' ;;
        av1_nvenc|hevc_nvenc) printf '1 51 CQ' ;;
        av1_qsv|hevc_qsv) printf '1 51 ICQ' ;;
        *) return 1 ;;
    esac
}

calibration_apply_quality() {
    local encoder=$1 quality=$2
    case "$encoder" in
        av1_vaapi|hevc_vaapi)
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "$quality") ;;
        av1_nvenc|hevc_nvenc)
            encoder_args=("-cq:v" "$quality" "-preset:v" "p4") ;;
        av1_qsv|hevc_qsv)
            encoder_args=("-global_quality:v" "$quality" "-preset:v" "balanced") ;;
        *) return 1 ;;
    esac
}

calibration_build_filter_chain() {
    hardcore_video_accel_filter "$1"
}

calibration_candidate_command() {
    local encoder=$1 quality=$2 start=$3 sample_length=$4 sample_file=$5
    local CAL_FILTER_CHAIN=''
    calibration_build_filter_chain "$encoder"
    hardcore_video_accel_arguments "$encoder"
    CAL_COMMAND=(ffmpeg -hide_banner -v error -nostdin -y)
    CAL_COMMAND+=("${HARDCORE_VIDEO_DEVICE_ARGS[@]}")
    CAL_COMMAND+=(
        -ss "$start" "${HARDCORE_VIDEO_INPUT_ARGS[@]}" -i "$input" -t "$sample_length"
        -map '0:V:0' -an -sn -dn
        -c:v "$encoder"
    )
    case "$encoder" in
        av1_vaapi|hevc_vaapi) CAL_COMMAND+=(-rc_mode CQP -global_quality:v "$quality") ;;
        av1_nvenc|hevc_nvenc) CAL_COMMAND+=(-cq:v "$quality" -preset:v p4) ;;
        av1_qsv|hevc_qsv) CAL_COMMAND+=(-global_quality:v "$quality" -preset:v balanced) ;;
        *) return 1 ;;
    esac
    [[ -n "$CAL_FILTER_CHAIN" ]] && CAL_COMMAND+=(-vf "$CAL_FILTER_CHAIN")
    CAL_COMMAND+=("${HARDCORE_VIDEO_OUTPUT_ARGS[@]}")
    CAL_COMMAND+=(-f matroska "$sample_file")
}

evaluate_hardware_quality() {
    local codec=$1 encoder=$2 quality=$3 mode=${4:-full}
    local sample_length=3
    local -a positions=(0.10 0.50 0.90)
    local position start sample_file actual_length sample_size sample_bps encode_started
    local total_bps=0 sample_count=0 minimum_vmaf=101
    local -a CAL_COMMAND=()
    CAL_MIN_VMAF=''
    CAL_AVG_VIDEO_BPS=''
    CAL_WORST_POSITION=''

    if [[ $mode == one-shot ]]; then
        [[ ${5:-0.50} =~ ^0\.(10|50|90)$ ]] || return 1
        positions=("${5:-0.50}")
    fi

    if LC_NUMERIC=C awk -v d="$duration" 'BEGIN {exit !(d<9)}'; then
        positions=(0.50)
        sample_length=$(LC_NUMERIC=C awk -v d="$duration" 'BEGIN {
            v=d; if(v>3)v=3; if(v<1)v=1; printf "%.3f",v
        }')
    fi

    for position in "${positions[@]}"; do
        start=$(LC_NUMERIC=C awk -v d="$duration" -v l="$sample_length" -v p="$position" 'BEGIN {
            room=d-l; if(room<0)room=0; s=room*p; if(s<0)s=0; printf "%.3f",s
        }')
        sample_file="${output_dir}/.${output_name}.calibrate-${codec}-${quality}.$$.${sample_count}.mkv"
        preflight_files+=("$sample_file" "${sample_file}.vmaf.json")
        rm -f -- "$sample_file" "${sample_file}.vmaf.json"

        calibration_candidate_command "$encoder" "$quality" "$start" "$sample_length" "$sample_file" || return 1
        printf 'Encoding calibration sample %s/%s at %ss (%s %s)...\n' \
            "$((sample_count + 1))" "${#positions[@]}" "$start" "$encoder" "$quality"
        encode_started=$SECONDS
        if ! "${CAL_COMMAND[@]}"; then
            printf '%s via %s quality %s: sample encode failed.\n' "${codec^^}" "$encoder" "$quality"
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi
        printf 'Sample encoding finished in %ss.\n' "$((SECONDS - encode_started))"

        actual_length=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$sample_file" 2>/dev/null | head -n1)
        sample_size=$(stat -c '%s' -- "$sample_file" 2>/dev/null || printf 0)
        if [[ ! $actual_length =~ ^[0-9]+([.][0-9]+)?$ ]] || (( sample_size <= 0 )) || \
           ! LC_NUMERIC=C awk -v d="$actual_length" 'BEGIN {exit !(d>0)}'; then
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi
        sample_bps=$(LC_NUMERIC=C awk -v bytes="$sample_size" -v seconds="$actual_length" \
            'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
        (( sample_bps > 0 )) || { rm -f -- "$sample_file" "${sample_file}.vmaf.json"; return 1; }
        total_bps=$((total_bps + sample_bps))
        sample_count=$((sample_count + 1))

        if ! measure_preflight_quality "$start" "$actual_length" "$sample_file" || \
           [[ $MEASURED_QUALITY_KIND != VMAF || ! $MEASURED_QUALITY_SCORE =~ ^[0-9]+([.][0-9]+)?$ ]] || \
           ! LC_NUMERIC=C awk -v v="$MEASURED_QUALITY_SCORE" 'BEGIN {exit !(v>=0 && v<=100)}'; then
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi
        if LC_NUMERIC=C awk -v a="$MEASURED_QUALITY_SCORE" -v b="$minimum_vmaf" \
            'BEGIN {exit !(a<b)}'; then
            minimum_vmaf=$MEASURED_QUALITY_SCORE
            CAL_WORST_POSITION=$position
        fi
        rm -f -- "$sample_file" "${sample_file}.vmaf.json"
    done

    (( sample_count > 0 )) || return 1
    CAL_MIN_VMAF=$minimum_vmaf
    CAL_AVG_VIDEO_BPS=$((total_bps / sample_count))
    return 0
}

calibrate_hardware_candidate() {
    hardcore_timed video_calibration calibrate_hardware_candidate_accelerated "$@"
}

calibrate_hardware_candidate_accelerated() {
    local codec=$1 encoder=$2 rc=1 mode start_mode selection kind record range low high label
    local best='' best_bps=0 all_rejected=true cacheable=true fastest='' fastest_ns=0
    local CAL_PIPELINE_HINT='' CAL_ENDPOINT_HINT=''
    local -a modes=() finalists=()
    local -A results=() qualities=()
    hardcore_video_accel_prepare "$encoder"
    start_mode=${HARDCORE_VIDEO_START_MODES[$encoder]:-cpu}
    if [[ $start_mode == cpu ]]; then
        HARDCORE_VIDEO_PIPELINES[$encoder]=cpu
        calibrate_hardware_candidate_impl "$codec" "$encoder"
        return $?
    fi
    case "$start_mode" in
        gpu) modes=(gpu hybrid cpu) ;;
        hybrid) modes=(hybrid cpu) ;;
    esac
    hardcore_video_selection_prepare "$codec" "$encoder" "$start_mode"
    if selection=$(hardcore_video_selection_read); then
        IFS=$'\t' read -r kind mode <<< "$selection"
        if [[ $start_mode == gpu || $mode != gpu ]]; then
            HARDCORE_VIDEO_PIPELINES[$encoder]=$mode
            calibration_cache_prepare "$codec" "$encoder"
            range=$(calibration_quality_range "$encoder") || return 4
            IFS=' ' read -r low high label <<< "$range"
            # A routing record alone never certifies a quality boundary.
            if record=$(calibration_video_cache_read "$low" "$high") && [[ $record == "$kind"$'\t'* ]]; then
                printf 'Reusing per-video preprocessing decision: %s (%s); validating its quality record.\n' "$mode" "$kind"
                if calibrate_hardware_candidate_impl "$codec" "$encoder"; then rc=0; else rc=$?; fi
                if [[ $kind == boundary && $rc == 0 && $CAL_REASON == cache-validated ]] ||
                   [[ $kind == rejected && $rc == 2 && $CAL_REASON == cached-quality-rejection-confirmed ]]; then
                    hardcore_video_accel_describe "$encoder"
                    return "$rc"
                fi
            fi
        fi
        printf 'Preprocessing decision needs fresh comparison; reopening available paths.\n'
        hardcore_video_selection_forget
    fi

    for mode in "${modes[@]}"; do
        HARDCORE_VIDEO_PIPELINES[$encoder]=$mode
        hardcore_video_accel_describe "$encoder"
        if [[ $mode == hybrid && $start_mode == gpu && $apply_scaling == true ]]; then
            printf 'Comparing GPU scaling against CPU Lanczos for quality and compression.\n'
        fi
        if calibrate_hardware_candidate_impl "$codec" "$encoder"; then rc=0; else rc=$?; fi
        if (( rc == 0 )); then
            all_rejected=false
            qualities[$mode]=$CAL_BEST_QUALITY
            results[$mode]="$CAL_BEST_QUALITY|$CAL_PREDICTED_SAVINGS|$CAL_REQUIRED_SAVINGS|$CAL_REASON|$CAL_QUALITY_LABEL|$CAL_MIN_VMAF|$CAL_AVG_VIDEO_BPS|$CAL_WORST_POSITION|$CAL_RESULT_VIDEO_BPS"
            if [[ -z $best ]] || (( CAL_RESULT_VIDEO_BPS < best_bps )); then
                best=$mode; best_bps=$CAL_RESULT_VIDEO_BPS; finalists=("$mode")
            elif (( CAL_RESULT_VIDEO_BPS == best_bps )); then
                finalists+=("$mode")
            fi
            CAL_PIPELINE_HINT=$CAL_BEST_QUALITY
            CAL_ENDPOINT_HINT=''
            # No resizing/denoising: preserve the direct GPU path. Comparisons
            # are needed when software filters introduce a transfer round trip.
            [[ $mode != gpu || $apply_scaling == true ]] || break
        else
            (( rc == 2 )) || all_rejected=false
            (( rc == 1 )) && cacheable=false
            CAL_PIPELINE_HINT=''
            CAL_ENDPOINT_HINT=''
            # Probe an alternative at the known failing position/endpoint before
            # spending another binary search on a pipeline-level quality limit.
            (( rc != 2 )) || CAL_ENDPOINT_HINT=$CAL_WORST_POSITION
            [[ $mode == cpu ]] || printf 'Preprocessing attempt failed; checking the next compatible path.\n'
        fi
    done
    if [[ -z $best ]]; then
        [[ $all_rejected != true ]] || hardcore_video_selection_write rejected cpu
        return "$rc"
    fi

    if (( ${#finalists[@]} > 1 )); then
        printf 'Accepted paths predict identical video bitrate; comparing bounded encode speed.\n'
        for mode in "${finalists[@]}"; do
            HARDCORE_VIDEO_PIPELINES[$encoder]=$mode
            if hardcore_video_speed_probe "$codec" "$encoder" "${qualities[$mode]}"; then
                if [[ -z $fastest ]] || (( HARDCORE_VIDEO_PROBE_NS < fastest_ns )); then
                    fastest=$mode; fastest_ns=$HARDCORE_VIDEO_PROBE_NS
                fi
            else
                cacheable=false
                printf 'Speed probe failed for %s; not caching this selection.\n' "$mode"
            fi
        done
        [[ -z $fastest ]] || best=$fastest
    fi
    HARDCORE_VIDEO_PIPELINES[$encoder]=$best
    IFS='|' read -r CAL_BEST_QUALITY CAL_PREDICTED_SAVINGS CAL_REQUIRED_SAVINGS CAL_REASON CAL_QUALITY_LABEL \
        CAL_MIN_VMAF CAL_AVG_VIDEO_BPS CAL_WORST_POSITION CAL_RESULT_VIDEO_BPS <<< "${results[$best]}"
    printf 'Selected preprocessing: %s; best accepted compression, speed used only to break equal-bitrate ties.\n' "$best"
    [[ $cacheable != true ]] || hardcore_video_selection_write boundary "$best"
    return 0
}

calibrate_hardware_candidate_impl() {
    local codec=$1 encoder=$2
    local range low high endpoint quality_label mid best_quality=0 best_video_bps=0 best_position=''
    local source_average_bps required_savings cached_quality='' cache_source=group count next_quality=''
    local record='' cache_kind cached_position cached_bps plateau_checked=false
    local -a failed_qualities=() failed_scores=()

    CAL_BEST_QUALITY=''
    CAL_PREDICTED_SAVINGS=''
    CAL_REQUIRED_SAVINGS=''
    CAL_REASON=''
    CAL_QUALITY_LABEL=''
    CAL_RESULT_VIDEO_BPS=''

    calibration_encoder_supported "$encoder" || {
        CAL_REASON='encoder-family-not-calibrated'
        return 4
    }
    range=$(calibration_quality_range "$encoder") || return 4
    IFS=' ' read -r low high quality_label <<< "$range"
    endpoint=$low
    CAL_QUALITY_LABEL=$quality_label

    source_average_bps=$(LC_NUMERIC=C awk -v bytes="$original_size" -v seconds="$duration" \
        'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
    [[ $source_average_bps =~ ^[0-9]+$ ]] && (( source_average_bps > 0 )) || {
        CAL_REASON='source-bitrate-unavailable'; return 1;
    }

    required_savings="$min_savings_percent"
    if [[ "$source_video_codec" == "$codec" && "$apply_scaling" != true && "$apply_denoise" != true ]]; then
        required_savings=$(LC_NUMERIC=C awk -v minimum="$min_savings_percent" 'BEGIN {
            candidate=minimum+5; if(candidate<10) candidate=10; printf "%.3f",candidate
        }')
    fi
    CAL_REQUIRED_SAVINGS=$required_savings

    printf '\n%s hardware quality calibration\n' "${codec^^}"
    printf '%s\n' '────────────────────────────────────────────────────────────'
    printf 'Encoder: %s | searching %s %s..%s for worst-sample VMAF >= %s.\n' \
        "$encoder" "$quality_label" "$low" "$high" "$quality_vmaf_threshold"

    calibration_cache_prepare "$codec" "$encoder"
    record=$(calibration_video_cache_read "$low" "$high") || record=''
    if [[ -z $record && ${CAL_ENDPOINT_HINT:-} =~ ^0\.(10|50|90)$ ]]; then
        printf 'Another preprocessing path failed quality; testing this path at its highest-quality endpoint first.\n'
        if ! evaluate_hardware_quality "$codec" "$encoder" "$endpoint" one-shot "$CAL_ENDPOINT_HINT"; then
            CAL_REASON="sample-probe-failed-at-${endpoint}"
            return 1
        fi
        if ! calibration_score_passes; then
            CAL_REASON='quality-endpoint-below-floor'
            calibration_video_cache_write rejected "$endpoint" "$CAL_WORST_POSITION" "$CAL_AVG_VIDEO_BPS"
            return 2
        fi
        printf 'Alternative endpoint passes; searching its compression boundary.\n'
    fi
    if [[ -n $record ]]; then
        IFS=$'\t' read -r cache_kind cached_quality cached_position cached_bps <<< "$record"
        printf 'Calibration cache source: video (%s).\n' "$cache_kind"
        printf 'Cached %s %s: validating one 3s segment at the previously worst position %s.\n' \
            "$quality_label" "$cached_quality" "$cached_position"
        if evaluate_hardware_quality "$codec" "$encoder" "$cached_quality" one-shot "$cached_position"; then
            if [[ $cache_kind == rejected ]] && ! calibration_score_passes; then
                CAL_REASON='cached-quality-rejection-confirmed'
                printf 'Highest-quality setting still fails VMAF (%s < %s); skipping repeated codec search.\n' \
                    "$CAL_MIN_VMAF" "$quality_vmaf_threshold"
                calibration_video_cache_write rejected "$cached_quality" "$CAL_WORST_POSITION" "$CAL_AVG_VIDEO_BPS"
                return 2
            fi
            if [[ $cache_kind == boundary ]] && calibration_score_passes; then
                calibration_predict_savings "$CAL_AVG_VIDEO_BPS" "$source_average_bps"
                if calibration_savings_pass; then
                    # Keep the three-segment bitrate estimate for fair codec
                    # competition; one difficult scene is not representative.
                    calibration_predict_savings "$cached_bps" "$source_average_bps"
                    if calibration_savings_pass; then
                        CAL_BEST_QUALITY=$cached_quality
                        CAL_RESULT_VIDEO_BPS=$cached_bps
                        CAL_REASON='cache-validated'
                        printf 'Cached setting passed: VMAF %s >= %s; predicted saving %s%% (required %s%%).\n' \
                            "$CAL_MIN_VMAF" "$quality_vmaf_threshold" "$CAL_PREDICTED_SAVINGS" "$required_savings"
                        calibration_video_cache_write boundary "$cached_quality" "$cached_position" "$cached_bps"
                        return 0
                    fi
                fi
            fi
        fi
        printf 'Cached result needs a fresh search; running full calibration.\n'
        CAL_PREDICTED_SAVINGS=''
    else
        if cached_quality=$(calibration_cache_read "$low" "$high" "$CAL_FILE_CACHE_FILE"); then
            cache_source=legacy-video
        else
            cached_quality=$(calibration_cache_read "$low" "$high") || cached_quality=''
        fi
        if [[ -z $cached_quality && ${CAL_PIPELINE_HINT:-} =~ ^[1-9][0-9]{0,2}$ ]] &&
           (( CAL_PIPELINE_HINT >= low && CAL_PIPELINE_HINT <= high )); then
            cached_quality=$CAL_PIPELINE_HINT
            cache_source=other-pipeline
        fi
        if [[ -n $cached_quality ]]; then
            printf 'Calibration cache source: %s.\n' "$cache_source"
            printf 'Using cached %s %s as a search hint; checking all segments and seeking the compression boundary.\n' \
                "$quality_label" "$cached_quality"
            if evaluate_hardware_quality "$codec" "$encoder" "$cached_quality"; then
                if calibration_score_passes; then
                    best_quality=$cached_quality
                    best_video_bps=$CAL_AVG_VIDEO_BPS
                    best_position=$CAL_WORST_POSITION
                    low=$((cached_quality + 1))
                    # Usually the group hint is already near the boundary.
                    # Check its neighbor before bisecting the remaining range.
                    next_quality=$low
                else
                    high=$((cached_quality - 1))
                fi
            else
                printf 'Cached hint measurement unavailable; running full calibration.\n'
            fi
        fi
    fi

    while (( low <= high )); do
        if [[ -n $next_quality ]]; then mid=$next_quality; next_quality=''
        else mid=$(((low + high) / 2)); fi
        if ! evaluate_hardware_quality "$codec" "$encoder" "$mid"; then
            CAL_REASON="sample-probe-failed-at-${mid}"
            return 1
        fi
        printf '%s %s: worst VMAF %s.\n' "$quality_label" "$mid" "$CAL_MIN_VMAF"
        if calibration_score_passes; then
            best_quality=$mid
            best_video_bps=$CAL_AVG_VIDEO_BPS
            best_position=$CAL_WORST_POSITION
            low=$((mid + 1))
        else
            if (( best_quality == 0 )); then
                failed_qualities+=("$mid")
                failed_scores+=("$CAL_MIN_VMAF")
                count=${#failed_qualities[@]}
                if [[ $plateau_checked == false ]] && (( count >= 3 )) && calibration_has_plateau \
                    "${failed_qualities[count-3]}" "${failed_qualities[count-2]}" "${failed_qualities[count-1]}" \
                    "${failed_scores[count-3]}" "${failed_scores[count-2]}" "${failed_scores[count-1]}"; then
                    plateau_checked=true
                    printf 'VMAF plateau detected; checking highest-quality %s %s at the failing position before rejecting.\n' \
                        "$quality_label" "$endpoint"
                    if ! evaluate_hardware_quality "$codec" "$encoder" "$endpoint" one-shot "$CAL_WORST_POSITION"; then
                        CAL_REASON="sample-probe-failed-at-${endpoint}"
                        return 1
                    fi
                    if ! calibration_score_passes; then
                        CAL_REASON='quality-endpoint-below-floor'
                        printf 'Highest-quality setting fails VMAF (%s < %s); another codec may still qualify.\n' \
                            "$CAL_MIN_VMAF" "$quality_vmaf_threshold"
                        calibration_video_cache_write rejected "$endpoint" "$CAL_WORST_POSITION" "$CAL_AVG_VIDEO_BPS"
                        return 2
                    fi
                    printf 'Highest-quality sample recovered; continuing the boundary search.\n'
                fi
            fi
            high=$((mid - 1))
        fi
    done

    if (( best_quality <= 0 )); then
        CAL_REASON='quality-floor-not-met'
        if ! calibration_score_passes; then
            calibration_video_cache_write rejected "$endpoint" "$CAL_WORST_POSITION" "$CAL_AVG_VIDEO_BPS"
        fi
        return 2
    fi

    calibration_predict_savings "$best_video_bps" "$source_average_bps"
    CAL_BEST_QUALITY=$best_quality
    CAL_RESULT_VIDEO_BPS=$best_video_bps
    printf '%s quality-valid boundary: %s %s; predicted saving %s%%; required %s%%.\n' \
        "${codec^^}" "$quality_label" "$best_quality" "$CAL_PREDICTED_SAVINGS" "$required_savings"

    if ! calibration_savings_pass; then
        CAL_REASON='minimum-saving-not-met'
        return 3
    fi
    calibration_cache_write "$best_quality"
    calibration_video_cache_write boundary "$best_quality" "$best_position" "$best_video_bps"
    CAL_REASON='candidate-valid'
    return 0
}

apply_calibrated_candidate() {
    local codec=$1 encoder=$2 quality=$3 label=$4
    local CAL_FILTER_CHAIN=''
    apply_encoder "$encoder"
    calibration_apply_quality "$encoder" "$quality" || return 1
    calibration_build_filter_chain "$encoder"
    filter_chain=$CAL_FILTER_CHAIN
    CAL_SELECTED_VALIDATED=true
    case "$encoder" in
        av1_vaapi) video_crf="CQP q_idx ${quality} (calibrated)" ;;
        hevc_vaapi) video_crf="CQP QP ${quality} (calibrated)" ;;
        av1_nvenc|hevc_nvenc) video_crf="CQ ${quality} (calibrated)" ;;
        av1_qsv|hevc_qsv) video_crf="ICQ ${quality} (calibrated)" ;;
    esac
    printf 'Selected %s via %s at %s %s.\n' "${codec^^}" "$encoder" "$label" "$quality"
}

calibrate_and_choose_video_codec() {
    CAL_SELECTED_VALIDATED=false
    [[ "$quality_check" != off ]] || {
        if [[ $HARDCORE_AUTO_CODEC_MODE == 1 ]]; then
            printf 'Automatic AV1/HEVC comparison requires VMAF; original preserved unchanged.\n'
            return 3
        fi
        return 0
    }
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        printf 'Video quality calibration could not determine duration. Original preserved unchanged.\n'
        return 3
    }

    local av1_encoder='' hevc_encoder='' av1_rc=9 hevc_rc=9
    local av1_quality='' hevc_quality='' av1_saving='' hevc_saving=''
    local av1_reason='unavailable' hevc_reason='unavailable'
    local av1_label='' hevc_label=''

    if [[ $HARDCORE_AUTO_CODEC_MODE == 1 ]]; then
        av1_encoder=$HARDCORE_AUTO_AV1_ENCODER
        hevc_encoder=$HARDCORE_AUTO_HEVC_ENCODER
    else
        case "$expected_codec" in
            av1) av1_encoder=$video_encoder ;;
            hevc) hevc_encoder=$video_encoder ;;
        esac
    fi

    if [[ -n $av1_encoder ]]; then
        if calibrate_hardware_candidate av1 "$av1_encoder"; then av1_rc=0; else av1_rc=$?; fi
        av1_quality=$CAL_BEST_QUALITY; av1_saving=$CAL_PREDICTED_SAVINGS; av1_reason=$CAL_REASON; av1_label=$CAL_QUALITY_LABEL
    fi
    if [[ -n $hevc_encoder ]]; then
        if calibrate_hardware_candidate hevc "$hevc_encoder"; then hevc_rc=0; else hevc_rc=$?; fi
        hevc_quality=$CAL_BEST_QUALITY; hevc_saving=$CAL_PREDICTED_SAVINGS; hevc_reason=$CAL_REASON; hevc_label=$CAL_QUALITY_LABEL
    fi

    if [[ $HARDCORE_AUTO_CODEC_MODE != 1 ]]; then
        local rc quality saving reason label codec encoder
        if [[ -n $av1_encoder ]]; then rc=$av1_rc; quality=$av1_quality; saving=$av1_saving; reason=$av1_reason; label=$av1_label; codec=av1; encoder=$av1_encoder
        else rc=$hevc_rc; quality=$hevc_quality; saving=$hevc_saving; reason=$hevc_reason; label=$hevc_label; codec=hevc; encoder=$hevc_encoder; fi
        if (( rc == 4 )); then
            printf '%s encoder %s has no calibrated search policy; using its existing validated settings.\n' "${codec^^}" "$encoder"
            return 0
        fi
        if (( rc != 0 )); then
            printf '%s calibration rejected this file (%s). Original preserved unchanged.\n' "${codec^^}" "$reason"
            return 3
        fi
        apply_calibrated_candidate "$codec" "$encoder" "$quality" "$label"
        return $?
    fi

    printf '\nAutomatic codec competition\n'
    printf '%s\n' '════════════════════════════════════════════════════════════'
    printf 'AV1:  encoder=%s | result=%s | quality=%s %s | predicted saving=%s%%\n' \
        "${av1_encoder:-unavailable}" "$av1_reason" "${av1_label:-n/a}" "${av1_quality:-n/a}" "${av1_saving:-n/a}"
    printf 'HEVC: encoder=%s | result=%s | quality=%s %s | predicted saving=%s%%\n' \
        "${hevc_encoder:-unavailable}" "$hevc_reason" "${hevc_label:-n/a}" "${hevc_quality:-n/a}" "${hevc_saving:-n/a}"

    if (( av1_rc == 4 )) && [[ -n $av1_encoder && -z $hevc_encoder ]]; then
        printf 'Only AV1 is available and its encoder family has no calibrated competition policy; keeping existing AV1 settings.\n'
        return 0
    fi
    if (( hevc_rc == 4 )) && [[ -n $hevc_encoder && -z $av1_encoder ]]; then
        printf 'Only HEVC is available and its encoder family has no calibrated competition policy; keeping existing HEVC settings.\n'
        return 0
    fi

    if (( av1_rc == 0 && hevc_rc == 0 )); then
        if LC_NUMERIC=C awk -v a="$av1_saving" -v h="$hevc_saving" 'BEGIN {exit !(a>=h)}'; then
            printf 'Winner: AV1, because its quality-valid candidate is predicted smaller.\n'
            apply_calibrated_candidate av1 "$av1_encoder" "$av1_quality" "$av1_label"
        else
            printf 'Winner: HEVC, because its quality-valid candidate is predicted smaller.\n'
            apply_calibrated_candidate hevc "$hevc_encoder" "$hevc_quality" "$hevc_label"
        fi
        return $?
    elif (( av1_rc == 0 )); then
        printf 'Winner: AV1; HEVC did not produce an accepted quality/size candidate.\n'
        apply_calibrated_candidate av1 "$av1_encoder" "$av1_quality" "$av1_label"
        return $?
    elif (( hevc_rc == 0 )); then
        printf 'Winner: HEVC; AV1 did not produce an accepted quality/size candidate.\n'
        apply_calibrated_candidate hevc "$hevc_encoder" "$hevc_quality" "$hevc_label"
        return $?
    fi

    printf 'Neither AV1 nor HEVC produced a candidate meeting both VMAF and minimum-savings requirements. Original preserved unchanged.\n'
    return 3
}

run_video_preflight() {
    if [[ $CAL_SELECTED_VALIDATED == true && $quality_check != off ]]; then
        printf "\nVideo preflight: reusing this file's calibrated quality and size measurements.\n"
        return 0
    fi
    [[ "$video_preflight" == true ]] || return 0
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0

    local duration_is_long=false
    if LC_NUMERIC=C awk -v d="$duration" -v minimum="$preflight_min_duration" \
        'BEGIN {exit !(d >= minimum)}'; then
        duration_is_long=true
    fi
    if [[ "$quality_check" == off && "$duration_is_long" != true ]] && (( original_size < preflight_min_size )); then
        printf '\nVideo preflight: skipped for this short, small file; direct encoding is cheaper.\n'
        return 0
    fi

    local required_savings="$min_savings_percent"
    if [[ "$source_video_codec" == "$expected_codec" && "$apply_scaling" != true && "$apply_denoise" != true ]]; then
        required_savings=$(LC_NUMERIC=C awk -v minimum="$min_savings_percent" 'BEGIN {
            candidate=minimum+5; if(candidate<10) candidate=10; printf "%.3f",candidate
        }')
    fi

    local -a positions=(0.10 0.50 0.90)
    local position start sample_length sample_file sample_size actual_length sample_bps
    local successful=0 total_bps=0 min_bps=0 max_bps=0 index=0
    local quality_samples=0 minimum_vmaf=101 minimum_ssim=2 quality_failed=false
    local -a sample_command=()

    printf '\nVideo compression preflight\n'
    printf '%s\n' '────────────────────────────────────────────────────────────'
    printf 'Testing three representative %ss segments with the final encoder settings.\n' \
        "$preflight_sample_seconds"

    for position in "${positions[@]}"; do
        ((index++))
        start=$(LC_NUMERIC=C awk -v d="$duration" -v p="$position" -v seglen="$preflight_sample_seconds" 'BEGIN {
            start=d*p-seglen/2; if(start<0)start=0; if(start+seglen>d)start=d-seglen; if(start<0)start=0;
            printf "%.3f",start
        }')
        sample_length=$(LC_NUMERIC=C awk -v d="$duration" -v start="$start" -v maximum="$preflight_sample_seconds" 'BEGIN {
            remaining=d-start; if(remaining>maximum)remaining=maximum; if(remaining<1)remaining=1; printf "%.3f",remaining
        }')
        sample_file="${output_dir}/.${output_name}.preflight.$$.${index}.mkv"
        preflight_files+=("$sample_file")
        rm -f -- "$sample_file"

        sample_command=(ffmpeg -hide_banner -v error -nostdin -y)
        if [[ "$video_encoder" == *_vaapi ]]; then
            sample_command+=(-init_hw_device "vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" -filter_hw_device va)
        fi
        sample_command+=(
            -ss "$start" -i "$input" -t "$sample_length"
            -map '0:V:0' -an -sn -dn -map_metadata -1 -map_chapters -1
            -c:v "$video_encoder" "${encoder_args[@]}"
        )
        if [[ "$video_encoder" != *_vaapi ]]; then
            sample_command+=(-pix_fmt:v "$video_pix_fmt")
        fi
        if [[ "$video_encoder" == *_nvenc ]]; then
            sample_command+=(-gpu:v "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}")
        fi
        [[ -n "$filter_chain" ]] && sample_command+=(-vf "$filter_chain")
        sample_command+=("$sample_file")

        printf 'Sample %s/3 at %ss: ' "$index" "$start"
        if ! "${sample_command[@]}"; then
            printf 'failed.\n'
            [[ $quality_check != off ]] && quality_failed=true
            rm -f -- "$sample_file"
            continue
        fi

        sample_size=$(stat -c '%s' -- "$sample_file" 2>/dev/null || printf '0')
        actual_length=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 \
            "$sample_file" 2>/dev/null | head -n1)
        if (( sample_size <= 0 )) || ! [[ "$actual_length" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            printf 'invalid.\n'
            [[ $quality_check != off ]] && quality_failed=true
            rm -f -- "$sample_file"
            continue
        fi

        sample_bps=$(LC_NUMERIC=C awk -v bytes="$sample_size" -v seconds="$actual_length" \
            'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
        if (( sample_bps <= 0 )); then
            [[ $quality_check != off ]] && quality_failed=true
            continue
        fi
        successful=$((successful + 1))
        total_bps=$((total_bps + sample_bps))
        if (( min_bps == 0 || sample_bps < min_bps )); then min_bps=$sample_bps; fi
        if (( sample_bps > max_bps )); then max_bps=$sample_bps; fi
        printf '%s video bitrate' "$(LC_NUMERIC=C awk -v b="$sample_bps" 'BEGIN {printf "%.2f Mbit/s",b/1000000}')"
        if measure_preflight_quality "$start" "$actual_length" "$sample_file"; then
            quality_samples=$((quality_samples + 1))
            printf '; %s %s' "$MEASURED_QUALITY_KIND" "$MEASURED_QUALITY_SCORE"
            if [[ $MEASURED_QUALITY_KIND == VMAF ]] && \
               LC_NUMERIC=C awk -v a="$MEASURED_QUALITY_SCORE" -v b="$minimum_vmaf" 'BEGIN {exit !(a<b)}'; then
                minimum_vmaf=$MEASURED_QUALITY_SCORE
            elif [[ $MEASURED_QUALITY_KIND == SSIM ]] && \
                 LC_NUMERIC=C awk -v a="$MEASURED_QUALITY_SCORE" -v b="$minimum_ssim" 'BEGIN {exit !(a<b)}'; then
                minimum_ssim=$MEASURED_QUALITY_SCORE
            fi
        elif [[ $quality_check != off ]]; then
            printf '; quality measurement failed'
            quality_failed=true
        fi
        printf '.\n'
        rm -f -- "$sample_file"
    done

    if [[ $quality_check != off ]] && (( quality_samples == 0 )); then
        quality_failed=true
    fi
    if [[ $quality_failed == true ]]; then
        printf 'Sample VMAF quality validation was unavailable. Original preserved unchanged.\n'
        exit 3
    fi
    if (( quality_samples > 0 )); then
        if LC_NUMERIC=C awk -v value="$minimum_vmaf" -v threshold="$quality_vmaf_threshold" \
            'BEGIN {exit !(value<=100 && value<threshold)}'; then
            printf 'Sample VMAF %s is below the %s threshold. Original preserved unchanged.\n' \
                "$minimum_vmaf" "$quality_vmaf_threshold"
            exit 3
        fi
        if LC_NUMERIC=C awk -v value="$minimum_ssim" -v threshold="$quality_ssim_threshold" \
            'BEGIN {exit !(value<=1 && value<threshold)}'; then
            printf 'Sample SSIM %s is below the %s threshold. Original preserved unchanged.\n' \
                "$minimum_ssim" "$quality_ssim_threshold"
            exit 3
        fi
    fi

    if (( successful < 2 )); then
        printf 'Preflight was inconclusive; proceeding with the full encode.\n'
        return 0
    fi

    local average_video_bps source_average_bps predicted_output_bps predicted_savings variation safety_margin=2
    average_video_bps=$((total_bps / successful))
    source_average_bps=$(LC_NUMERIC=C awk -v bytes="$original_size" -v seconds="$duration" \
        'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
    predicted_output_bps=$(LC_NUMERIC=C awk -v video="$average_video_bps" -v audio="$estimated_output_audio_bps" \
        'BEGIN {printf "%.0f",(video+audio)*1.015}')
    predicted_savings=$(LC_NUMERIC=C awk -v source="$source_average_bps" -v output="$predicted_output_bps" 'BEGIN {
        if(source<=0){print 0; exit} printf "%.2f",(source-output)*100/source
    }')
    variation=$(LC_NUMERIC=C awk -v minimum="$min_bps" -v maximum="$max_bps" -v average="$average_video_bps" 'BEGIN {
        if(average<=0){print 100; exit} printf "%.2f",(maximum-minimum)*100/average
    }')

    printf 'Predicted output rate: %s\n' \
        "$(LC_NUMERIC=C awk -v b="$predicted_output_bps" 'BEGIN {printf "%.2f Mbit/s",b/1000000}')"
    printf 'Predicted size saving: %s%%\n' "$predicted_savings"
    printf 'Sample variation:      %s%%\n' "$variation"
    printf 'Required saving:       %s%%\n' "$required_savings"

    if LC_NUMERIC=C awk -v predicted="$predicted_savings" 'BEGIN {exit !(predicted<=-20)}'; then
        printf 'Preflight predicts severe expansion (%s%% saving). Original preserved unchanged.\n' "$predicted_savings"
        exit 3
    fi

    if LC_NUMERIC=C awk -v predicted="$predicted_savings" -v required="$required_savings" \
        -v margin="$safety_margin" -v variation="$variation" \
        'BEGIN {exit !((predicted+margin)<required && variation<=35)}'; then
        printf 'Preflight predicts insufficient savings. Original preserved unchanged.\n'
        exit 3
    fi

    printf 'Preflight supports a full encode, or is uncertain enough that skipping would be unsafe.\n'
}

calibrate_and_choose_video_codec
calibration_rc=$?
if (( calibration_rc == 3 )); then
    exit 3
elif (( calibration_rc != 0 )); then
    die "Video codec calibration/selection failed with exit code $calibration_rc."
fi

run_video_preflight

printf '\nRecommended encoding plan\n'
printf '%s\n' '════════════════════════════════════════════════════════════'
printf 'Input:              %s\n' "$input"
printf 'Output:             %s\n' "$output"
printf 'Video:              %s\n' "$video_codec_label"
printf 'Quality:            %s\n' "$video_crf"
printf 'Resolution:         %s\n' "$scaling_reason"
printf 'Denoising:          %s\n' "$denoise_reason"
if ((${#audio_plan[@]} == 0)); then
    printf 'Audio:              No audio streams\n'
else
    printf 'Audio:              %s\n' "${audio_plan[0]}"
    for ((i=1; i<${#audio_plan[@]}; i++)); do printf '                    %s\n' "${audio_plan[$i]}"; done
fi
printf 'Validation:         Codec, duration, full decode + completed-output VMAF (%s)\n' "$video_quality_validation"
printf '%s\n' '════════════════════════════════════════════════════════════'

if [[ -e "$output" && "$same_output_as_input" != true && "$assume_yes" != true ]]; then
    ask_yes_no 'Replace the existing destination?' n || { printf 'Cancelled.\n'; exit 0; }
fi
if [[ "$assume_yes" != true ]]; then
    printf '\n'
    ask_yes_no 'Start compression?' y || { printf 'Cancelled.\n'; exit 0; }
fi

encode_rc=0
hardcore_video_encode_full || encode_rc=$?
if (( encode_rc != 0 )); then
    rm -f -- "$temporary"
    temporary=''
    if (( encode_rc == 3 )); then
        printf 'Completed output did not pass the configured visual-quality acceptance policy. Original preserved unchanged.\n'
        exit 3
    fi
    die 'Video encoding or structural validation failed after compatible preprocessing retries.'
fi

output_video_stream_count=$(stream_count_file v "$temporary")
output_audio_count=$(stream_count_file a "$temporary")
output_subtitle_count=$(stream_count_file s "$temporary")
output_attachment_count=$(stream_count_file t "$temporary")
output_data_count=$(stream_count_file d "$temporary")
if (( output_video_stream_count != all_video_stream_count || output_audio_count != audio_count ||
      output_subtitle_count != subtitle_count || output_attachment_count != attachment_count ||
      output_data_count != data_stream_count )); then
    rm -f -- "$temporary"
    printf 'Stream-preservation validation failed. Original preserved unchanged.\n'
    exit 3
fi
if ! python3 "$HARDCORE_ARCHIVE_MEDIA_HELPER" validate "$input" "$temporary"; then
    rm -f -- "$temporary"
    printf 'Semantic media-preservation validation failed. Original preserved unchanged.\n'
    exit 3
fi

compressed_size=$(stat -c '%s' -- "$temporary")
printf '\nResult\n'
printf '%s\n' '────────────────────────────────────────────────────────────'
printf 'Original:           %s\n' "$(human_size "$original_size")"
printf 'Compressed:         %s\n' "$(human_size "$compressed_size")"

savings_percent=$(LC_NUMERIC=C awk -v original="$original_size" -v compressed="$compressed_size" 'BEGIN {
    if (original <= 0) { print "0.000"; exit }
    printf "%.3f", (original-compressed)*100/original
}')
printf 'Size reduction:     %s%%\n' "$savings_percent"

meets_savings=false
if LC_NUMERIC=C awk -v saved="$savings_percent" -v minimum="$min_savings_percent"     'BEGIN {exit !(saved >= minimum && saved > 0)}'; then
    meets_savings=true
fi

if [[ "$meets_savings" != true ]]; then
    retain=false
    [[ "$keep_larger" == true ]] && retain=true
    if [[ "$assume_yes" != true && "$retain" != true ]] &&        ask_yes_no "Keep result despite not meeting ${min_savings_percent}% minimum savings?" n; then
        retain=true
    fi
    if [[ "$retain" != true ]]; then
        rm -f -- "$temporary"
        if (( compressed_size >= original_size )); then
            printf 'The larger result was removed.\n'
        else
            printf 'Minimum savings not reached. Original preserved unchanged.\n'
        fi
        exit 3
    fi
fi

chmod --reference="$input" -- "$temporary" 2>/dev/null || true
touch --reference="$input" -- "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || die 'Could not finalize output.'
temporary=''

if [[ "$replace_original" == true && "$same_output_as_input" != true ]]; then rm -f -- "$input"; fi
printf '\nCompleted successfully:\n  %s\n' "$output"
