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
HARDCORE_INTEL_LEGACY_BOOTSTRAPPED_RUNTIME=''
HARDCORE_INTEL_LEGACY_COMMAND=()

# The compatibility stack has a separate cache and release channel from the
# normal FFmpeg/oneVPL runtime. It is fetched only after modern hardware has
# failed and an Intel i915 render device is present. The Full Feature iHD
# driver is downloaded through the host's configured package repositories and
# extracted into this cache; it is never installed system-wide.
hardcore_intel_legacy_cache_root() {
    printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/hardcore-archive/intel-legacy-runtime"
}

hardcore_intel_legacy_auto_enabled() {
    case ${HARDCORE_ARCHIVE_INTEL_LEGACY_AUTO_SETUP:-${HARDCORE_ARCHIVE_AUTO_RUNTIME:-1}} in
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
        *) return 0 ;;
    esac
}

hardcore_intel_legacy_relevant_host() {
    local device vendor driver
    case ${HARDCORE_ARCHIVE_INTEL_LEGACY_RELEVANT:-auto} in
        1|true|TRUE|yes|YES|on|ON) return 0 ;;
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
    esac
    [[ $(uname -s 2>/dev/null || true) == Linux && $(uname -m 2>/dev/null || true) == x86_64 ]] || return 1
    for device in /sys/class/drm/renderD*/device; do
        [[ -r $device/vendor ]] || continue
        read -r vendor < "$device/vendor" || continue
        [[ ${vendor,,} == 0x8086 ]] || continue
        driver=$(basename "$(readlink -f "$device/driver" 2>/dev/null || true)")
        [[ $driver == i915 ]] && return 0
    done
    return 1
}

hardcore_intel_legacy_set_error() {
    HARDCORE_INTEL_LEGACY_ERROR=$1
    export HARDCORE_ARCHIVE_INTEL_LEGACY_SETUP_ERROR=$1
}

hardcore_intel_legacy_bootstrap_runtime() {
    local target cache final_root repo tag base asset pointer selected tmp archive checksum expected actual candidate
    local lock lock_status=0 inspector root
    target=$(hardcore_intel_legacy_target 2>/dev/null) || return 1
    cache=$(hardcore_intel_legacy_cache_root)
    final_root="$cache/$target/runtime"
    if [[ -x $final_root/bin/ffmpeg && -x $final_root/bin/ffprobe ]]; then
        HARDCORE_INTEL_LEGACY_BOOTSTRAPPED_RUNTIME=$final_root
        return 0
    fi
    hardcore_intel_legacy_auto_enabled && hardcore_intel_legacy_relevant_host || return 1
    declare -F hardcore_runtime_download >/dev/null 2>&1 || { hardcore_intel_legacy_set_error 'media runtime downloader is unavailable'; return 1; }

    mkdir -p -- "$cache/$target" || return 1
    lock="$cache/$target/.install.lock"
    hardcore_runtime_acquire_install_lock "$lock" "$final_root" || lock_status=$?
    if (( lock_status == 2 )); then HARDCORE_INTEL_LEGACY_BOOTSTRAPPED_RUNTIME=$final_root; return 0; fi
    if (( lock_status != 0 )); then hardcore_intel_legacy_set_error 'timed out waiting for another Intel legacy runtime setup'; return 1; fi
    if [[ -x $final_root/bin/ffmpeg && -x $final_root/bin/ffprobe ]]; then
        hardcore_runtime_release_install_lock "$lock"; HARDCORE_INTEL_LEGACY_BOOTSTRAPPED_RUNTIME=$final_root; return 0
    fi

    tmp=$(mktemp -d "$cache/$target/.install.XXXXXX") || { hardcore_runtime_release_install_lock "$lock"; return 1; }
    repo=${HARDCORE_ARCHIVE_RUNTIME_REPOSITORY:-andr8076/Hardcore-Archive}
    tag=intel-legacy-runtime-latest
    base="https://github.com/$repo/releases/download/$tag"
    asset="hardcore-archive-intel-legacy-runtime-$target.tar.gz"
    pointer="$tmp/hardcore-archive-intel-legacy-runtime-$target.current"
    if hardcore_runtime_download "$base/${pointer##*/}" "$pointer"; then
        selected=$(head -n1 "$pointer" | tr -d '\r\n')
        [[ $selected =~ ^hardcore-archive-intel-legacy-runtime-${target}-[0-9a-f]{40}\.tar\.gz$ ]] && asset=$selected
    fi
    archive="$tmp/$asset"; checksum="$archive.sha256"
    printf 'Hardcore Archive: downloading optional Intel legacy compatibility runtime...\n' >&2
    if ! hardcore_runtime_download "$base/$asset" "$archive" || ! hardcore_runtime_download "$base/$asset.sha256" "$checksum"; then
        hardcore_intel_legacy_set_error 'the pinned Intel legacy compatibility runtime is not currently available'
        rm -rf -- "$tmp"; hardcore_runtime_release_install_lock "$lock"; return 1
    fi
    expected=$(awk 'NF {print $1; exit}' "$checksum")
    actual=$(hardcore_intel_legacy_hash_file "$archive" 2>/dev/null || true)
    if [[ ! $expected =~ ^[0-9a-fA-F]{64}$ || ${expected,,} != ${actual,,} ]]; then
        hardcore_intel_legacy_set_error 'downloaded Intel legacy runtime checksum did not match'
        rm -rf -- "$tmp"; hardcore_runtime_release_install_lock "$lock"; return 1
    fi
    if ! tar -tzf "$archive" | awk '{p=$0; sub(/^\.\//,"",p); if (p!="runtime" && p!~/^runtime\//) bad=1; n=split(p,a,"/"); for(i=1;i<=n;i++) if(a[i]=="..") bad=1} END{exit bad}' ||
       ! tar -xzf "$archive" -C "$tmp" || [[ ! -x $tmp/runtime/bin/ffmpeg || ! -x $tmp/runtime/bin/ffprobe ]]; then
        hardcore_intel_legacy_set_error 'downloaded Intel legacy runtime was unsafe or incomplete'
        rm -rf -- "$tmp"; hardcore_runtime_release_install_lock "$lock"; return 1
    fi
    root=${HARDCORE_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
    inspector="$root/packaging/intel-legacy-runtime/inspect.sh"
    if [[ ! -r $inspector ]] || ! bash "$inspector" "$tmp/runtime" >/dev/null 2>&1; then
        hardcore_intel_legacy_set_error 'downloaded Intel legacy runtime failed its isolation inspection'
        rm -rf -- "$tmp"; hardcore_runtime_release_install_lock "$lock"; return 1
    fi
    candidate="$cache/$target/.runtime.new.$$"
    rm -rf -- "$candidate"
    if ! mv -- "$tmp/runtime" "$candidate" || ! mv -- "$candidate" "$final_root"; then
        hardcore_intel_legacy_set_error 'Intel legacy runtime could not be cached atomically'
        rm -rf -- "$tmp" "$candidate"; hardcore_runtime_release_install_lock "$lock"; return 1
    fi
    rm -rf -- "$tmp"; hardcore_runtime_release_install_lock "$lock"
    HARDCORE_INTEL_LEGACY_BOOTSTRAPPED_RUNTIME=$final_root
}

hardcore_intel_legacy_install_driver() {
    local runtime=$1 tmp package archive extracted driver copyright version hash staged
    [[ -r $runtime/lib/dri/iHD_drv_video.so ]] && return 0
    hardcore_intel_legacy_auto_enabled && hardcore_intel_legacy_relevant_host || return 1
    command -v dpkg-deb >/dev/null 2>&1 || { hardcore_intel_legacy_set_error 'dpkg-deb is required to privately extract the Intel Full Feature driver'; return 1; }
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-intel-driver.XXXXXX") || return 1
    package=${HARDCORE_ARCHIVE_INTEL_LEGACY_DRIVER_DEB:-}
    if [[ -z $package ]]; then
        if command -v apt-get >/dev/null 2>&1; then
            printf 'Hardcore Archive: downloading the Intel Full Feature VA driver into its private cache (no system installation)...\n' >&2
            (cd "$tmp" && apt-get download intel-media-va-driver-non-free) >/dev/null 2>"$tmp/apt.log" || true
        elif command -v apt >/dev/null 2>&1; then
            (cd "$tmp" && apt download intel-media-va-driver-non-free) >/dev/null 2>"$tmp/apt.log" || true
        fi
        package=$(find "$tmp" -maxdepth 1 -type f -name 'intel-media-va-driver-non-free_*.deb' -print -quit)
        if [[ -z $package ]]; then
            archive=$(find "$tmp" -maxdepth 1 -type f -name '*.tar.gz' -print -quit)
            if [[ -n $archive ]]; then
                mkdir -p "$tmp/unwrapped" && tar -xzf "$archive" -C "$tmp/unwrapped" 2>/dev/null || true
                package=$(find "$tmp/unwrapped" -type f -name 'intel-media-va-driver-non-free_*.deb' -print -quit)
            fi
        fi
    fi
    if [[ ! -r $package ]]; then
        hardcore_intel_legacy_set_error "could not download intel-media-va-driver-non-free from the configured distribution repositories: $(tail -n2 "$tmp/apt.log" 2>/dev/null | tr '\n' ' ')"
        rm -rf -- "$tmp"; return 1
    fi
    extracted="$tmp/extracted"; mkdir -p "$extracted"
    if ! dpkg-deb -x "$package" "$extracted"; then hardcore_intel_legacy_set_error 'could not extract the Intel Full Feature driver package'; rm -rf -- "$tmp"; return 1; fi
    driver=$(find "$extracted" -type f -name iHD_drv_video.so -print -quit)
    [[ -r $driver && ! -L $driver ]] || { hardcore_intel_legacy_set_error 'the downloaded package did not contain iHD_drv_video.so'; rm -rf -- "$tmp"; return 1; }
    staged="$runtime/lib/.dri.new.$$"; rm -rf -- "$staged"; mkdir -p "$staged"
    cp -- "$driver" "$staged/iHD_drv_video.so" || { rm -rf -- "$tmp" "$staged"; return 1; }
    version=$(dpkg-deb -f "$package" Version 2>/dev/null || printf unknown)
    hash=$(hardcore_intel_legacy_hash_file "$staged/iHD_drv_video.so" 2>/dev/null || true)
    copyright=$(find "$extracted/usr/share/doc" -type f -name copyright -print -quit)
    mkdir -p -- "$runtime/licenses"
    [[ -z $copyright ]] || cp -- "$copyright" "$runtime/licenses/Intel-media-driver-package-copyright"
    printf 'package=intel-media-va-driver-non-free\nversion=%s\nsha256=%s\nacquisition=private-apt-extraction\n' "$version" "$hash" > "$staged/driver-manifest.txt"
    if ! mv -- "$staged" "$runtime/lib/dri"; then rm -rf -- "$tmp" "$staged"; return 1; fi
    rm -rf -- "$tmp"
}

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
    local root target cache
    root=${HARDCORE_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
    target=$(hardcore_intel_legacy_target 2>/dev/null || printf 'linux-x86_64')
    [[ -z ${HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME:-} ]] || printf '%s\n' "$HARDCORE_ARCHIVE_INTEL_LEGACY_RUNTIME"
    printf '%s\n' "$root/runtime/intel-legacy" "$root/runtime/$target/intel-legacy"
    cache=$(hardcore_intel_legacy_cache_root)
    printf '%s\n' "$cache/$target/runtime"
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
    if [[ -z $runtime ]] && hardcore_intel_legacy_auto_enabled && hardcore_intel_legacy_relevant_host; then
        if hardcore_intel_legacy_bootstrap_runtime; then
            runtime=$HARDCORE_INTEL_LEGACY_BOOTSTRAPPED_RUNTIME
        fi
    fi
    [[ -n $runtime ]] || { hardcore_intel_legacy_set_error "${HARDCORE_ARCHIVE_INTEL_LEGACY_SETUP_ERROR:-optional Intel legacy compatibility runtime was not found}"; return 1; }

    if [[ -z ${HARDCORE_ARCHIVE_INTEL_LEGACY_VA_DRIVER_DIR:-} && ! -r $runtime/lib/dri/iHD_drv_video.so ]]; then
        hardcore_intel_legacy_install_driver "$runtime" || return 1
    fi

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
