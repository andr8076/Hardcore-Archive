#!/usr/bin/env bash

# Configuration layering and post-run launcher policy.
[[ ${HARDCORE_CONFIG_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_CONFIG_SH_LOADED=1

HARDCORE_MERGED_CONFIG=''

hardcore_config_cleanup() {
    [[ -n ${HARDCORE_MERGED_CONFIG:-} ]] && rm -f -- "$HARDCORE_MERGED_CONFIG" 2>/dev/null || true
}

hardcore_trim_config_value() {
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

hardcore_config_value() {
    local wanted=$1 file=$2 line key value found=''
    [[ -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *=* ]] || continue
        key=$(hardcore_trim_config_value "${line%%=*}")
        value=$(hardcore_trim_config_value "${line#*=}")
        key=${key^^}
        [[ $key == "$wanted" ]] && found=$value
    done < "$file"
    [[ -n $found ]] || return 1
    printf '%s' "$found"
}

hardcore_config_bool_value() {
    local value
    value=$(hardcore_config_value "$1" "$2" || true)
    case ${value,,} in
        1|true|yes|on) printf true ;;
        0|false|no|off) printf false ;;
        *) return 1 ;;
    esac
}

hardcore_quality_value_is_score() {
    local value=$1
    [[ $value =~ ^[0-9]+([.][0-9]+)?$ ]] || return 1
    LC_NUMERIC=C awk -v v="$value" 'BEGIN {exit !(v >= 0 && v <= 100)}'
}

hardcore_normalize_quality_config() {
    local value
    value=$(hardcore_config_value QUALITY_CHECK "$HARDCORE_MERGED_CONFIG" || true)
    [[ -n $value ]] || return 0

    case ${value,,} in
        auto|off|required)
            # Legacy policy values remain accepted for existing user configs.
            return 0
            ;;
    esac

    if ! hardcore_quality_value_is_score "$value"; then
        printf 'Error: QUALITY_CHECK must be a VMAF score from 0 to 100, or off.\n' >&2
        return 2
    fi

    # The checked-in engine still separates the quality policy from its VMAF
    # threshold. Keep that internal interface private while exposing one simple
    # numeric QUALITY_CHECK value in the real configuration.
    printf '# ---- normalized quality check ----\n' >> "$HARDCORE_MERGED_CONFIG"
    printf 'VIDEO_MIN_VMAF=%s\n' "$value" >> "$HARDCORE_MERGED_CONFIG"
    printf 'QUALITY_CHECK=auto\n\n' >> "$HARDCORE_MERGED_CONFIG"
}

hardcore_append_config() {
    local file=$1 label=$2
    printf '# ---- %s: %s ----\n' "$label" "$file" >> "$HARDCORE_MERGED_CONFIG"
    cat -- "$file" >> "$HARDCORE_MERGED_CONFIG"
    printf '\n' >> "$HARDCORE_MERGED_CONFIG"
}

hardcore_config_main() {
    hardcore_require_bash || return 1

    local program_name=${0##*/}
    local root=${HARDCORE_ARCHIVE_ROOT:-$(hardcore_root_dir)}
    local runner="$root/hardcore-archive-runner.sh"
    local shipped_config="$root/config"
    local platform user_config
    platform=$(hardcore_platform_name)
    user_config=$(hardcore_user_config_path "$platform")

    hardcore_require_file "$runner" 'runner' || return 1
    [[ -r $shipped_config ]] || {
        printf 'Error: Hardcore Archive default config is missing or unreadable: %s\n' "$shipped_config" >&2
        return 1
    }

    local -a original_args=("$@") forwarded=()
    local ignore_external_config=false custom_config=''
    local power_off_state=auto power_off_explicit=false power_off_eligible=true
    local show_launcher_help=false after_dash_dash=false
    local arg config_power_off power_off_enabled=false rc power_rc quality_value
    local i

    for ((i=0; i<${#original_args[@]}; i++)); do
        arg=${original_args[i]}
        if $after_dash_dash; then
            continue
        fi
        case $arg in
            --)
                after_dash_dash=true
                ;;
            --no-config)
                ignore_external_config=true
                ;;
            --config)
                if (( i + 1 >= ${#original_args[@]} )); then
                    printf 'Error: --config requires a file.\n' >&2
                    return 2
                fi
                custom_config=${original_args[i+1]}
                i=$((i + 1))
                ;;
            --config=*)
                custom_config=${arg#*=}
                [[ -n $custom_config ]] || {
                    printf 'Error: --config requires a file.\n' >&2
                    return 2
                }
                ;;
            --poweroff)
                power_off_state=true
                power_off_explicit=true
                ;;
            --no-poweroff)
                power_off_state=false
                power_off_explicit=true
                ;;
            -h|--help)
                show_launcher_help=true
                power_off_eligible=false
                ;;
            --doctor|--inspect|--restore|--version|--analyze-only)
                power_off_eligible=false
                ;;
        esac
    done

    if ! $ignore_external_config && [[ -n $custom_config && ! -r $custom_config ]]; then
        printf 'Error: requested config is missing or unreadable: %s\n' "$custom_config" >&2
        return 2
    fi
    if ! $ignore_external_config && [[ -e $user_config && ! -r $user_config ]]; then
        printf 'Error: user config exists but is unreadable: %s\n' "$user_config" >&2
        return 2
    fi

    hardcore_config_cleanup
    umask 077
    HARDCORE_MERGED_CONFIG=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-config.XXXXXX")
    trap hardcore_config_cleanup EXIT HUP INT TERM

    hardcore_append_config "$shipped_config" 'shipped defaults'
    if ! $ignore_external_config; then
        [[ -r $user_config ]] && hardcore_append_config "$user_config" 'user overrides'
        [[ -n $custom_config ]] && hardcore_append_config "$custom_config" 'explicit overrides'
    fi

    hardcore_normalize_quality_config || return $?

    config_power_off=$(hardcore_config_bool_value POWER_OFF_ON_SUCCESS "$HARDCORE_MERGED_CONFIG" || true)
    if [[ $power_off_state == auto ]]; then
        [[ $config_power_off == true || $config_power_off == false ]] && power_off_enabled=$config_power_off || power_off_enabled=false
    else
        power_off_enabled=$power_off_state
    fi

    if [[ $power_off_enabled == true && $power_off_eligible != true ]]; then
        if [[ $power_off_explicit == true && $power_off_state == true ]]; then
            printf 'Error: --poweroff is only valid for archive create/batch jobs, not help, doctor, inspect, restore, version, or analyze-only runs.\n' >&2
            return 2
        fi
        power_off_enabled=false
    fi

    if [[ $power_off_enabled == true ]]; then
        hardcore_prepare_poweroff_command "$platform" || return $?
    else
        HARDCORE_POWER_OFF_COMMAND=()
    fi

    after_dash_dash=false
    for ((i=0; i<${#original_args[@]}; i++)); do
        arg=${original_args[i]}
        if $after_dash_dash; then
            forwarded+=("$arg")
            continue
        fi
        case $arg in
            --)
                after_dash_dash=true
                forwarded+=("$arg")
                ;;
            --no-config|--poweroff|--no-poweroff)
                ;;
            --config)
                i=$((i + 1))
                ;;
            --config=*)
                ;;
            --quality-check)
                if (( i + 1 >= ${#original_args[@]} )); then
                    printf 'Error: --quality-check requires a VMAF score from 0 to 100, or off.\n' >&2
                    return 2
                fi
                quality_value=${original_args[i+1]}
                if hardcore_quality_value_is_score "$quality_value"; then
                    forwarded+=(--quality-check auto --video-min-vmaf "$quality_value")
                else
                    forwarded+=(--quality-check "$quality_value")
                fi
                i=$((i + 1))
                ;;
            --quality-check=*)
                quality_value=${arg#*=}
                if hardcore_quality_value_is_score "$quality_value"; then
                    forwarded+=(--quality-check auto --video-min-vmaf "$quality_value")
                else
                    forwarded+=("$arg")
                fi
                ;;
            *)
                forwarded+=("$arg")
                ;;
        esac
    done

    set +e
    HARDCORE_ARCHIVE_POWER_OFF_REQUESTED=$([[ $power_off_enabled == true ]] && printf 1 || printf 0) \
        bash -c 'runner=$1; shift; source "$runner"' "$program_name" "$runner" \
            --config "$HARDCORE_MERGED_CONFIG" "${forwarded[@]}"
    rc=$?
    set -e

    if $show_launcher_help && (( rc == 0 )); then
        cat <<'EOF_HELP'

Post-run launcher options:
  --poweroff               Power off the computer after a successful create/batch job.
  --no-poweroff            Override POWER_OFF_ON_SUCCESS=true for this run.
                           Poweroff is never attempted after failure or read-only/diagnostic modes.

Quality setting:
  --quality-check V        Set the VMAF quality floor from 0 to 100.
                           Use --quality-check off to disable sample quality checks.
EOF_HELP
    fi

    (( rc == 0 )) || return "$rc"

    if [[ $power_off_enabled == true ]]; then
        hardcore_config_cleanup
        HARDCORE_MERGED_CONFIG=''
        trap - EXIT HUP INT TERM
        command -v sync >/dev/null 2>&1 && sync
        printf 'Archive completed successfully. Powering off the computer...\n' >&2
        set +e
        "${HARDCORE_POWER_OFF_COMMAND[@]}"
        power_rc=$?
        set -e
        if (( power_rc != 0 )); then
            printf 'Error: archive completed successfully, but the requested poweroff command failed with exit code %s.\n' "$power_rc" >&2
            return 4
        fi
    fi

    hardcore_config_cleanup
    HARDCORE_MERGED_CONFIG=''
    trap - EXIT HUP INT TERM
    return 0
}
