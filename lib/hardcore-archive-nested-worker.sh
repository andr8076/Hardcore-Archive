#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

source_parent=''; relative=''; output_rel=''; stage_parent=''; task_dir=''
result_file=''; log_file=''; seven_zip=''; script_path=''
depth=0; max_depth=0; dictionary_mib=4
video_transcode=false; video_encoder=''; calibration_namespace=''; gpu_lock=''; diagnostics_dir=''
declare -a inherited=()

while (( $# > 0 )); do
    case "$1" in
        --source-parent) source_parent=$2; shift 2 ;;
        --relative) relative=$2; shift 2 ;;
        --output-rel) output_rel=$2; shift 2 ;;
        --stage-parent) stage_parent=$2; shift 2 ;;
        --task-dir) task_dir=$2; shift 2 ;;
        --result) result_file=$2; shift 2 ;;
        --log) log_file=$2; shift 2 ;;
        --seven-zip) seven_zip=$2; shift 2 ;;
        --script) script_path=$2; shift 2 ;;
        --depth) depth=$2; shift 2 ;;
        --max-depth) max_depth=$2; shift 2 ;;
        --dictionary-mib) dictionary_mib=$2; shift 2 ;;
        --video-transcode) video_transcode=$2; shift 2 ;;
        --video-encoder) video_encoder=$2; shift 2 ;;
        --calibration-namespace) calibration_namespace=$2; shift 2 ;;
        --gpu-lock) gpu_lock=$2; shift 2 ;;
        --diagnostics-dir) diagnostics_dir=$2; shift 2 ;;
        --) shift; inherited=("$@"); break ;;
        *) printf 'Unknown nested-worker option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ -n $source_parent && -n $relative && -n $output_rel && -n $stage_parent && -n $task_dir ]] || exit 2
[[ -n $result_file && -n $log_file && -n $seven_zip && -n $script_path ]] || exit 2
[[ $depth =~ ^[0-9]+$ && $max_depth =~ ^[0-9]+$ && $dictionary_mib =~ ^[1-9][0-9]*$ ]] || exit 2
case $video_transcode in true|false) ;; *) exit 2 ;; esac

mkdir -p -- "$task_dir" "$(dirname -- "$result_file")" "$(dirname -- "$log_file")"
: > "$result_file"
touch -- "$log_file"

input="$source_parent/$relative"
full_output="$stage_parent/$output_rel"
original_size=$(stat -c '%s' -- "$input") || exit 2
mkdir -p -- "$(dirname -- "$full_output")"
rm -f -- "$full_output"

extracted="$task_dir/extracted"
normalized="$task_dir/normalized"
child_work="$task_dir/child-work"
child_archive="$task_dir/child.7z"
mkdir -p -- "$extracted" "$normalized" "$child_work"

grant_cpu=${HARDCORE_RESOURCE_GRANTED_CPU:-1}
grant_ram=${HARDCORE_RESOURCE_GRANTED_RAM_MIB:-0}
[[ $grant_cpu =~ ^[1-9][0-9]*$ ]] || grant_cpu=1
[[ $grant_ram =~ ^[1-9][0-9]*$ ]] || grant_ram=256
lzma_threads=$grant_cpu
(( lzma_threads > 2 )) && lzma_threads=2
# The parent RAM claim reserves exactly one 256 MiB image worker beside LZMA2.
# File-level parallelism comes from multiple independent nested workers instead
# of multiplying hidden image RAM inside each recursive child.
image_jobs=1

cleanup() {
    rm -rf --one-file-system -- "$extracted" "$normalized" "$child_work" 2>/dev/null || true
    rm -f -- "$child_archive" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

write_result() {
    local action=$1 archived=$2 candidate_size=$3 archived_size=$4 reason=$5
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$action" "$relative" "$archived" "$original_size" "$candidate_size" "$archived_size" "$reason" \
        > "$result_file"
}

fallback() {
    local reason=$1 candidate_size=${2:-0}
    rm -f -- "$full_output"
    write_result original "$relative" "$candidate_size" "$original_size" "$reason"
    return 0
}

remove_internal_entries() {
    local root=$1 name
    for name in \
        .hardcore-archive-metadata \
        .hardcore-archive-sha256.txt \
        .hardcore-archive-video-manifest.txt \
        .hardcore-archive-image-manifest.txt \
        .hardcore-archive-container-manifest.txt \
        .hardcore-archive-nested-manifest.txt
    do
        rm -rf --one-file-system -- "$root/$name"
    done
}

contains_direct_video() {
    find "$extracted" -type f \
        \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.webm' -o -iname '*.mov' -o -iname '*.m4v' \
           -o -iname '*.avi' -o -iname '*.wmv' -o -iname '*.flv' -o -iname '*.mpg' -o -iname '*.mpeg' \
           -o -iname '*.m2ts' -o -iname '*.mts' -o -iname '*.ts' -o -iname '*.vob' -o -iname '*.ogv' \
           -o -iname '*.3gp' -o -iname '*.3g2' -o -iname '*.mxf' -o -iname '*.dvr-ms' -o -iname '*.rm' \
           -o -iname '*.rmvb' -o -iname '*.asf' -o -iname '*.divx' -o -iname '*.f4v' \) \
        -print -quit 2>/dev/null | grep -q .
}

{
    printf 'Nested archive: %s\n' "$relative"
    printf 'Depth: %s\n' "$((depth + 1))"
    printf 'Resource grant: %s CPU / %s MiB RAM\n' "$grant_cpu" "$grant_ram"
    printf 'Recursive policy: dictionary %s MiB / LZMA threads %s / image jobs %s\n' \
        "$dictionary_mib" "$lzma_threads" "$image_jobs"
    printf 'Started: %s\n\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
} >> "$log_file"

if (( depth >= max_depth )); then fallback max-depth-reached; exit 0; fi
if ! "$seven_zip" x -y -spd -o"$extracted" "$input" >>"$log_file" 2>&1; then
    fallback source-extraction-failed; exit 0
fi

child_rc=0
child_diag=${diagnostics_dir:-$task_dir/diagnostics}
mkdir -p -- "$child_diag"
child_command=(
    env
    HARDCORE_ARCHIVE_INHIBITED=1
    HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1
    HARDCORE_ARCHIVE_NESTED_CHILD=1
    HARDCORE_ARCHIVE_CPU_LIMIT="$grant_cpu"
    HARDCORE_ARCHIVE_RAM_LIMIT_MIB="$grant_ram"
    HARDCORE_ARCHIVE_PARENT_GPU_LOCK="$gpu_lock"
    HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS="$grant_cpu"
    HARDCORE_ARCHIVE_CALIBRATION_NAMESPACE="$calibration_namespace"
    HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$child_diag"
    HARDCORE_ARCHIVE_LIVE_LOG="$log_file"
    HARDCORE_ARCHIVE_HARDWARE_ENCODER_LOCKED="$video_encoder"
    HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME="${HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME:-}"
    HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR="${HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR:-}"
    HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME_ID="${HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME_ID:-}"
    HARDCORE_ARCHIVE_VIDEO_ENCODER_RUNTIME_ID="${HARDCORE_ARCHIVE_VIDEO_ENCODER_RUNTIME_ID:-modern-default}"
    HARDCORE_ARCHIVE_NESTED_DEPTH=$((depth + 1))
    bash "$script_path"
    "${inherited[@]}"
    --dictionary "${dictionary_mib}m"
    --threads "$lzma_threads"
    --image-jobs "$image_jobs"
    --video-sequential
    --work-dir "$child_work"
    "$extracted" "$child_archive"
)

if [[ $video_transcode == true && -n $gpu_lock ]] && contains_direct_video; then
    mkdir -p -- "$(dirname -- "$gpu_lock")"
    flock "$gpu_lock" "${child_command[@]}" >>"$log_file" 2>&1 || child_rc=$?
else
    "${child_command[@]}" >>"$log_file" 2>&1 || child_rc=$?
fi

printf '\nRecursive child exit status: %s\n' "$child_rc" >> "$log_file"
if (( child_rc != 0 )); then
    if (( child_rc == 1 )) && grep -Eq '^Error: (The shared output/work filesystem needs|The destination needs|The working filesystem needs|Insufficient destination space\.|No suitable working directory has enough free space\.)' "$log_file"; then
        fallback insufficient-child-work-space
    else
        fallback "recursive-archive-failed-rc-${child_rc}"
    fi
    exit 0
fi

if ! "$seven_zip" x -y -spd -o"$normalized" "$child_archive" >>"$log_file" 2>&1; then
    fallback child-extraction-failed; exit 0
fi

remove_internal_entries "$normalized"
root_count=$(find "$normalized" -mindepth 1 -maxdepth 1 -printf '.' | wc -c)
content_root="$normalized"
if (( root_count == 1 )); then
    root_entry=$(find "$normalized" -mindepth 1 -maxdepth 1 -printf '%f' | head -n1)
    [[ -d $normalized/$root_entry ]] && content_root="$normalized/$root_entry"
fi

if ! (cd -- "$content_root" && "$seven_zip" a "$full_output" \
    -t7z -m0=lzma2 -mx=9 -ms=on "-mmt=${lzma_threads}" -spd -scsUTF-8 -bsp1 -y .) >>"$log_file" 2>&1; then
    fallback candidate-build-failed; exit 0
fi
if ! "$seven_zip" t "$full_output" >>"$log_file" 2>&1; then
    candidate_size=$(stat -c '%s' -- "$full_output" 2>/dev/null || printf 0)
    fallback candidate-integrity-failed "$candidate_size"; exit 0
fi

candidate_size=$(stat -c '%s' -- "$full_output" 2>/dev/null || printf 0)
if (( candidate_size > 0 && candidate_size < original_size )); then
    write_result repacked "$output_rel" "$candidate_size" "$candidate_size" candidate-smaller
else
    fallback candidate-not-smaller "$candidate_size"
fi
printf 'Finished: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" >> "$log_file"
