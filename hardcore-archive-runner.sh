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
CONTAINER_PATCHER="$SCRIPT_DIR/lib/hardcore-archive-container-lane.py"
CONTAINER_HELPER="$SCRIPT_DIR/lib/hardcore-archive-container-repack.py"

for required in \
    "$POLICY_RUNNER" "$CORE_SOURCE" "$POLICY_PATCHER" "$COPY_LANE_PATCHER" \
    "$MEDIA_FIX_PATCHER" "$CONTAINER_PATCHER" "$CONTAINER_HELPER"
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

# Python is a strict create capability and also powers the deterministic runtime
# policy/engine patches. If it is missing, delegate to the stable frontend so
# its doctor can report the normal MISSING diagnosis and exact repair command.
if ! command -v python3 >/dev/null 2>&1; then
    exec bash -c 'runner=$1; shift; source "$runner"' "$0" "$POLICY_RUNNER" "$@"
fi

RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-archive-runtime.XXXXXX")
cleanup_runtime() {
    [[ -n ${RUNTIME_DIR:-} && -d ${RUNTIME_DIR:-} ]] && rm -rf -- "$RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup_runtime EXIT HUP INT TERM
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
if ! python3 "$COPY_LANE_PATCHER" "$CORE_SOURCE" "$COPY_PATCHED_CORE"; then
    printf 'Error: refusing to start with an unpatched archive engine.\n' >&2
    exit 3
fi
if ! python3 "$MEDIA_FIX_PATCHER" "$COPY_PATCHED_CORE" "$MEDIA_PATCHED_CORE"; then
    printf 'Error: refusing to start with a stale video/nested archive engine.\n' >&2
    exit 3
fi
if ! python3 "$CONTAINER_PATCHER" "$MEDIA_PATCHED_CORE" "$RUNTIME_DIR/lib/hardcore-archive-core.sh"; then
    printf 'Error: refusing to start with a stale container-repack engine.\n' >&2
    exit 3
fi
rm -f -- "$COPY_PATCHED_CORE" "$MEDIA_PATCHED_CORE"

set +e
run_policy "$RUNTIME_POLICY" "$@"
rc=$?
set -e
exit "$rc"
