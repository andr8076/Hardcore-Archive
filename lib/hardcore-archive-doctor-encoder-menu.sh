#!/usr/bin/env bash
# Interactive encoder/device inventory and selection. Loaded after the automatic
# codec doctor so it can wrap the resolved hardware-policy check.

# Preserve the current auto/single-codec doctor implementation and the normal
# hardware probe. The wrapper below only changes VAAPI when a specific render
# node has been selected.
eval "$(declare -f check_video_capability | sed '1s/check_video_capability/check_video_capability_without_menu/')"
eval "$(declare -f probe_hardware_encoder | sed '1s/probe_hardware_encoder/probe_hardware_encoder_without_selected_device/')"

declare -a HARDCORE_ENCODER_MENU_CODEC=()
declare -a HARDCORE_ENCODER_MENU_ENCODER=()
declare -a HARDCORE_ENCODER_MENU_DEVICE=()
declare -a HARDCORE_ENCODER_MENU_LABEL=()
declare -a HARDCORE_ENCODER_MENU_FAILED=()
declare -a HARDCORE_ENCODER_MENU_CPU=()

probe_hardware_encoder() {
    local codec=$1 encoder=$2
    if [[ $encoder != *_vaapi || -z ${HARDCORE_ARCHIVE_VAAPI_DEVICE:-} ]]; then
        probe_hardware_encoder_without_selected_device "$@"
        return $?
    fi

    local out err actual quality=33 ignored_line device=$HARDCORE_ARCHIVE_VAAPI_DEVICE
    [[ $codec == hevc ]] && quality=28
    out=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-hw.XXXXXX.mkv") || return 1
    err=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-hw.XXXXXX.err") || { rm -f -- "$out"; return 1; }
    local -a cmd=(
        ffmpeg -hide_banner -v warning -nostdin -y
        -init_hw_device "vaapi=va:$device" -filter_hw_device va
        -f lavfi -i 'color=c=black:s=128x72:r=30' -t 0.25
        -vf 'format=nv12,hwupload' -c:v "$encoder"
        -rc_mode CQP -global_quality:v "$quality"
        -an -sn -dn -f matroska "$out"
    )
    if ! "${cmd[@]}" >/dev/null 2>"$err"; then
        VIDEO_PROBE_ERROR="VAAPI device $device: $(tail -n 12 "$err" 2>/dev/null || true)"
        rm -f -- "$out" "$err"
        return 1
    fi
    ignored_line=$(awk '/AVOption .* has not been used for any stream|No quality level set; using default/ {print; exit}' "$err" 2>/dev/null || true)
    if [[ -n $ignored_line ]]; then
        VIDEO_PROBE_ERROR="VAAPI device $device ignored required encoder quality options: $ignored_line"
        rm -f -- "$out" "$err"
        return 1
    fi
    actual=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$out" 2>"$err" | head -n1 || true)
    rm -f -- "$out" "$err"
    [[ $actual == "$codec" ]] || {
        VIDEO_PROBE_ERROR="VAAPI device $device produced codec '$actual' instead of '$codec'."
        return 1
    }
    VIDEO_PROBE_ERROR=''
    return 0
}

hardcore_encoder_codec() {
    case "$1" in
        av1_*) printf av1 ;;
        hevc_*) printf hevc ;;
        libaom-av1|librav1e|libsvtav1) printf av1 ;;
        libx265) printf hevc ;;
        *) return 1 ;;
    esac
}

hardcore_encoder_backend_label() {
    case "$1" in
        *_vaapi) printf 'VAAPI' ;;
        *_nvenc) printf 'NVIDIA NVENC' ;;
        *_qsv) printf 'Intel Quick Sync' ;;
        *_videotoolbox) printf 'Apple VideoToolbox' ;;
        *) printf 'software' ;;
    esac
}

hardcore_encoder_render_nodes() {
    local node
    if [[ -n ${HARDCORE_ARCHIVE_RENDER_NODES:-} ]]; then
        tr ':' '\n' <<< "$HARDCORE_ARCHIVE_RENDER_NODES"
        return 0
    fi
    for node in /dev/dri/renderD*; do
        [[ -e $node ]] && printf '%s\n' "$node"
    done
}

hardcore_encoder_render_label() {
    local device=$1 node=${1##*/} sysfs vendor='' vendor_name='GPU' slot='' desc='' driver=''
    sysfs="/sys/class/drm/$node/device"
    [[ -r $sysfs/vendor ]] && vendor=$(<"$sysfs/vendor")
    case ${vendor,,} in
        0x1002) vendor_name='AMD GPU' ;;
        0x10de) vendor_name='NVIDIA GPU' ;;
        0x8086) vendor_name='Intel GPU' ;;
    esac
    if [[ -r $sysfs/uevent ]]; then
        slot=$(awk -F= '$1=="PCI_SLOT_NAME"{print $2; exit}' "$sysfs/uevent" 2>/dev/null || true)
    fi
    if [[ -n $slot ]] && command -v lspci >/dev/null 2>&1; then
        desc=$(lspci -s "$slot" 2>/dev/null | sed -E 's/^[^ ]+[[:space:]]+//' | head -n1 || true)
    fi
    if [[ -L $sysfs/driver ]]; then
        driver=$(basename "$(readlink -f "$sysfs/driver")")
    fi
    [[ -n $desc ]] || desc=$vendor_name
    printf '%s (%s%s%s)' "$desc" "$device" "${driver:+, }" "$driver"
}

hardcore_encoder_probe_candidate() {
    local codec=$1 encoder=$2 device=${3:-}
    if [[ -n $device ]]; then
        local HARDCORE_ARCHIVE_VAAPI_DEVICE=$device
        probe_hardware_encoder "$codec" "$encoder"
    else
        probe_hardware_encoder "$codec" "$encoder"
    fi
}

hardcore_encoder_menu_collect() {
    HARDCORE_ENCODER_MENU_CODEC=()
    HARDCORE_ENCODER_MENU_ENCODER=()
    HARDCORE_ENCODER_MENU_DEVICE=()
    HARDCORE_ENCODER_MENU_LABEL=()
    HARDCORE_ENCODER_MENU_FAILED=()
    HARDCORE_ENCODER_MENU_CPU=()

    command -v ffmpeg >/dev/null 2>&1 || return 0

    local encoder codec node label err
    local -a hardware=(av1_vaapi hevc_vaapi av1_nvenc hevc_nvenc av1_qsv hevc_qsv hevc_videotoolbox)
    local -a software=(libaom-av1 librav1e libsvtav1 libx265)
    local -a nodes=()
    mapfile -t nodes < <(hardcore_encoder_render_nodes)

    for encoder in "${hardware[@]}"; do
        encoder_available "$encoder" || continue
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
        encoder_available "$encoder" || continue
        codec=$(hardcore_encoder_codec "$encoder") || continue
        HARDCORE_ENCODER_MENU_CPU+=("${codec^^} $encoder")
    done
}

hardcore_encoder_menu_display() {
    local i
    printf '\nFFmpeg AV1/HEVC encoder inventory\n' >&2
    printf '%s\n' '════════════════════════════════════════════════════════════' >&2
    printf 'GPU / hardware encoders (selectable)\n' >&2
    printf '  [0] AUTO — let Hardcore Archive choose/compare working GPU encoders\n' >&2
    if ((${#HARDCORE_ENCODER_MENU_ENCODER[@]} == 0)); then
        printf '  none passed the real hardware probe\n' >&2
    else
        for ((i=0; i<${#HARDCORE_ENCODER_MENU_ENCODER[@]}; i++)); do
            printf '  [%s] %-4s %-20s %s\n' "$((i+1))" "${HARDCORE_ENCODER_MENU_CODEC[i]^^}" \
                "${HARDCORE_ENCODER_MENU_ENCODER[i]}" "${HARDCORE_ENCODER_MENU_LABEL[i]}" >&2
        done
    fi

    if ((${#HARDCORE_ENCODER_MENU_FAILED[@]} > 0)); then
        printf '\nGPU encoders exposed by FFmpeg but failing the real probe\n' >&2
        for i in "${HARDCORE_ENCODER_MENU_FAILED[@]}"; do printf '  - %s\n' "$i" >&2; done
    fi

    printf '\nCPU / software encoders (detected, not selectable: GPU encoding is mandatory)\n' >&2
    if ((${#HARDCORE_ENCODER_MENU_CPU[@]} == 0)); then
        printf '  none detected\n' >&2
    else
        for i in "${HARDCORE_ENCODER_MENU_CPU[@]}"; do printf '  - %s\n' "$i" >&2; done
    fi
    printf '%s\n' '════════════════════════════════════════════════════════════' >&2
}

hardcore_encoder_menu_should_prompt() {
    [[ ${DOCTOR_MODE:-false} != true ]] || return 1
    [[ ${HARDCORE_ARCHIVE_NESTED_CHILD:-0} != 1 ]] || return 1
    [[ -z ${REQUESTED_VIDEO_ENCODER:-} ]] || return 1
    [[ -t 0 && -t 1 ]] || return 1
    local arg
    for arg in "${ORIGINAL_ARGS[@]:-}"; do
        case $arg in --yes|-y) return 1 ;; esac
    done
    return 0
}

hardcore_encoder_menu_prompt() {
    local choice index codec encoder device
    while true; do
        printf 'Select GPU encoder [0=auto]: ' >&2
        IFS= read -r choice || return 1
        choice=${choice:-0}
        if [[ $choice == 0 ]]; then
            printf 'Encoder selection: AUTO\n' >&2
            return 0
        fi
        [[ $choice =~ ^[0-9]+$ ]] || { printf 'Enter a listed number.\n' >&2; continue; }
        index=$((choice-1))
        if (( index < 0 || index >= ${#HARDCORE_ENCODER_MENU_ENCODER[@]} )); then
            printf 'Enter a listed number.\n' >&2
            continue
        fi
        codec=${HARDCORE_ENCODER_MENU_CODEC[index]}
        encoder=${HARDCORE_ENCODER_MENU_ENCODER[index]}
        device=${HARDCORE_ENCODER_MENU_DEVICE[index]}
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

check_video_capability() {
    if [[ $VIDEO_ENABLED == true && $VIDEO_RELEVANT == true && ${HARDCORE_ARCHIVE_NESTED_CHILD:-0} != 1 ]]; then
        hardcore_encoder_menu_collect
        hardcore_encoder_menu_display
        if hardcore_encoder_menu_should_prompt; then
            hardcore_encoder_menu_prompt || {
                add_failure BROKEN 'Encoder selection' 'Could not read an encoder selection from the terminal.' ffmpeg-gpu
                return 0
            }
        fi
    fi
    check_video_capability_without_menu
}
