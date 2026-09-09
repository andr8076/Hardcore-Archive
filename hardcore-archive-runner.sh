#!/usr/bin/env bash

# Compatibility runtime entrypoint. Runtime orchestration now lives in
# lib/scheduler.sh and feature-specific modules.
if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 || ( ${BASH_VERSINFO[0]:-0} -eq 4 && ${BASH_VERSINFO[1]:-0} -lt 2 ) ]]; then
    printf 'Error: hardcore-archive requires Bash 4.2 or newer.\n' >&2
    exit 1
fi
set -Eeuo pipefail
IFS=$'\n\t'

HARDCORE_ARCHIVE_ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
export HARDCORE_ARCHIVE_ROOT
# shellcheck source=/dev/null
source "$HARDCORE_ARCHIVE_ROOT/lib/runtime.sh"
hardcore_runtime_prepare_toolchain
# shellcheck source=/dev/null
source "$HARDCORE_ARCHIVE_ROOT/lib/scheduler.sh"
hardcore_runtime_main "$@"
