#!/usr/bin/env bash
[[ ${HARDCORE_RESTORE_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_RESTORE_SH_LOADED=1

hardcore_restore_command_selected() {
    local arg
    for arg in "$@"; do
        [[ $arg == --restore ]] && return 0
    done
    return 1
}
