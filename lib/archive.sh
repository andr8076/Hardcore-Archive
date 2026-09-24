#!/usr/bin/env bash

# Static archive-engine boundary. The final engine is checked in and syntax
# checked by the test suite; runtime source patching is deliberately forbidden.
[[ ${HARDCORE_ARCHIVE_MODULE_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_ARCHIVE_MODULE_SH_LOADED=1

# Keep automatic dictionaries no larger than the data lane, but do not
# reject a caller-pinned dictionary merely because the lane is smaller. 7-Zip
# permits that; memory limits are checked before this policy is reached.
hardcore_archive_lzma_dictionary_candidate_allowed() {
    local candidate=${1:-}
    local lane_mib=${2:-}
    local format_limit_mib=${3:-}
    local overridden=${4:-}

    [[ $candidate =~ ^[0-9]+$ && $lane_mib =~ ^[0-9]+$ && \
       $format_limit_mib =~ ^[0-9]+$ ]] || return 1
    [[ $overridden == true || $overridden == false ]] || return 1
    (( candidate >= 4 && candidate <= format_limit_mib )) || return 1
    if [[ $overridden == false ]] && (( candidate > lane_mib )); then
        return 1
    fi
    return 0
}

hardcore_archive_static_engine_ready() {
    hardcore_require_file "$HARDCORE_CORE_SOURCE" 'static archive engine'
}
