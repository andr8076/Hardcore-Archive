#!/usr/bin/env bash

# Safe, source-preserving frontend for Hardcore Archive. The full archive engine
# lives in lib/hardcore-archive-core.sh; this frontend only resolves policy
# defaults and then delegates without removing any core capability.
if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 || ( ${BASH_VERSINFO[0]:-0} -eq 4 && ${BASH_VERSINFO[1]:-0} -lt 2 ) ]]; then
    printf 'Error: hardcore-archive requires Bash 4.2 or newer.\n' >&2
    if [[ $(uname -s 2>/dev/null || true) == Darwin ]]; then
        printf 'Install it with: brew install bash\n' >&2
        brew_bash=/opt/homebrew/bin/bash
        [[ -x $brew_bash ]] || brew_bash=/usr/local/bin/bash
        printf 'Then run: %q %q' "$brew_bash" "$0" >&2
        printf ' %q' "$@" >&2
        printf '\n' >&2
    fi
    exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CORE_SCRIPT="$SCRIPT_DIR/lib/hardcore-archive-core.sh"
[[ -f $CORE_SCRIPT ]] || {
    printf 'Error: Hardcore Archive core is missing: %s\n' "$CORE_SCRIPT" >&2
    exit 1
}

usage() {
    cat <<EOF_HELP
Usage:
  $PROGRAM_NAME [OPTIONS] SOURCE_FOLDER [OUTPUT_ARCHIVE]
  $PROGRAM_NAME --batch [OPTIONS] PARENT_FOLDER [OUTPUT_DIRECTORY]
  $PROGRAM_NAME --inspect ARCHIVE.7z
  $PROGRAM_NAME --restore ARCHIVE.7z [DESTINATION]

Default policy
  Source files are preserved. Video transcoding, image optimization, nested-
  archive repacking, and source deletion are all opt-in. Temporary/generated
  working files are cleaned automatically after a successful run unless
  --keep-work explicitly asks to retain working data.

Transformation opt-ins:
  --video-transcode         Allow validated smaller video transcodes (AV1 by default).
  --no-video-transcode      Store original video bitstreams. Default unless config opts in.
  --image-optimize          Allow validated lossless JPEG/PNG optimization.
  --no-image-optimize       Store original JPEG/PNG bitstreams. Default unless config opts in.
  --nested-repack           Allow validated smaller nested-archive repacking.
  --no-nested-repack        Preserve nested archive files bit-for-bit. Default unless config opts in.

Source deletion:
  --remove-source           Delete the source only after strong hash verification.
                            Without this option, user-owned source data is never deleted.
                            Generated staging data is still cleaned automatically.

Core options:
  --batch                   Archive each immediate subfolder separately.
  --analyze-only            Show the plan without creating archives.
  --force                   Atomically replace an existing validated output.
  --dictionary SIZE         Override automatic LZMA2 dictionary selection.
  --threads N               Override LZMA2 thread count.
  --effort MODE             practical, extreme, or insane. Default: extreme.
  --search-cycles N         Exact LZMA BT4 mc value.
  --mc-auto / --no-mc-auto Enable/disable bounded match-cycle tuning.
  --progress-interval N     Status interval in seconds. Default: 15.
  -y, --yes                 Accept confirmation prompts/fallbacks.

Archive-aware preprocessing:
  --nested-max-depth N      Maximum recursive nested-repack depth. Default: 3.

Safety, recovery, and storage:
  --verify MODE             auto, integrity, hashes, or extract. Default: auto.
  --work-dir PATH           Override the automatic working directory.
  --resume / --no-resume   Reuse validated completed video work. Default: resume.
  --keep-work               Keep working data after success.
  --one-file-system         Exclude nested mounts. Default.
  --cross-filesystems       Include nested mounted filesystems.
  --report / --no-report   Enable/disable OUTPUT.report.txt. Default: report.
  --config FILE             Read defaults from FILE.
  --no-config               Ignore the user config.

Video policy (used only when video transcoding is enabled):
  --video-mode MODE         maximum, balanced, or fast. Default: balanced.
  --video-codec CODEC       av1 or hevc. Default: av1.
  --video-encoder NAME      Force a specific FFmpeg encoder.
  --video-parallel          Run video work beside LZMA2.
  --video-sequential        Finish video work before LZMA2.
  --video-no-scale          Never reduce large video resolution.
  --video-no-denoise        Disable automatic mild denoising.
  --video-copy-audio        Copy audio streams instead of Opus optimization.
  --video-min-savings P     Minimum accepted saving. Default: 3 percent.
  --video-no-preflight      Disable representative sample testing.
  --quality-check MODE      auto, off, or required. Default: auto.
  --no-video-manifest       Omit the video transformation manifest.

Image policy (used only when image optimization is enabled):
  --image-mode MODE         maximum, balanced, or fast. Default: maximum.
  --image-jobs N|auto       Concurrent lossless image workers. Default: auto.

Batch policy:
  --batch-root-files MODE   archive, ignore, or error. Default: archive.
  --batch-jobs N|auto       Concurrent child archives.
  --retry-failed            Retry failed state-file entries. Default.
  --no-retry-failed         Skip entries marked failed by the previous state.

Commands:
  --inspect                 Test and summarize an existing archive/manifests.
  --restore                 Verify and atomically restore an archive.

Other:
  --allow-sleep             Disable sleep inhibition.
  --version                 Show the core version.
  -h, --help                Show this guide.

Config opt-in examples:
  VIDEO_TRANSCODE=true
  IMAGE_OPTIMIZE=true
  NESTED_REPACK=true

Examples:
  $PROGRAM_NAME "/data/My folder"
  $PROGRAM_NAME --video-transcode "/data/My folder"
  $PROGRAM_NAME --video-transcode --image-optimize "/data/My folder"
  $PROGRAM_NAME --nested-repack "/data/My folder"
  $PROGRAM_NAME --remove-source "/data/My folder"
  $PROGRAM_NAME --inspect "/archives/Important.7z"
  $PROGRAM_NAME --restore "/archives/Important.7z" "/restore/Important"
EOF_HELP
}

trim_config_value() {
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

# Print the last valid boolean value for one config key. Invalid values are
# deliberately treated as absent so the frontend falls back to preservation.
config_feature_value() {
    local wanted=$1 file=$2 line key value found=''
    [[ -r $file ]] || return 1

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *=* ]] || continue
        key=$(trim_config_value "${line%%=*}")
        value=$(trim_config_value "${line#*=}")
        key=${key^^}
        [[ $key == "$wanted" ]] || continue
        case ${value,,} in
            1|true|yes|on) found=true ;;
            0|false|no|off) found=false ;;
            *) ;;
        esac
    done < "$file"

    [[ -n $found ]] || return 1
    printf '%s' "$found"
}

case $(uname -s 2>/dev/null || printf unknown) in
    Darwin) DEFAULT_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/Library/Application Support}/hardcore-archive/config" ;;
    *)      DEFAULT_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/hardcore-archive/config" ;;
esac

CONFIG_ENABLED=true
CONFIG_FILE=$DEFAULT_CONFIG_FILE
ORIGINAL_ARGS=("$@")
AFTER_DASH_DASH=false
for ((i=0; i<${#ORIGINAL_ARGS[@]}; i++)); do
    arg=${ORIGINAL_ARGS[i]}
    if $AFTER_DASH_DASH; then
        continue
    fi
    case $arg in
        --) AFTER_DASH_DASH=true ;;
        --no-config) CONFIG_ENABLED=false ;;
        --config)
            if (( i + 1 < ${#ORIGINAL_ARGS[@]} )); then
                CONFIG_FILE=${ORIGINAL_ARGS[i+1]}
                i=$((i + 1))
            fi
            ;;
        --config=*) CONFIG_FILE=${arg#*=} ;;
    esac
done

VIDEO_STATE=auto
IMAGE_STATE=auto
NESTED_STATE=auto
VIDEO_AUDIO_COPY_COMPAT=false
FORWARDED=()
AFTER_DASH_DASH=false
while (( $# > 0 )); do
    if $AFTER_DASH_DASH; then
        FORWARDED+=("$1")
        shift
        continue
    fi
    case $1 in
        --)
            AFTER_DASH_DASH=true
            FORWARDED+=("$1")
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --video-transcode)
            VIDEO_STATE=true
            shift
            ;;
        --no-video-transcode)
            VIDEO_STATE=false
            shift
            ;;
        --image-optimize)
            IMAGE_STATE=true
            shift
            ;;
        --no-image-optimize)
            IMAGE_STATE=false
            shift
            ;;
        --nested-repack)
            NESTED_STATE=true
            shift
            ;;
        --no-nested-repack)
            NESTED_STATE=false
            shift
            ;;
        --video-copy-audio)
            VIDEO_AUDIO_COPY_COMPAT=true
            FORWARDED+=("$1")
            shift
            ;;
        *)
            FORWARDED+=("$1")
            shift
            ;;
    esac
done

VIDEO_CONFIG=''
IMAGE_CONFIG=''
NESTED_CONFIG=''
if $CONFIG_ENABLED; then
    VIDEO_CONFIG=$(config_feature_value VIDEO_TRANSCODE "$CONFIG_FILE" || true)
    IMAGE_CONFIG=$(config_feature_value IMAGE_OPTIMIZE "$CONFIG_FILE" || true)
    NESTED_CONFIG=$(config_feature_value NESTED_REPACK "$CONFIG_FILE" || true)
fi

# The legacy core defaults these transformations on. The frontend therefore
# supplies an explicit negative option whenever neither CLI nor config opted in.
case $VIDEO_STATE in
    false) FORWARDED+=(--no-video-transcode) ;;
    auto)  [[ $VIDEO_CONFIG == true ]] || FORWARDED+=(--no-video-transcode) ;;
esac
case $IMAGE_STATE in
    false) FORWARDED+=(--no-image-optimize) ;;
    auto)  [[ $IMAGE_CONFIG == true ]] || FORWARDED+=(--no-image-optimize) ;;
esac
case $NESTED_STATE in
    false) FORWARDED+=(--no-nested-repack) ;;
    auto)  [[ $NESTED_CONFIG == true ]] || FORWARDED+=(--no-nested-repack) ;;
esac

TEMP_CONFIG=''
cleanup_frontend() {
    [[ -n ${TEMP_CONFIG:-} ]] && rm -f -- "$TEMP_CONFIG" 2>/dev/null || true
}
trap cleanup_frontend EXIT

# Positive frontend switches need to override a valid false value from config.
# The core has only negative CLI switches, so create a private merged config in
# that specific case and make it the final --config seen by the core.
NEED_CONFIG_OVERRIDE=false
if $CONFIG_ENABLED; then
    [[ $VIDEO_STATE == true && $VIDEO_CONFIG == false ]] && NEED_CONFIG_OVERRIDE=true
    [[ $IMAGE_STATE == true && $IMAGE_CONFIG == false ]] && NEED_CONFIG_OVERRIDE=true
    [[ $NESTED_STATE == true && $NESTED_CONFIG == false ]] && NEED_CONFIG_OVERRIDE=true
fi

if $NEED_CONFIG_OVERRIDE; then
    umask 077
    TEMP_CONFIG=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-config.XXXXXX")
    if [[ -r $CONFIG_FILE ]]; then
        cat -- "$CONFIG_FILE" > "$TEMP_CONFIG"
        printf '\n' >> "$TEMP_CONFIG"
    fi
    [[ $VIDEO_STATE == true ]] && printf 'VIDEO_TRANSCODE=true\n' >> "$TEMP_CONFIG"
    [[ $IMAGE_STATE == true ]] && printf 'IMAGE_OPTIMIZE=true\n' >> "$TEMP_CONFIG"
    [[ $NESTED_STATE == true ]] && printf 'NESTED_REPACK=true\n' >> "$TEMP_CONFIG"
    FORWARDED+=(--config "$TEMP_CONFIG")
fi

# The current core has a legacy cache-key variable name. Exporting the matching
# value keeps resume-cache behavior correct without changing archive semantics.
export VIDEO_AUDIO_COPY=$VIDEO_AUDIO_COPY_COMPAT

set +e
bash -c 'core=$1; shift; source "$core"' "$0" "$CORE_SCRIPT" "${FORWARDED[@]}"
rc=$?
set -e
exit "$rc"
