#!/usr/bin/env bash

# Top-level runtime coordinator. Keep orchestration here; feature policy belongs
# in its dedicated module.
[[ ${HARDCORE_SCHEDULER_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_SCHEDULER_SH_LOADED=1

HARDCORE_LIB_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
for module in common platform reporting inventory verify restore planner doctor images video nested containers visual archive runtime; do
    # shellcheck source=/dev/null
    source "$HARDCORE_LIB_DIR/$module.sh"
done

hardcore_runtime_cleanup() {
    local exit_status=$?
    trap - EXIT HUP INT TERM
    hardcore_reporting_finish "$exit_status"
    return "$exit_status"
}

hardcore_runtime_main() {
    hardcore_require_bash || return 1
    hardcore_planner_init_runtime_paths || return 1
    hardcore_archive_static_engine_ready || return 1

    local rc
    if hardcore_planner_direct_policy_mode "$@"; then
        :
    else
        hardcore_reporting_start "$@" || return $?
    fi

    trap hardcore_runtime_cleanup EXIT
    trap 'exit 129' HUP
    trap 'exit 130' INT
    trap 'exit 143' TERM

    export HARDCORE_ARCHIVE_CONTAINER_HELPER="$HARDCORE_CONTAINER_HELPER"
    export HARDCORE_ARCHIVE_METADATA_HELPER="$HARDCORE_METADATA_HELPER"
    hardcore_enable_adaptive_hash_verifier

    set +e
    hardcore_run_sourced "$HARDCORE_POLICY_RUNNER" "$@"
    rc=$?
    set -e
    return "$rc"
}
