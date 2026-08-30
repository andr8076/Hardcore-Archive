#!/usr/bin/env bash

# Shared shell primitives for Hardcore Archive modules.
[[ ${HARDCORE_COMMON_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_COMMON_SH_LOADED=1

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
    local runner=$1
    shift
    bash -c 'runner=$1; shift; source "$runner"' "$0" "$runner" "$@"
}
