#!/usr/bin/env bash

# Persistent run transcript and failure-diagnostic directory handling.
[[ ${HARDCORE_REPORTING_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_REPORTING_SH_LOADED=1

HARDCORE_LIVE_LOG=''
HARDCORE_DIAGNOSTIC_DIR=''

hardcore_reporting_start() {
    command -v tee >/dev/null 2>&1 || {
        printf 'Error: tee is required for the persistent run log. Install/restore coreutils and rerun.\n' >&2
        return 3
    }
    local state_root run_stamp
    state_root=$(hardcore_state_root)
    run_stamp=$(date '+%Y%m%d-%H%M%S')
    HARDCORE_DIAGNOSTIC_DIR="$state_root/runs/${run_stamp}-$$"
    mkdir -p -- "$HARDCORE_DIAGNOSTIC_DIR"
    HARDCORE_LIVE_LOG="$HARDCORE_DIAGNOSTIC_DIR/run.log"
    : > "$HARDCORE_LIVE_LOG"
    export HARDCORE_ARCHIVE_LIVE_LOG="$HARDCORE_LIVE_LOG"
    export HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$HARDCORE_DIAGNOSTIC_DIR"
    exec > >(tee -a "$HARDCORE_LIVE_LOG") 2> >(tee -a "$HARDCORE_LIVE_LOG" >&2)
    printf 'Persistent run log: %s\n' "$HARDCORE_LIVE_LOG"
    printf 'Run diagnostics:    %s\n' "$HARDCORE_DIAGNOSTIC_DIR"
    printf 'Started:            %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Working directory:  %s\n' "$PWD"
    printf 'Command:'
    printf ' %q' "$0" "$@"
    printf '\n\n'
}

hardcore_reporting_finish() {
    local exit_status=$1
    [[ -n ${HARDCORE_LIVE_LOG:-} ]] || return 0
    {
        printf '\nFinished: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
        printf 'Exit status: %s\n' "$exit_status"
    } >> "$HARDCORE_LIVE_LOG" 2>/dev/null || true
}
