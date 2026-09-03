#!/usr/bin/env bash

# Select the FFmpeg/VMAF toolchain used by Hardcore Archive. Release packages
# place a tested runtime under runtime/<platform>-<arch>; source checkouts may
# continue to use the host FFmpeg. Selection happens by PATH so the static
# engine and all nested workers use the same tools without per-call rewrites.
[[ ${HARDCORE_MEDIA_RUNTIME_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_MEDIA_RUNTIME_SH_LOADED=1

HARDCORE_MEDIA_RUNTIME_SOURCE=unselected
HARDCORE_MEDIA_RUNTIME_ROOT=''
HARDCORE_MEDIA_RUNTIME_BIN_DIR=''
HARDCORE_MEDIA_RUNTIME_LIB_DIR=''
HARDCORE_MEDIA_RUNTIME_MODEL_DIR=''
HARDCORE_MEDIA_RUNTIME_ID='unselected'

hardcore_media_runtime_platform_key() {
    local kernel arch platform
    kernel=$(uname -s 2>/dev/null || printf unknown)
    arch=$(uname -m 2>/dev/null || printf unknown)
    case $kernel in
        Linux) platform=linux ;;
        Darwin) platform=macos ;;
        *) return 1 ;;
    esac
    case $arch in
        x86_64|amd64) arch=x86_64 ;;
        arm64|aarch64) arch=arm64 ;;
        *) return 1 ;;
    esac
    printf '%s-%s\n' "$platform" "$arch"
}

hardcore_media_runtime_resolve_layout() {
    local candidate=$1
    HARDCORE_MEDIA_RUNTIME_ROOT=''
    HARDCORE_MEDIA_RUNTIME_BIN_DIR=''
    HARDCORE_MEDIA_RUNTIME_LIB_DIR=''
    HARDCORE_MEDIA_RUNTIME_MODEL_DIR=''

    if [[ -x $candidate/bin/ffmpeg && -x $candidate/bin/ffprobe ]]; then
        HARDCORE_MEDIA_RUNTIME_ROOT=$candidate
        HARDCORE_MEDIA_RUNTIME_BIN_DIR="$candidate/bin"
    elif [[ -x $candidate/ffmpeg && -x $candidate/ffprobe ]]; then
        HARDCORE_MEDIA_RUNTIME_ROOT=$(cd -- "$candidate/.." 2>/dev/null && pwd -P || printf '%s' "$candidate")
        HARDCORE_MEDIA_RUNTIME_BIN_DIR=$candidate
    else
        return 1
    fi

    [[ -d $HARDCORE_MEDIA_RUNTIME_ROOT/lib ]] && HARDCORE_MEDIA_RUNTIME_LIB_DIR="$HARDCORE_MEDIA_RUNTIME_ROOT/lib"
    if [[ -d $HARDCORE_MEDIA_RUNTIME_ROOT/share/vmaf/model ]]; then
        HARDCORE_MEDIA_RUNTIME_MODEL_DIR="$HARDCORE_MEDIA_RUNTIME_ROOT/share/vmaf/model"
    elif [[ -d $HARDCORE_MEDIA_RUNTIME_ROOT/model ]]; then
        HARDCORE_MEDIA_RUNTIME_MODEL_DIR="$HARDCORE_MEDIA_RUNTIME_ROOT/model"
    fi
    return 0
}

hardcore_media_runtime_prepend_loader_path() {
    local lib_dir=$1 kernel
    [[ -n $lib_dir ]] || return 0
    kernel=$(uname -s 2>/dev/null || printf unknown)
    case $kernel in
        Linux)
            LD_LIBRARY_PATH="$lib_dir${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
            export LD_LIBRARY_PATH
            ;;
        Darwin)
            DYLD_LIBRARY_PATH="$lib_dir${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
            export DYLD_LIBRARY_PATH
            ;;
    esac
}

hardcore_media_runtime_read_id() {
    local root=$1 line=''
    if [[ -r $root/runtime-id ]]; then
        IFS= read -r line < "$root/runtime-id" || true
        line=${line//$'\r'/}
    fi
    [[ -n $line ]] && printf '%s\n' "$line" || return 1
}

hardcore_media_runtime_select() {
    local root=${1:-${HARDCORE_ARCHIVE_ROOT:-$(hardcore_root_dir)}}
    local mode=${HARDCORE_MEDIA_RUNTIME:-auto}
    local key candidate custom=${HARDCORE_FFMPEG_DIR:-} version_line=''

    case $mode in
        auto|bundled|system) ;;
        *)
            printf 'Error: HARDCORE_MEDIA_RUNTIME must be auto, bundled, or system.\n' >&2
            return 2
            ;;
    esac

    if [[ -n $custom ]]; then
        if ! hardcore_media_runtime_resolve_layout "$custom"; then
            printf 'Error: HARDCORE_FFMPEG_DIR must contain ffmpeg and ffprobe, either directly or in bin/: %s\n' "$custom" >&2
            return 2
        fi
        HARDCORE_MEDIA_RUNTIME_SOURCE=custom
    elif [[ $mode != system ]]; then
        key=$(hardcore_media_runtime_platform_key || true)
        if [[ -n $key ]]; then
            candidate="$root/runtime/$key"
            if [[ -d $candidate ]]; then
                if ! hardcore_media_runtime_resolve_layout "$candidate"; then
                    printf 'Error: bundled media runtime is incomplete: %s\n' "$candidate" >&2
                    printf 'Expected executable bin/ffmpeg and bin/ffprobe.\n' >&2
                    return 3
                fi
                HARDCORE_MEDIA_RUNTIME_SOURCE=bundled
            elif [[ $mode == bundled ]]; then
                printf 'Error: bundled media runtime requested but not installed for %s.\n' "$key" >&2
                return 3
            fi
        elif [[ $mode == bundled ]]; then
            printf 'Error: bundled media runtime is unsupported on this platform/architecture.\n' >&2
            return 3
        fi
    fi

    if [[ $HARDCORE_MEDIA_RUNTIME_SOURCE == bundled || $HARDCORE_MEDIA_RUNTIME_SOURCE == custom ]]; then
        PATH="$HARDCORE_MEDIA_RUNTIME_BIN_DIR${PATH:+:$PATH}"
        export PATH
        hardcore_media_runtime_prepend_loader_path "$HARDCORE_MEDIA_RUNTIME_LIB_DIR"
        if [[ -n $HARDCORE_MEDIA_RUNTIME_MODEL_DIR ]]; then
            HARDCORE_ARCHIVE_VMAF_MODEL_DIR=$HARDCORE_MEDIA_RUNTIME_MODEL_DIR
            export HARDCORE_ARCHIVE_VMAF_MODEL_DIR
        fi
        HARDCORE_MEDIA_RUNTIME_ID=$(hardcore_media_runtime_read_id "$HARDCORE_MEDIA_RUNTIME_ROOT" || true)
        if [[ -z $HARDCORE_MEDIA_RUNTIME_ID ]]; then
            version_line=$(ffmpeg -version 2>/dev/null | head -n1 || true)
            HARDCORE_MEDIA_RUNTIME_ID="${HARDCORE_MEDIA_RUNTIME_SOURCE}:${version_line:-unknown}"
        fi
    else
        HARDCORE_MEDIA_RUNTIME_SOURCE=system
        HARDCORE_MEDIA_RUNTIME_ROOT=''
        HARDCORE_MEDIA_RUNTIME_BIN_DIR=''
        HARDCORE_MEDIA_RUNTIME_LIB_DIR=''
        HARDCORE_MEDIA_RUNTIME_MODEL_DIR=''
        version_line=$(ffmpeg -version 2>/dev/null | head -n1 || true)
        HARDCORE_MEDIA_RUNTIME_ID="system:${version_line:-unavailable}"
    fi

    HARDCORE_ARCHIVE_MEDIA_RUNTIME_SOURCE=$HARDCORE_MEDIA_RUNTIME_SOURCE
    HARDCORE_ARCHIVE_MEDIA_RUNTIME_ROOT=$HARDCORE_MEDIA_RUNTIME_ROOT
    HARDCORE_ARCHIVE_MEDIA_RUNTIME_ID=$HARDCORE_MEDIA_RUNTIME_ID
    export HARDCORE_ARCHIVE_MEDIA_RUNTIME_SOURCE HARDCORE_ARCHIVE_MEDIA_RUNTIME_ROOT HARDCORE_ARCHIVE_MEDIA_RUNTIME_ID
    return 0
}
