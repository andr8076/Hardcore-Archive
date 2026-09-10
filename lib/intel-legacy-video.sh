#!/usr/bin/env bash

# Optional Intel Media SDK compatibility candidate. This module never changes
# PATH, LD_LIBRARY_PATH, or libva settings in the current shell. Legacy values
# are attached only to the child process that runs the compatibility FFmpeg.
[[ ${HARDCORE_INTEL_LEGACY_VIDEO_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_INTEL_LEGACY_VIDEO_SH_LOADED=1

HARDCORE_INTEL_LEGACY_ERROR=''
HARDCORE_INTEL_LEGACY_RUNTIME_RESOLVED=''
HARDCORE_INTEL_LEGACY_VA_DRIVER_RESOLVED=''
HARDCORE_INTEL_LEGACY_RUNTIME_ID=''
HARDCORE_INTEL_LEGACY_PROVEN_ID=''
HARDCORE_INTEL_LEGACY_COMMAND=()

hardcore_intel_legacy_target() {
    if declare -F hardcore_runtime_target >/dev/null 2>&1; then
        hardcore_runtime_target
        return
    fi
    case "$(uname -s 2>/dev/null)-$(uname -m 2>/dev/null)" in
        Linux-x86_64) printf 'linux-x86_64' ;;
        *) return 1 ;;
    esac
}

hardcore_intel_legacy_hash_file() {
    if declare -F hardcore_runtime_hash_file >/dev/null 2>&1; then
        hardcore_runtime_hash_file "$1"
    else
        sha256sum -- "$1" 2>/dev/null | awk '{print $1}'
    fi
}

hardcore_intel_legacy_runtime_candidates() {
    local root target
    root=${HARDCORE_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
    target=$(hardcore_intel_legacy_target 2>/dev/null || printf 'linux-x86_64')
    [[ -z ${HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME:-} ]] || printf '%s\n' "$HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME"
    printf '%s\n' "$root/runtime/intel-legacy" "$root/runtime/$target/intel-legacy"
}

hardcore_intel_legacy_discover() {
    local root candidate runtime='' driver='' inspector manifest runtime_hash driver_hash
    HARDCORE_INTEL_LEGACY_ERROR=''
    HARDCORE_INTEL_LEGACY_RUNTIME_RESOLVED=''
    HARDCORE_INTEL_LEGACY_VA_DRIVER_RESOLVED=''
    HARDCORE_INTEL_LEGACY_RUNTIME_ID=''
    [[ $(uname -s 2>/dev/null || true) == Linux && $(uname -m 2>/dev/null || true) == x86_64 ]] || {
        HARDCORE_INTEL_LEGACY_ERROR='compatibility runtime is supported only on Linux x86_64'
        return 1
    }

    while IFS= read -r candidate; do
        [[ -n $candidate && -d $candidate ]] || continue
        runtime=$(cd -- "$candidate" 2>/dev/null && pwd -P) || continue
        [[ -x $runtime/bin/ffmpeg && -x $runtime/bin/ffprobe ]] || continue
        break
    done < <(hardcore_intel_legacy_runtime_candidates)
    [[ -n $runtime ]] || {
        HARDCORE_INTEL_LEGACY_ERROR='optional Intel legacy compatibility runtime was not found'
        return 1
    }

    if [[ -n ${HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR:-} ]]; then
        driver=$HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR
    elif [[ -r $runtime/lib/dri/iHD_drv_video.so ]]; then
        driver=$runtime/lib/dri
    elif [[ -r $runtime/dri/iHD_drv_video.so ]]; then
        driver=$runtime/dri
    fi
    driver=$(cd -- "$driver" 2>/dev/null && pwd -P) || driver=''
    [[ -n $driver && -f $driver/iHD_drv_video.so && -r $driver/iHD_drv_video.so &&
       ! -L $driver/iHD_drv_video.so ]] || {
        HARDCORE_INTEL_LEGACY_ERROR='isolated full-feature iHD VA-API driver was not found'
        return 1
    }

    root=${HARDCORE_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
    inspector="$root/packaging/intel-legacy-runtime/inspect.sh"
    [[ -r $inspector ]] || {
        HARDCORE_INTEL_LEGACY_ERROR='legacy runtime integrity inspector is unavailable'
        return 1
    }
    if ! HARDCORE_INTEL_LEGACY_ERROR=$(bash "$inspector" "$runtime" 2>&1); then
        HARDCORE_INTEL_LEGACY_ERROR=${HARDCORE_INTEL_LEGACY_ERROR//$'\n'/ }
        return 1
    fi

    manifest="$runtime/runtime-manifest.txt"
    runtime_hash=$(hardcore_intel_legacy_hash_file "$manifest" 2>/dev/null || true)
    driver_hash=$(hardcore_intel_legacy_hash_file "$driver/iHD_drv_video.so" 2>/dev/null || true)
    [[ $runtime_hash =~ ^[0-9a-fA-F]{64}$ && $driver_hash =~ ^[0-9a-fA-F]{64}$ ]] || {
        HARDCORE_INTEL_LEGACY_ERROR='could not identify the compatibility runtime and isolated VA driver'
        return 1
    }

    HARDCORE_INTEL_LEGACY_RUNTIME_RESOLVED=$runtime
    HARDCORE_INTEL_LEGACY_VA_DRIVER_RESOLVED=$driver
    HARDCORE_INTEL_LEGACY_RUNTIME_ID="intel-msdk-legacy-${runtime_hash:0:12}-ihd-${driver_hash:0:12}"
    export HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME="$runtime"
    export HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR="$driver"
    export HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME_ID="$HARDCORE_INTEL_LEGACY_RUNTIME_ID"
    HARDCORE_INTEL_LEGACY_ERROR=''
    return 0
}

hardcore_intel_legacy_ffmpeg_command() {
    local runtime=${HARDCORE_INTEL_LEGACY_RUNTIME_RESOLVED:-${HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME:-}}
    local driver=${HARDCORE_INTEL_LEGACY_VA_DRIVER_RESOLVED:-${HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR:-}}
    [[ -x $runtime/bin/ffmpeg && -r $driver/iHD_drv_video.so ]] || return 1
    HARDCORE_INTEL_LEGACY_COMMAND=(
        env
        INTEL_MEDIA_RUNTIME=MSDK
        "LD_LIBRARY_PATH=$runtime/lib"
        "LIBVA_DRIVERS_PATH=$driver"
        LIBVA_DRIVER_NAME=iHD
        "$runtime/bin/ffmpeg"
    )
}

hardcore_intel_legacy_probe() {
    local tmp raw output log actual status=0
    hardcore_intel_legacy_discover || return 1
    [[ -z ${HARDCORE_INTEL_LEGACY_PROVEN_ID:-} ||
       $HARDCORE_INTEL_LEGACY_PROVEN_ID != "$HARDCORE_INTEL_LEGACY_RUNTIME_ID" ]] || return 0
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-intel-legacy-probe.XXXXXX") || return 1
    raw="$tmp/reference.nv12"
    output="$tmp/output.mkv"
    log="$tmp/encode.log"
    if ! python3 - "$raw" <<'PYLEGACYPROBE'
import sys
width, height, frames = 640, 360, 30
frame = bytes(width * height * 3 // 2)
with open(sys.argv[1], "wb") as handle:
    for _ in range(frames):
        handle.write(frame)
PYLEGACYPROBE
    then
        HARDCORE_INTEL_LEGACY_ERROR='could not generate the bounded legacy probe input'
        rm -rf -- "$tmp"
        return 1
    fi
    hardcore_intel_legacy_ffmpeg_command || {
        HARDCORE_INTEL_LEGACY_ERROR='could not construct the isolated legacy FFmpeg command'
        rm -rf -- "$tmp"
        return 1
    }
    local -a command=("${HARDCORE_INTEL_LEGACY_COMMAND[@]}" -nostdin -hide_banner -v verbose -y
        -f rawvideo -pixel_format nv12 -video_size 640x360 -framerate 30 -i "$raw"
        -frames:v 30 -an -sn -dn -c:v hevc_qsv -load_plugin hevc_hw -low_power 0
        -global_quality:v 28 -preset:v medium -f matroska "$output")
    if command -v timeout >/dev/null 2>&1; then
        timeout --kill-after=3 30 "${command[@]}" > /dev/null 2>"$log" || status=$?
    else
        "${command[@]}" > /dev/null 2>"$log" || status=$?
    fi
    if (( status != 0 )) || [[ ! -s $output ]]; then
        HARDCORE_INTEL_LEGACY_ERROR="real HEVC encode failed (status $status): $(tail -n 8 "$log" 2>/dev/null || true)"
        HARDCORE_INTEL_LEGACY_ERROR=${HARDCORE_INTEL_LEGACY_ERROR//$'\n'/ }
        rm -rf -- "$tmp"
        return 1
    fi
    if ! grep -Fq 'Use Intel(R) Media SDK to create MFX session' "$log" ||
       ! grep -Fq 'hardware accelerated implementation' "$log" ||
       grep -Fq 'software implementation' "$log"; then
        HARDCORE_INTEL_LEGACY_ERROR='encode completed without proving a hardware Intel Media SDK implementation'
        rm -rf -- "$tmp"
        return 1
    fi
    actual=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name \
        -of default=nw=1:nk=1 "$output" 2>/dev/null | head -n1 || true)
    if [[ $actual != hevc ]] || ! ffmpeg -nostdin -hide_banner -v error -xerror \
        -i "$output" -map '0:V:0' -f null - >/dev/null 2>&1; then
        HARDCORE_INTEL_LEGACY_ERROR="legacy probe output verification failed (codec=${actual:-unknown})"
        rm -rf -- "$tmp"
        return 1
    fi
    rm -rf -- "$tmp"
    HARDCORE_INTEL_LEGACY_PROVEN_ID=$HARDCORE_INTEL_LEGACY_RUNTIME_ID
    HARDCORE_INTEL_LEGACY_ERROR=''
    return 0
}

hardcore_intel_legacy_select() {
    [[ -n ${HARDCORE_INTEL_LEGACY_RUNTIME_ID:-} ]] || hardcore_intel_legacy_discover || return 1
    export HARDCORE_ARCHIVE_VIDEO_ENCODER_RUNTIME_ID="$HARDCORE_INTEL_LEGACY_RUNTIME_ID"
    export HARDCORE_ARCHIVE_VIDEO_ENCODER_RUNTIME_KIND=intel-media-sdk-legacy
    return 0
}
