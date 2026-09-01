#!/usr/bin/env bash

# Static runtime component plan. The executable policy and archive engine are
# checked-in sources; startup never rewrites either one.
[[ ${HARDCORE_PLANNER_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_PLANNER_SH_LOADED=1

hardcore_planner_init_runtime_paths() {
    HARDCORE_ROOT=$(hardcore_root_dir)
    HARDCORE_POLICY_RUNNER="$HARDCORE_ROOT/hardcore-archive-runner-policy.sh"
    HARDCORE_CORE_SOURCE="$HARDCORE_ROOT/lib/hardcore-archive-core.sh"
    HARDCORE_CONTAINER_HELPER="$HARDCORE_ROOT/lib/hardcore-archive-container-repack.py"
    HARDCORE_METADATA_HELPER="$HARDCORE_ROOT/lib/hardcore-archive-metadata.py"

    local required
    for required in \
        "$HARDCORE_POLICY_RUNNER" "$HARDCORE_CORE_SOURCE" \
        "$HARDCORE_CONTAINER_HELPER" "$HARDCORE_METADATA_HELPER"
    do
        hardcore_require_file "$required" || return 1
    done
}

hardcore_planner_direct_policy_mode() {
    hardcore_inventory_diagnostic_command_selected "$@" && return 0
    hardcore_verify_command_selected "$@" && return 0
    hardcore_restore_command_selected "$@" && return 0
    return 1
}
