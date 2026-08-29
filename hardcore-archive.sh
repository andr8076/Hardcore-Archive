#!/usr/bin/env bash

# Preservation-first frontend for Hardcore Archive. It resolves policy, scans
# the requested source before feature-specific dependency checks, performs a
# strict capability doctor, and then delegates to the full archive engine.
if [[ -z ${BASH_VERSION:-} || ${BASH_VERSINFO[0]:-0} -lt 4 || ( ${BASH_VERSINFO[0]:-0} -eq 4 && ${BASH_VERSINFO[1]:-0} -lt 2 ) ]]; then
    printf 'Error: hardcore-archive requires Bash 4.2 or newer.\n' >&2
    if [[ $(uname -s 2>/dev/null || true) == Darwin ]]; then
        printf 'Install it with: brew install bash\n' >&2
    fi
    exit 1
fi

set -Eeuo pipefail
IFS=$'\n\t'

PROGRAM_NAME=${0##*/}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CORE_SCRIPT="$SCRIPT_DIR/lib/hardcore-archive-core.sh"
[[ -f $CORE_SCRIPT ]] || { printf 'Error: Hardcore Archive core is missing: %s\n' "$CORE_SCRIPT" >&2; exit 1; }

PLATFORM=$(uname -s 2>/dev/null || printf unknown)
if [[ $PLATFORM == Darwin ]]; then
    for d in /opt/homebrew/bin /opt/homebrew/sbin /usr/local/bin /usr/local/sbin; do
        [[ -d $d ]] && PATH="$d:$PATH"
    done
    if command -v brew >/dev/null 2>&1; then
        for formula in coreutils findutils util-linux gnu-sed grep gawk acl jpeg-turbo; do
            prefix=$(brew --prefix "$formula" 2>/dev/null || true)
            [[ -n $prefix ]] || continue
            [[ -d $prefix/libexec/gnubin ]] && PATH="$prefix/libexec/gnubin:$PATH"
            [[ -d $prefix/bin ]] && PATH="$prefix/bin:$PATH"
        done
    fi
    export PATH
fi

usage() {
    cat <<EOF_HELP
Usage:
  $PROGRAM_NAME [OPTIONS] SOURCE_FOLDER [OUTPUT_ARCHIVE]
  $PROGRAM_NAME --batch [OPTIONS] PARENT_FOLDER [OUTPUT_DIRECTORY]
  $PROGRAM_NAME --doctor [OPTIONS] SOURCE_FOLDER
  $PROGRAM_NAME --inspect ARCHIVE.7z
  $PROGRAM_NAME --restore ARCHIVE.7z [DESTINATION]

Default policy
  Source data is preserved. Video transcoding, image optimization, nested-
  archive repacking, and source deletion are opt-in. Before a create job starts,
  Hardcore Archive scans the source and checks only capabilities required by
  the selected workflow and file types. There are no dependency fallbacks.

Doctor / dependencies:
  --doctor                  Scan SOURCE and print the exact capabilities needed.
                            Normal create jobs run the same check automatically;
                            the full doctor is printed automatically on failure.
  Missing capability        Required executable/package is not installed.
  Unsupported capability    Tool exists but lacks a required encoder/filter/API.
  Broken capability         Capability is advertised but a real probe fails.
  Repair commands are printed only; Hardcore Archive never installs software.

Transformation opt-ins:
  --video-transcode         Validated video transcoding. Hardware encoding is mandatory.
  --no-video-transcode      Store original video bitstreams. Default unless config opts in.
  --image-optimize          Validated lossless JPEG/PNG optimization.
  --no-image-optimize       Store original JPEG/PNG bitstreams. Default unless config opts in.
  --nested-repack           Validated nested-archive repacking.
  --no-nested-repack        Preserve nested archives bit-for-bit. Default unless config opts in.

Video policy:
  --video-codec CODEC       av1 or hevc. Default: av1.
  --video-encoder NAME      Force a supported hardware FFmpeg encoder.
  --video-parallel          Hardware video work runs beside LZMA2.
  --video-sequential        Accepted for compatibility; hardware policy overrides it.
  --video-mode MODE         maximum, balanced, or fast.
  --video-no-scale          Never reduce large video resolution.
  --video-no-denoise        Disable automatic mild denoising.
  --video-copy-audio        Copy audio streams instead of Opus optimization.
  --video-min-savings P     Minimum accepted saving.
  --video-no-preflight      Disable representative sample testing.
  --quality-check MODE      auto, off, or required.
  --no-video-manifest       Omit transformation manifest.

AV1 is preferred. The only automatic codec fallback is AV1 -> HEVC when a real
hardware probe proves the GPU itself cannot encode AV1 and HEVC hardware encode
passes. Missing/broken FFmpeg, drivers, permissions, or filters never trigger a fallback.

Source deletion:
  --remove-source           Delete source only after strong verification.

Core options are passed through unchanged, including --batch, --analyze-only,
--force, --dictionary, --threads, --effort, --search-cycles, --mc-auto,
--no-mc-auto, --verify, --work-dir, --resume, --keep-work,
--one-file-system, --cross-filesystems, --report, --config, image/batch tuning,
--allow-sleep, --inspect, --restore, and --version.
EOF_HELP
}

trim_config_value() {
    local value=$1
    value=${value#"${value%%[![:space:]]*}"}
    value=${value%"${value##*[![:space:]]}"}
    if [[ $value == \"*\" && $value == *\" ]]; then value=${value:1:${#value}-2};
    elif [[ $value == \'*\' && $value == *\' ]]; then value=${value:1:${#value}-2}; fi
    printf '%s' "$value"
}

config_value() {
    local wanted=$1 file=$2 line key value found=''
    [[ -r $file ]] || return 1
    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *=* ]] || continue
        key=$(trim_config_value "${line%%=*}")
        value=$(trim_config_value "${line#*=}")
        key=${key^^}
        [[ $key == "$wanted" ]] && found=$value
    done < "$file"
    [[ -n $found ]] || return 1
    printf '%s' "$found"
}

config_bool_value() {
    local value
    value=$(config_value "$1" "$2" || true)
    case ${value,,} in
        1|true|yes|on) printf true ;;
        0|false|no|off) printf false ;;
        *) return 1 ;;
    esac
}

if [[ $PLATFORM == Darwin ]]; then
    DEFAULT_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/Library/Application Support}/hardcore-archive/config"
else
    DEFAULT_CONFIG_FILE="${XDG_CONFIG_HOME:-$HOME/.config}/hardcore-archive/config"
fi

CONFIG_ENABLED=true
CONFIG_FILE=$DEFAULT_CONFIG_FILE
ORIGINAL_ARGS=("$@")
AFTER_DASH_DASH=false
for ((i=0; i<${#ORIGINAL_ARGS[@]}; i++)); do
    arg=${ORIGINAL_ARGS[i]}
    $AFTER_DASH_DASH && continue
    case $arg in
        --) AFTER_DASH_DASH=true ;;
        --no-config) CONFIG_ENABLED=false ;;
        --config)
            (( i + 1 < ${#ORIGINAL_ARGS[@]} )) && { CONFIG_FILE=${ORIGINAL_ARGS[i+1]}; i=$((i+1)); }
            ;;
        --config=*) CONFIG_FILE=${arg#*=} ;;
    esac
done

VIDEO_STATE=auto
IMAGE_STATE=auto
NESTED_STATE=auto
MC_AUTO_STATE=auto
VIDEO_PREFLIGHT_STATE=auto
QUALITY_CHECK_CLI=''
CLI_VIDEO_CODEC=''
CLI_VIDEO_ENCODER=''
VIDEO_AUDIO_COPY_COMPAT=false
DOCTOR_MODE=false
NON_CREATE_MODE=false
BATCH_MODE=false
ANALYZE_ONLY=false
ALLOW_SLEEP=false
ONE_FILE_SYSTEM=true
POSITIONALS=()
FORWARDED=()
AFTER_DASH_DASH=false

need_value() {
    (( $# >= 2 )) || { printf 'Error: %s requires a value.\n' "$1" >&2; exit 1; }
}

while (( $# > 0 )); do
    if $AFTER_DASH_DASH; then
        POSITIONALS+=("$1")
        FORWARDED+=("$1")
        shift
        continue
    fi
    case $1 in
        --)
            AFTER_DASH_DASH=true; FORWARDED+=("$1"); shift ;;
        -h|--help)
            usage; exit 0 ;;
        --doctor)
            DOCTOR_MODE=true; shift ;;
        --inspect|--restore|--version)
            NON_CREATE_MODE=true; FORWARDED+=("$1"); shift ;;
        --batch)
            BATCH_MODE=true; FORWARDED+=("$1"); shift ;;
        --analyze-only)
            ANALYZE_ONLY=true; FORWARDED+=("$1"); shift ;;
        --allow-sleep)
            ALLOW_SLEEP=true; FORWARDED+=("$1"); shift ;;
        --one-file-system)
            ONE_FILE_SYSTEM=true; FORWARDED+=("$1"); shift ;;
        --cross-filesystems)
            ONE_FILE_SYSTEM=false; FORWARDED+=("$1"); shift ;;
        --mc-auto)
            MC_AUTO_STATE=true; FORWARDED+=("$1"); shift ;;
        --no-mc-auto)
            MC_AUTO_STATE=false; FORWARDED+=("$1"); shift ;;
        --video-transcode)
            VIDEO_STATE=true; shift ;;
        --no-video-transcode)
            VIDEO_STATE=false; shift ;;
        --image-optimize)
            IMAGE_STATE=true; shift ;;
        --no-image-optimize)
            IMAGE_STATE=false; shift ;;
        --nested-repack)
            NESTED_STATE=true; shift ;;
        --no-nested-repack)
            NESTED_STATE=false; shift ;;
        --video-no-preflight)
            VIDEO_PREFLIGHT_STATE=false; FORWARDED+=("$1"); shift ;;
        --video-codec)
            need_value "$@"; CLI_VIDEO_CODEC=${2,,}; FORWARDED+=("$1" "$2"); shift 2 ;;
        --video-codec=*)
            CLI_VIDEO_CODEC=${1#*=}; CLI_VIDEO_CODEC=${CLI_VIDEO_CODEC,,}; FORWARDED+=("$1"); shift ;;
        --video-encoder)
            need_value "$@"; CLI_VIDEO_ENCODER=$2; FORWARDED+=("$1" "$2"); shift 2 ;;
        --video-encoder=*)
            CLI_VIDEO_ENCODER=${1#*=}; FORWARDED+=("$1"); shift ;;
        --quality-check)
            need_value "$@"; QUALITY_CHECK_CLI=${2,,}; FORWARDED+=("$1" "$2"); shift 2 ;;
        --quality-check=*)
            QUALITY_CHECK_CLI=${1#*=}; QUALITY_CHECK_CLI=${QUALITY_CHECK_CLI,,}; FORWARDED+=("$1"); shift ;;
        --video-copy-audio)
            VIDEO_AUDIO_COPY_COMPAT=true; FORWARDED+=("$1"); shift ;;
        --dictionary|--threads|--effort|--search-cycles|--progress-interval|--nested-max-depth|--verify|--work-dir|--config|--video-mode|--video-min-savings|--image-mode|--image-jobs|--batch-root-files|--batch-jobs)
            need_value "$@"; FORWARDED+=("$1" "$2"); shift 2 ;;
        --dictionary=*|--threads=*|--effort=*|--search-cycles=*|--progress-interval=*|--nested-max-depth=*|--verify=*|--work-dir=*|--config=*|--video-mode=*|--video-min-savings=*|--image-mode=*|--image-jobs=*|--batch-root-files=*|--batch-jobs=*)
            FORWARDED+=("$1"); shift ;;
        --*)
            FORWARDED+=("$1"); shift ;;
        *)
            POSITIONALS+=("$1"); FORWARDED+=("$1"); shift ;;
    esac
done

if $NON_CREATE_MODE && ! $DOCTOR_MODE; then
    export VIDEO_AUDIO_COPY=$VIDEO_AUDIO_COPY_COMPAT
    exec bash -c 'core=$1; shift; source "$core"' "$0" "$CORE_SCRIPT" "${FORWARDED[@]}"
fi

VIDEO_CONFIG=''
IMAGE_CONFIG=''
NESTED_CONFIG=''
CONFIG_VIDEO_CODEC=''
CONFIG_VIDEO_ENCODER=''
CONFIG_MC_AUTO=''
CONFIG_VIDEO_PREFLIGHT=''
CONFIG_QUALITY_CHECK=''
if $CONFIG_ENABLED; then
    VIDEO_CONFIG=$(config_bool_value VIDEO_TRANSCODE "$CONFIG_FILE" || true)
    IMAGE_CONFIG=$(config_bool_value IMAGE_OPTIMIZE "$CONFIG_FILE" || true)
    NESTED_CONFIG=$(config_bool_value NESTED_REPACK "$CONFIG_FILE" || true)
    CONFIG_VIDEO_CODEC=$(config_value VIDEO_CODEC "$CONFIG_FILE" || true); CONFIG_VIDEO_CODEC=${CONFIG_VIDEO_CODEC,,}
    CONFIG_VIDEO_ENCODER=$(config_value VIDEO_ENCODER "$CONFIG_FILE" || true)
    CONFIG_MC_AUTO=$(config_bool_value MC_AUTO "$CONFIG_FILE" || true)
    CONFIG_VIDEO_PREFLIGHT=$(config_bool_value VIDEO_PREFLIGHT "$CONFIG_FILE" || true)
    CONFIG_QUALITY_CHECK=$(config_value QUALITY_CHECK "$CONFIG_FILE" || true); CONFIG_QUALITY_CHECK=${CONFIG_QUALITY_CHECK,,}
fi

resolve_bool_state() {
    local state=$1 config=$2 default=$3
    case $state in
        true|false) printf '%s' "$state" ;;
        auto) [[ $config == true || $config == false ]] && printf '%s' "$config" || printf '%s' "$default" ;;
    esac
}

VIDEO_ENABLED=$(resolve_bool_state "$VIDEO_STATE" "$VIDEO_CONFIG" false)
IMAGE_ENABLED=$(resolve_bool_state "$IMAGE_STATE" "$IMAGE_CONFIG" false)
NESTED_ENABLED=$(resolve_bool_state "$NESTED_STATE" "$NESTED_CONFIG" false)
MC_AUTO_ENABLED=$(resolve_bool_state "$MC_AUTO_STATE" "$CONFIG_MC_AUTO" true)
VIDEO_PREFLIGHT_ENABLED=$(resolve_bool_state "$VIDEO_PREFLIGHT_STATE" "$CONFIG_VIDEO_PREFLIGHT" true)
QUALITY_CHECK_EFFECTIVE=${QUALITY_CHECK_CLI:-${CONFIG_QUALITY_CHECK:-auto}}
EFFECTIVE_VIDEO_CODEC=${CLI_VIDEO_CODEC:-${CONFIG_VIDEO_CODEC:-av1}}
EFFECTIVE_VIDEO_CODEC=${EFFECTIVE_VIDEO_CODEC,,}
REQUESTED_VIDEO_ENCODER=${CLI_VIDEO_ENCODER:-$CONFIG_VIDEO_ENCODER}
case $EFFECTIVE_VIDEO_CODEC in av1|hevc) ;; *) printf 'Error: video codec must be av1 or hevc.\n' >&2; exit 1;; esac
case $QUALITY_CHECK_EFFECTIVE in auto|off|required) ;; *) printf 'Error: quality check must be auto, off, or required.\n' >&2; exit 1;; esac

if (( ${#POSITIONALS[@]} == 0 )); then
    $DOCTOR_MODE && { printf 'Error: --doctor requires the source folder/file to diagnose.\n' >&2; exit 2; }
    printf 'Error: source folder is required.\n' >&2; exit 2
fi
SOURCE=${POSITIONALS[0]}
[[ -e $SOURCE || -L $SOURCE ]] || { printf 'Error: source does not exist: %s\n' "$SOURCE" >&2; exit 2; }

TOTAL_FILES=0
VIDEO_COUNT=0
JPEG_COUNT=0
PNG_COUNT=0
NESTED_COUNT=0
NESTED_PATHS=()
SYMLINK_COUNT=0
FIRST_VIDEO=''

is_video_path() {
    case ${1,,} in *.mp4|*.m4v|*.mkv|*.mov|*.avi|*.webm|*.wmv|*.flv|*.mpg|*.mpeg|*.m2ts|*.mts|*.ts|*.3gp|*.3g2|*.vob|*.ogv) return 0;; *) return 1;; esac
}
is_jpeg_path() { case ${1,,} in *.jpg|*.jpeg|*.jpe) return 0;; *) return 1;; esac; }
is_png_path() { [[ ${1,,} == *.png ]]; }
is_nested_path() {
    case ${1,,} in *.7z|*.zip|*.rar|*.tar|*.tar.gz|*.tgz|*.tar.bz2|*.tbz|*.tbz2|*.tar.xz|*.txz|*.tar.zst|*.tzst) return 0;; *) return 1;; esac
}

ROOT_DEVICE=''
path_device() {
    if [[ $PLATFORM == Darwin ]]; then stat -f '%d' -- "$1" 2>/dev/null || true
    else stat -c '%d' -- "$1" 2>/dev/null || true
    fi
}
command -v stat >/dev/null 2>&1 && ROOT_DEVICE=$(path_device "$SOURCE")

scan_entry() {
    local path=$1 dev entry
    if [[ -L $path ]]; then
        SYMLINK_COUNT=$((SYMLINK_COUNT + 1)); return 0
    fi
    if [[ -f $path ]]; then
        TOTAL_FILES=$((TOTAL_FILES + 1))
        if is_video_path "$path"; then VIDEO_COUNT=$((VIDEO_COUNT + 1)); [[ -n $FIRST_VIDEO ]] || FIRST_VIDEO=$path
        elif is_jpeg_path "$path"; then JPEG_COUNT=$((JPEG_COUNT + 1))
        elif is_png_path "$path"; then PNG_COUNT=$((PNG_COUNT + 1))
        elif is_nested_path "$path"; then NESTED_COUNT=$((NESTED_COUNT + 1)); NESTED_PATHS+=("$path")
        fi
        return 0
    fi
    [[ -d $path ]] || return 0
    if $ONE_FILE_SYSTEM && [[ -n $ROOT_DEVICE ]] && [[ $path != "$SOURCE" ]]; then
        dev=$(path_device "$path")
        [[ -n $dev && $dev != "$ROOT_DEVICE" ]] && return 0
    fi
    local old_dotglob old_nullglob
    old_dotglob=$(shopt -p dotglob || true); old_nullglob=$(shopt -p nullglob || true)
    shopt -s dotglob nullglob
    local -a entries=("$path"/*)
    eval "$old_dotglob"; eval "$old_nullglob"
    for entry in "${entries[@]}"; do scan_entry "$entry"; done
}
scan_entry "$SOURCE"

# Features with no relevant content are disabled before the core sees them. This
# prevents the legacy core from requiring feature libraries that cannot be used.
VIDEO_RELEVANT=false
IMAGE_RELEVANT=false
NESTED_RELEVANT=false
(( NESTED_COUNT > 0 )) && $NESTED_ENABLED && NESTED_RELEVANT=true
(( VIDEO_COUNT > 0 )) && VIDEO_RELEVANT=true
(( JPEG_COUNT > 0 || PNG_COUNT > 0 )) && IMAGE_RELEVANT=true
# Strict source-specific dependency/capability doctor.
source "$SCRIPT_DIR/lib/hardcore-archive-doctor.sh"

check_strict_runtime_capabilities

if (( ${#FAIL_TYPES[@]} > 0 )); then
    print_doctor_report || true
    exit 3
fi
if $DOCTOR_MODE; then
    print_doctor_report
    exit 0
fi

# Now that nested contents have been inspected, disable transforms that cannot
# be used by this particular source before the legacy core performs its own
# broad preflight.
if [[ $VIDEO_ENABLED != true || $VIDEO_RELEVANT != true ]]; then VIDEO_ENABLED=false; FORWARDED+=(--no-video-transcode); fi
if [[ $IMAGE_ENABLED != true || $IMAGE_RELEVANT != true ]]; then IMAGE_ENABLED=false; FORWARDED+=(--no-image-optimize); fi
if [[ $NESTED_ENABLED != true || $NESTED_RELEVANT != true ]]; then NESTED_ENABLED=false; FORWARDED+=(--no-nested-repack); fi

# Preserve CLI opt-in precedence over an explicit false config value.
TEMP_CONFIG=''
cleanup_frontend() { [[ -n ${TEMP_CONFIG:-} ]] && rm -f -- "$TEMP_CONFIG" 2>/dev/null || true; }
trap cleanup_frontend EXIT
NEED_CONFIG_OVERRIDE=false
$CONFIG_ENABLED && [[ $VIDEO_ENABLED == true && $VIDEO_STATE == true && $VIDEO_CONFIG == false ]] && NEED_CONFIG_OVERRIDE=true
$CONFIG_ENABLED && [[ $IMAGE_ENABLED == true && $IMAGE_STATE == true && $IMAGE_CONFIG == false ]] && NEED_CONFIG_OVERRIDE=true
$CONFIG_ENABLED && [[ $NESTED_ENABLED == true && $NESTED_STATE == true && $NESTED_CONFIG == false ]] && NEED_CONFIG_OVERRIDE=true
if $NEED_CONFIG_OVERRIDE; then
    umask 077
    TEMP_CONFIG=$(mktemp "${TMPDIR:-/tmp}/hardcore-archive-config.XXXXXX")
    [[ -r $CONFIG_FILE ]] && cat -- "$CONFIG_FILE" > "$TEMP_CONFIG"
    printf '\n' >> "$TEMP_CONFIG"
    [[ $VIDEO_ENABLED == true && $VIDEO_STATE == true ]] && printf 'VIDEO_TRANSCODE=true\n' >> "$TEMP_CONFIG"
    [[ $IMAGE_ENABLED == true && $IMAGE_STATE == true ]] && printf 'IMAGE_OPTIMIZE=true\n' >> "$TEMP_CONFIG"
    [[ $NESTED_ENABLED == true && $NESTED_STATE == true ]] && printf 'NESTED_REPACK=true\n' >> "$TEMP_CONFIG"
    FORWARDED+=(--config "$TEMP_CONFIG")
fi

printf 'Self-check: READY for this source; all required capabilities passed.\n' >&2
for info in "${INFO_LINES[@]}"; do printf '%s\n' "$info" >&2; done

if [[ $VIDEO_ENABLED == true && $VIDEO_RELEVANT == true ]]; then
    [[ -n $HARDWARE_VIDEO_ENCODER ]] || { printf 'Error: internal doctor error: video encoder was not resolved.\n' >&2; exit 3; }
    # Append final codec/encoder so they win over earlier CLI/config values. This
    # also applies the permitted AV1->HEVC hardware compatibility fallback.
    FORWARDED+=(--video-codec "$EFFECTIVE_VIDEO_CODEC" --video-encoder "$HARDWARE_VIDEO_ENCODER" --video-parallel)
    printf 'Hardware video policy: %s via %s; CPU fallback disabled; video runs in parallel.\n' "${EFFECTIVE_VIDEO_CODEC^^}" "$HARDWARE_VIDEO_ENCODER" >&2
fi

# The legacy core still labels several strict capabilities as optional. The
# frontend has now proved every one that can be used by this source, so suppress
# the old fallback prompt; this is not permission to omit a required capability.
export HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1
export VIDEO_AUDIO_COPY=$VIDEO_AUDIO_COPY_COMPAT

set +e
bash -c 'core=$1; shift; source "$core"' "$0" "$CORE_SCRIPT" "${FORWARDED[@]}"
rc=$?
set -e
exit "$rc"
