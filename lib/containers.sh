#!/usr/bin/env bash

# Format-preserving application-container runtime boundary.
[[ ${HARDCORE_CONTAINERS_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_CONTAINERS_SH_LOADED=1

hardcore_containers_apply_runtime_patch() {
    local input_core=$1 output_core=$2
    python3 "$HARDCORE_CONTAINER_PATCHER" "$input_core" "$output_core" || {
        printf 'Error: refusing to start with a stale container-repack engine.\n' >&2
        return 3
    }
}
