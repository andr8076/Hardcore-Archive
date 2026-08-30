#!/usr/bin/env bash

# Runtime engine preparer for Hardcore Archive.
#
# Stable policy/core sources are retained in the repository. The public runner
# creates a private runtime copy and applies deterministic, fail-closed policy
# and engine patches before executing a create job.

if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 || ( ${BASH_VERSINFO[0]:-0} -eq 4 && ${BASH_VERSINFO[1]:-0} -lt 2 ) ]]; then
    printf 'Error: hardcore-archive requires Bash 4.2 or newer.\n' >&2
    exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
POLICY_RUNNER="$SCRIPT_DIR/hardcore-archive-runner-policy.sh"
CORE_SOURCE="$SCRIPT_DIR/lib/hardcore-archive-core.sh"
POLICY_PATCHER="$SCRIPT_DIR/lib/hardcore-archive-policy-updates.py"
COPY_LANE_PATCHER="$SCRIPT_DIR/lib/hardcore-archive-copy-lane.py"
MEDIA_FIX_PATCHER="$SCRIPT_DIR/lib/hardcore-archive-media-fixes.py"
HARDWARE_VIDEO_PATCHER="$SCRIPT_DIR/lib/hardcore-archive-hardware-video.py"
CONTAINER_PATCHER="$SCRIPT_DIR/lib/hardcore-archive-container-lane.py"
CONTAINER_HELPER="$SCRIPT_DIR/lib/hardcore-archive-container-repack.py"

for required in \
    "$POLICY_RUNNER" "$CORE_SOURCE" "$POLICY_PATCHER" "$COPY_LANE_PATCHER" \
    "$MEDIA_FIX_PATCHER" "$HARDWARE_VIDEO_PATCHER" "$CONTAINER_PATCHER" "$CONTAINER_HELPER"
do
    [[ -f $required ]] || {
        printf 'Error: Hardcore Archive runtime component is missing: %s\n' "$required" >&2
        exit 1
    }
done

DIRECT_POLICY=false
for arg in "$@"; do
    case $arg in
        -h|--help|--doctor|--inspect|--restore|--version)
            DIRECT_POLICY=true
            break
            ;;
    esac
done

run_policy() {
    local runner=$1
    shift
    bash -c 'runner=$1; shift; source "$runner"' "$0" "$runner" "$@"
}

# Create jobs always keep a permanent transcript. This starts before runtime
# patching and the doctor so Ctrl+C/failures still leave a useful record.
LIVE_LOG=''
DIAGNOSTIC_DIR=''
if ! $DIRECT_POLICY; then
    command -v tee >/dev/null 2>&1 || {
        printf 'Error: tee is required for the persistent run log. Install/restore coreutils and rerun.\n' >&2
        exit 3
    }
    kernel=$(uname -s 2>/dev/null || printf unknown)
    if [[ $kernel == Darwin ]]; then
        state_root="${HOME}/Library/Logs/Hardcore Archive"
    else
        state_root="${XDG_STATE_HOME:-$HOME/.local/state}/hardcore-archive"
    fi
    run_stamp=$(date '+%Y%m%d-%H%M%S')
    DIAGNOSTIC_DIR="$state_root/runs/${run_stamp}-$$"
    mkdir -p -- "$DIAGNOSTIC_DIR"
    LIVE_LOG="$DIAGNOSTIC_DIR/run.log"
    : > "$LIVE_LOG"
    export HARDCORE_ARCHIVE_LIVE_LOG="$LIVE_LOG"
    export HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$DIAGNOSTIC_DIR"
    exec > >(tee -a "$LIVE_LOG") 2> >(tee -a "$LIVE_LOG" >&2)
    printf 'Persistent run log: %s\n' "$LIVE_LOG"
    printf 'Run diagnostics:    %s\n' "$DIAGNOSTIC_DIR"
    printf 'Started:            %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
    printf 'Working directory:  %s\n' "$PWD"
    printf 'Command:'
    printf ' %q' "$0" "$@"
    printf '\n\n'
fi

# Python is a strict create capability and also powers the deterministic runtime
# policy/engine patches. If it is missing, delegate to the stable frontend so
# its doctor can report the normal MISSING diagnosis and exact repair command.
if ! command -v python3 >/dev/null 2>&1; then
    exec bash -c 'runner=$1; shift; source "$runner"' "$0" "$POLICY_RUNNER" "$@"
fi

RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-archive-runtime.XXXXXX")
cleanup_runtime() {
    local exit_status=$?
    trap - EXIT HUP INT TERM
    if [[ -n ${LIVE_LOG:-} ]]; then
        {
            printf '\nFinished: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
            printf 'Exit status: %s\n' "$exit_status"
        } >> "$LIVE_LOG" 2>/dev/null || true
    fi
    [[ -n ${RUNTIME_DIR:-} && -d ${RUNTIME_DIR:-} ]] && rm -rf -- "$RUNTIME_DIR" 2>/dev/null || true
    return "$exit_status"
}
trap cleanup_runtime EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
mkdir -p -- "$RUNTIME_DIR/lib"

RUNTIME_POLICY="$RUNTIME_DIR/hardcore-archive-runner-policy.sh"
if ! python3 "$POLICY_PATCHER" "$POLICY_RUNNER" "$RUNTIME_POLICY"; then
    printf 'Error: refusing to start with stale archive policy.\n' >&2
    exit 3
fi

for module in \
    hardcore-archive-doctor.sh \
    hardcore-archive-doctor-base.sh \
    hardcore-archive-doctor-checks.sh \
    hardcore-archive-doctor-video-fix.sh \
    hardcore-archive-doctor-report.sh
do
    [[ -f $SCRIPT_DIR/lib/$module ]] || {
        printf 'Error: Hardcore Archive doctor module is missing: %s\n' "$SCRIPT_DIR/lib/$module" >&2
        exit 1
    }
    ln -s -- "$SCRIPT_DIR/lib/$module" "$RUNTIME_DIR/lib/$module"
done

export HARDCORE_ARCHIVE_CONTAINER_HELPER="$CONTAINER_HELPER"

if $DIRECT_POLICY; then
    # Non-create commands still need the stable core path for inspect/restore/
    # version. Help/doctor never enter it.
    ln -s -- "$CORE_SOURCE" "$RUNTIME_DIR/lib/hardcore-archive-core.sh"
    set +e
    run_policy "$RUNTIME_POLICY" "$@"
    rc=$?
    set -e
    exit "$rc"
fi

# Engine patchers are deliberately fail-closed: every expected anchor must
# match exactly once. A changed/incompatible engine is reported instead of
# silently reverting to stale compression behavior.
COPY_PATCHED_CORE="$RUNTIME_DIR/lib/.hardcore-archive-core.copy-lane.sh"
MEDIA_PATCHED_CORE="$RUNTIME_DIR/lib/.hardcore-archive-core.media.sh"
HARDWARE_PATCHED_CORE="$RUNTIME_DIR/lib/.hardcore-archive-core.hardware.sh"
if ! python3 "$COPY_LANE_PATCHER" "$CORE_SOURCE" "$COPY_PATCHED_CORE"; then
    printf 'Error: refusing to start with an unpatched archive engine.\n' >&2
    exit 3
fi
if ! python3 "$MEDIA_FIX_PATCHER" "$COPY_PATCHED_CORE" "$MEDIA_PATCHED_CORE"; then
    printf 'Error: refusing to start with a stale video/nested archive engine.\n' >&2
    exit 3
fi
if ! python3 "$HARDWARE_VIDEO_PATCHER" "$MEDIA_PATCHED_CORE" "$HARDWARE_PATCHED_CORE"; then
    printf 'Error: refusing to start with a video engine that can fall back to CPU encoding.\n' >&2
    exit 3
fi
if ! python3 "$CONTAINER_PATCHER" "$HARDWARE_PATCHED_CORE" "$RUNTIME_DIR/lib/hardcore-archive-core.sh"; then
    printf 'Error: refusing to start with a stale container-repack engine.\n' >&2
    exit 3
fi
rm -f -- "$COPY_PATCHED_CORE" "$MEDIA_PATCHED_CORE" "$HARDWARE_PATCHED_CORE"

set +e
run_policy "$RUNTIME_POLICY" "$@"
rc=$?
set -e
exit "$rc"
