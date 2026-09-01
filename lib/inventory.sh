#!/usr/bin/env bash

# Command/source-inventory routing boundary. The source classifier currently
# lives in the checked-in static engine.
[[ ${HARDCORE_INVENTORY_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_INVENTORY_SH_LOADED=1

hardcore_inventory_diagnostic_command_selected() {
    local arg
    for arg in "$@"; do
        case $arg in
            -h|--help|--doctor|--version) return 0 ;;
        esac
    done
    return 1
}
