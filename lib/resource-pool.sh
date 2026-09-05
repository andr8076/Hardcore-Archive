#!/usr/bin/env bash

# Shared CPU/RAM scheduling policy for concurrent archive lanes.
[[ ${HARDCORE_RESOURCE_POOL_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_RESOURCE_POOL_SH_LOADED=1

hardcore_resource_pool_runtime_ready() { return 0; }

hardcore_resource_media_initial_cpu() {
    local cpu_threads=$1 lzma_threads=$2 lzma_count=$3 initial
    [[ $cpu_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $lzma_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $lzma_count =~ ^[0-9]+$ ]] || return 2
    if (( lzma_count == 0 )); then
        printf '%s\n' "$cpu_threads"
        return 0
    fi
    initial=$((cpu_threads - lzma_threads))
    (( initial < 0 )) && initial=0
    printf '%s\n' "$initial"
}

hardcore_resource_media_initial_ram() {
    local memory_budget_mib=$1 lzma_ram_mib=$2 lzma_count=$3 initial
    [[ $memory_budget_mib =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $lzma_ram_mib =~ ^[0-9]+$ ]] || return 2
    [[ $lzma_count =~ ^[0-9]+$ ]] || return 2
    if (( lzma_count == 0 )); then
        printf '%s\n' "$memory_budget_mib"
        return 0
    fi
    initial=$((memory_budget_mib - lzma_ram_mib))
    (( initial < 0 )) && initial=0
    printf '%s\n' "$initial"
}

hardcore_resource_quality_cpu_threads() {
    local cpu_threads=$1 quality_check=$2 requested=${HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS:-auto}
    local quality
    [[ $cpu_threads =~ ^[1-9][0-9]*$ ]] || return 2
    if [[ $quality_check == off ]]; then
        printf '0\n'
        return 0
    fi
    if [[ $requested == auto ]]; then
        quality=$cpu_threads
        (( quality > 8 )) && quality=8
    else
        [[ $requested =~ ^([1-9]|[1-5][0-9]|6[0-4])$ ]] || return 2
        quality=$requested
        (( quality > cpu_threads )) && quality=$cpu_threads
    fi
    printf '%s\n' "$quality"
}

hardcore_resource_video_cpu_claim() {
    local cpu_threads=$1 quality_check=$2 quality claim
    quality=$(hardcore_resource_quality_cpu_threads "$cpu_threads" "$quality_check") || return 2
    # Hardware video still needs decode/control CPU. Keep the same +2 allowance
    # used by the existing batch resource planner around VMAF workers.
    claim=$((quality + 2))
    (( claim < 1 )) && claim=1
    (( claim > cpu_threads )) && claim=$cpu_threads
    printf '%s\n' "$claim"
}

hardcore_resource_pool_init() {
    local runner=$1 pool=$2 cpu_initial=$3 cpu_max=$4 ram_initial=$5 ram_max=$6
    [[ -f $runner ]] || return 2
    python3 "$runner" init \
        --pool "$pool" \
        --cpu-initial "$cpu_initial" \
        --cpu-max "$cpu_max" \
        --ram-initial-mib "$ram_initial" \
        --ram-max-mib "$ram_max" \
        --ram-chunk-mib 64
}

hardcore_resource_pool_expand_full() {
    local runner=$1 pool=$2 cpu_max=$3 ram_max=$4
    [[ -f $runner ]] || return 2
    python3 "$runner" expand \
        --pool "$pool" \
        --cpu-total "$cpu_max" \
        --ram-total-mib "$ram_max"
}
