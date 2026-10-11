#!/usr/bin/env bash

# Shared shell primitives for Hardcore Archive modules.
[[ ${HARDCORE_COMMON_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_COMMON_SH_LOADED=1

# Background work is registered in the shell that owns the run.  Every
# registered process is either placed in its own process group or is treated as
# a best-effort single-process fallback when setsid is unavailable.  Cleanup
# must happen before staging directories are removed; otherwise a late worker
# can recreate files after the parent has finished cleaning up.
declare -a HARDCORE_PROCESS_REGISTRY_PIDS=()
declare -a HARDCORE_PROCESS_REGISTRY_GROUPS=()
declare -a HARDCORE_PROCESS_REGISTRY_LABELS=()
HARDCORE_PROCESS_CLEANUP_RUNNING=false

hardcore_process_register() {
    local pid=${1:-} group=${2:-false} label=${3:-child}
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 2
    case $group in
        true|false) ;;
        *) return 2 ;;
    esac
    HARDCORE_PROCESS_REGISTRY_PIDS+=("$pid")
    HARDCORE_PROCESS_REGISTRY_GROUPS+=("$group")
    HARDCORE_PROCESS_REGISTRY_LABELS+=("$label")
}

hardcore_process_unregister() {
    local pid=${1:-} i
    local -a remaining_pids=() remaining_groups=() remaining_labels=()
    for i in "${!HARDCORE_PROCESS_REGISTRY_PIDS[@]}"; do
        [[ ${HARDCORE_PROCESS_REGISTRY_PIDS[i]} == "$pid" ]] && continue
        remaining_pids+=("${HARDCORE_PROCESS_REGISTRY_PIDS[i]}")
        remaining_groups+=("${HARDCORE_PROCESS_REGISTRY_GROUPS[i]}")
        remaining_labels+=("${HARDCORE_PROCESS_REGISTRY_LABELS[i]}")
    done
    HARDCORE_PROCESS_REGISTRY_PIDS=("${remaining_pids[@]}")
    HARDCORE_PROCESS_REGISTRY_GROUPS=("${remaining_groups[@]}")
    HARDCORE_PROCESS_REGISTRY_LABELS=("${remaining_labels[@]}")
}

hardcore_process_signal_tree() {
    local pid=${1:-} signal=${2:-TERM} child
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 0

    # This is only a fallback for systems without setsid.  The normal path
    # signals the complete process group in one operation.
    if command -v pgrep >/dev/null 2>&1; then
        while IFS= read -r child; do
            [[ $child =~ ^[1-9][0-9]*$ ]] || continue
            hardcore_process_signal_tree "$child" "$signal"
        done < <(pgrep -P "$pid" 2>/dev/null || true)
    fi
    kill -"$signal" "$pid" 2>/dev/null || true
}

hardcore_process_signal_registered() {
    local index=$1 signal=$2 pid group
    pid=${HARDCORE_PROCESS_REGISTRY_PIDS[index]:-}
    group=${HARDCORE_PROCESS_REGISTRY_GROUPS[index]:-false}
    [[ $pid =~ ^[1-9][0-9]*$ ]] || return 0
    if [[ $group == true ]]; then
        kill -"$signal" -- "-$pid" 2>/dev/null || true
        # A process can have exited between the group signal and this check.
        kill -"$signal" "$pid" 2>/dev/null || true
    else
        hardcore_process_signal_tree "$pid" "$signal"
    fi
}

hardcore_process_cancel_all() {
    local i pid alive
    ((${#HARDCORE_PROCESS_REGISTRY_PIDS[@]} > 0)) || return 0
    [[ ${HARDCORE_PROCESS_CLEANUP_RUNNING:-false} == true ]] && return 0
    HARDCORE_PROCESS_CLEANUP_RUNNING=true

    for i in "${!HARDCORE_PROCESS_REGISTRY_PIDS[@]}"; do
        hardcore_process_signal_registered "$i" TERM
    done

    # Give cooperative children a short grace period so they can close files
    # and flush logs.  The final KILL is deliberately bounded: cancellation
    # must not leave the parent trapped in cleanup forever.
    for ((i=0; i<50; i++)); do
        alive=false
        for pid in "${HARDCORE_PROCESS_REGISTRY_PIDS[@]}"; do
            if kill -0 "$pid" 2>/dev/null; then
                alive=true
                break
            fi
        done
        $alive || break
        sleep 0.1
    done

    for i in "${!HARDCORE_PROCESS_REGISTRY_PIDS[@]}"; do
        pid=${HARDCORE_PROCESS_REGISTRY_PIDS[i]}
        if kill -0 "$pid" 2>/dev/null; then
            hardcore_process_signal_registered "$i" KILL
        fi
    done
    for pid in "${HARDCORE_PROCESS_REGISTRY_PIDS[@]}"; do
        wait "$pid" 2>/dev/null || true
    done

    HARDCORE_PROCESS_REGISTRY_PIDS=()
    HARDCORE_PROCESS_REGISTRY_GROUPS=()
    HARDCORE_PROCESS_REGISTRY_LABELS=()
    HARDCORE_PROCESS_CLEANUP_RUNNING=false
}

hardcore_require_bash() {
    if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 || ( ${BASH_VERSINFO[0]:-0} -eq 4 && ${BASH_VERSINFO[1]:-0} -lt 2 ) ]]; then
        printf 'Error: hardcore-archive requires Bash 4.2 or newer.\n' >&2
        return 1
    fi
}

hardcore_root_dir() {
    if [[ -n ${HARDCORE_ARCHIVE_ROOT:-} ]]; then
        printf '%s\n' "$HARDCORE_ARCHIVE_ROOT"
    else
        cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P
    fi
}

hardcore_require_file() {
    local path=$1 label=${2:-runtime component}
    [[ -f $path ]] || {
        printf 'Error: Hardcore Archive %s is missing: %s\n' "$label" "$path" >&2
        return 1
    }
}

hardcore_run_sourced() {
    local runner=$1 group=false pid rc
    shift
    if command -v setsid >/dev/null 2>&1; then
        setsid bash -c 'runner=$1; shift; source "$runner"' "$0" "$runner" "$@" &
        group=true
    else
        bash -c 'runner=$1; shift; source "$runner"' "$0" "$runner" "$@" &
    fi
    pid=$!
    hardcore_process_register "$pid" "$group" "sourced runner"
    if wait "$pid"; then
        rc=0
    else
        rc=$?
    fi
    hardcore_process_unregister "$pid"
    return "$rc"
}
