#!/usr/bin/env bash

set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
# shellcheck source=/dev/null
source "$ROOT/lib/common.sh"

cleanup() {
    set +e
    hardcore_process_cancel_all 2>/dev/null || true
}
trap cleanup EXIT

# An empty cleanup must not permanently disable a later run's cancellation.
hardcore_process_cancel_all

if command -v setsid >/dev/null 2>&1; then
    setsid bash -c 'trap "" TERM; sleep 30 & wait' &
    grouped_pid=$!
    grouped=true
else
    bash -c 'sleep 30 & wait' &
    grouped_pid=$!
    grouped=false
fi
hardcore_process_register "$grouped_pid" "$grouped" grouped-child
sleep 0.1
hardcore_process_cancel_all
if kill -0 "$grouped_pid" 2>/dev/null; then
    printf 'Grouped child survived cancellation: %s\n' "$grouped_pid" >&2
    exit 1
fi

# Verify the fallback tree walk also terminates a child below the registered
# process when process groups are unavailable.
bash -c 'sleep 30 & wait' &
tree_pid=$!
hardcore_process_register "$tree_pid" false descendant-child
sleep 0.1
hardcore_process_cancel_all
if kill -0 "$tree_pid" 2>/dev/null; then
    printf 'Descendant child survived fallback cancellation: %s\n' "$tree_pid" >&2
    exit 1
fi

(( ${#HARDCORE_PROCESS_REGISTRY_PIDS[@]} == 0 ))
printf 'Cancellation cleanup tests passed.\n'
