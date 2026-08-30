#!/usr/bin/env bash

# Runtime component plan. Compression/resource planning inside the legacy engine
# will migrate here in later mechanical steps.
[[ ${HARDCORE_PLANNER_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_PLANNER_SH_LOADED=1

hardcore_planner_init_runtime_paths() {
    HARDCORE_ROOT=$(hardcore_root_dir)
    HARDCORE_POLICY_RUNNER="$HARDCORE_ROOT/hardcore-archive-runner-policy.sh"
    HARDCORE_CORE_SOURCE="$HARDCORE_ROOT/lib/hardcore-archive-core.sh"
    HARDCORE_POLICY_PATCHER="$HARDCORE_ROOT/lib/hardcore-archive-policy-updates.py"
    HARDCORE_COPY_LANE_PATCHER="$HARDCORE_ROOT/lib/hardcore-archive-copy-lane.py"
    HARDCORE_MEDIA_FIX_PATCHER="$HARDCORE_ROOT/lib/hardcore-archive-media-fixes.py"
    HARDCORE_HARDWARE_VIDEO_PATCHER="$HARDCORE_ROOT/lib/hardcore-archive-hardware-video.py"
    HARDCORE_VIDEO_CALIBRATION_PATCHER="$HARDCORE_ROOT/lib/hardcore-archive-video-calibration.py"
    HARDCORE_NESTED_DIAGNOSTICS_PATCHER="$HARDCORE_ROOT/lib/hardcore-archive-nested-diagnostics.py"
    HARDCORE_CONTAINER_PATCHER="$HARDCORE_ROOT/lib/hardcore-archive-container-lane.py"
    HARDCORE_CONTAINER_HELPER="$HARDCORE_ROOT/lib/hardcore-archive-container-repack.py"

    local required
    for required in \
        "$HARDCORE_POLICY_RUNNER" "$HARDCORE_CORE_SOURCE" "$HARDCORE_POLICY_PATCHER" \
        "$HARDCORE_COPY_LANE_PATCHER" "$HARDCORE_MEDIA_FIX_PATCHER" \
        "$HARDCORE_HARDWARE_VIDEO_PATCHER" "$HARDCORE_VIDEO_CALIBRATION_PATCHER" \
        "$HARDCORE_NESTED_DIAGNOSTICS_PATCHER" "$HARDCORE_CONTAINER_PATCHER" \
        "$HARDCORE_CONTAINER_HELPER"
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
