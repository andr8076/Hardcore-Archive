#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

has() { command -v "$1" >/dev/null 2>&1; }

jpeg_pixel_hash() {
    djpeg "$1" 2>/dev/null | sha256sum | awk '{print $1}'
}

png_pixel_hash() {
    if has ffmpeg; then
        ffmpeg -hide_banner -v error -nostdin -i "$1" -map 0:v:0 -f framemd5 - 2>/dev/null |
            sha256sum | awk '{print $1}'
    elif has pngcheck; then
        pngcheck -q "$1" >/dev/null 2>&1 || return 1
        printf 'validated-by-pngcheck\n'
    else
        return 1
    fi
}

oxipng_supports() {
    local needle=$1
    if [[ -z ${OXIPNG_HELP_CACHE+x} ]]; then
        OXIPNG_HELP_CACHE=$(oxipng --help 2>&1 || true)
    fi
    [[ $OXIPNG_HELP_CACHE == *"$needle"* ]]
}

oxipng_thread_args() {
    local threads=$1
    OXIPNG_THREAD_ARGS=()
    if oxipng_supports '--threads'; then
        OXIPNG_THREAD_ARGS=(--threads "$threads")
        unset RAYON_NUM_THREADS || true
    else
        export RAYON_NUM_THREADS=$threads
    fi
}

run_with_budget() {
    local seconds=$1
    shift
    if has timeout; then
        timeout --signal=TERM --kill-after=5 "${seconds}s" "$@"
    else
        "$@"
    fi
}

zopfli_budget_seconds() {
    local bytes=$1
    if (( bytes <= 1 * 1024 * 1024 )); then
        printf '20'
    elif (( bytes <= 8 * 1024 * 1024 )); then
        printf '45'
    elif (( bytes <= 32 * 1024 * 1024 )); then
        printf '75'
    else
        printf '90'
    fi
}

zopfli_refinement_worthwhile() {
    local original=$1 baseline=$2 saved threshold
    (( baseline > 0 && baseline < original )) || return 1
    saved=$((original - baseline))
    threshold=$((original / 1000))
    (( threshold < 1024 )) && threshold=1024
    (( saved >= threshold ))
}

run_oxipng_baseline() {
    local mode=$1 threads=$2 target=$3
    oxipng_thread_args "$threads"
    case "$mode" in
        maximum) oxipng -q -o 6 --preserve "${OXIPNG_THREAD_ARGS[@]}" "$target" ;;
        balanced) oxipng -q -o 4 --preserve "${OXIPNG_THREAD_ARGS[@]}" "$target" ;;
        fast) oxipng -q -o 2 --preserve "${OXIPNG_THREAD_ARGS[@]}" "$target" ;;
        *) return 2 ;;
    esac
}

run_oxipng_zopfli_refinement() {
    local threads=$1 target=$2 budget=$3
    local -a args=(-q -o 2 --zopfli --preserve)
    oxipng_supports '--zopfli' || return 2
    oxipng_thread_args "$threads"
    args+=("${OXIPNG_THREAD_ARGS[@]}")
    if oxipng_supports '--zi'; then
        args+=(--zi 5)
    fi
    if oxipng_supports '--ziwi'; then
        args+=(--ziwi 2)
    fi
    if ! has timeout && oxipng_supports '--timeout'; then
        args+=(--timeout "$budget")
    fi
    run_with_budget "$budget" oxipng "${args[@]}" "$target"
}

optimize_one() {
    local source_parent=$1 stage_parent=$2 result_file=$3 log_file=$4 mode=$5 threads=$6 relative=$7
    local input output output_dir temp_dir original_size lower source_hash candidate_hash
    local baseline progressive candidate candidate_size best='' best_size=0 tool='unavailable'
    local zopfli zopfli_size zopfli_budget

    input="$source_parent/$relative"
    output="$stage_parent/$relative"
    output_dir=$(dirname -- "$output")
    mkdir -p -- "$output_dir"
    original_size=$(stat -c '%s' -- "$input")
    lower=${relative,,}
    temp_dir=$(mktemp -d "$output_dir/.image-opt.XXXXXX")

    if [[ $lower == *.jpg || $lower == *.jpeg || $lower == *.jpe || $lower == *.jfif ]]; then
        if has jpegtran && has djpeg; then
            tool=jpegtran
            source_hash=$(jpeg_pixel_hash "$input" || true)
            baseline="$temp_dir/baseline.jpg"
            progressive="$temp_dir/progressive.jpg"

            if [[ -n $source_hash ]] && jpegtran -copy all -optimize "$input" >"$baseline" 2>>"$log_file" && [[ -s $baseline ]]; then
                candidate_hash=$(jpeg_pixel_hash "$baseline" || true)
                if [[ $candidate_hash == "$source_hash" ]]; then
                    best=$baseline
                    best_size=$(stat -c '%s' -- "$baseline")
                    tool=jpegtran-optimize
                fi
            fi

            if [[ -n $source_hash ]] && jpegtran -copy all -optimize -progressive "$input" >"$progressive" 2>>"$log_file" && [[ -s $progressive ]]; then
                candidate_hash=$(jpeg_pixel_hash "$progressive" || true)
                if [[ $candidate_hash == "$source_hash" ]]; then
                    candidate_size=$(stat -c '%s' -- "$progressive")
                    if (( best_size == 0 || candidate_size < best_size )); then
                        best=$progressive
                        best_size=$candidate_size
                        tool=jpegtran-progressive
                    fi
                fi
            fi
        fi
    elif [[ $lower == *.png ]]; then
        candidate="$temp_dir/optimized.png"
        cp --reflink=auto --preserve=all -- "$input" "$candidate"
        if has oxipng; then
            source_hash=$(png_pixel_hash "$input" || true)
            if [[ -n $source_hash ]] && run_oxipng_baseline "$mode" "$threads" "$candidate" >>"$log_file" 2>&1 && [[ -s $candidate ]]; then
                best=$candidate
                best_size=$(stat -c '%s' -- "$candidate")
                tool="oxipng-${mode}"
            fi

            if [[ $mode == maximum && -n $best ]] && \
               oxipng_supports '--zopfli' && \
               zopfli_refinement_worthwhile "$original_size" "$best_size"; then
                zopfli="$temp_dir/zopfli.png"
                cp --reflink=auto --preserve=all -- "$best" "$zopfli"
                zopfli_budget=$(zopfli_budget_seconds "$best_size")
                printf 'Zopfli refinement: %s, budget %ss, threads %s\n' "$relative" "$zopfli_budget" "$threads" >>"$log_file"
                if run_oxipng_zopfli_refinement "$threads" "$zopfli" "$zopfli_budget" >>"$log_file" 2>&1 && [[ -s $zopfli ]]; then
                    zopfli_size=$(stat -c '%s' -- "$zopfli")
                    if (( zopfli_size < best_size )); then
                        best=$zopfli
                        best_size=$zopfli_size
                        tool='oxipng-maximum+bounded-zopfli'
                    fi
                else
                    printf 'Zopfli refinement skipped/expired; keeping baseline candidate for %s\n' "$relative" >>"$log_file"
                fi
            fi

            # Decode only the final winner. OxiPNG candidates are temporary, so
            # an interrupted/invalid refinement can never replace the source.
            if [[ -n $best ]]; then
                candidate_hash=$(png_pixel_hash "$best" || true)
                if [[ -z $source_hash || $candidate_hash != "$source_hash" ]]; then
                    printf 'Final PNG pixel validation failed; preserving original: %s\n' "$relative" >>"$log_file"
                    best=''
                    best_size=0
                    tool='oxipng-validation-failed'
                fi
            fi
        elif has optipng; then
            tool=optipng
            case "$mode" in
                maximum) optipng -quiet -preserve -o7 "$candidate" >>"$log_file" 2>&1 || true ;;
                balanced) optipng -quiet -preserve -o5 "$candidate" >>"$log_file" 2>&1 || true ;;
                fast) optipng -quiet -preserve -o2 "$candidate" >>"$log_file" 2>&1 || true ;;
            esac
            if [[ -s $candidate ]]; then
                source_hash=$(png_pixel_hash "$input" || true)
                candidate_hash=$(png_pixel_hash "$candidate" || true)
                if [[ -n $source_hash && $candidate_hash == "$source_hash" ]]; then
                    best=$candidate
                    best_size=$(stat -c '%s' -- "$candidate")
                fi
            fi
        fi
    fi

    if [[ -n $best && $best_size -lt $original_size ]]; then
        cp --reflink=auto -- "$best" "$output"
        chmod --reference="$input" -- "$output" 2>/dev/null || true
        touch --reference="$input" -- "$output" 2>/dev/null || true
        line=$(printf 'optimized\t%s\t%s\t%s\t%s\t%s\n' \
            "$relative" "$relative" "$original_size" "$best_size" "$tool")
    else
        line=$(printf 'original\t%s\t%s\t%s\t%s\t%s\n' \
            "$relative" "$relative" "$original_size" "$original_size" "$tool")
    fi

    rm -rf -- "$temp_dir"
    if has flock; then
        { flock 9; printf '%s\n' "$line" >>"$result_file"; } 9>"${result_file}.lock"
    else
        printf '%s\n' "$line" >>"$result_file"
    fi
}

if [[ ${1:-} == --worker ]]; then
    shift
    optimize_one "$@"
    exit 0
fi

source_parent=''
stage_parent=''
list_file=''
result_file=''
log_file=''
mode=maximum
jobs=1
threads_per_worker=1
while (( $# > 0 )); do
    case "$1" in
        --source-parent) source_parent=$2; shift 2 ;;
        --stage-parent) stage_parent=$2; shift 2 ;;
        --list) list_file=$2; shift 2 ;;
        --result) result_file=$2; shift 2 ;;
        --log) log_file=$2; shift 2 ;;
        --mode) mode=$2; shift 2 ;;
        --jobs) jobs=$2; shift 2 ;;
        --threads-per-worker) threads_per_worker=$2; shift 2 ;;
        *) printf 'Unknown image-helper option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ $jobs =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid image job count: %s\n' "$jobs" >&2; exit 2; }
[[ $threads_per_worker =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid threads per image worker: %s\n' "$threads_per_worker" >&2; exit 2; }
case $mode in maximum|balanced|fast) ;; *) printf 'Invalid image mode: %s\n' "$mode" >&2; exit 2;; esac

: >"$result_file"
: >"$log_file"
xargs -r -d '\n' -P "$jobs" -I '{}' \
    bash "$0" --worker "$source_parent" "$stage_parent" "$result_file" "$log_file" "$mode" "$threads_per_worker" '{}' \
    <"$list_file"
