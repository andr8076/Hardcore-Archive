#!/usr/bin/env bash

# Nested-archive/media correctness runtime boundary.
[[ ${HARDCORE_NESTED_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_NESTED_SH_LOADED=1

hardcore_nested_apply_runtime_patch() {
    local input_core=$1 output_core=$2
    python3 "$HARDCORE_MEDIA_FIX_PATCHER" "$input_core" "$output_core" || {
        printf 'Error: refusing to start with a stale video/nested archive engine.\n' >&2
        return 3
    }
}
