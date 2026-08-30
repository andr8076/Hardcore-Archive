#!/usr/bin/env bash

# Operating-system paths and post-run platform actions.
[[ ${HARDCORE_PLATFORM_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_PLATFORM_SH_LOADED=1

hardcore_platform_name() {
    uname -s 2>/dev/null || printf unknown
}

hardcore_user_config_path() {
    local platform=${1:-$(hardcore_platform_name)}
    if [[ $platform == Darwin ]]; then
        printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/Library/Application Support}/hardcore-archive/config"
    else
        printf '%s\n' "${XDG_CONFIG_HOME:-$HOME/.config}/hardcore-archive/config"
    fi
}

hardcore_state_root() {
    local platform=${1:-$(hardcore_platform_name)}
    if [[ $platform == Darwin ]]; then
        printf '%s\n' "${HOME}/Library/Logs/Hardcore Archive"
    else
        printf '%s\n' "${XDG_STATE_HOME:-$HOME/.local/state}/hardcore-archive"
    fi
}

hardcore_prepare_poweroff_command() {
    local platform=$1
    HARDCORE_POWER_OFF_COMMAND=()
    case $platform in
        Linux)
            if ! command -v systemctl >/dev/null 2>&1; then
                printf 'Error: poweroff-on-success is enabled, but systemctl is missing. Hardcore Archive will not substitute another shutdown mechanism.\n' >&2
                printf 'Repair command (not executed):\n' >&2
                if command -v pacman >/dev/null 2>&1; then
                    printf '  sudo pacman -S --needed systemd\n' >&2
                elif command -v apt-get >/dev/null 2>&1; then
                    printf '  sudo apt-get update && sudo apt-get install -y systemd\n' >&2
                elif command -v dnf >/dev/null 2>&1; then
                    printf '  sudo dnf install systemd\n' >&2
                elif command -v zypper >/dev/null 2>&1; then
                    printf '  sudo zypper install systemd\n' >&2
                else
                    printf '  Install/restore the systemd package for this Linux distribution.\n' >&2
                fi
                return 3
            fi
            HARDCORE_POWER_OFF_COMMAND=(systemctl poweroff)
            ;;
        Darwin)
            command -v osascript >/dev/null 2>&1 || {
                printf 'Error: poweroff-on-success is enabled, but macOS osascript is unavailable.\n' >&2
                return 3
            }
            HARDCORE_POWER_OFF_COMMAND=(osascript -e 'tell application "System Events" to shut down')
            ;;
        *)
            printf 'Error: poweroff-on-success is unsupported on this operating system: %s\n' "$platform" >&2
            return 3
            ;;
    esac
}
