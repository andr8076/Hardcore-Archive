#!/usr/bin/env bash

# Image scheduling and policy shared by the checked-in static engine.
[[ ${HARDCORE_IMAGES_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_IMAGES_SH_LOADED=1

hardcore_images_runtime_ready() { return 0; }

# Print: jobs<TAB>threads-per-worker<TAB>cpu-budget
#
# Automatic image scheduling is intentionally aggressive. Image workers run at
# reduced process priority, so they may claim every logical CPU when it is idle
# while yielding promptly to the primary LZMA/video work under contention.
# Prefer file-level parallelism first because JPEG tools and parts of PNG
# optimization are serial; give each worker more internal threads only when the
# source has fewer images than available CPUs or RAM limits process fan-out.
hardcore_images_compute_cpu_schedule() {
    local cpu_threads=$1 image_count=$2 requested_jobs=${3:-auto} available_mib=${4:-0}
    local jobs threads worker_cap memory_cap

    [[ $cpu_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $image_count =~ ^[0-9]+$ ]] || return 2
    [[ $requested_jobs == auto || $requested_jobs =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $available_mib =~ ^[0-9]+$ ]] || return 2

    if (( image_count == 0 )); then
        printf '0\t1\t0\n'
        return 0
    fi

    # Cap process fan-out, not CPU usage. Large CPUs feed more Rayon threads to
    # each worker once this limit is reached.
    worker_cap=$cpu_threads
    (( worker_cap > 32 )) && worker_cap=32

    # Each active image worker already reserves 256 MiB elsewhere in the core.
    # Keep the aggregate reserve around <=25% of currently available RAM by
    # allowing roughly one worker per GiB. CPU saturation is preserved by giving
    # fewer workers more internal OxiPNG threads.
    if (( available_mib > 0 )); then
        memory_cap=$((available_mib / 1024))
        (( memory_cap < 1 )) && memory_cap=1
        (( worker_cap > memory_cap )) && worker_cap=$memory_cap
    fi

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
