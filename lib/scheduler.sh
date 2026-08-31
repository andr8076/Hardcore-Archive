#!/usr/bin/env bash

# Top-level runtime coordinator. Keep orchestration here; feature policy belongs
# in its dedicated module.
[[ ${HARDCORE_SCHEDULER_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_SCHEDULER_SH_LOADED=1

HARDCORE_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for module in common platform reporting inventory verify restore planner doctor images video nested containers visual archive; do
    # shellcheck source=/dev/null
    source "$HARDCORE_LIB_DIR/$module.sh"
done

hardcore_runtime_cleanup() {
    local exit_status=$?
    trap - EXIT HUP INT TERM
    hardcore_reporting_finish "$exit_status"
    hardcore_archive_cleanup_runtime_dir
    return "$exit_status"
}

hardcore_runtime_main() {
    hardcore_require_bash || return 1
    hardcore_planner_init_runtime_paths || return 1

    local direct_policy=false rc
    if hardcore_planner_direct_policy_mode "$@"; then
        direct_policy=true
    else
        hardcore_reporting_start "$@" || return $?
    fi

    # Python powers the deterministic transition patchers. If missing, delegate
    # to the stable policy so its doctor can report the normal repair command.
    if ! command -v python3 >/dev/null 2>&1; then
        exec bash -c 'runner=$1; shift; source "$runner"' "$0" "$HARDCORE_POLICY_RUNNER" "$@"
    fi

    hardcore_archive_prepare_runtime_dir || return $?
    trap hardcore_runtime_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    hardcore_archive_patch_policy || return $?
    hardcore_doctor_link_runtime_modules "$HARDCORE_RUNTIME_DIR" || return $?
    export HARDCORE_ARCHIVE_CONTAINER_HELPER="$HARDCORE_CONTAINER_HELPER"

    if $direct_policy; then
        hardcore_archive_link_stable_core || return $?
    else
        hardcore_archive_build_runtime_core || return $?
    fi

    set +e
    hardcore_run_sourced "$HARDCORE_RUNTIME_POLICY" "$@"
    rc=$?
    set -e
    return "$rc"
}
