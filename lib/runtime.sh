#!/usr/bin/env bash

[[ ${HARDCORE_RUNTIME_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_RUNTIME_SH_LOADED=1

hardcore_runtime_target() {
    local os arch
    os=$(uname -s 2>/dev/null || printf unknown)
    arch=$(uname -m 2>/dev/null || printf unknown)
    case $os in
        Linux) os=linux ;;
        Darwin) os=macos ;;
        *) os=${os,,} ;;
    esac
    case $arch in
        x86_64|amd64) arch=x86_64 ;;
        arm64|aarch64) arch=arm64 ;;
    esac
    printf '%s-%s\n' "$os" "$arch"
}

hardcore_runtime_hash_text() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 | awk '{print $1}'
    else
        return 1
    fi
}

hardcore_runtime_hash_file() {
    local file=$1
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum -- "$file" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 -- "$file" | awk '{print $1}'
    else
        return 1
    fi
}

hardcore_runtime_identity() {
    local ffmpeg_bin=$1 manifest=${2:-} material hash
    if [[ -n $manifest && -r $manifest ]]; then
        material=$(cat -- "$manifest")
    else
        material=$( {
            "$ffmpeg_bin" -hide_banner -version 2>/dev/null || true
            "$ffmpeg_bin" -hide_banner -buildconf 2>/dev/null || true
        } )
    fi
    hash=$(printf '%s' "$material" | hardcore_runtime_hash_text 2>/dev/null || true)
    if [[ -n $hash ]]; then
        printf 'hca-video-%s\n' "${hash:0:16}"
    else
        printf 'hca-video-unhashed\n'
    fi
}

hardcore_runtime_activate_dir() {
    local dir=$1 mode=$2 manifest=${3:-}
    [[ -x $dir/ffmpeg && -x $dir/ffprobe ]] || return 1

    PATH="$dir:$PATH"
    export PATH

    if [[ -d ${dir%/bin}/lib ]]; then
        case $(uname -s 2>/dev/null || true) in
            Darwin)
                DYLD_LIBRARY_PATH="${dir%/bin}/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
                export DYLD_LIBRARY_PATH
                ;;
            *)
                LD_LIBRARY_PATH="${dir%/bin}/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
                export LD_LIBRARY_PATH
                ;;
        esac
    fi

    export HARDCORE_ARCHIVE_FFMPEG="$dir/ffmpeg"
    export HARDCORE_ARCHIVE_FFPROBE="$dir/ffprobe"
    export HARDCORE_ARCHIVE_VIDEO_RUNTIME_MODE=$mode
    export HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID
    HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID=$(hardcore_runtime_identity "$dir/ffmpeg" "$manifest")
    return 0
}

hardcore_runtime_cache_root() {
    if [[ $(uname -s 2>/dev/null || true) == Darwin ]]; then
        printf '%s\n' "${XDG_CACHE_HOME:-$HOME/Library/Caches}/hardcore-archive/media-runtime"
    else
        printf '%s\n' "${XDG_CACHE_HOME:-$HOME/.cache}/hardcore-archive/media-runtime"
    fi
}

hardcore_runtime_download() {
    local url=$1 output=$2
    if command -v curl >/dev/null 2>&1; then
        curl --fail --location --silent --retry 2 --connect-timeout 15 \
            --output "$output" "$url" 2>/dev/null
    elif command -v wget >/dev/null 2>&1; then
        wget -q --timeout=15 --tries=3 -O "$output" "$url" 2>/dev/null
    else
        return 1
    fi
}

hardcore_runtime_auto_enabled() {
    case ${HARDCORE_ARCHIVE_AUTO_RUNTIME:-1} in
        0|false|FALSE|no|NO|off|OFF) return 1 ;;
        *) return 0 ;;
    esac
}

hardcore_runtime_bootstrap() {
    local target=$1 cache_root final_root tag asset repo base_url tmp archive checksum expected actual

    cache_root=$(hardcore_runtime_cache_root)
    final_root="$cache_root/$target/runtime"
    if [[ -x $final_root/bin/ffmpeg && -x $final_root/bin/ffprobe ]]; then
        hardcore_runtime_activate_dir "$final_root/bin" downloaded "$final_root/runtime-manifest.txt"
        return $?
    fi

    hardcore_runtime_auto_enabled || return 1
    case $target in
        linux-x86_64|linux-arm64|macos-x86_64|macos-arm64) ;;
        *) return 1 ;;
    esac

    repo=${HARDCORE_ARCHIVE_RUNTIME_REPOSITORY:-andr8076/Hardcore-Archive}
    tag=media-runtime-latest
    asset="hardcore-archive-media-runtime-$target.tar.gz"
    base_url="https://github.com/$repo/releases/download/$tag"

    mkdir -p -- "$cache_root/$target" || return 1
    tmp=$(mktemp -d "$cache_root/$target/.install.XXXXXX") || return 1
    archive="$tmp/$asset"
    checksum="$archive.sha256"

    printf 'Hardcore Archive: downloading media runtime for %s...\n' "$target" >&2
    if ! hardcore_runtime_download "$base_url/$asset" "$archive" || \
       ! hardcore_runtime_download "$base_url/$asset.sha256" "$checksum"; then
        HARDCORE_ARCHIVE_RUNTIME_BOOTSTRAP_ERROR="Latest media runtime is not currently available for $target."
        export HARDCORE_ARCHIVE_RUNTIME_BOOTSTRAP_ERROR
        rm -rf -- "$tmp"
        return 1
    fi

    expected=$(awk 'NF {print $1; exit}' "$checksum")
    actual=$(hardcore_runtime_hash_file "$archive" 2>/dev/null || true)
    if [[ -z $expected || -z $actual || $expected != "$actual" ]]; then
        HARDCORE_ARCHIVE_RUNTIME_BOOTSTRAP_ERROR='Downloaded media runtime checksum did not match.'
        export HARDCORE_ARCHIVE_RUNTIME_BOOTSTRAP_ERROR
        rm -rf -- "$tmp"
        return 1
    fi

    if ! tar -xzf "$archive" -C "$tmp" || \
       [[ ! -x $tmp/runtime/bin/ffmpeg || ! -x $tmp/runtime/bin/ffprobe ]]; then
        HARDCORE_ARCHIVE_RUNTIME_BOOTSTRAP_ERROR='Downloaded media runtime could not be extracted or was incomplete.'
        export HARDCORE_ARCHIVE_RUNTIME_BOOTSTRAP_ERROR
        rm -rf -- "$tmp"
        return 1
    fi

    rm -rf -- "$final_root"
    mv -- "$tmp/runtime" "$final_root"
    rm -rf -- "$tmp"
    hardcore_runtime_activate_dir "$final_root/bin" downloaded "$final_root/runtime-manifest.txt"
}

hardcore_runtime_prepare_video_toolchain() {
    local root target packaged_dir target_dir manifest cache_root cached_dir
    root=${HARDCORE_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
    target=$(hardcore_runtime_target)

    # Explicit escape hatch for developers and distro packages.
    if [[ ${HARDCORE_ARCHIVE_USE_SYSTEM_FFMPEG:-0} == 1 ]]; then
        command -v ffmpeg >/dev/null 2>&1 || return 0
        export HARDCORE_ARCHIVE_FFMPEG
        HARDCORE_ARCHIVE_FFMPEG=$(command -v ffmpeg)
        export HARDCORE_ARCHIVE_FFPROBE
        HARDCORE_ARCHIVE_FFPROBE=$(command -v ffprobe 2>/dev/null || true)
        export HARDCORE_ARCHIVE_VIDEO_RUNTIME_MODE=system
        export HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID
        HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID=$(hardcore_runtime_identity "$HARDCORE_ARCHIVE_FFMPEG")
        return 0
    fi

    # A packaged release carrying runtime/bin always wins and needs no network.
    packaged_dir="$root/runtime/bin"
    target_dir="$root/runtime/$target/bin"
    if [[ -x $packaged_dir/ffmpeg && -x $packaged_dir/ffprobe ]]; then
        manifest="$root/runtime/runtime-manifest.txt"
        hardcore_runtime_activate_dir "$packaged_dir" bundled "$manifest"
        return $?
    fi
    if [[ -x $target_dir/ffmpeg && -x $target_dir/ffprobe ]]; then
        manifest="$root/runtime/$target/runtime-manifest.txt"
        hardcore_runtime_activate_dir "$target_dir" bundled "$manifest"
        return $?
    fi

    # A source checkout downloads the newest HCA-managed runtime exactly once.
    # Once present, that cached copy remains static and is reused on every run.
    cache_root=$(hardcore_runtime_cache_root)
    cached_dir="$cache_root/$target/runtime"
    if [[ -x $cached_dir/bin/ffmpeg && -x $cached_dir/bin/ffprobe ]]; then
        hardcore_runtime_activate_dir "$cached_dir/bin" downloaded "$cached_dir/runtime-manifest.txt"
        return $?
    fi
    if hardcore_runtime_bootstrap "$target"; then
        return 0
    fi

    # Offline/development fallback. The doctor still fails closed if the host
    # FFmpeg lacks libvmaf or any hardware capability required by the source.
    export HARDCORE_ARCHIVE_VIDEO_RUNTIME_MODE=system-fallback
    if command -v ffmpeg >/dev/null 2>&1; then
        export HARDCORE_ARCHIVE_FFMPEG
        HARDCORE_ARCHIVE_FFMPEG=$(command -v ffmpeg)
        export HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID
        HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID=$(hardcore_runtime_identity "$HARDCORE_ARCHIVE_FFMPEG")
    fi
    if command -v ffprobe >/dev/null 2>&1; then
        export HARDCORE_ARCHIVE_FFPROBE
        HARDCORE_ARCHIVE_FFPROBE=$(command -v ffprobe)
    fi
}

hardcore_runtime_probe_vmaf() {
    local ffmpeg_bin=${HARDCORE_ARCHIVE_FFMPEG:-ffmpeg} err
    err=$(mktemp "${TMPDIR:-/tmp}/hardcore-vmaf-probe.XXXXXX.err") || return 1
    if "$ffmpeg_bin" -hide_banner -v error -nostdin \
        -f lavfi -i 'color=c=black:s=64x64:r=1:d=1' \
        -f lavfi -i 'color=c=black:s=64x64:r=1:d=1' \
        -filter_complex '[0:v][1:v]libvmaf' -frames:v 1 -f null - \
        >/dev/null 2>"$err"; then
        rm -f -- "$err"
        return 0
    fi
    HARDCORE_ARCHIVE_VMAF_PROBE_ERROR=$(tail -n 12 "$err" 2>/dev/null || true)
    export HARDCORE_ARCHIVE_VMAF_PROBE_ERROR
    rm -f -- "$err"
    return 1
}
