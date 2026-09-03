#!/usr/bin/env bash
# Final encoder inventory/probe interaction layer. Loaded after the base doctor,
# automatic codec policy, and encoder menu so it can correct backend probing
# without changing the archive engine.

# Use a conservative synthetic frame size accepted by modern AV1/HEVC hardware
# encoders. 128x72 is below the minimum supported by some AMD HEVC VAAPI paths.
HARDCORE_ENCODER_PROBE_SIZE=${HARDCORE_ENCODER_PROBE_SIZE:-640x360}

probe_hardware_encoder() {
    local codec=$1 encoder=$2 out err actual device='' quality=33 ignored_line
    out=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-hw.XXXXXX.mkv") || return 1
    err=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-hw.XXXXXX.err") || { rm -f -- "$out"; return 1; }
    local -a cmd=(ffmpeg -hide_banner -v warning -nostdin -y)

    case $encoder in
        *_vaapi)
            if [[ -n ${HARDCORE_ARCHIVE_VAAPI_DEVICE:-} ]]; then
                device=$HARDCORE_ARCHIVE_VAAPI_DEVICE
            elif [[ ${PLATFORM:-} == Linux ]]; then
                case $encoder in
                    av1_vaapi|hevc_vaapi)
                        if linux_has_drm_vendor 0x1002; then device=$(vaapi_device_for_vendor 0x1002 || true)
                        elif linux_has_drm_vendor 0x8086; then device=$(vaapi_device_for_vendor 0x8086 || true)
                        else device=$(vaapi_device_for_vendor '' || true); fi
                        ;;
                esac
            fi
            [[ $encoder == hevc_vaapi ]] && quality=28
            [[ -n $device ]] && cmd+=( -init_hw_device "vaapi=va:$device" ) || cmd+=( -init_hw_device 'vaapi=va:' )
            cmd+=(
                -filter_hw_device va
                -f lavfi -i "color=c=black:s=${HARDCORE_ENCODER_PROBE_SIZE}:r=30" -t 0.25
                -vf 'format=nv12,hwupload'
                -c:v "$encoder" -rc_mode CQP -global_quality:v "$quality"
            )
            ;;
        *_nvenc)
            cmd+=(
                -f lavfi -i "color=c=black:s=${HARDCORE_ENCODER_PROBE_SIZE}:r=30" -t 0.25
                -c:v "$encoder" -gpu:v "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}" -cq:v 33 -preset:v p4
            )
            ;;
        *_qsv)
            # FFmpeg QSV names the balanced target-usage preset "medium".
            cmd+=(
                -f lavfi -i "color=c=black:s=${HARDCORE_ENCODER_PROBE_SIZE}:r=30" -t 0.25
                -c:v "$encoder" -global_quality:v 33 -preset:v medium
            )
            ;;
        *_videotoolbox)
            cmd+=(
                -f lavfi -i "color=c=black:s=${HARDCORE_ENCODER_PROBE_SIZE}:r=30" -t 0.25
                -c:v "$encoder" -q:v 65 -pix_fmt nv12
            )
            ;;
        *)
            rm -f -- "$out" "$err"
            VIDEO_PROBE_ERROR='unsupported encoder policy'
            return 1
            ;;
    esac

    cmd+=( -an -sn -dn -f matroska "$out" )
    if ! "${cmd[@]}" >/dev/null 2>"$err"; then
        VIDEO_PROBE_ERROR=$(tail -n 12 "$err" 2>/dev/null || true)
        [[ -n $device ]] && VIDEO_PROBE_ERROR="VAAPI device $device: $VIDEO_PROBE_ERROR"
        rm -f -- "$out" "$err"
        return 1
    fi

    ignored_line=$(awk '/AVOption .* has not been used for any stream|No quality level set; using default/ {print; exit}' "$err" 2>/dev/null || true)
    if [[ -n $ignored_line ]]; then
        VIDEO_PROBE_ERROR="FFmpeg ignored required encoder quality options: $ignored_line"
        rm -f -- "$out" "$err"
        return 1
    fi

    actual=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$out" 2>"$err" | head -n1 || true)
    rm -f -- "$out" "$err"
    [[ $actual == "$codec" ]] || {
        VIDEO_PROBE_ERROR="Hardware probe produced codec '$actual' instead of '$codec'."
        return 1
    }
    VIDEO_PROBE_ERROR=''
    return 0
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

    command -v ffmpeg >/dev/null 2>&1 || return 0

    local encoder codec node label err
    local -a hardware=(av1_vaapi hevc_vaapi av1_nvenc hevc_nvenc av1_qsv hevc_qsv hevc_videotoolbox)
    local -a software=(libaom-av1 librav1e libsvtav1 libx265)
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
        encoder_available "$encoder" || continue
        codec=$(hardcore_encoder_codec "$encoder") || continue
        HARDCORE_ENCODER_MENU_CPU+=("${codec^^} $encoder")
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
    local choice index codec encoder device
    local use_tty=false
    hardcore_encoder_has_controlling_tty && use_tty=true

    while true; do
        if $use_tty; then
            printf 'Select GPU encoder [0=auto]: ' > /dev/tty
            IFS= read -r choice < /dev/tty || return 1
        else
            printf 'Select GPU encoder [0=auto]: ' >&2
            IFS= read -r choice || return 1
        fi
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
