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
    claim=$((quality + 2))
    (( claim < 1 )) && claim=1
    (( claim > cpu_threads )) && claim=$cpu_threads
    printf '%s\n' "$claim"
}

# Target at most four independent recursive children. On the common eight-thread
# machine this gives each busy child two CPU tokens, preserving the normal LZMA2
# ratio policy while allowing four unrelated nested archives to make progress.
hardcore_resource_nested_cpu_max() {
    local cpu_threads=$1 nested_count=$2 target cpu_max
    [[ $cpu_threads =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $nested_count =~ ^[1-9][0-9]*$ ]] || return 2
    target=$nested_count
    (( target > 4 )) && target=4
    (( target > cpu_threads )) && target=$cpu_threads
    (( target < 1 )) && target=1
    cpu_max=$(((cpu_threads + target - 1) / target))
    (( cpu_max > 8 )) && cpu_max=8
    (( cpu_max < 1 )) && cpu_max=1
    printf '%s\n' "$cpu_max"
}

# Reproduce the core engine's automatic dictionary choice, but against the RAM
# actually reserved for this recursive worker instead of the whole host. The
# default 256 MiB headroom covers one image worker overlapping child LZMA2.
hardcore_resource_nested_dictionary_mib() {
    local expanded_bytes=$1 pool_max_mib=$2 format_max_mib=${3:-4096} extra_mib=${4:-256}
    local mib=1048576 expanded_mib usable_mib max_by_ram limit dict=4 candidate
    local -a candidates=(4096 3072 2048 1536 1024 768 512 384 256 192 128 96 64 48 32 24 16 12 8 4)

    [[ $expanded_bytes =~ ^[0-9]+$ ]] || return 2
    [[ $pool_max_mib =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $format_max_mib =~ ^[1-9][0-9]*$ ]] || return 2
    [[ $extra_mib =~ ^[0-9]+$ ]] || return 2

    expanded_mib=$(((expanded_bytes + mib - 1) / mib))
    (( expanded_mib < 4 )) && expanded_mib=4
    usable_mib=$((pool_max_mib - extra_mib))
    (( usable_mib < 0 )) && usable_mib=0
    if (( usable_mib > 512 )); then
        max_by_ram=$(((usable_mib - 512) * 2 / 23))
    else
        max_by_ram=4
    fi
    (( max_by_ram < 4 )) && max_by_ram=4

    limit=$format_max_mib
    (( limit > max_by_ram )) && limit=$max_by_ram
    (( limit > expanded_mib )) && limit=$expanded_mib
    (( limit < 4 )) && limit=4
    for candidate in "${candidates[@]}"; do
        if (( candidate <= limit )); then
            dict=$candidate
            break
        fi
    done
    printf '%s\n' "$dict"
}

hardcore_resource_nested_ram_claim() {
    local expanded_bytes=$1 pool_max_mib=$2 format_max_mib=${3:-4096} extra_mib=${4:-256}
    local dict claim
    dict=$(hardcore_resource_nested_dictionary_mib \
        "$expanded_bytes" "$pool_max_mib" "$format_max_mib" "$extra_mib") || return 2
    claim=$((dict * 23 / 2 + 512 + extra_mib))
    claim=$(((claim + 63) / 64 * 64))
    (( claim > pool_max_mib )) && claim=$pool_max_mib
    (( claim < 64 )) && claim=64
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
