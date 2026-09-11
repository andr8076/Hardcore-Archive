#!/usr/bin/env bash
# Final encoder inventory/probe interaction layer. Loaded after the base doctor,
# automatic codec policy, and encoder menu so it can correct backend probing
# without changing the archive engine.

probe_hardware_encoder() {
    local codec=$1 encoder=$2 device=''
    hardcore_video_encoder_auto_eligible "$encoder" || {
        VIDEO_PROBE_ERROR="Encoder '$encoder' is software/manual-only and cannot participate in AUTO."
        return 1
    }
    if [[ $encoder == *_vaapi ]]; then
        if [[ -n ${HARDCORE_ARCHIVE_VAAPI_DEVICE:-} ]]; then
            device=$HARDCORE_ARCHIVE_VAAPI_DEVICE
        elif [[ ${PLATFORM:-} == Linux ]]; then
            if linux_has_drm_vendor 0x1002; then device=$(vaapi_device_for_vendor 0x1002 || true)
            elif linux_has_drm_vendor 0x8086; then device=$(vaapi_device_for_vendor 0x8086 || true)
            else device=$(vaapi_device_for_vendor '' || true); fi
        fi
    fi
    probe_video_encoder_capability "$codec" "$encoder" "$device"
}

probe_software_encoder() {
    [[ $(hardcore_video_encoder_class "$2" 2>/dev/null || true) == software ]] || {
        VIDEO_PROBE_ERROR="Encoder '$2' is not a supported software/manual-only encoder."
        return 1
    }
    probe_video_encoder_capability "$@"
}

hardcore_encoder_backend_applicable() {
    local encoder=$1
    case $encoder in
        *_vaapi)
            [[ ${PLATFORM:-} == Linux ]]
            ;;
        *_nvenc)
            [[ ${PLATFORM:-} == Linux ]] && linux_has_drm_vendor 0x10de
            ;;
        *_qsv)
            [[ ${PLATFORM:-} == Linux ]] && linux_has_drm_vendor 0x8086
            ;;
        *_videotoolbox)
            [[ ${PLATFORM:-} == Darwin ]]
            ;;
        *)
            return 1
            ;;
    esac
}

# Replace the menu collector so FFmpeg-built backends are only probed when the
# matching physical GPU/backend exists. This avoids calling absent CUDA/QSV
# stacks "broken" on an AMD-only host.
hardcore_encoder_menu_collect() {
    HARDCORE_ENCODER_MENU_CODEC=()
    HARDCORE_ENCODER_MENU_ENCODER=()
    HARDCORE_ENCODER_MENU_DEVICE=()
    HARDCORE_ENCODER_MENU_LABEL=()
    HARDCORE_ENCODER_MENU_FAILED=()
    HARDCORE_ENCODER_MENU_CPU=()
    HARDCORE_ENCODER_MENU_CPU_CODEC=()
    HARDCORE_ENCODER_MENU_CPU_ENCODER=()
    HARDCORE_ENCODER_MENU_CPU_FAILED=()

    command -v ffmpeg >/dev/null 2>&1 || return 0

    local encoder codec node label err
    local -a hardware=(av1_vaapi hevc_vaapi av1_nvenc hevc_nvenc av1_qsv hevc_qsv hevc_videotoolbox)
    local -a software=(libsvtav1 libx265)
    local -a nodes=()
    mapfile -t nodes < <(hardcore_encoder_render_nodes)

    for encoder in "${hardware[@]}"; do
        encoder_available "$encoder" || continue
        hardcore_encoder_backend_applicable "$encoder" || continue
        codec=$(hardcore_encoder_codec "$encoder") || continue

        if [[ $encoder == *_vaapi ]]; then
            if ((${#nodes[@]} == 0)); then
                if hardcore_encoder_probe_candidate "$codec" "$encoder" ''; then
                    HARDCORE_ENCODER_MENU_CODEC+=("$codec")
                    HARDCORE_ENCODER_MENU_ENCODER+=("$encoder")
                    HARDCORE_ENCODER_MENU_DEVICE+=('')
                    HARDCORE_ENCODER_MENU_LABEL+=("$(hardcore_encoder_backend_label "$encoder") default device")
                else
                    HARDCORE_ENCODER_MENU_FAILED+=("${codec^^} $encoder / default VAAPI device — ${VIDEO_PROBE_ERROR//$'\n'/ }")
                fi
            else
                for node in "${nodes[@]}"; do
                    label=$(hardcore_encoder_render_label "$node")
                    if hardcore_encoder_probe_candidate "$codec" "$encoder" "$node"; then
                        HARDCORE_ENCODER_MENU_CODEC+=("$codec")
                        HARDCORE_ENCODER_MENU_ENCODER+=("$encoder")
                        HARDCORE_ENCODER_MENU_DEVICE+=("$node")
                        HARDCORE_ENCODER_MENU_LABEL+=("$label")
                    else
                        err=${VIDEO_PROBE_ERROR//$'\n'/ }
                        HARDCORE_ENCODER_MENU_FAILED+=("${codec^^} $encoder / $label — $err")
                    fi
                done
            fi
        elif hardcore_encoder_probe_candidate "$codec" "$encoder" ''; then
            HARDCORE_ENCODER_MENU_CODEC+=("$codec")
            HARDCORE_ENCODER_MENU_ENCODER+=("$encoder")
            HARDCORE_ENCODER_MENU_DEVICE+=('')
            HARDCORE_ENCODER_MENU_LABEL+=("$(hardcore_encoder_backend_label "$encoder")")
        else
            HARDCORE_ENCODER_MENU_FAILED+=("${codec^^} $encoder / $(hardcore_encoder_backend_label "$encoder") — ${VIDEO_PROBE_ERROR//$'\n'/ }")
        fi
    done

    for encoder in "${software[@]}"; do
        codec=$(hardcore_encoder_codec "$encoder") || continue
        if probe_software_encoder "$codec" "$encoder"; then
            HARDCORE_ENCODER_MENU_CPU+=("${codec^^} $encoder")
            HARDCORE_ENCODER_MENU_CPU_CODEC+=("$codec")
            HARDCORE_ENCODER_MENU_CPU_ENCODER+=("$encoder")
        else
            HARDCORE_ENCODER_MENU_CPU_FAILED+=("${codec^^} $encoder — ${VIDEO_PROBE_ERROR//$'\n'/ }")
        fi
    done
}

hardcore_encoder_has_controlling_tty() {
    [[ ${HARDCORE_ARCHIVE_TEST_STDIN:-0} == 1 ]] && return 1
    local tty_fd status
    { exec {tty_fd}<>/dev/tty; } 2>/dev/null || return 1
    [[ -t $tty_fd ]]
    status=$?
    exec {tty_fd}>&-
    return "$status"
}

hardcore_encoder_menu_should_prompt() {
    [[ ${DOCTOR_MODE:-false} != true ]] || return 1
    [[ ${HARDCORE_ARCHIVE_NESTED_CHILD:-0} != 1 ]] || return 1
    [[ -z ${REQUESTED_VIDEO_ENCODER:-} ]] || return 1
    local arg
    for arg in "${ORIGINAL_ARGS[@]:-}"; do
        case $arg in --yes|-y) return 1 ;; esac
    done
    hardcore_encoder_has_controlling_tty && return 0
    [[ -t 0 ]]
}

hardcore_encoder_menu_prompt() {
    local choice index codec encoder device hardware_count=${#HARDCORE_ENCODER_MENU_ENCODER[@]}
    local use_tty=false
    hardcore_encoder_has_controlling_tty && use_tty=true

    while true; do
        if $use_tty; then
            printf 'Select encoder [0=AUTO hardware]: ' > /dev/tty
            IFS= read -r choice < /dev/tty || return 1
        else
            printf 'Select encoder [0=AUTO hardware]: ' >&2
            IFS= read -r choice || return 1
        fi
        choice=${choice:-0}

        if [[ $choice == 0 ]]; then
            printf 'Encoder selection: AUTO\n' >&2
            return 0
        fi
        [[ $choice =~ ^[0-9]+$ ]] || { printf 'Enter a listed number.\n' >&2; continue; }
        index=$((choice-1))
        if (( index < 0 || index >= hardware_count + ${#HARDCORE_ENCODER_MENU_CPU_ENCODER[@]} )); then
            printf 'Enter a listed number.\n' >&2
            continue
        fi
        if (( index < hardware_count )); then
            codec=${HARDCORE_ENCODER_MENU_CODEC[index]}
            encoder=${HARDCORE_ENCODER_MENU_ENCODER[index]}
            device=${HARDCORE_ENCODER_MENU_DEVICE[index]}
        else
            index=$((index - hardware_count))
            codec=${HARDCORE_ENCODER_MENU_CPU_CODEC[index]}
            encoder=${HARDCORE_ENCODER_MENU_CPU_ENCODER[index]}
            device=''
        fi
        EFFECTIVE_VIDEO_CODEC=$codec
        REQUESTED_VIDEO_ENCODER=$encoder
        if [[ -n $device ]]; then
            export HARDCORE_ARCHIVE_VAAPI_DEVICE=$device
        else
            unset HARDCORE_ARCHIVE_VAAPI_DEVICE 2>/dev/null || true
        fi
        printf 'Encoder selection: %s via %s%s\n' "${codec^^}" "$encoder" "${device:+ on $device}" >&2
        return 0
    done
}
