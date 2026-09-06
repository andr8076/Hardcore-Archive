#!/usr/bin/env bash

# Image scheduling and policy shared by the checked-in static engine.
[[ ${HARDCORE_IMAGES_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_IMAGES_SH_LOADED=1

hardcore_images_runtime_ready() { return 0; }

# Compatibility helper: automatic image dispatch may have at most one waiting
# worker per logical CPU because every image worker requires at least one CPU
# token. RAM is deliberately NOT used here. The shared CPU/RAM pool is the
# single authority that decides how many workers may actually execute.
hardcore_images_worker_cap() {
    local cpu_threads=$1 available_mib=${2:-0}
    [[ $cpu_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $available_mib =~ ^[0-9]+$ ]] || return 2
    printf '%s\n' "$cpu_threads"
}

# Print: dispatch-slots<TAB>threads-per-worker<TAB>cpu-budget
#
# `dispatch-slots` only bounds the number of lightweight workers waiting on the
# shared pool. In automatic mode it cannot restrict useful execution because
# every worker needs >=1 CPU token and there are only cpu_threads tokens total.
# Explicit --image-jobs remains a user-requested outer concurrency limit.
hardcore_images_compute_cpu_schedule() {
    local cpu_threads=$1 image_count=$2 requested_jobs=${3:-auto} available_mib=${4:-0}
    local jobs threads

    [[ $cpu_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $image_count =~ ^[0-9]+$ ]] || return 2
    [[ $requested_jobs == auto || $requested_jobs =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $available_mib =~ ^[0-9]+$ ]] || return 2

    if (( image_count == 0 )); then
        printf '0\t1\t0\n'
        return 0
    fi

    if [[ $requested_jobs == auto ]]; then
        jobs=$image_count
        (( jobs > cpu_threads )) && jobs=$cpu_threads
    else
        jobs=$requested_jobs
        (( jobs > cpu_threads )) && jobs=$cpu_threads
        (( jobs > image_count )) && jobs=$image_count
    fi
    (( jobs < 1 )) && jobs=1

    threads=$(((cpu_threads + jobs - 1) / jobs))
    (( threads < 1 )) && threads=1
    printf '%s\t%s\t%s\n' "$jobs" "$threads" "$cpu_threads"
}

hardcore_images_png_fallback_threads() {
    local cpu_threads=$1 png_count=$2 dispatch_slots=$3 requested_jobs=${4:-auto}
    local png_parallel threads
    [[ $cpu_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $png_count =~ ^[0-9]+$ ]] || return 2
    [[ $dispatch_slots =~ ^[1-9][0-9]*$ ]] || return 2

    if (( png_count == 0 )); then
        printf '1\n'
        return 0
    fi

    if [[ $requested_jobs == auto ]]; then
        png_parallel=$png_count
        (( png_parallel > cpu_threads )) && png_parallel=$cpu_threads
    else
        png_parallel=$png_count
        (( png_parallel > dispatch_slots )) && png_parallel=$dispatch_slots
    fi
    (( png_parallel < 1 )) && png_parallel=1
    threads=$(((cpu_threads + png_parallel - 1) / png_parallel))
    (( threads < 1 )) && threads=1
    printf '%s\n' "$threads"
}

# Print: dispatch-slots<TAB>png-cpu-max<TAB>cpu-budget<TAB>scheduler-source
#
# JPEG and PNG workers are intentionally heterogeneous:
#   * JPEG/optipng workers claim exactly one CPU in the worker helper.
#   * OxiPNG workers claim 1..png-cpu-max CPUs and use the actual grant.
#
# The launcher does not shrink dispatch slots for RAM. The shared resource pool
# already accounts each active image worker's RAM and is the only runtime gate.
# OxiPNG calibration therefore tunes only the per-PNG CPU ceiling; its measured
# process count no longer limits JPEG fan-out or mixed-image dispatch.
hardcore_images_choose_cpu_schedule() {
    local cpu_threads=$1 image_count=$2 png_count=$3 requested_jobs=${4:-auto}
    local available_mib=${5:-0} cpu_model=${6:-unknown} analyze_only=${7:-false}
    local fallback jobs ignored_threads budget png_threads calibrator cache_dir result
    local calibration_workers calibrated_jobs calibrated_threads calibrated_budget calibrated_source
    local -a args

    [[ $png_count =~ ^[0-9]+$ ]] || return 2
    (( png_count <= image_count )) || return 2
    fallback=$(hardcore_images_compute_cpu_schedule \
        "$cpu_threads" "$image_count" "$requested_jobs" "$available_mib") || return 2
    IFS=$'\t' read -r jobs ignored_threads budget <<< "$fallback"

    if (( image_count == 0 )); then
        printf '0\t1\t0\tinactive\n'
        return 0
    fi

    png_threads=$(hardcore_images_png_fallback_threads \
        "$cpu_threads" "$png_count" "$jobs" "$requested_jobs") || return 2

    if [[ $requested_jobs != auto ]]; then
        printf '%s\t%s\t%s\theterogeneous-explicit\n' "$jobs" "$png_threads" "$budget"
        return 0
    fi
    if (( png_count == 0 )); then
        printf '%s\t1\t%s\theterogeneous-jpeg-only\n' "$jobs" "$budget"
        return 0
    fi
    if (( png_count == 1 )); then
        # One PNG can opportunistically consume every CPU token not currently
        # held by JPEG/LZMA/video work; the resource pool grants only what is free.
        printf '%s\t%s\t%s\theterogeneous-single-png\n' "$jobs" "$cpu_threads" "$budget"
        return 0
    fi
    if [[ ${HARDCORE_ARCHIVE_IMAGE_CALIBRATION_DISABLE:-0} == 1 ]]; then
        printf '%s\t%s\t%s\theterogeneous-heuristic-disabled\n' "$jobs" "$png_threads" "$budget"
        return 0
    fi
    command -v oxipng >/dev/null 2>&1 || {
        printf '%s\t%s\t%s\theterogeneous-heuristic-no-oxipng\n' "$jobs" "$png_threads" "$budget"
        return 0
    }
    command -v python3 >/dev/null 2>&1 || {
        printf '%s\t%s\t%s\theterogeneous-heuristic-no-python\n' "$jobs" "$png_threads" "$budget"
        return 0
    }

    calibrator=${HARDCORE_ARCHIVE_IMAGE_CALIBRATOR:-"$(dirname -- "${BASH_SOURCE[0]}")/hardcore-archive-image-calibrate.py"}
    cache_dir=${HARDCORE_ARCHIVE_IMAGE_SCHEDULER_CACHE_DIR:-}
    [[ -f $calibrator && -n $cache_dir ]] || {
        printf '%s\t%s\t%s\theterogeneous-heuristic-no-calibrator\n' "$jobs" "$png_threads" "$budget"
        return 0
    }

    # This only bounds the synthetic PNG calibration wave. It is not a runtime
    # worker cap and is independent of available RAM.
    calibration_workers=$png_count
    (( calibration_workers > cpu_threads )) && calibration_workers=$cpu_threads
    (( calibration_workers < 1 )) && calibration_workers=1
    args=(
        "$calibrator"
        --oxipng "$(command -v oxipng)"
        --cpu-threads "$cpu_threads"
        --max-workers "$calibration_workers"
        --cache-dir "$cache_dir"
        --cpu-model "$cpu_model"
        --platform "${PLATFORM_ID:-unknown}"
    )
    [[ $analyze_only == true ]] && args+=(--cache-only)
    [[ ${HARDCORE_ARCHIVE_IMAGE_CALIBRATION_REFRESH:-0} == 1 ]] && args+=(--refresh)

    if ! result=$(python3 "${args[@]}"); then
        printf '%s\t%s\t%s\theterogeneous-heuristic-calibration-unavailable\n' "$jobs" "$png_threads" "$budget"
        return 0
    fi
    IFS=$'\t' read -r calibrated_jobs calibrated_threads calibrated_budget calibrated_source <<< "$result"
    [[ $calibrated_jobs =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $calibrated_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $calibrated_budget =~ ^[1-9][0-9]*$ ]] || return 2
    (( calibrated_threads > cpu_threads )) && calibrated_threads=$cpu_threads

    printf '%s\t%s\t%s\theterogeneous-%s\n' \
        "$jobs" "$calibrated_threads" "$cpu_threads" "${calibrated_source:-calibrated}"
}
