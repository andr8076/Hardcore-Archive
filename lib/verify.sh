#!/usr/bin/env bash
[[ ${HARDCORE_VERIFY_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_VERIFY_SH_LOADED=1

hardcore_verify_command_selected() {
    local arg
    for arg in "$@"; do
        [[ $arg == --inspect ]] && return 0
    done
    return 1
}
