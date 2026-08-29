#!/usr/bin/env bash

# Runtime engine preparer for Hardcore Archive.
#
# The policy/doctor frontend is kept byte-for-byte in
# hardcore-archive-runner-policy.sh.  Create workflows get a private runtime
# copy of the legacy engine with deterministic engine patches applied before the
# policy runner delegates to it.  Read-only commands do not need an engine copy.

if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 || ( ${BASH_VERSINFO[0]:-0} -eq 4 && ${BASH_VERSINFO[1]:-0} -lt 2 ) ]]; then
    printf 'Error: hardcore-archive requires Bash 4.2 or newer.\n' >&2
    exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
POLICY_RUNNER="$SCRIPT_DIR/hardcore-archive-runner-policy.sh"
CORE_SOURCE="$SCRIPT_DIR/lib/hardcore-archive-core.sh"
COPY_LANE_PATCHER="$SCRIPT_DIR/lib/hardcore-archive-copy-lane.py"

for required in "$POLICY_RUNNER" "$CORE_SOURCE" "$COPY_LANE_PATCHER"; do
    [[ -f $required ]] || {
        printf 'Error: Hardcore Archive runtime component is missing: %s\n' "$required" >&2
        exit 1
    }
done

# These commands never enter the create engine, so avoid generating a runtime
# engine merely to print help/doctor output or inspect/restore an existing file.
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

if $DIRECT_POLICY; then
    exec bash -c 'runner=$1; shift; source "$runner"' "$0" "$POLICY_RUNNER" "$@"
fi

# Python is already a strict create-mode capability. If it is absent, delegate
# to the policy runner unchanged so its doctor can produce the normal MISSING
# diagnosis and exact repair command rather than failing here with less context.
if ! command -v python3 >/dev/null 2>&1; then
    exec bash -c 'runner=$1; shift; source "$runner"' "$0" "$POLICY_RUNNER" "$@"
fi

RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-archive-runtime.XXXXXX")
cleanup_runtime() {
    [[ -n ${RUNTIME_DIR:-} && -d ${RUNTIME_DIR:-} ]] && rm -rf -- "$RUNTIME_DIR" 2>/dev/null || true
}
trap cleanup_runtime EXIT HUP INT TERM

mkdir -p -- "$RUNTIME_DIR/lib"
cp -- "$POLICY_RUNNER" "$RUNTIME_DIR/hardcore-archive-runner-policy.sh"

# The patcher is deliberately fail-closed: every expected legacy-core anchor
# must match exactly once. A changed/incompatible engine is therefore reported
# instead of silently reverting to recompressing already-compressed files.
if ! python3 "$COPY_LANE_PATCHER" "$CORE_SOURCE" "$RUNTIME_DIR/lib/hardcore-archive-core.sh"; then
    printf 'Error: refusing to start with an unpatched archive engine.\n' >&2
    exit 3
fi

for module in \
    hardcore-archive-doctor.sh \
    hardcore-archive-doctor-base.sh \
    hardcore-archive-doctor-checks.sh \
    hardcore-archive-doctor-report.sh
do
    [[ -f $SCRIPT_DIR/lib/$module ]] || {
        printf 'Error: Hardcore Archive doctor module is missing: %s\n' "$SCRIPT_DIR/lib/$module" >&2
        exit 1
    }
    ln -s -- "$SCRIPT_DIR/lib/$module" "$RUNTIME_DIR/lib/$module"
done

set +e
run_policy "$RUNTIME_DIR/hardcore-archive-runner-policy.sh" "$@"
rc=$?
set -e
exit "$rc"
