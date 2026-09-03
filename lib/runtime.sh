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
    export HARDCORE_ARCHIVE_FFMPEG="$dir/ffmpeg"
    export HARDCORE_ARCHIVE_FFPROBE="$dir/ffprobe"
    export HARDCORE_ARCHIVE_VIDEO_RUNTIME_MODE=$mode
    export HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID
    HARDCORE_ARCHIVE_VIDEO_RUNTIME_ID=$(hardcore_runtime_identity "$dir/ffmpeg" "$manifest")

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
    return 0
}

hardcore_runtime_prepare_video_toolchain() {
    local root target packaged_dir target_dir manifest
    root=${HARDCORE_ARCHIVE_ROOT:-$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)}
    target=$(hardcore_runtime_target)

    # Explicit escape hatch for developers and distro packages. It is opt-in so
    # a release never silently changes quality behavior with the host FFmpeg.
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

    # Release packages use runtime/bin. The target-specific location is useful
    # in source checkouts and for multi-platform packaging workspaces.
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

    # Source checkouts remain usable without a downloaded runtime. Releases are
    # expected to contain runtime/bin, so this path is mainly for development.
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
