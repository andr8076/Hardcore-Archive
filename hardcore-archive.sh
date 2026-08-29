#!/usr/bin/env bash

# Hardcore Archive configuration launcher.
#
# Configuration precedence:
#   1. ./config                                  shipped installation defaults
#   2. user config                               personal overrides
#   3. --config FILE                             per-run/custom overrides
#   4. command-line options                      highest priority
#
# --no-config disables external/user overrides, but the shipped ./config still
# defines the program defaults for this installation.

if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 || ( ${BASH_VERSINFO[0]:-0} -eq 4 && ${BASH_VERSINFO[1]:-0} -lt 2 ) ]]; then
    printf 'Error: hardcore-archive requires Bash 4.2 or newer.\n' >&2
    exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
RUNNER="$SCRIPT_DIR/hardcore-archive-runner.sh"
SHIPPED_CONFIG="$SCRIPT_DIR/config"

[[ -f $RUNNER ]] || {
    printf 'Error: Hardcore Archive runner is missing: %s\n' "$RUNNER" >&2
    exit 1
}
[[ -r $SHIPPED_CONFIG ]] || {
    printf 'Error: Hardcore Archive default config is missing or unreadable: %s\n' "$SHIPPED_CONFIG" >&2
    exit 1
}

PLATFORM=$(uname -s 2>/dev/null || printf unknown)
if [[ $PLATFORM == Darwin ]]; then
    USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/Library/Application Support}/hardcore-archive/config"
else
    USER_CONFIG="${XDG_CONFIG_HOME:-$HOME/.config}/hardcore-archive/config"
fi

ORIGINAL_ARGS=("$@")
IGNORE_EXTERNAL_CONFIG=false
CUSTOM_CONFIG=''
POWER_OFF_STATE=auto
POWER_OFF_EXPLICIT=false
POWER_OFF_ELIGIBLE=true
SHOW_LAUNCHER_HELP=false
AFTER_DASH_DASH=false

for ((i=0; i<${#ORIGINAL_ARGS[@]}; i++)); do
    arg=${ORIGINAL_ARGS[i]}
    if $AFTER_DASH_DASH; then
        continue
    fi
    case $arg in
        --)
            AFTER_DASH_DASH=true
            ;;
        --no-config)
            IGNORE_EXTERNAL_CONFIG=true
            ;;
        --config)
            if (( i + 1 >= ${#ORIGINAL_ARGS[@]} )); then
                printf 'Error: --config requires a file.\n' >&2
                exit 2
            fi
            CUSTOM_CONFIG=${ORIGINAL_ARGS[i+1]}
            i=$((i + 1))
            ;;
        --config=*)
            CUSTOM_CONFIG=${arg#*=}
            [[ -n $CUSTOM_CONFIG ]] || {
                printf 'Error: --config requires a file.\n' >&2
                exit 2
            }
            ;;
        --poweroff)
            POWER_OFF_STATE=true
            POWER_OFF_EXPLICIT=true
            ;;
        --no-poweroff)
            POWER_OFF_STATE=false
            POWER_OFF_EXPLICIT=true
            ;;
        -h|--help)
            SHOW_LAUNCHER_HELP=true
            POWER_OFF_ELIGIBLE=false
            ;;
        --doctor|--inspect|--restore|--version|--analyze-only)
            POWER_OFF_ELIGIBLE=false
            ;;
    esac
done

if ! $IGNORE_EXTERNAL_CONFIG && [[ -n $CUSTOM_CONFIG && ! -r $CUSTOM_CONFIG ]]; then
    printf 'Error: requested config is missing or unreadable: %s\n' "$CUSTOM_CONFIG" >&2
    exit 2
fi
if ! $IGNORE_EXTERNAL_CONFIG && [[ -e $USER_CONFIG && ! -r $USER_CONFIG ]]; then
    printf 'Error: user config exists but is unreadable: %s\n' "$USER_CONFIG" >&2
    exit 2
fi

MERGED_CONFIG=''
cleanup_config_launcher() {
    [[ -n ${MERGED_CONFIG:-} ]] && rm -f -- "$MERGED_CONFIG" 2>/dev/null || true
}
trap cleanup_config_launcher EXIT HUP INT TERM

umask 077
MERGED_CONFIG=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-config.XXXXXX")

append_config() {
    local file=$1 label=$2
    printf '# ---- %s: %s ----\n' "$label" "$file" >> "$MERGED_CONFIG"
    cat -- "$file" >> "$MERGED_CONFIG"
    printf '\n' >> "$MERGED_CONFIG"
}

append_config "$SHIPPED_CONFIG" 'shipped defaults'
if ! $IGNORE_EXTERNAL_CONFIG; then
    [[ -r $USER_CONFIG ]] && append_config "$USER_CONFIG" 'user overrides'
    [[ -n $CUSTOM_CONFIG ]] && append_config "$CUSTOM_CONFIG" 'explicit overrides'
fi

trim_config_value() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [[ $value == \"*\" && $value == *\" ]]; then
        value=${value:1:${#value}-2}
    elif [[ $value == \'*\' && $value == *\' ]]; then
        value=${value:1:${#value}-2}
    fi
    printf '%s' "$value"
}

config_value() {
    local wanted=$1 file=$2 line key value found=''
    [[ -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *=* ]] || continue
        key=$(trim_config_value "${line%%=*}")
        value=$(trim_config_value "${line#*=}")
        key=${key^^}
        [[ $key == "$wanted" ]] && found=$value
    done < "$file"
    [[ -n $found ]] || return 1
    printf '%s' "$found"
}

config_bool_value() {
    local value
    value=$(config_value "$1" "$2" || true)
    case ${value,,} in
        1|true|yes|on) printf true ;;
        0|false|no|off) printf false ;;
        *) return 1 ;;
    esac
}

CONFIG_POWER_OFF=$(config_bool_value POWER_OFF_ON_SUCCESS "$MERGED_CONFIG" || true)
if [[ $POWER_OFF_STATE == auto ]]; then
    [[ $CONFIG_POWER_OFF == true || $CONFIG_POWER_OFF == false ]] && POWER_OFF_ENABLED=$CONFIG_POWER_OFF || POWER_OFF_ENABLED=false
else
    POWER_OFF_ENABLED=$POWER_OFF_STATE
fi

if [[ $POWER_OFF_ENABLED == true && $POWER_OFF_ELIGIBLE != true ]]; then
    if [[ $POWER_OFF_EXPLICIT == true && $POWER_OFF_STATE == true ]]; then
        printf 'Error: --poweroff is only valid for archive create/batch jobs, not help, doctor, inspect, restore, version, or analyze-only runs.\n' >&2
        exit 2
    fi
    # A configured default must never make read-only/diagnostic commands power
    # the machine off. It is simply inactive outside a real archive job.
    POWER_OFF_ENABLED=false
fi

POWER_OFF_COMMAND=()
if [[ $POWER_OFF_ENABLED == true ]]; then
    case $PLATFORM in
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
                exit 3
            fi
            POWER_OFF_COMMAND=(systemctl poweroff)
            ;;
        Darwin)
            if ! command -v osascript >/dev/null 2>&1; then
                printf 'Error: poweroff-on-success is enabled, but macOS osascript is unavailable.\n' >&2
                exit 3
            fi
            POWER_OFF_COMMAND=(osascript -e 'tell application "System Events" to shut down')
            ;;
        *)
            printf 'Error: poweroff-on-success is unsupported on this operating system: %s\n' "$PLATFORM" >&2
            exit 3
            ;;
    esac
fi

# Remove launcher-owned arguments before delegating. The internal runner gets
# exactly one generated config containing the resolved layers. All other CLI
# arguments are preserved in their original order and therefore remain the
# highest-precedence policy input.
FORWARDED=()
AFTER_DASH_DASH=false
for ((i=0; i<${#ORIGINAL_ARGS[@]}; i++)); do
    arg=${ORIGINAL_ARGS[i]}
    if $AFTER_DASH_DASH; then
        FORWARDED+=("$arg")
        continue
    fi
    case $arg in
        --)
            AFTER_DASH_DASH=true
            FORWARDED+=("$arg")
            ;;
        --no-config|--poweroff|--no-poweroff)
            ;;
        --config)
            i=$((i + 1))
            ;;
        --config=*)
            ;;
        *)
            FORWARDED+=("$arg")
            ;;
    esac
done

# Source the runner in a child Bash so $0 remains the public program name while
# BASH_SOURCE still resolves the runner beside the core/doctor files. Waiting in
# this launcher also guarantees the temporary merged config is removed.
set +e
HARDCORE_ARCHIVE_POWER_OFF_REQUESTED=$([[ $POWER_OFF_ENABLED == true ]] && printf 1 || printf 0) \
    bash -c 'runner=$1; shift; source "$runner"' "$PROGRAM_NAME" "$RUNNER" \
        --config "$MERGED_CONFIG" "${FORWARDED[@]}"
rc=$?
set -e

if $SHOW_LAUNCHER_HELP && (( rc == 0 )); then
    cat <<'EOF_HELP'

Post-run launcher options:
  --poweroff               Power off the computer after a successful create/batch job.
  --no-poweroff            Override POWER_OFF_ON_SUCCESS=true for this run.
                           Poweroff is never attempted after failure or read-only/diagnostic modes.
EOF_HELP
fi

(( rc == 0 )) || exit "$rc"

if [[ $POWER_OFF_ENABLED == true ]]; then
    # Remove our temporary config before requesting shutdown. The archive engine
    # has already completed its own validation/sync path at this point.
    cleanup_config_launcher
    MERGED_CONFIG=''
    trap - EXIT HUP INT TERM
    command -v sync >/dev/null 2>&1 && sync
    printf 'Archive completed successfully. Powering off the computer...\n' >&2
    set +e
    "${POWER_OFF_COMMAND[@]}"
    power_rc=$?
    set -e
    if (( power_rc != 0 )); then
        printf 'Error: archive completed successfully, but the requested poweroff command failed with exit code %s.\n' "$power_rc" >&2
        exit 4
    fi
fi

exit 0
