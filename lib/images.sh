#!/usr/bin/env bash

# Image scheduling and policy shared by the checked-in static engine.
[[ ${HARDCORE_IMAGES_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_IMAGES_SH_LOADED=1

hardcore_images_runtime_ready() { return 0; }

hardcore_images_worker_cap() {
    local cpu_threads=$1 available_mib=${2:-0}
    local worker_cap memory_cap
    [[ $cpu_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $available_mib =~ ^[0-9]+$ ]] || return 2

    worker_cap=$cpu_threads
    (( worker_cap > 32 )) && worker_cap=32

    # Each active worker is accounted as roughly 256 MiB elsewhere. Keep image
    # process fan-out around <=25% of currently available memory while allowing
    # Rayon threads inside fewer OxiPNG processes to use the remaining CPUs.
    if (( available_mib > 0 )); then
        memory_cap=$((available_mib / 1024))
        (( memory_cap < 1 )) && memory_cap=1
        (( worker_cap > memory_cap )) && worker_cap=$memory_cap
    fi
    (( worker_cap < 1 )) && worker_cap=1
    printf '%s\n' "$worker_cap"
}

# Print: jobs<TAB>threads-per-worker<TAB>cpu-budget
#
# This is the deterministic fallback and the explicit --image-jobs policy.
# Automatic mode may replace this result with a machine-calibrated schedule via
# hardcore_images_choose_cpu_schedule below.
hardcore_images_compute_cpu_schedule() {
    local cpu_threads=$1 image_count=$2 requested_jobs=${3:-auto} available_mib=${4:-0}
    local jobs threads worker_cap

    [[ $cpu_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $image_count =~ ^[0-9]+$ ]] || return 2
    [[ $requested_jobs == auto || $requested_jobs =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $available_mib =~ ^[0-9]+$ ]] || return 2

    if (( image_count == 0 )); then
        printf '0\t1\t0\n'
        return 0
    fi

    worker_cap=$(hardcore_images_worker_cap "$cpu_threads" "$available_mib") || return 2
    if [[ $requested_jobs == auto ]]; then
        jobs=$image_count
        (( jobs > worker_cap )) && jobs=$worker_cap
    else
        jobs=$requested_jobs
        (( jobs > worker_cap )) && jobs=$worker_cap
        (( jobs > image_count )) && jobs=$image_count
    fi
    (( jobs < 1 )) && jobs=1

    # Ceiling division deliberately permits only slight oversubscription while
    # ensuring the complete logical-CPU budget is covered.
    threads=$(((cpu_threads + jobs - 1) / jobs))
    (( threads < 1 )) && threads=1

    printf '%s\t%s\t%s\n' "$jobs" "$threads" "$cpu_threads"
}

# Print: jobs<TAB>threads-per-worker<TAB>cpu-budget<TAB>scheduler-source
#
# The first run on a CPU/OxiPNG/worker-cap combination benchmarks a deterministic
# synthetic PNG across several process/thread splits. The winner is cached for
# 30 days by the Python calibrator. Analyze-only mode may consume an existing
# cache entry but never creates or refreshes one.
hardcore_images_choose_cpu_schedule() {
    local cpu_threads=$1 image_count=$2 png_count=$3 requested_jobs=${4:-auto}
    local available_mib=${5:-0} cpu_model=${6:-unknown} analyze_only=${7:-false}
    local fallback jobs threads budget worker_cap calibrator cache_dir result
    local calibrated_jobs calibrated_threads calibrated_budget calibrated_source
    local -a args

    [[ $png_count =~ ^[0-9]+$ ]] || return 2
    fallback=$(hardcore_images_compute_cpu_schedule \
        "$cpu_threads" "$image_count" "$requested_jobs" "$available_mib") || return 2
    IFS=$'\t' read -r jobs threads budget <<< "$fallback"

    if [[ $requested_jobs != auto ]]; then
        printf '%s\t%s\t%s\texplicit\n' "$jobs" "$threads" "$budget"
        return 0
    fi
    if (( image_count == 0 )); then
        printf '0\t1\t0\tinactive\n'
        return 0
    fi
    # There is nothing to calibrate for one PNG: one worker already receives the
    # full CPU budget. JPEG-only sets keep the aggressive deterministic policy.
    if (( png_count < 2 )); then
        printf '%s\t%s\t%s\theuristic\n' "$jobs" "$threads" "$budget"
        return 0
    fi
    # jpegtran is effectively file-parallel rather than internally threaded.
    # An OxiPNG-derived low worker count can therefore hurt a JPEG-heavy mixed
    # set, so keep the high fan-out deterministic policy when PNG is the minority.
    if (( png_count * 2 < image_count )); then
        printf '%s\t%s\t%s\theuristic-jpeg-dominant\n' "$jobs" "$threads" "$budget"
        return 0
    fi
    if [[ ${HARDCORE_ARCHIVE_IMAGE_CALIBRATION_DISABLE:-0} == 1 ]]; then
        printf '%s\t%s\t%s\theuristic-disabled\n' "$jobs" "$threads" "$budget"
        return 0
    fi
    command -v oxipng >/dev/null 2>&1 || {
        printf '%s\t%s\t%s\theuristic-no-oxipng\n' "$jobs" "$threads" "$budget"
        return 0
    }
    command -v python3 >/dev/null 2>&1 || {
        printf '%s\t%s\t%s\theuristic-no-python\n' "$jobs" "$threads" "$budget"
        return 0
    }

    calibrator=${HARDCORE_ARCHIVE_IMAGE_CALIBRATOR:-"$(dirname -- "${BASH_SOURCE[0]}")/hardcore-archive-image-calibrate.py"}
    cache_dir=${HARDCORE_ARCHIVE_IMAGE_SCHEDULER_CACHE_DIR:-}
    [[ -f $calibrator && -n $cache_dir ]] || {
        printf '%s\t%s\t%s\theuristic-no-calibrator\n' "$jobs" "$threads" "$budget"
        return 0
    }

    worker_cap=$(hardcore_images_worker_cap "$cpu_threads" "$available_mib") || return 2
    args=(
        "$calibrator"
        --oxipng "$(command -v oxipng)"
        --cpu-threads "$cpu_threads"
        --max-workers "$worker_cap"
        --cache-dir "$cache_dir"
        --cpu-model "$cpu_model"
        --platform "${PLATFORM_ID:-unknown}"
    )
    [[ $analyze_only == true ]] && args+=(--cache-only)
    [[ ${HARDCORE_ARCHIVE_IMAGE_CALIBRATION_REFRESH:-0} == 1 ]] && args+=(--refresh)

    if ! result=$(python3 "${args[@]}"); then
        printf '%s\t%s\t%s\theuristic-calibration-unavailable\n' "$jobs" "$threads" "$budget"
        return 0
    fi
    IFS=$'\t' read -r calibrated_jobs calibrated_threads calibrated_budget calibrated_source <<< "$result"
    [[ $calibrated_jobs =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $calibrated_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $calibrated_budget =~ ^[1-9][0-9]*$ ]] || return 2

    # The cache is machine/worker-cap specific rather than source-count specific.
    # Clamp to the current number of files and redistribute the full CPU budget.
    if (( calibrated_jobs > image_count )); then
        calibrated_jobs=$image_count
        (( calibrated_jobs < 1 )) && calibrated_jobs=1
        calibrated_threads=$(((cpu_threads + calibrated_jobs - 1) / calibrated_jobs))
        calibrated_source="${calibrated_source}-clamped"
    fi
    if (( calibrated_jobs > worker_cap )); then
        calibrated_jobs=$worker_cap
        calibrated_threads=$(((cpu_threads + calibrated_jobs - 1) / calibrated_jobs))
        calibrated_source="${calibrated_source}-memory-clamped"
    fi

    printf '%s\t%s\t%s\t%s\n' \
        "$calibrated_jobs" "$calibrated_threads" "$cpu_threads" "${calibrated_source:-calibrated}"
}
