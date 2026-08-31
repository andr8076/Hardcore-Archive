#!/usr/bin/env bash

# Visual observability mode. The public launcher consumes --visual and exports
# the mode; runtime patching adds live terminal viewers without handing worker
# ownership to the terminal emulator.
[[ ${HARDCORE_VISUAL_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_VISUAL_SH_LOADED=1

hardcore_visual_launcher_main() {
    local -a original_args=("$@") forwarded=()
    local visual=false show_help=false after_dash_dash=false arg rc i

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
            --visual)
                visual=true
                ;;
            -h|--help)
                show_help=true
                forwarded+=("$arg")
                ;;
            *)
                forwarded+=("$arg")
                ;;
        esac
    done

    export HARDCORE_ARCHIVE_VISUAL=$($visual && printf 1 || printf 0)
    set +e
    hardcore_config_main "${forwarded[@]}"
    rc=$?
    set -e

    if $show_help && (( rc == 0 )); then
        cat <<'EOF_VISUAL_HELP'

Visual observability:
  --visual                 Open separate live terminal windows for the video/FFmpeg,
                           image, 7-Zip/archive, and nested-child worker logs.
                           The main script still owns every worker and all normal
                           persistent diagnostics remain enabled.
EOF_VISUAL_HELP
    fi
    return "$rc"
}

hardcore_visual_apply_runtime_patch() {
    local input_core=$1 output_core=$2
    if ! python3 "$HARDCORE_VISUAL_PATCHER" "$input_core" "$output_core"; then
        rm -f -- "$output_core"
        printf 'Error: refusing to start with stale --visual runtime hooks.\n' >&2
        return 3
    fi
}
