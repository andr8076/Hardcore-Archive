#!/usr/bin/env bash

# macOS ships an obsolete Bash 3.2. This script uses associative arrays and
# modern parameter expansion, so fail with a useful bootstrap message before
# Bash 3 attempts to parse the rest of the file.
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

PLATFORM_KERNEL=$(uname -s 2>/dev/null || printf unknown)
case $PLATFORM_KERNEL in
    Linux)
        PLATFORM_ID=linux
        PLATFORM_NAME=Linux
        PLATFORM_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/.cache}
        PLATFORM_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/.config}
        ;;
    Darwin)
        PLATFORM_ID=macos
        PLATFORM_NAME=macOS
        PLATFORM_CACHE_HOME=${XDG_CACHE_HOME:-$HOME/Library/Caches}
        PLATFORM_CONFIG_HOME=${XDG_CONFIG_HOME:-$HOME/Library/Application Support}
        ;;
    *)
        printf 'Error: unsupported operating system: %s. Only Linux and macOS are supported.\n' "$PLATFORM_KERNEL" >&2
        exit 1
        ;;
esac

# Shared by per-file helpers, batch jobs and nested archive children.
export HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR=${HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR:-$PLATFORM_CACHE_HOME/hardcore-archive/video-calibration-v1}

# Homebrew keeps GNU utilities out of the default command names on macOS.
# Prefer their gnubin directories automatically so the main workflow has one
# consistent command contract on both supported operating systems.
prepend_path_if_directory() {
    if [[ -d $1 ]]; then PATH="$1:$PATH"; fi
    return 0
}
if [[ $PLATFORM_ID == macos ]]; then
    prepend_path_if_directory /opt/homebrew/bin
    prepend_path_if_directory /opt/homebrew/sbin
    prepend_path_if_directory /usr/local/bin
    prepend_path_if_directory /usr/local/sbin
    if command -v brew >/dev/null 2>&1; then
        for formula in coreutils findutils util-linux gnu-sed grep gawk jpeg-turbo; do
            prefix=$(brew --prefix "$formula" 2>/dev/null || true)
            [[ -n $prefix ]] || continue
            prepend_path_if_directory "$prefix/libexec/gnubin"
            prepend_path_if_directory "$prefix/bin"
            prepend_path_if_directory "$prefix/sbin"
        done
    fi
    export PATH
fi

PROGRAM_NAME=${0##*/}
SCRIPT_START_SECONDS=$SECONDS
source "$(dirname -- "${BASH_SOURCE[0]}")/calibration-identity.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/timing.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/video-acceleration.sh"
source "$(dirname -- "${BASH_SOURCE[0]}")/media-policy.sh"
hardcore_timing_init
SCRIPT_VERSION="2026-09-04"
METADATA_HELPER=${HARDCORE_ARCHIVE_METADATA_HELPER:-}
MEDIA_HELPER=${HARDCORE_ARCHIVE_MEDIA_HELPER:-"$(dirname -- "${BASH_SOURCE[0]}")/hardcore-archive-media.py"}
export HARDCORE_ARCHIVE_MEDIA_HELPER=$MEDIA_HELPER
MIB=$((1024 * 1024))
GIB=$((1024 * MIB))

REMOVE_SOURCE=false
ALLOW_SLEEP=false
SLEEP_PROTECTION_ACTIVE=false
ANALYZE_ONLY=false
FORCE=false
ASSUME_YES=false
DICTIONARY_OVERRIDE=""
THREADS_OVERRIDE=""
EFFORT="extreme"
EFFORT_EXPLICIT=false
SEARCH_CYCLES=""
SEARCH_CYCLES_EXPLICIT=false
MC_AUTO=true
MC_AUTO_EXPLICIT=false
MC_AUTO_SAMPLE_MIB=64
MC_AUTO_TIMEOUT_SECONDS=60
MC_AUTO_RESULT="not run"
PROGRESS_INTERVAL=15
POSITIONAL=()
BATCH_MODE=false
TEMP_ARCHIVE=""
FAILURE_CONTEXT="archive-build"
FAILED_ARCHIVE_PATH=""
FAILED_LOG_PATH=""
MC_SAMPLE_DIR=""
MC_SAMPLE_FILE=""
MC_TUNING_LOG=""

VIDEO_TRANSCODE=true
VIDEO_CODEC="av1"
VIDEO_ENCODER=""
VIDEO_PARALLEL=true
VIDEO_NO_SCALE=false
VIDEO_NO_DENOISE=false
VIDEO_COPY_AUDIO=false
VIDEO_MIN_VMAF="92"
VIDEO_MIN_SAVINGS_PERCENT="3"
VIDEO_PREFLIGHT=true
VIDEO_WRITE_MANIFEST=true
VIDEO_SPECIAL_POLICY="ask"
VIDEO_SPECIAL_LIST=""
VIDEO_SPECIAL_PRESERVE_LIST=""
VIDEO_SPECIAL_OMIT_LIST=""
VIDEO_SPECIAL_COUNT=0
VIDEO_SPECIAL_PRESERVE_COUNT=0
VIDEO_SPECIAL_CONVERT_COUNT=0
VIDEO_OMITTED_COUNT=0
VIDEO_OMITTED_BYTES=0
VIDEO_TRANSCODE_COUNT=0
VIDEO_TRANSCODE_BYTES=0
VIDEO_SELECTED_BYTES=0
LARGEST_TRANSCODE_VIDEO_BYTES=0
VIDEO_STAGE_PARENT=""
VIDEO_STAGE_ROOT=""
VIDEO_HELPER=""
VIDEO_LOG=""
VIDEO_PIPELINE_PID=""
VIDEO_PIPELINE_GROUP=false
VIDEO_COMPRESSED_LIST=""
VIDEO_FALLBACK_LIST=""
VIDEO_COMPRESSED_COUNT=0
VIDEO_FALLBACK_COUNT=0
VIDEO_COMPRESSED_BYTES=0
VIDEO_FALLBACK_BYTES=0
VIDEO_SAVED_BYTES=0
VIDEO_RESULT_MANIFEST=""
ARCHIVE_MANIFEST_STAGE=""
ARCHIVE_MANIFEST_FILE=""
LARGEST_VIDEO_BYTES=0

# Unattended best-practice workflow defaults.
CONFIG_FILE="$PLATFORM_CONFIG_HOME/hardcore-archive/config"
CONFIG_ENABLED=true
OUTPUT_WAS_AUTOMATIC=false
VERIFY_MODE="auto"
VERIFY_MODE_EFFECTIVE="integrity"
WORK_DIR_OVERRIDE=""
WORK_ROOT=""
JOB_WORK_DIR=""
RESUME_ENABLED=true
KEEP_WORK=false
LOCK_FILE=""
LOCK_FD=""
CROSS_FILESYSTEMS=false
ONE_FILE_SYSTEM=true
BATCH_ROOT_FILES="archive"
BATCH_JOBS="auto"
RETRY_FAILED=true
WRITE_REPORT=true
REPORT_PATH=""
BATCH_STATE_FILE=""
EXPECTED_PATHS=""
ARCHIVE_PATHS=""
HASH_MANIFEST=""
HASH_VERIFY_LOG=""
METADATA_DIR=""
METADATA_MANIFEST=""
ACL_MANIFEST=""
XATTR_MANIFEST=""
RESTORE_HELPER=""
SPECIAL_FILES_LIST=""
NESTED_MOUNTS_LIST=""
RESUME_MAP=""
VIDEO_CACHE_DIR=""
VIDEO_CACHE_HITS=0
VIDEO_CACHE_MISSES=0
MC_SAMPLE_RATIO=""
MC_SAMPLE_SECONDS_PER_MIB=""
ESTIMATED_ARCHIVE_BYTES=0
ESTIMATED_SECONDS=0
QUALITY_CHECK="auto"
VIDEO_MODE="balanced"
VIDEO_PARALLEL_EXPLICIT=false

# Lossless JPEG/PNG optimization lane. Images are kept bit-for-bit as fallbacks;
# only validated smaller files replace them inside the archive.
IMAGE_OPTIMIZE=true
IMAGE_MODE="maximum"
IMAGE_JOBS="auto"
IMAGE_JOBS_EFFECTIVE=1
IMAGE_THREADS_PER_WORKER=1
IMAGE_LIST=""
IMAGE_LOG=""
IMAGE_STAGE_PARENT=""
IMAGE_STAGE_ROOT=""
IMAGE_HELPER=""
IMAGE_PIPELINE_PID=""
IMAGE_PIPELINE_GROUP=false
IMAGE_RESULT_MANIFEST=""
IMAGE_OPTIMIZED_LIST=""
IMAGE_FALLBACK_LIST=""
IMAGE_MANIFEST_FILE=""
IMAGE_COUNT=0
IMAGE_BYTES=0
IMAGE_OPTIMIZED_COUNT=0
IMAGE_FALLBACK_COUNT=0
IMAGE_OPTIMIZED_BYTES=0
IMAGE_FALLBACK_BYTES=0
IMAGE_SAVED_BYTES=0
IMAGE_JPEG_COUNT=0
IMAGE_PNG_COUNT=0
IMAGE_TOOL_SUMMARY="not needed"
IMAGE_PARALLEL_RESERVE_MIB=0
IMAGE_PARALLEL=true
IMAGE_OPTIMIZER_AVAILABLE=false

# Nested archive repacking and alternate command modes.
COMMAND_MODE="create"
NESTED_REPACK=true
NESTED_MAX_DEPTH=3
NESTED_LIST=""
NESTED_STAGE_PARENT=""
NESTED_RESULT_MANIFEST=""
NESTED_REPACKED_LIST=""
NESTED_FALLBACK_LIST=""
NESTED_COUNT=0
NESTED_BYTES=0
NESTED_REPACKED_COUNT=0
NESTED_FALLBACK_COUNT=0
NESTED_SAVED_BYTES=0
SPARSE_MANIFEST=""
SPARSE_FILE_COUNT=0
SPARSE_HOLE_BYTES=0
DESTINATION_REQUIRED_BYTES=0
DESTINATION_FREE_BYTES=0

# Consolidated dependency policy. Critical requirements abort before archive
# work begins. Missing optional helpers are explained together and require one
# explicit confirmation before the script may continue.
DEPENDENCY_APPROVED=${HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED:-0}
SLEEP_INHIBITOR_UNAVAILABLE=false
DEPENDENCY_PREFLIGHT_SUMMARY="not run"
declare -a DEP_CRITICAL_LABELS=() DEP_CRITICAL_DESCRIPTIONS=()
declare -a DEP_OPTIONAL_LABELS=() DEP_OPTIONAL_DESCRIPTIONS=()
declare -A DEP_CRITICAL_SEEN=() DEP_OPTIONAL_SEEN=()

usage() {
    cat <<EOF
Usage:
  $PROGRAM_NAME [OPTIONS] SOURCE_FOLDER [OUTPUT_ARCHIVE]
  $PROGRAM_NAME --batch [OPTIONS] PARENT_FOLDER [OUTPUT_DIRECTORY]
  $PROGRAM_NAME --inspect ARCHIVE.7z
  $PROGRAM_NAME --restore ARCHIVE.7z [DESTINATION]

With only a source path, output is selected automatically:
  SOURCE_FOLDER      -> SOURCE_FOLDER.7z beside the source
  --batch PARENT     -> PARENT-archives/ beside the parent

Supported systems: Linux and macOS. The script uses one consistent GNU-tool
contract on both platforms; macOS resolves Homebrew gnubin paths automatically.

The default workflow is unattended and ratio-first once its dependencies are
available. It analyses the machine, chooses safe LZMA2 settings, tunes match-
search effort, preflights media, verifies completeness and integrity, writes
metadata/reports, and cleans up. Missing critical dependencies stop the job;
missing optional dependencies are explained together and require confirmation.
Failed archives and reusable work are preserved for diagnosis and resume.

Core options:
  --batch                  Archive each immediate subfolder separately.
                           Loose root files are archived separately by default.
  --remove-source          Remove each source only after strong hash verification.
  --analyze-only           Show the plan without creating archives.
  --force                  Atomically replace an existing validated output.
  --dictionary SIZE        Override the automatic dictionary, such as 2g.
  --threads N              Override LZMA2 thread count; above 2 may reduce ratio.
  --effort MODE            practical, extreme, or insane. Default: extreme.
  --search-cycles N        Exact LZMA BT4 mc value; disables automatic tuning.
  --mc-auto                Tune mc on a bounded sample. Default.
  --no-mc-auto             Use the selected effort preset directly.
  --progress-interval N    Status interval in seconds. Default: 15.
  -y, --yes                Answer yes to confirmation prompts, including the
                           deliberate use of missing optional dependencies.

Archive-aware preprocessing:
  --no-nested-repack       Store nested archives unchanged.
  --nested-max-depth N     Maximum recursive archive-repack depth. Default: 3.
                           ZIP/RAR/7z/TAR-compressed containers are unpacked,
                           recursively archived by this script, and accepted only
                           when the validated replacement is smaller.

Safety, recovery, and storage:
  --verify MODE            auto, integrity, hashes, or extract. Default: auto.
                           auto always compares SHA-256 content hashes.
  --work-dir PATH          Override the automatically selected local work area.
  --resume / --no-resume   Reuse validated completed video work. Default: resume.
  --keep-work              Keep work files even after success.
  --one-file-system        Exclude nested mounts. Default.
  --cross-filesystems      Include nested mounted filesystems.
  --report / --no-report   Write report.txt in the run's log folder. Default: report.
  --config FILE            Read defaults from FILE.
  --no-config              Ignore ~/.config/hardcore-archive/config.

Video policy:
  --video-mode MODE        maximum, balanced, or fast. Default: balanced.
  --no-video-transcode     Store original videos bit-for-bit.
  --video-codec CODEC      av1 or hevc. Default: av1.
  --video-encoder NAME     Force a specific FFmpeg encoder.
  --video-parallel         Run video work beside LZMA2.
  --video-sequential       Finish video work before LZMA2.
  --video-no-scale         Never reduce large video resolution.
  --video-no-denoise       Disable automatic mild denoising.
  --video-copy-audio       Copy audio streams instead of Opus optimization.
  --video-special-policy P ask, preserve, convert, or omit. Default: ask.
                           Interactive runs ask before unusual media is changed.
                           "omit" deliberately excludes those files entirely.
  --video-min-vmaf V       Minimum accepted VMAF score. Default: 92.
  --video-min-savings P    Minimum accepted saving. Default: 3 percent.
  --video-no-preflight     Disable representative sample testing.
  --quality-check MODE     auto, off, or required. Default: auto.
  --no-video-manifest      Omit the video transformation manifest.

Image policy:
  --no-image-optimize      Store JPEG and PNG originals without optimization.
  --image-mode MODE        maximum, balanced, or fast. Default: maximum.
  --image-jobs N|auto      Concurrent lossless image workers. Default: auto.
                           Automatic mode leaves resources for LZMA and video.

Batch policy:
  --batch-root-files MODE  archive, ignore, or error. Default: archive.
  --batch-jobs N|auto      Concurrent child archives. Automatic mode uses
                           conservative RAM/CPU scheduling and is often 1.
  --retry-failed           Retry failed state-file entries. Default.
  --no-retry-failed        Skip entries marked failed by the last batch state.

Commands:
  --inspect                Test and summarize an existing archive and manifests.
  --restore                Verify, extract atomically, restore metadata and sparse
                           holes, then move the completed tree into place.

Dependency policy:
  Critical missing tools   Refuse before archive work begins.
  Optional missing tools   Explain each fallback and ask once before continuing.
  --yes                    Deliberately accept that optional-dependency warning.
  macOS full feature set   brew install bash coreutils findutils util-linux
                           sevenzip ffmpeg python jpeg-turbo oxipng

Other:
  --allow-sleep            Disable Linux/macOS sleep inhibition.
  --version                Show the version.
  -h, --help               Show this guide.

Examples:
  $PROGRAM_NAME "/data/My folder"
  $PROGRAM_NAME --remove-source "/data/My folder"
  $PROGRAM_NAME --batch "/data/Collections"
  $PROGRAM_NAME --batch --force "/data/Collections" "/archives/Collections"
  $PROGRAM_NAME --verify extract "/data/Important" "/archives/Important.7z"
  $PROGRAM_NAME --inspect "/archives/Important.7z"
  $PROGRAM_NAME --restore "/archives/Important.7z" "/restore/Important"
EOF
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

warn() {
    printf 'Warning: %s\n' "$*" >&2
}

platform_install_guidance() {
    if [[ $PLATFORM_ID == macos ]]; then
        printf '\nmacOS installation guidance:\n' >&2
        printf '  brew install bash coreutils findutils util-linux sevenzip ffmpeg python jpeg-turbo oxipng\n' >&2
        printf '  Run the script with Homebrew Bash, normally: %s/bin/bash %s ...\n' \
            "$(command -v brew >/dev/null 2>&1 && brew --prefix 2>/dev/null || printf /opt/homebrew)" \
            "$PROGRAM_NAME" >&2
    else
        printf '\nInstall the named packages with your Linux distribution package manager, then rerun the command.\n' >&2
    fi
}

platform_sleep_tool_label() {
    if [[ $PLATFORM_ID == macos ]]; then printf 'caffeinate'; else printf 'systemd-inhibit'; fi
}

platform_sleep_tool_available() {
    if [[ $PLATFORM_ID == macos ]]; then
        command -v caffeinate >/dev/null 2>&1
    else
        command -v systemd-inhibit >/dev/null 2>&1 && systemd-inhibit --list >/dev/null 2>&1
    fi
}

platform_cpu_threads() {
    if command -v nproc >/dev/null 2>&1; then
        nproc 2>/dev/null && return 0
    fi
    if [[ $PLATFORM_ID == macos ]]; then
        sysctl -n hw.logicalcpu 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || printf '1'
    else
        getconf _NPROCESSORS_ONLN 2>/dev/null || printf '1'
    fi
}

platform_cpu_model() {
    if [[ $PLATFORM_ID == macos ]]; then
        sysctl -n machdep.cpu.brand_string 2>/dev/null || \
            sysctl -n hw.model 2>/dev/null || printf 'Unknown CPU'
    else
        awk -F: '/model name|Hardware|Processor/ {
            gsub(/^[ \t]+|[ \t]+$/, "", $2); print $2; exit
        }' /proc/cpuinfo 2>/dev/null || printf 'Unknown CPU'
    fi
}

# Prints total-KiB, available-KiB, swap-total-KiB and swap-free-KiB.
# Available memory is intentionally conservative and swap is report-only.
platform_memory_kib() {
    if [[ $PLATFORM_ID == linux ]]; then
        local total available swap_total swap_free
        total=$(awk '/^MemTotal:/ {print $2; exit}' /proc/meminfo)
        available=$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)
        if [[ -z ${available:-} ]]; then
            available=$(awk '
                /^MemFree:/  {free=$2}
                /^Buffers:/  {buffers=$2}
                /^Cached:/   {cached=$2}
                END {print free + buffers + cached}
            ' /proc/meminfo)
        fi
        swap_total=$(awk '/^SwapTotal:/ {print $2; exit}' /proc/meminfo)
        swap_free=$(awk '/^SwapFree:/ {print $2; exit}' /proc/meminfo)
        printf '%s\t%s\t%s\t%s\n' "${total:-0}" "${available:-0}" "${swap_total:-0}" "${swap_free:-0}"
        return
    fi

    python3 - <<'PYMEM'
import re, subprocess

def out(*args):
    try: return subprocess.check_output(args, text=True, stderr=subprocess.DEVNULL).strip()
    except Exception: return ''

total_b = int(out('sysctl','-n','hw.memsize') or 0)
page = int(out('sysctl','-n','hw.pagesize') or 4096)
vm = out('vm_stat')
vals = {}
for line in vm.splitlines():
    m = re.match(r'([^:]+):\s*([0-9]+)', line)
    if m: vals[m.group(1)] = int(m.group(2))
# Free, inactive, speculative and purgeable pages are reclaimable without swap.
available_pages = sum(vals.get(k,0) for k in (
    'Pages free', 'Pages inactive', 'Pages speculative', 'Pages purgeable'))
available_b = min(total_b, available_pages * page)
swap = out('sysctl','-n','vm.swapusage')
def amount(label):
    m = re.search(rf'{label}\s*=\s*([0-9.]+)([MGT])', swap)
    if not m: return 0
    value=float(m.group(1)); unit=m.group(2)
    return int(value * {'M':1024,'G':1024**2,'T':1024**3}[unit])
print(total_b//1024, available_b//1024, amount('total'), amount('free'), sep='\t')
PYMEM
}

platform_os_version() {
    if [[ $PLATFORM_ID == macos ]]; then
        printf 'macOS %s (%s)' \
            "$(sw_vers -productVersion 2>/dev/null || printf unknown)" \
            "$(sw_vers -buildVersion 2>/dev/null || printf unknown)"
    else
        if [[ -r /etc/os-release ]]; then
            . /etc/os-release
            printf '%s' "${PRETTY_NAME:-Linux}"
        else
            printf 'Linux'
        fi
    fi
}

dependency_reset() {
    DEP_CRITICAL_LABELS=()
    DEP_CRITICAL_DESCRIPTIONS=()
    DEP_OPTIONAL_LABELS=()
    DEP_OPTIONAL_DESCRIPTIONS=()
    DEP_CRITICAL_SEEN=()
    DEP_OPTIONAL_SEEN=()
}

dependency_add_critical() {
    local label=$1 description=$2
    [[ -n ${DEP_CRITICAL_SEEN[$label]:-} ]] && return 0
    DEP_CRITICAL_SEEN[$label]=1
    DEP_CRITICAL_LABELS+=("$label")
    DEP_CRITICAL_DESCRIPTIONS+=("$description")
}

dependency_add_optional() {
    local label=$1 description=$2
    [[ -n ${DEP_OPTIONAL_SEEN[$label]:-} ]] && return 0
    DEP_OPTIONAL_SEEN[$label]=1
    DEP_OPTIONAL_LABELS+=("$label")
    DEP_OPTIONAL_DESCRIPTIONS+=("$description")
}

dependency_require_command() {
    local command_name=$1 description=$2
    command -v "$command_name" >/dev/null 2>&1 || \
        dependency_add_critical "$command_name" "$description"
}

dependency_optional_command() {
    local command_name=$1 description=$2
    command -v "$command_name" >/dev/null 2>&1 || \
        dependency_add_optional "$command_name" "$description"
}

dependency_require_portable_command_contract() {
    # intentionally standardizes on the GNU command interface on both OSes.
    # Linux normally provides it natively; Homebrew provides it on macOS.
    stat -c '%s' -- /dev/null >/dev/null 2>&1 || \
        dependency_add_critical 'GNU coreutils' \
            'Provides the consistent stat, realpath, checksum, sizing, copy, removal, and timeout semantics used on Linux and macOS.'
    realpath -m -- . >/dev/null 2>&1 || \
        dependency_add_critical 'GNU realpath' \
            'Canonicalizes paths that may not exist yet without changing their intended destination.'
    numfmt --to=iec-i 1024 >/dev/null 2>&1 || \
        dependency_add_critical 'GNU numfmt' \
            'Formats byte counts consistently in plans, progress reports, and validation messages.'
    printf 'b\0a\0' | sort -z >/dev/null 2>&1 || \
        dependency_add_critical 'GNU sort' \
            'Sorts NUL-delimited path inventories without breaking filenames containing spaces or newlines.'
    find . -maxdepth 0 -printf '%p\0' >/dev/null 2>&1 || \
        dependency_add_critical 'GNU findutils' \
            'Builds exact NUL-safe inventories and snapshots with the same behavior on Linux and macOS.'
    flock --version >/dev/null 2>&1 || \
        dependency_add_critical 'util-linux flock' \
            'Prevents simultaneous jobs from writing to the same archive, restore destination, or batch state.'
}

dependency_resolve_7zip() {
    local candidate
    SEVEN_ZIP=''
    for candidate in 7zz 7z 7za; do
        if command -v "$candidate" >/dev/null 2>&1; then
            SEVEN_ZIP=$(command -v "$candidate")
            break
        fi
    done
    if [[ -z $SEVEN_ZIP ]]; then
        dependency_add_critical '7-Zip (7zz, 7z, or 7za)' \
            'Creates, lists, extracts, and integrity-tests the final and nested archives.'
    elif ! "$SEVEN_ZIP" i >/dev/null 2>&1; then
        dependency_add_critical "working 7-Zip ($SEVEN_ZIP)" \
            'The detected 7-Zip executable must start successfully and report its supported formats.'
    fi
}

dependency_ffmpeg_has_encoder() {
    local encoder=$1
    ffmpeg -hide_banner -encoders 2>/dev/null | awk 'NF >= 2 {print $2}' | grep -Fxq "$encoder"
}

dependency_ffmpeg_has_filter() {
    local filter=$1
    ffmpeg -hide_banner -filters 2>/dev/null | awk 'NF >= 2 {print $2}' | grep -Fxq "$filter"
}

dependency_abort_if_critical() {
    local i
    (( ${#DEP_CRITICAL_LABELS[@]} == 0 )) && return 0
    printf '\nDependency preflight failed\n' >&2
    printf '════════════════════════════════════════════════════════════════\n' >&2
    printf 'The following critical dependencies are unavailable:\n' >&2
    for i in "${!DEP_CRITICAL_LABELS[@]}"; do
        printf '  %-28s %s\n' "${DEP_CRITICAL_LABELS[i]}" "${DEP_CRITICAL_DESCRIPTIONS[i]}" >&2
    done
    printf '════════════════════════════════════════════════════════════════\n' >&2
    platform_install_guidance
    die 'Refusing to continue because the requested archive workflow cannot be completed and verified safely.'
}

dependency_confirm_optional() {
    local i answer=''
    if (( ${#DEP_OPTIONAL_LABELS[@]} == 0 )); then
        DEPENDENCY_PREFLIGHT_SUMMARY='all requested optional features available'
        export HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1
        DEPENDENCY_APPROVED=1
        return 0
    fi

    # Batch children and recursive nested-archive children inherit approval
    # after the parent has displayed this exact warning once.
    if [[ ${HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED:-0} == 1 ]]; then
        DEPENDENCY_PREFLIGHT_SUMMARY="optional omissions approved by parent (${#DEP_OPTIONAL_LABELS[@]})"
        return 0
    fi

    printf '\nOptional dependencies are unavailable\n' >&2
    printf '════════════════════════════════════════════════════════════════\n' >&2
    for i in "${!DEP_OPTIONAL_LABELS[@]}"; do
        printf '  %-28s %s\n' "${DEP_OPTIONAL_LABELS[i]}" "${DEP_OPTIONAL_DESCRIPTIONS[i]}" >&2
    done
    printf '════════════════════════════════════════════════════════════════\n' >&2

    if $ASSUME_YES; then
        printf 'Proceeding because --yes was supplied; the features above will be omitted or use their documented fallback.\n' >&2
        DEPENDENCY_PREFLIGHT_SUMMARY="continued without ${#DEP_OPTIONAL_LABELS[@]} optional dependencies"
        export HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1
        DEPENDENCY_APPROVED=1
        return 0
    fi

    local tty_fd
    if ! { exec {tty_fd}<>/dev/tty; } 2>/dev/null; then
        die 'Optional dependencies are missing and no interactive terminal is available; re-run with --yes only if you deliberately accept the listed fallbacks.'
    fi

    printf 'Continue without these optional features? [y/N]: ' >&"$tty_fd"
    if ! IFS= read -r answer <&"$tty_fd" 2>/dev/null; then
        eval "exec ${tty_fd}>&-" 2>/dev/null || true
        die 'Optional dependencies are missing and confirmation could not be read; re-run with --yes only if you deliberately accept the listed fallbacks.'
    fi
    eval "exec ${tty_fd}>&-" 2>/dev/null || true
    case ${answer,,} in
        y|yes)
            DEPENDENCY_PREFLIGHT_SUMMARY="continued without ${#DEP_OPTIONAL_LABELS[@]} optional dependencies"
            export HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1
            DEPENDENCY_APPROVED=1
            ;;
        *)
            die 'Cancelled because optional dependencies are missing.'
            ;;
    esac
}

dependency_require_core_create_commands() {
    dependency_require_portable_command_contract
    dependency_require_command awk 'Parses resource measurements, manifests, and tool capability output.'
    dependency_require_command grep 'Searches archive listings, logs, and encoder capability output.'
    dependency_require_command sed 'Normalizes paths and parses command output used by the workflow.'
    dependency_require_command find 'Scans the source tree and builds exact file inventories.'
    dependency_require_command sort 'Creates deterministic inventories and solid-compression ordering.'
    dependency_require_command comm 'Compares expected and actual archive path inventories.'
    dependency_require_command cmp 'Detects source changes and validates generated helper data.'
    dependency_require_command stat 'Reads file sizes, timestamps, allocation, and filesystem identifiers.'
    dependency_require_command realpath 'Canonicalizes source, output, work, restore, and script paths safely.'
    dependency_require_command mktemp 'Creates private temporary files and staging directories.'
    dependency_require_command date 'Timestamps reports, state records, and preserved failures.'
    dependency_require_command df 'Verifies free space on work and destination filesystems.'
    dependency_require_command du 'Measures staged data and archive-working storage.'
    dependency_require_command sha256sum 'Builds and verifies content hashes, especially before source deletion.'
    dependency_require_command head 'Reads bounded probe and manifest results.'
    dependency_require_command tail 'Reads bounded diagnostic and progress output.'
    dependency_require_command cut 'Extracts structured fields from probe output.'
    dependency_require_command tr 'Converts safe NUL-delimited diagnostic listings for display.'
    dependency_require_command wc 'Counts files and batch-root entries.'
    dependency_require_command xargs 'Runs bounded parallel image workers safely.'
    dependency_require_command chmod 'Secures generated helpers and restores recorded modes.'
    dependency_require_command cp 'Stages originals without modifying the source.'
    dependency_require_command mv 'Performs atomic finalization and preserves failed outputs.'
    dependency_require_command rm 'Cleans temporary data and removes sources only after verification.'
    dependency_require_command mkdir 'Creates output, staging, metadata, and restore directories.'
    dependency_require_command touch 'Creates batch state and marker files.'
    dependency_require_command readlink 'Records and recreates symbolic-link targets.'
    dependency_require_command sync 'Flushes completed and failed archive data before reporting success.'
    dependency_require_command nproc 'Budgets CPU threads for compression and parallel scheduling.'
    dependency_require_command sleep 'Provides bounded polling for progress and child-process scheduling.'
    dependency_require_command tee 'Captures diagnostics while preserving command output.'
    dependency_require_command ln 'Creates efficient hard-link staging when the filesystem permits it.'
    dependency_require_command env 'Launches isolated child jobs with explicit inherited state.'
    dependency_require_command basename 'Builds safe default archive and report names.'
    dependency_require_command dirname 'Resolves output, source, and work parent directories.'
    dependency_require_command flock 'Prevents concurrent processes from targeting the same archive or batch destination.'
}

dependency_preflight_create_critical() {
    local encoder_found=false candidate
    dependency_reset
    dependency_resolve_7zip
    dependency_require_core_create_commands
    dependency_require_command python3 'Detects exact sparse-file data and hole ranges so sparsity can be restored.'

    if $MC_AUTO && ! $ANALYZE_ONLY; then
        dependency_require_command timeout 'Bounds automatic LZMA match-cycle benchmark attempts.'
        dependency_require_command dd 'Builds bounded representative samples for automatic LZMA tuning.'
    fi

    if $VIDEO_TRANSCODE; then
        dependency_require_command ffmpeg 'Transcodes, decodes, and validates video and image media streams.'
        dependency_require_command ffprobe 'Reads stream layout, duration, codec, bitrate, and metadata before video processing.'
        dependency_require_command numfmt 'Formats media-helper byte counts consistently for logging and validation.'
        if command -v ffmpeg >/dev/null 2>&1; then
            ffmpeg -version >/dev/null 2>&1 || \
                dependency_add_critical 'working FFmpeg' 'The detected FFmpeg executable must start successfully before media processing.'
            if [[ -n $VIDEO_ENCODER ]]; then
                dependency_ffmpeg_has_encoder "$VIDEO_ENCODER" || \
                    dependency_add_critical "FFmpeg encoder: $VIDEO_ENCODER" 'The explicitly selected encoder must be compiled into the installed FFmpeg build.'
            else
                if [[ $VIDEO_CODEC == av1 ]]; then
                    for candidate in av1_vaapi av1_nvenc av1_qsv; do
                        dependency_ffmpeg_has_encoder "$candidate" && encoder_found=true && break
                    done
                else
                    for candidate in hevc_videotoolbox hevc_vaapi hevc_nvenc hevc_qsv; do
                        dependency_ffmpeg_has_encoder "$candidate" && encoder_found=true && break
                    done
                fi
                $encoder_found || dependency_add_critical "FFmpeg $VIDEO_CODEC encoder" \
                    "At least one supported hardware or software $VIDEO_CODEC encoder is required by the enabled video pipeline."
            fi
            if $VIDEO_PREFLIGHT && [[ $QUALITY_CHECK == required ]] && \
               ! dependency_ffmpeg_has_filter libvmaf && ! dependency_ffmpeg_has_filter ssim; then
                dependency_add_critical 'FFmpeg quality filter' 'Required quality verification needs either the libvmaf or SSIM filter.'
            fi
        fi
        if command -v ffprobe >/dev/null 2>&1; then
            ffprobe -version >/dev/null 2>&1 || \
                dependency_add_critical 'working FFprobe' 'The detected FFprobe executable must start successfully before stream analysis.'
        fi
    fi

    dependency_abort_if_critical
    printf 'Dependency preflight: all critical create-mode requirements are available.\n'
}

dependency_preflight_create_optional() {
    local video_count=${1:-0} jpeg_count=${2:-0} png_count=${3:-0} nested_count=${4:-0} batch_context=${5:-false}
    dependency_reset

    if $IMAGE_OPTIMIZE && (( jpeg_count > 0 || nested_count > 0 )); then
        if ! command -v jpegtran >/dev/null 2>&1 || ! command -v djpeg >/dev/null 2>&1; then
            dependency_add_optional 'jpegtran + djpeg' \
                'Losslessly optimizes JPEG entropy coding and decode-verifies identical pixels; affected JPEGs will otherwise be stored unchanged.'
        fi
    fi
    if $IMAGE_OPTIMIZE && (( png_count > 0 || nested_count > 0 )); then
        if ! command -v oxipng >/dev/null 2>&1 && ! command -v optipng >/dev/null 2>&1; then
            dependency_add_optional 'OxiPNG or OptiPNG' \
                'Losslessly recompresses PNG files; affected PNGs will otherwise be stored unchanged.'
        fi
    fi

    if [[ $PLATFORM_ID == linux ]]; then
        dependency_require_command getfacl \
            'Records POSIX access-control lists; silently omitting ACL permissions is forbidden.'
        dependency_abort_if_critical
        dependency_optional_command findmnt \
            'Identifies nested mounts and filesystem types for safer staging and one-filesystem reporting.'
        if [[ $batch_context == true ]]; then
            dependency_optional_command lsblk \
                'Maps partitions to physical disks so parallel batch jobs avoid excessive same-drive contention.'
        fi
    fi
    if (( video_count > 0 || jpeg_count > 0 || png_count > 0 || nested_count > 0 )); then
        dependency_optional_command setsid \
            'Places media workers in separate process groups so interruptions can terminate every child cleanly.'
    fi
    if ! $ALLOW_SLEEP && ! $SLEEP_PROTECTION_ACTIVE && ! platform_sleep_tool_available; then
        dependency_add_optional "$(platform_sleep_tool_label)" \
            'Prevents the operating system from sleeping while a long archive job is running.'
    fi

    if $VIDEO_TRANSCODE && $VIDEO_PREFLIGHT && (( video_count > 0 || nested_count > 0 )) && \
       command -v ffmpeg >/dev/null 2>&1; then
        if ! dependency_ffmpeg_has_filter libvmaf; then
            if dependency_ffmpeg_has_filter ssim; then
                dependency_add_optional 'FFmpeg libvmaf filter' \
                    'Provides perceptual video-quality scoring; the script will use the less perceptual SSIM comparison instead.'
            elif [[ $QUALITY_CHECK != required ]]; then
                dependency_add_optional 'FFmpeg libvmaf/SSIM filters' \
                    'Measure preflight quality against the source; without either filter only stream validity and size savings can be evaluated.'
            fi
        fi
    fi

    dependency_confirm_optional
}

dependency_preflight_inspect() {
    dependency_reset
    dependency_require_portable_command_contract
    dependency_resolve_7zip
    dependency_require_command awk 'Parses the technical archive listing and embedded metadata.'
    dependency_require_command grep 'Locates embedded manifests in the archive listing.'
    dependency_require_command stat 'Reads the physical archive size.'
    dependency_require_command realpath 'Canonicalizes the archive path before inspection.'
    dependency_require_command head 'Reads bounded listing and manifest results.'
    dependency_require_command numfmt 'Formats archive sizes for the inspection summary.'
    dependency_abort_if_critical
    DEPENDENCY_PREFLIGHT_SUMMARY='inspect dependencies complete'
}

dependency_archive_has_path() {
    local archive=$1 path=$2
    "$SEVEN_ZIP" l -ba "$archive" "$path" 2>/dev/null | grep -Fq "$path"
}

dependency_archive_manifest_has_data() {
    local archive=$1 path=$2 pattern=$3
    "$SEVEN_ZIP" x -so -y -spd "$archive" -- "$path" 2>/dev/null | grep -Eq "$pattern"
}

dependency_preflight_restore() {
    local archive_input=${1:-} archive=''
    dependency_reset
    dependency_require_portable_command_contract
    dependency_resolve_7zip
    dependency_require_command awk 'Parses embedded verification and metadata manifests.'
    dependency_require_command grep 'Locates and validates embedded manifests.'
    dependency_require_command find 'Validates the extracted tree and performs atomic restore layout handling.'
    dependency_require_command stat 'Reads archive and restored-file properties.'
    dependency_require_command realpath 'Canonicalizes archive and restore paths safely.'
    dependency_require_command mktemp 'Creates the isolated temporary restore destination.'
    dependency_require_command sha256sum 'Verifies restored file contents against the embedded hash manifest.'
    dependency_require_command mv 'Atomically moves the verified restored tree into place.'
    dependency_require_command rm 'Removes only temporary restore data after completion or failure.'
    dependency_require_command mkdir 'Creates the restore destination and its parent directories.'
    dependency_require_command wc 'Counts top-level restored objects.'
    dependency_require_command head 'Reads the single restored top-level path when applicable.'
    dependency_require_command flock 'Protects the restore workflow from conflicting archive operations.'

    if [[ -f $archive_input ]]; then
        archive=$(realpath -e -- "$archive_input" 2>/dev/null || true)
    fi
    # Sparse restoration is implemented in Python by rebuilding only recorded
    # data extents, so it works on APFS and common Linux sparse filesystems
    # without Linux-specific fallocate hole punching.
    dependency_abort_if_critical

    dependency_reset
    if [[ -n $archive && -n ${SEVEN_ZIP:-} ]]; then
        if dependency_archive_has_path "$archive" '.hardcore-archive-metadata/acl.txt' && \
           dependency_archive_manifest_has_data "$archive" '.hardcore-archive-metadata/acl.txt' \
               '^# hardcore-archive acl darwin-'; then
            if [[ $PLATFORM_ID != macos ]]; then
                dependency_add_critical 'native macOS ACL restoration' \
                    'This archive contains macOS ACL metadata; restore it on macOS. Translating access controls to POSIX ACLs is unsafe.'
            fi
        elif dependency_archive_has_path "$archive" '.hardcore-archive-metadata/acl.txt' && \
           dependency_archive_manifest_has_data "$archive" '.hardcore-archive-metadata/acl.txt' \
               '^(default:|(user|group):[^:]+:|mask::)'; then
            if [[ $PLATFORM_ID == macos ]]; then
                dependency_add_critical 'POSIX ACL restoration' \
                    'The archive contains extended Linux/POSIX ACLs; macOS cannot safely restore these access controls.'
            else
                dependency_require_command setfacl \
                    'The archive contains extended POSIX ACLs; restore fails closed rather than silently dropping access controls.'
            fi
        fi
    fi
    if ! $ALLOW_SLEEP && ! $SLEEP_PROTECTION_ACTIVE && ! platform_sleep_tool_available; then
        dependency_add_optional "$(platform_sleep_tool_label)" \
            'Prevents the operating system from sleeping during archive testing and restoration.'
    fi
    dependency_abort_if_critical
    dependency_confirm_optional
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

config_bool() {
    case ${1,,} in
        1|true|yes|on) printf 'true' ;;
        0|false|no|off) printf 'false' ;;
        *) return 1 ;;
    esac
}

load_config_file() {
    local file=$1 line key value bool
    [[ -r $file ]] || return 0

    while IFS= read -r line || [[ -n $line ]]; do
        line=${line%$'\r'}
        [[ $line =~ ^[[:space:]]*(#|$) ]] && continue
        [[ $line == *=* ]] || { warn "Ignoring malformed config line: $line"; continue; }
        key=${line%%=*}
        value=${line#*=}
        key=$(trim_config_value "$key")
        value=$(trim_config_value "$value")
        key=${key^^}

        case $key in
            EFFORT) EFFORT=${value,,} ;;
            PROGRESS_INTERVAL) PROGRESS_INTERVAL=$value ;;
            VIDEO_CODEC) VIDEO_CODEC=${value,,} ;;
            VIDEO_ENCODER) VIDEO_ENCODER=$value ;;
            VIDEO_MODE) VIDEO_MODE=${value,,} ;;
            VIDEO_SPECIAL_POLICY) VIDEO_SPECIAL_POLICY=${value,,} ;;
            VIDEO_MIN_VMAF) VIDEO_MIN_VMAF=$value ;;
            VIDEO_MIN_SAVINGS_PERCENT) VIDEO_MIN_SAVINGS_PERCENT=$value ;;
            VIDEO_CALIBRATION_CACHE|VIDEO_CALIBRATION_EARLY_ABORT)
                [[ ${HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED:-0} == 1 ]] && continue
                bool=$(config_bool "$value") || { warn "Invalid $key value in config: $value"; continue; }
                if [[ $key == VIDEO_CALIBRATION_CACHE ]]; then
                    export HARDCORE_ARCHIVE_CALIBRATION_CACHE=$bool
                else
                    export HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT=$bool
                fi
                ;;
            VIDEO_CALIBRATION_CACHE_DIR)
                [[ ${HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED:-0} == 1 ]] && continue
                export HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR=$value
                ;;
            VIDEO_QUALITY_THREADS)
                [[ ${HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED:-0} == 1 ]] && continue
                if [[ $value != auto && ! $value =~ ^([1-9]|[1-5][0-9]|6[0-4])$ ]]; then
                    die 'VIDEO_QUALITY_THREADS must be auto or an integer from 1 to 64.'
                fi
                export HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS=$value
                ;;
            VIDEO_ACCELERATION|VIDEO_GPU_FILTERS|VIDEO_CUDA_DEVICE)
                [[ ${HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED:-0} == 1 ]] && continue
                case "$key:$value" in
                    VIDEO_ACCELERATION:auto|VIDEO_ACCELERATION:cpu) export HARDCORE_ARCHIVE_VIDEO_ACCELERATION=$value ;;
                    VIDEO_GPU_FILTERS:auto|VIDEO_GPU_FILTERS:off) export HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS=$value ;;
                    VIDEO_CUDA_DEVICE:*)
                        [[ $value =~ ^(0|[1-9][0-9]{0,2})$ ]] || die 'VIDEO_CUDA_DEVICE must be a GPU index from 0 to 999.'
                        export HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE=$value ;;
                    *) die "Invalid $key: $value" ;;
                esac
                ;;
            VERIFY_MODE) VERIFY_MODE=${value,,} ;;
            WORK_DIR) WORK_DIR_OVERRIDE=$value ;;
            BATCH_ROOT_FILES) BATCH_ROOT_FILES=${value,,} ;;
            BATCH_JOBS) BATCH_JOBS=${value,,} ;;
            QUALITY_CHECK) QUALITY_CHECK=${value,,} ;;
            IMAGE_MODE) IMAGE_MODE=${value,,} ;;
            IMAGE_JOBS) IMAGE_JOBS=${value,,} ;;
            NESTED_MAX_DEPTH) NESTED_MAX_DEPTH=$value ;;
            NESTED_REPACK)
                bool=$(config_bool "$value") || { warn "Invalid NESTED_REPACK value in config: $value"; continue; }
                NESTED_REPACK=$bool
                ;;
            CONTAINER_REPACK)
                bool=$(config_bool "$value") || { warn "Invalid CONTAINER_REPACK value in config: $value"; continue; }
                CONTAINER_REPACK=$bool
                ;;
            POWER_OFF_ON_SUCCESS) : ;; # handled by the public launcher
            DICTIONARY) DICTIONARY_OVERRIDE=$value ;;
            THREADS) THREADS_OVERRIDE=$value ;;
            SEARCH_CYCLES)
                SEARCH_CYCLES=$value
                SEARCH_CYCLES_EXPLICIT=true
                ;;
            MC_AUTO)
                bool=$(config_bool "$value") || { warn "Invalid MC_AUTO value in config: $value"; continue; }
                MC_AUTO=$bool
                ;;
            VIDEO_TRANSCODE)
                bool=$(config_bool "$value") || { warn "Invalid VIDEO_TRANSCODE value in config: $value"; continue; }
                VIDEO_TRANSCODE=$bool
                ;;
            IMAGE_OPTIMIZE)
                bool=$(config_bool "$value") || { warn "Invalid IMAGE_OPTIMIZE value in config: $value"; continue; }
                IMAGE_OPTIMIZE=$bool
                ;;
            VIDEO_PREFLIGHT)
                bool=$(config_bool "$value") || { warn "Invalid VIDEO_PREFLIGHT value in config: $value"; continue; }
                VIDEO_PREFLIGHT=$bool
                ;;
            VIDEO_SCALE)
                bool=$(config_bool "$value") || { warn "Invalid VIDEO_SCALE value in config: $value"; continue; }
                [[ $bool == true ]] && VIDEO_NO_SCALE=false || VIDEO_NO_SCALE=true
                ;;
            VIDEO_DENOISE)
                bool=$(config_bool "$value") || { warn "Invalid VIDEO_DENOISE value in config: $value"; continue; }
                [[ $bool == true ]] && VIDEO_NO_DENOISE=false || VIDEO_NO_DENOISE=true
                ;;
            RESUME)
                bool=$(config_bool "$value") || { warn "Invalid RESUME value in config: $value"; continue; }
                RESUME_ENABLED=$bool
                ;;
            WRITE_REPORT)
                bool=$(config_bool "$value") || { warn "Invalid WRITE_REPORT value in config: $value"; continue; }
                WRITE_REPORT=$bool
                ;;
            CROSS_FILESYSTEMS)
                bool=$(config_bool "$value") || { warn "Invalid CROSS_FILESYSTEMS value in config: $value"; continue; }
                CROSS_FILESYSTEMS=$bool
                [[ $bool == true ]] && ONE_FILE_SYSTEM=false || ONE_FILE_SYSTEM=true
                ;;
            *) warn "Ignoring unknown config key: $key" ;;
        esac
    done < "$file"
}

safe_slug() {
    local value=$1
    value=${value//[^A-Za-z0-9._-]/-}
    value=${value#-}
    value=${value%-}
    [[ -n $value ]] || value=archive
    printf '%s' "$value"
}

platform_macos_mount_info() {
    local target=$1
    TARGET_FOR_MOUNT_INFO=$target python3 - <<'PYMOUNTINFO'
import os,re,subprocess
path=os.path.realpath(os.environ['TARGET_FOR_MOUNT_INFO'])
try: text=subprocess.check_output(['mount'],text=True,stderr=subprocess.DEVNULL)
except Exception: text=''
best=None
for line in text.splitlines():
    m=re.match(r'^(.*?) on (.+) \(([^,)]*)',line)
    if not m: continue
    source=m.group(1).replace('\\040',' ')
    mount=m.group(2).replace('\\040',' ')
    fstype=m.group(3).strip().lower()
    try: mount=os.path.realpath(mount)
    except OSError: pass
    if path==mount or path.startswith(mount.rstrip('/')+'/'):
        if best is None or len(mount)>len(best[0]): best=(mount,source,fstype)
if best: print(best[1],best[2],sep='\t')
else: print('unknown','unknown',sep='\t')
PYMOUNTINFO
}

filesystem_type() {
    local target=$1 source fstype
    if [[ $PLATFORM_ID == linux ]] && command -v findmnt >/dev/null 2>&1; then
        findmnt -T "$target" -n -o FSTYPE 2>/dev/null | head -n1
    elif [[ $PLATFORM_ID == macos ]]; then
        IFS=$'\t' read -r source fstype < <(platform_macos_mount_info "$target")
        printf '%s' "${fstype:-unknown}"
    else
        stat -f -c '%T' -- "$target" 2>/dev/null || printf 'unknown'
    fi
}

filesystem_source() {
    local target=$1 source fstype
    if [[ $PLATFORM_ID == linux ]] && command -v findmnt >/dev/null 2>&1; then
        findmnt -T "$target" -n -o SOURCE 2>/dev/null | head -n1
    elif [[ $PLATFORM_ID == macos ]]; then
        IFS=$'\t' read -r source fstype < <(platform_macos_mount_info "$target")
        printf '%s' "${source:-unknown}"
    else
        df -P -- "$target" 2>/dev/null | awk 'NR==2 {print $1}'
    fi
}

same_filesystem() {
    [[ $(stat -c '%d' -- "$1") == $(stat -c '%d' -- "$2") ]]
}

# Return a conservative storage-lane key. Linux resolves partitions through
# lsblk; macOS collapses diskXsY/APFS device nodes to their parent diskX.
storage_lane_key() {
    local target=$1 source device parent
    source=$(filesystem_source "$target")
    [[ -n $source ]] || source=unknown
    device=${source%%\[*}
    if [[ $PLATFORM_ID == linux && $device == /dev/* ]] && command -v lsblk >/dev/null 2>&1; then
        parent=$(lsblk -ndo PKNAME -- "$device" 2>/dev/null | head -n1 || true)
        if [[ -n $parent ]]; then
            printf 'disk:%s' "$parent"
            return 0
        fi
        parent=$(lsblk -ndo KNAME -- "$device" 2>/dev/null | head -n1 || true)
        if [[ -n $parent ]]; then
            printf 'disk:%s' "$parent"
            return 0
        fi
    elif [[ $PLATFORM_ID == macos && $device =~ ^/dev/(r?disk[0-9]+) ]]; then
        printf 'disk:%s' "${BASH_REMATCH[1]}"
        return 0
    fi
    printf 'mount:%s' "$source"
}

platform_list_nested_mounts() {
    local source=$1 destination=$2
    : > "$destination"
    if [[ $PLATFORM_ID == linux ]] && command -v findmnt >/dev/null 2>&1; then
        findmnt -R -n -o TARGET --target "$source" 2>/dev/null | \
            awk -v source="$source" 'index($0, source "/") == 1' > "$destination" || true
        return
    fi
    if [[ $PLATFORM_ID == macos ]]; then
        SOURCE_FOR_MOUNTS=$source python3 - "$destination" <<'PYMOUNTS'
import os, re, subprocess, sys
source=os.path.realpath(os.environ['SOURCE_FOR_MOUNTS'])
out=sys.argv[1]
try:
    text=subprocess.check_output(['mount'], text=True, stderr=subprocess.DEVNULL)
except Exception:
    text=''
mounts=[]
for line in text.splitlines():
    m=re.search(r' on (.+) \([^)]*\)$', line)
    if not m: continue
    path=m.group(1).replace('\\040',' ')
    try: path=os.path.realpath(path)
    except OSError: continue
    if path.startswith(source + os.sep): mounts.append(path)
with open(out,'w',encoding='utf-8') as f:
    for path in sorted(set(mounts)): f.write(path+'\n')
PYMOUNTS
    fi
}

acquire_output_lock() {
    command -v flock >/dev/null 2>&1 ||         die "Critical dependency disappeared after preflight: flock"
    LOCK_FILE="${ARCHIVE}.lock"
    exec {LOCK_FD}>"$LOCK_FILE"
    if ! flock -n "$LOCK_FD"; then
        die "Another process is already targeting this output: $ARCHIVE"
    fi
    printf 'PID=%s\nStarted=%s\nSource=%s\n' "$$" "$(date --iso-8601=seconds)" "$SOURCE" > "$LOCK_FILE"
}

release_output_lock() {
    if [[ -n ${LOCK_FD:-} ]]; then
        flock -u "$LOCK_FD" 2>/dev/null || true
        eval "exec ${LOCK_FD}>&-" 2>/dev/null || true
        LOCK_FD=""
    fi
    [[ -n ${LOCK_FILE:-} ]] && rm -f -- "$LOCK_FILE" 2>/dev/null || true
}

choose_work_root() {
    local candidate probe fs free required
    required=${MINIMUM_STAGING_BYTES:-$((512 * MIB))}
    local -a candidates=()
    [[ -n $WORK_DIR_OVERRIDE ]] && candidates+=("$WORK_DIR_OVERRIDE")
    candidates+=("$PLATFORM_CACHE_HOME/hardcore-archive" "$ARCHIVE_PARENT/.hardcore-archive-work")

    for candidate in "${candidates[@]}"; do
        candidate=$(realpath -m -- "$candidate")
        if [[ -n ${SOURCE:-} ]] && { [[ $candidate == "$SOURCE" || $candidate == "$SOURCE/"* ]] || [[ $SOURCE == "$candidate/"* ]]; }; then
            warn "Rejecting unsafe working directory because it overlaps the source: $candidate"
            continue
        fi
        mkdir -p -- "$candidate" 2>/dev/null || continue
        probe="$candidate/.write-test.$$"
        if ! (umask 077; : > "$probe") 2>/dev/null; then
            continue
        fi
        rm -f -- "$probe"
        free=$(df -PB1 -- "$candidate" | awk 'NR==2 {print $4}')
        (( free >= required )) || continue
        fs=$(filesystem_type "$candidate")
        case $fs in
            ext2|ext3|ext4|btrfs|xfs|f2fs|zfs|tmpfs|overlay|reiserfs|jfs|apfs|hfs|hfsplus)
                WORK_ROOT=$(realpath -m -- "$candidate")
                return 0
                ;;
            *)
                [[ -n $WORK_DIR_OVERRIDE ]] || continue
                WORK_ROOT=$(realpath -m -- "$candidate")
                return 0
                ;;
        esac
    done

    die "No suitable working directory has enough free space. Use --work-dir PATH."
}

archive_report_path() {
    if [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
        printf '%s/report.txt' "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR"
        return
    fi
    local stem=$ARCHIVE
    [[ $stem == *.7z ]] && stem=${stem%.7z}
    printf '%s.report.txt' "$stem"
}

component_log_path() {
    if [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
        mkdir -p -- "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR" || return 1
        : > "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/$1" || return 1
        printf '%s/%s' "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR" "$1"
    else
        mktemp
    fi
}

human_bytes() {
    local value=$1
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "$value"
    else
        awk -v b="$value" 'BEGIN {
            split("B KiB MiB GiB TiB", u, " "); i=1;
            while (b >= 1024 && i < 5) { b/=1024; i++ }
            printf "%.2f %s", b, u[i]
        }'
    fi
}

format_duration() {
    local total=$1
    local hours=$((total / 3600))
    local minutes=$(((total % 3600) / 60))
    local seconds=$((total % 60))

    if (( hours > 0 )); then
        printf '%dh %02dm %02ds' "$hours" "$minutes" "$seconds"
    elif (( minutes > 0 )); then
        printf '%dm %02ds' "$minutes" "$seconds"
    else
        printf '%ds' "$seconds"
    fi
}

current_archive_size() {
    if [[ -n ${TEMP_ARCHIVE:-} && -e $TEMP_ARCHIVE ]]; then
        stat -c '%s' -- "$TEMP_ARCHIVE" 2>/dev/null || printf '0'
    else
        printf '0'
    fi
}

video_progress_summary() {
    [[ -n ${VIDEO_PIPELINE_PID:-} && -s ${VIDEO_LOG:-} ]] || return 0

    local completed unchanged failed processed current_file ff_time source_duration state percent
    completed=$(grep -c '^Completed successfully:' "$VIDEO_LOG" 2>/dev/null || true)
    unchanged=$(grep -Ec 'The larger result was removed\.|Minimum savings not reached\.|Complex source preserved unchanged\.|Stream-preservation validation failed\.|Preflight predicts insufficient savings\.' "$VIDEO_LOG" 2>/dev/null || true)
    failed=$(grep -c 'Batch item failed with exit code' "$VIDEO_LOG" 2>/dev/null || true)
    processed=$((completed + unchanged + failed))

    current_file=$(awk '
        /^\[[0-9]+\/[0-9]+\] Processing$/ {
            if (getline > 0) {
                sub(/^[[:space:]]+/, "", $0)
                last=$0
            }
        }
        END {print last}
    ' "$VIDEO_LOG" 2>/dev/null)

    ff_time=$(tail -c 131072 "$VIDEO_LOG" 2>/dev/null |
        tr '\r' '\n' |
        grep -Eo 'time=[^[:space:]]+' |
        tail -n 1 |
        cut -d= -f2 || true)

    source_duration=$(awk '
        /^Source analysis$/ {candidate=""}
        /^Duration:[[:space:]]+/ {candidate=$2}
        END {print candidate}
    ' "$VIDEO_LOG" 2>/dev/null)

    percent=''
    if [[ $ff_time =~ ^([0-9]+):([0-9]+):([0-9]+([.][0-9]+)?)$ &&           $source_duration =~ ^([0-9]+):([0-9]+):([0-9]+)$ ]]; then
        percent=$(LC_NUMERIC=C awk -v current="$ff_time" -v total="$source_duration" '
            function seconds(v, a) { split(v,a,":"); return a[1]*3600+a[2]*60+a[3] }
            BEGIN { t=seconds(total); c=seconds(current); if (t>0) { p=c*100/t; if(p>100)p=100; printf "%.1f",p } }
        ')
    fi

    if kill -0 "$VIDEO_PIPELINE_PID" 2>/dev/null; then
        state="running"
    else
        state="finished"
    fi

    printf 'video %s: %s/%s handled' "$state" "$processed" "${VIDEO_COUNT:-0}"
    [[ -n $percent ]] && printf ', current file %s%%' "$percent"
    [[ -n $ff_time ]] && printf ' (%s)' "$ff_time"
    [[ -n $current_file ]] && printf ', %s' "$(basename -- "$current_file")"
}

heartbeat() {
    local stage=$1
    local watched_pid=$2
    local started=$3
    local elapsed size available_kib available_mib video_status image_status

    (( PROGRESS_INTERVAL > 0 )) || return 0

    while kill -0 "$watched_pid" 2>/dev/null; do
        sleep "$PROGRESS_INTERVAL" || return 0
        kill -0 "$watched_pid" 2>/dev/null || return 0

        elapsed=$((SECONDS - started))
        size=$(current_archive_size)
        IFS=$'\t' read -r _mem_total available_kib _swap_total _swap_free < <(platform_memory_kib)
        available_mib=$((available_kib / 1024))

        video_status=$(video_progress_summary || true)
        image_status=$(image_progress_summary || true)
        printf '\n[%(%H:%M:%S)T] Still running: %s | elapsed %s | archive so far %s | available RAM %s MiB' \
            -1 "$stage" "$(format_duration "$elapsed")" "$(human_bytes "$size")" "$available_mib" >&2
        [[ -n $video_status ]] && printf ' | %s' "$video_status" >&2
        [[ -n $image_status ]] && printf ' | %s' "$image_status" >&2
        printf '\n' >&2
    done
}

run_logged_stage() {
    local stage=$1
    local logfile=$2
    shift 2
    local started=$SECONDS
    local job_pid heartbeat_pid='' rc
    local timing_started timing_phase=archive_write
    timing_started=$(hardcore_timing_now 2>/dev/null) || timing_started=0
    [[ $stage == 'archive integrity test' ]] && timing_phase=archive_verification

    : > "$logfile"

    set +e
    (
        set -o pipefail
        "$@" 2>&1 | tee "$logfile"
    ) &
    job_pid=$!

    if (( PROGRESS_INTERVAL > 0 )); then
        heartbeat "$stage" "$job_pid" "$started" &
        heartbeat_pid=$!
    fi

    wait "$job_pid"
    rc=$?

    if [[ -n $heartbeat_pid ]]; then
        kill "$heartbeat_pid" 2>/dev/null || true
        wait "$heartbeat_pid" 2>/dev/null || true
    fi
    set -e

    # Strong verification is timed around extraction plus hashing as a whole.
    if [[ $stage != 'single-pass hash extraction' ]]; then
        hardcore_timing_record "$timing_phase" "$timing_started" "$rc"
    fi
    printf '\n%s finished after %s.\n' "$stage" "$(format_duration "$((SECONDS - started))")"
    return "$rc"
}

parse_size_mib() {
    local raw=${1,,}
    local number unit bytes

    if [[ $raw =~ ^([0-9]+)([kmgt]?)b?$ ]]; then
        number=${BASH_REMATCH[1]}
        unit=${BASH_REMATCH[2]}
    else
        return 1
    fi

    case "$unit" in
        "") bytes=$number ;;
        k)  bytes=$((number * 1024)) ;;
        m)  bytes=$((number * MIB)) ;;
        g)  bytes=$((number * GIB)) ;;
        t)  bytes=$((number * 1024 * GIB)) ;;
        *)  return 1 ;;
    esac

    # A suffix-less value is interpreted as MiB because this option controls
    # the 7-Zip dictionary, not an arbitrary byte count.
    if [[ -z $unit ]]; then
        printf '%s\n' "$number"
    else
        printf '%s\n' "$(((bytes + MIB - 1) / MIB))"
    fi
}

is_video_path() {
    local lower=${1,,}
    case "$lower" in
        *.mp4|*.mkv|*.webm|*.mov|*.m4v|*.avi|*.wmv|*.flv|*.mpg|*.mpeg|\
        *.m2ts|*.mts|*.ts|*.vob|*.ogv|*.3gp|*.3g2|*.mxf|*.dvr-ms|\
        *.rm|*.rmvb|*.asf|*.divx|*.f4v)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}


is_image_path() {
    local lower=${1,,}
    case "$lower" in
        *.jpg|*.jpeg|*.jpe|*.jfif|*.png) return 0 ;;
        *) return 1 ;;
    esac
}

write_embedded_video_helper() {
    local destination=$1
    cat > "$destination" <<'__HARDCORE_ARCHIVE_VIDEO_HELPER__'
#!/usr/bin/env bash
set -o pipefail

readonly TARGET_HEIGHT=1080
readonly AV1_CRF=33
readonly AV1_PRESET=2
readonly HEVC_CRF=28
readonly HEVC_PRESET=slow
readonly DENOISE_FILTER='hqdn3d=1.2:1.0:3.0:2.5'
readonly SCRIPT_VERSION='2026-07-22-integrated-video-r3'

codec_choice='av1'
force_encoder=''
min_savings_percent='0'
assume_yes=false
keep_larger=false
automatic_audio=true
allow_scaling=true
allow_denoise=true
video_preflight=true
quality_check=auto
quality_vmaf_threshold=''
quality_ssim_threshold=0.985
preflight_sample_seconds=12
preflight_min_duration=60
preflight_min_size=$((128 * 1024 * 1024))
preflight_files=()
replace_original=false
batch_mode=false
inhibit_pid=''

usage() {
    cat <<'USAGE'
Usage:
  compress-video [options] INPUT [OUTPUT.mkv]
  compress-video --batch [options] DIRECTORY

Options:
  --batch           Recursively process supported videos in DIRECTORY.
  --av1             Use AV1. Default.
  --hevc, --h265    Use H.265/HEVC.
  --list-encoders   List all successfully probed encoders on this system and exit.
  --encoder NAME    Force a specific encoder (e.g., hevc_videotoolbox). Bypasses auto-select.
  --yes, -y         Accept automatic recommendations and confirmations.
  --replace         Replace each source after successful validation.
                    Non-MKV input becomes NAME.mkv; MKV keeps its name.
  --keep-larger     Keep a valid result even if it is not smaller.
  --no-audio        Copy all audio streams unchanged.
  --no-scale        Never reduce resolution.
  --no-denoise      Never apply denoising.
  --min-savings P   Keep the transcode only if it saves at least P percent.
  --quality-vmaf V  Minimum accepted VMAF score (required).
  --no-preflight    Do not test representative segments before a full encode.
  --quality-check M  Sample-quality policy: auto, off, or required.
  --version         Show the script version.
  --help, -h        Show this help.
USAGE
}

die() { printf 'Error: %s\n' "$*" >&2; exit 1; }
has_command() { command -v "$1" >/dev/null 2>&1; }
# HARDCORE_MEDIA_NESTED_FIX_V1
has_encoder() { ffmpeg -hide_banner -encoders 2>/dev/null | awk -v wanted="$1" 'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'; }
has_filter() { ffmpeg -hide_banner -filters 2>/dev/null | awk -v wanted="$1" 'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'; }
human_size() { numfmt --to=iec-i --suffix=B "$1" 2>/dev/null || printf '%s bytes' "$1"; }

prevent_sleep() {
    [[ "${_IS_CHILD_PROCESS:-0}" == "1" ]] && return 0
    export _IS_CHILD_PROCESS=1

    if has_command systemd-inhibit; then
        systemd-inhibit --what=sleep:idle --who="compress-video" --why="Video encoding in progress" sleep 31536000 >/dev/null 2>&1 &
        inhibit_pid=$!
    elif has_command caffeinate; then
        caffeinate -i -m sleep 31536000 >/dev/null 2>&1 &
        inhibit_pid=$!
    elif has_command gnome-session-inhibit; then
        gnome-session-inhibit --inhibit suspend:idle sleep 31536000 >/dev/null 2>&1 &
        inhibit_pid=$!
    fi

    if [[ -n "$inhibit_pid" ]]; then
        disown "$inhibit_pid" 2>/dev/null || true
    fi
}

probe_encoder_synthetic() {
    local enc="$1"
    shift 1
    has_encoder "$enc" || return 1

    local va_probe=()
    [[ "$enc" == *_vaapi ]] && va_probe=("-init_hw_device" "vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" "-filter_hw_device" "va" "-vf" "format=nv12,hwupload")

    ffmpeg -hide_banner -v error "${va_probe[@]}" -f lavfi -i color=c=black:s=1280x720:r=24 -vframes 1 \
        -c:v "$enc" "$@" -f null - >/dev/null 2>&1
}

do_list_encoders() {
    for required in ffmpeg; do has_command "$required" || die "Missing command: $required"; done
    printf "Probing system for working encoders (Synthetic 720p Test)...\n\n"

    printf "AV1 Encoders:\n"
    probe_encoder_synthetic av1_vaapi -rc_mode CQP -global_quality:v 33 && printf "  av1_vaapi          (AMD/Mesa VA-API Linux Hardware)\n"
    probe_encoder_synthetic av1_nvenc -cq:v 33 -preset:v p4 && printf "  av1_nvenc          (NVIDIA NVENC)\n"
    probe_encoder_synthetic av1_qsv -global_quality:v 33 -preset:v balanced && printf "  av1_qsv            (Intel QSV)\n"
    has_encoder libsvtav1 && printf "  libsvtav1          (Software SVT-AV1)\n"

    printf "\nHEVC / H.265 Encoders:\n"
    probe_encoder_synthetic hevc_videotoolbox -q:v 65 -pix_fmt nv12 && printf "  hevc_videotoolbox  (Apple VideoToolbox Hardware)\n"
    probe_encoder_synthetic hevc_vaapi -rc_mode CQP -global_quality:v 28 && printf "  hevc_vaapi         (AMD/Mesa VA-API Linux Hardware)\n"
    probe_encoder_synthetic hevc_nvenc -cq:v 28 -preset:v p4 && printf "  hevc_nvenc         (NVIDIA NVENC)\n"
    probe_encoder_synthetic hevc_qsv -global_quality:v 28 -preset:v balanced && printf "  hevc_qsv           (Intel QSV)\n"
    has_encoder libx265 && printf "  libx265            (Software x265)\n"

    printf "\nUsage: compress-video --encoder <name> INPUT\n"
}

apply_encoder() {
    local enc="$1"
    video_encoder="$enc"
    case "$enc" in
        av1_vaapi)
            expected_codec='av1'; output_suffix='av1'; video_codec_label='AV1 / VA-API (Hardware)'
            # HARDCORE_VIDEO_CODEC_COMPETITION_V2
            video_crf="CQP q_idx 128 (pre-calibration)"; video_preset='N/A'; video_pix_fmt='vaapi'
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "128")
            ;;
        hevc_videotoolbox)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / Apple VideoToolbox (Hardware)'
            video_crf='Quality 65'; video_preset='N/A'; video_pix_fmt='nv12'
            encoder_args=("-q:v" "65")
            ;;
        hevc_vaapi)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / VA-API (Hardware)'
            video_crf="CQP QP 26 (pre-calibration)"; video_preset='N/A'; video_pix_fmt='vaapi'
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "26")
            ;;
        av1_nvenc)
            expected_codec='av1'; output_suffix='av1'; video_codec_label='AV1 / NVIDIA NVENC (Hardware)'
            video_crf="CQ ${AV1_CRF}"; video_preset='p4'; video_pix_fmt='p010le'
            encoder_args=("-cq:v" "$AV1_CRF" "-preset:v" "p4")
            ;;
        av1_qsv)
            expected_codec='av1'; output_suffix='av1'; video_codec_label='AV1 / Intel QSV (Hardware)'
            video_crf="ICQ ${AV1_CRF}"; video_preset='balanced'; video_pix_fmt='p010le'
            encoder_args=("-global_quality:v" "$AV1_CRF" "-preset:v" "balanced")
            ;;
        libsvtav1)
            expected_codec='av1'; output_suffix='av1'; video_codec_label='AV1 / SVT-AV1 (Software)'
            video_crf="CRF ${AV1_CRF}"; video_preset="$AV1_PRESET"; video_pix_fmt='yuv420p10le'
            encoder_args=("-crf:v" "$AV1_CRF" "-preset:v" "$AV1_PRESET")
            ;;
        hevc_nvenc)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / NVIDIA NVENC (Hardware)'
            video_crf="CQ ${HEVC_CRF}"; video_preset='p4'; video_pix_fmt='p010le'
            encoder_args=("-cq:v" "$HEVC_CRF" "-preset:v" "p4")
            ;;
        hevc_qsv)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / Intel QSV (Hardware)'
            video_crf="ICQ ${HEVC_CRF}"; video_preset='balanced'; video_pix_fmt='p010le'
            encoder_args=("-global_quality:v" "$HEVC_CRF" "-preset:v" "balanced")
            ;;
        libx265)
            expected_codec='hevc'; output_suffix='hevc'; video_codec_label='H.265 / x265 (Software)'
            video_crf="CRF ${HEVC_CRF}"; video_preset="$HEVC_PRESET"; video_pix_fmt='yuv420p10le'
            encoder_args=("-crf:v" "$HEVC_CRF" "-preset:v" "$HEVC_PRESET")
            ;;
        *)
            die "Unknown or unsupported encoder: $enc. Use --list-encoders to see valid options."
            ;;
    esac
}

determine_encoder() {
    local sample="$1"
    local test_out
    test_out="$(dirname -- "$sample")/.probe_test_$$.mkv"
    probe_temporary="$test_out"

    test_real_encode() {
        local enc="$1" expected="$2"
        shift 2
        printf "  Testing %-20s " "$enc..."

        if ! has_encoder "$enc"; then
            printf "Not available.\n"
            return 1
        fi

        local va_args=()
        if [[ "$enc" == *_vaapi ]]; then
            va_args=("-init_hw_device" "vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" "-filter_hw_device" "va" "-vf" "format=nv12,hwupload")
        elif [[ "$enc" == *_nvenc ]]; then
            va_args=(-gpu:v "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}")
        fi

        if ffmpeg -hide_banner -v error -y -t 2 -i "$sample" "${va_args[@]}" -map '0:V:0' \
            -c:v "$enc" "$@" -an -sn -f matroska "$test_out" >/dev/null 2>&1; then

            local actual_c
            actual_c=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$test_out" 2>/dev/null | head -n1)
            rm -f -- "$test_out"

            if [[ "$actual_c" == "$expected" ]]; then
                printf "Success!\n"
                return 0
            else
                printf "Failed (Output codec mismatch: %s).\n" "${actual_c:-None}"
                return 1
            fi
        else
            rm -f -- "$test_out"
            printf "Failed (Hardware/FFmpeg error).\n"
            return 1
        fi
    }

    printf '\nValidating encoder against real file constraints:\n  %s\n' "$(basename -- "$sample")"

    if [[ -n "$force_encoder" ]]; then
        case "$force_encoder" in
            av1_vaapi|av1_nvenc|av1_qsv|hevc_videotoolbox|hevc_vaapi|hevc_nvenc|hevc_qsv) ;;
            *) die "Software/non-hardware video encoder '$force_encoder' is forbidden. Hardware encoding is mandatory." ;;
        esac
        apply_encoder "$force_encoder"
        if [[ "$force_encoder" != libsvtav1 && "$force_encoder" != libx265 ]]; then
            if [[ ${HARDCORE_ARCHIVE_HARDWARE_ENCODER_LOCKED:-} == "$force_encoder" ]]; then
                printf "  Inherited hardware encoder %s already validated by parent.\n" "$force_encoder"
            else
                test_real_encode "$force_encoder" "$expected_codec" "${encoder_args[@]}" || die "Forced encoder '$force_encoder' crashed on the real file test."
            fi
        else
            has_encoder "$force_encoder" || die "Software encoder '$force_encoder' is missing."
            printf "  Forced software encoder %s accepted.\n" "$force_encoder"
        fi
    else
        case "$codec_choice" in
            av1)
                if test_real_encode av1_vaapi av1 -rc_mode CQP -global_quality:v "$AV1_CRF"; then apply_encoder av1_vaapi
                elif test_real_encode av1_nvenc av1 -cq:v "$AV1_CRF" -preset:v p4; then apply_encoder av1_nvenc
                elif test_real_encode av1_qsv av1 -global_quality:v "$AV1_CRF" -preset:v balanced; then apply_encoder av1_qsv
                else die 'No compatible hardware AV1 encoder successfully processed the sample file.'
                fi
                ;;
            hevc)
                if test_real_encode hevc_videotoolbox hevc -q:v 65 -pix_fmt nv12; then apply_encoder hevc_videotoolbox
                elif test_real_encode hevc_vaapi hevc -rc_mode CQP -global_quality:v "$HEVC_CRF"; then apply_encoder hevc_vaapi
                elif test_real_encode hevc_nvenc hevc -cq:v "$HEVC_CRF" -preset:v p4; then apply_encoder hevc_nvenc
                elif test_real_encode hevc_qsv hevc -global_quality:v "$HEVC_CRF" -preset:v balanced; then apply_encoder hevc_qsv
                else die 'No compatible hardware HEVC encoder successfully processed the sample file.'
                fi
                ;;
        esac
    fi
    probe_temporary=""
}

format_duration() {
    LC_NUMERIC=C awk -v seconds="${1:-0}" 'BEGIN {
        if (seconds == "" || seconds !~ /^[0-9]+([.][0-9]+)?$/) { print "Unknown"; exit }
        total=int(seconds+0.5); printf "%02d:%02d:%02d", int(total/3600), int((total%3600)/60), total%60
    }'
}

ask_yes_no() {
    local question="$1" default="${2:-n}" answer=''
    while true; do
        if [[ "$default" == y ]]; then
            read -r -p "$question [Y/n]: " answer; answer="${answer:-y}"
        else
            read -r -p "$question [y/N]: " answer; answer="${answer:-n}"
        fi
        case "${answer,,}" in y|yes) return 0;; n|no) return 1;; *) printf 'Please enter yes or no.\n';; esac
    done
}

calculate_scaled_width() {
    LC_NUMERIC=C awk -v width="$1" -v height="$2" -v target="$TARGET_HEIGHT" 'BEGIN {
        scaled=width*target/height; scaled=int((scaled/2)+0.5)*2; if (scaled<2) scaled=2; print scaled
    }'
}

stream_count_file() {
    local selector=$1 file=$2
    ffprobe -v error -select_streams "$selector" -show_entries stream=index -of csv=p=0 "$file" |
        sed '/^[[:space:]]*$/d' | wc -l
}

stream_count() {
    stream_count_file "$1" "$input"
}

cleanup() {
    local preflight_file
    if [[ -n "${temporary:-}" && -f "$temporary" ]]; then rm -f -- "$temporary"; fi
    if [[ -n "${probe_temporary:-}" && -f "$probe_temporary" ]]; then rm -f -- "$probe_temporary"; fi
    for preflight_file in "${preflight_files[@]:-}"; do
        [[ -n "$preflight_file" ]] && rm -f -- "$preflight_file"
    done
    if [[ -n "${inhibit_pid:-}" ]] && kill -0 "$inhibit_pid" 2>/dev/null; then
        kill "$inhibit_pid" 2>/dev/null || true
    fi
    if [[ -n ${RESTORE_TEMP:-} && -d ${RESTORE_TEMP:-} && ${RESTORE_COMMITTED:-false} != true ]]; then
        rm -rf --one-file-system -- "$RESTORE_TEMP" 2>/dev/null || true
    fi
    if [[ -n ${RESTORE_LOCK_FD:-} ]]; then
        flock -u "$RESTORE_LOCK_FD" 2>/dev/null || true
        eval "exec ${RESTORE_LOCK_FD}>&-" 2>/dev/null || true
    fi
    [[ -n ${RESTORE_LOCK_FILE:-} ]] && rm -f -- "$RESTORE_LOCK_FILE" 2>/dev/null || true
    local batch_pid
    for batch_pid in "${BATCH_CHILD_PIDS[@]:-}"; do
        [[ -n $batch_pid ]] && kill "$batch_pid" 2>/dev/null || true
    done
    for batch_pid in "${BATCH_CHILD_PIDS[@]:-}"; do
        [[ -n $batch_pid ]] && wait "$batch_pid" 2>/dev/null || true
    done
    [[ -n ${BATCH_ROOT_STAGE_PARENT:-} && -d ${BATCH_ROOT_STAGE_PARENT:-} ]] && rm -rf --one-file-system -- "$BATCH_ROOT_STAGE_PARENT" 2>/dev/null || true
    if [[ -n ${BATCH_LOCK_FD_GLOBAL:-} ]]; then flock -u "$BATCH_LOCK_FD_GLOBAL" 2>/dev/null || true; fi
    [[ -n ${BATCH_LOCK_FILE_GLOBAL:-} ]] && rm -f -- "$BATCH_LOCK_FILE_GLOBAL" 2>/dev/null || true
}
trap cleanup EXIT INT TERM HUP

cleanup_orphaned_partials() {
    local target_dir="$1"
    local recursive="${2:-false}"
    local find_args=("-maxdepth" "1")

    [[ "$recursive" == true ]] && find_args=()

    while IFS= read -r -d '' file; do
        if [[ "$(basename -- "$file")" =~ \.partial\.([0-9]+)\.mkv$ || "$(basename -- "$file")" =~ \.probe_test_([0-9]+)\.mkv$ ]]; then
            local pid="${BASH_REMATCH[1]}"
            if ! kill -0 "$pid" 2>/dev/null; then
                printf "Cleaning up orphaned file from a previous crash: %s\n" "$(basename -- "$file")"
                rm -f -- "$file"
            fi
        fi
    done < <(find "$target_dir" "${find_args[@]}" -type f \( -name ".*.partial.*.mkv" -o -name ".*.probe_test_*.mkv" \) -print0 2>/dev/null)
}

positional=()
while (($#)); do
    case "$1" in
        --list-encoders) do_list_encoders; exit 0;;
        --encoder) force_encoder="$2"; shift;;
        --batch) batch_mode=true;;
        --av1) codec_choice='av1';;
        --hevc|--h265) codec_choice='hevc';;
        --yes|-y) assume_yes=true;;
        --replace) replace_original=true;;
        --keep-larger) keep_larger=true;;
        --no-audio) automatic_audio=false;;
        --no-scale) allow_scaling=false;;
        --no-denoise) allow_denoise=false;;
        --no-preflight) video_preflight=false;;
        --quality-check)
            (($# >= 2)) || die '--quality-check requires auto, off, or required.'
            quality_check=${2,,}; shift
            ;;
        --quality-vmaf)
            (($# >= 2)) || die '--quality-vmaf requires a number.'
            quality_vmaf_threshold=$2; shift
            ;;
        --quality-vmaf=*) quality_vmaf_threshold=${1#*=};;
        --quality-ssim)
            (($# >= 2)) || die '--quality-ssim requires a number.'
            quality_ssim_threshold=$2; shift
            ;;
        --min-savings)
            (($# >= 2)) || die '--min-savings requires a percentage.'
            min_savings_percent=$2
            shift
            ;;
        --min-savings=*) min_savings_percent=${1#*=};;
        --version) printf '%s\n' "$SCRIPT_VERSION"; exit 0;;
        --help|-h) usage; exit 0;;
        --) shift; positional+=("$@"); break;;
        -*) die "Unknown option: $1";;
        *) positional+=("$1");;
    esac
    shift
done

if [[ "$batch_mode" == true ]]; then
    ((${#positional[@]} == 1)) || { usage >&2; exit 2; }
    batch_root="${positional[0]}"
    [[ -d "$batch_root" ]] || die "Batch input is not a directory: $batch_root"
    requested_output=''
else
    ((${#positional[@]} >= 1 && ${#positional[@]} <= 2)) || { usage >&2; exit 2; }
    input="${positional[0]}"
    requested_output="${positional[1]:-}"
    [[ -f "$input" ]] || die "Input does not exist: $input"
    if [[ "$replace_original" == true && -n "$requested_output" ]]; then
        die '--replace chooses the destination automatically; do not provide OUTPUT.'
    fi
fi

for required in ffmpeg ffprobe awk grep sed stat numfmt realpath chmod find; do has_command "$required" || die "Missing command: $required"; done
[[ $min_savings_percent =~ ^[0-9]+([.][0-9]+)?$ ]] || die '--min-savings must be a non-negative number.'
LC_NUMERIC=C awk -v p="$min_savings_percent" 'BEGIN {exit !(p >= 0 && p <= 100)}' || die '--min-savings must be between 0 and 100.'
case "$quality_check" in auto|off|required) ;; *) die '--quality-check must be auto, off, or required.' ;; esac
[[ $quality_vmaf_threshold =~ ^[0-9]+([.][0-9]+)?$ ]] || die '--quality-vmaf must be numeric and explicitly supplied.'
LC_NUMERIC=C awk -v v="$quality_vmaf_threshold" 'BEGIN {exit !(v >= 0 && v <= 100)}' || die '--quality-vmaf must be 0..100.'
LC_NUMERIC=C awk -v v="$quality_ssim_threshold" 'BEGIN {exit !(v >= 0 && v <= 1)}' || die '--quality-ssim must be 0..1.'

prevent_sleep

encoder_args=()
video_pix_fmt='yuv420p10le'

run_batch() {
    local root="$1" script_path file filename lower_name stem target
    local total success=0 failed=0 skipped=0 unchanged=0 rc index=0
    local -a files=() child_args=()
    local -A replacement_targets=()

    script_path=$(realpath -e -- "$0") || die 'Could not resolve the script path.'

    while IFS= read -r -d '' file; do
        filename=$(basename -- "$file")
        lower_name="${filename,,}"
        case "$lower_name" in
            .*\.partial.*|.*\.probe_test_*|*-compressed-av1.mkv|*-compressed-hevc.mkv) continue;;
        esac
        files+=("$file")
    done < <(
        find -L "$root" -type f \
            \( -iname '*.mp4' -o -iname '*.mkv' -o -iname '*.mov' -o -iname '*.m4v' \
               -o -iname '*.avi' -o -iname '*.webm' -o -iname '*.wmv' -o -iname '*.flv' \
               -o -iname '*.mpg' -o -iname '*.mpeg' -o -iname '*.m2ts' -o -iname '*.mts' \
               -o -iname '*.ts' -o -iname '*.vob' -o -iname '*.ogv' -o -iname '*.3gp' \
               -o -iname '*.3g2' -o -iname '*.asf' \) -print0
    )

    total=${#files[@]}
    if (( total == 0 )); then
        printf 'No supported video files were found under:\n  %s\n' "$root"
        return 0
    fi

    cleanup_orphaned_partials "$root" true
    determine_encoder "${files[0]}"

    printf '\nBatch plan\n'
    printf '%s\n' '════════════════════════════════════════════════════════════'
    printf 'Directory:          %s\n' "$root"
    printf 'Videos found:       %s\n' "$total"
    printf 'Traversal:          Recursive\n'
    printf 'Processing:         Sequential\n'
    printf 'Video codec:        %s\n' "$video_codec_label"
    if [[ "$replace_original" == true ]]; then
        printf 'Source handling:    Replace after validation\n'
    else
        printf 'Source handling:    Preserve originals\n'
    fi
    printf 'Existing outputs:   Skip safely\n'
    printf 'Per-file choices:   Automatic recommendations\n'
    printf '%s\n' '════════════════════════════════════════════════════════════'

    if [[ "$assume_yes" != true ]]; then
        ask_yes_no "Process $total video files?" y || { printf 'Cancelled.\n'; return 0; }
    fi

    child_args+=(--yes)
    child_args+=(--encoder "$video_encoder")
    [[ "$replace_original" == true ]] && child_args+=(--replace)
    [[ "$keep_larger" == true ]] && child_args+=(--keep-larger)
    [[ "$automatic_audio" != true ]] && child_args+=(--no-audio)
    [[ "$keep_larger" == true ]] && child_args+=(--keep-larger)
    [[ "$allow_scaling" != true ]] && child_args+=(--no-scale)
    [[ "$allow_denoise" != true ]] && child_args+=(--no-denoise)
    [[ "$video_preflight" != true ]] && child_args+=(--no-preflight)
    child_args+=(--quality-check "$quality_check" --quality-vmaf "$quality_vmaf_threshold")
    child_args+=(--min-savings "$min_savings_percent")

    for file in "${files[@]}"; do
        ((index++))
        filename=$(basename -- "$file")
        lower_name="${filename,,}"
        stem="$filename"
        if [[ "$filename" == *.* && "$filename" != .* ]]; then
            stem="${filename%.*}"
        fi

        if [[ "$replace_original" == true ]]; then
            if [[ "$lower_name" == *.mkv ]]; then
                target="$file"
            else
                target="$(dirname -- "$file")/${stem}.mkv"
            fi
        else
            target="$(dirname -- "$file")/${stem}-compressed-${output_suffix}.mkv"
        fi

        source_canonical=$(realpath -e -- "$file") || {
            printf '\n[%s/%s] SKIP: Could not resolve: %s\n' "$index" "$total" "$file"
            ((skipped++))
            continue
        }
        target_canonical=$(realpath -m -- "$target") || {
            printf '\n[%s/%s] SKIP: Could not resolve destination: %s\n' "$index" "$total" "$target"
            ((skipped++))
            continue
        }

        if [[ "$replace_original" == true ]]; then
            if [[ "$source_canonical" != "$target_canonical" && -e "$target" ]]; then
                printf '\n[%s/%s] SKIP: Replacement destination already exists:\n  Source: %s\n  Existing: %s\n' \
                    "$index" "$total" "$file" "$target"
                ((skipped++))
                continue
            fi
            if [[ -n "${replacement_targets[$target_canonical]:-}" && "${replacement_targets[$target_canonical]}" != "$source_canonical" ]]; then
                printf '\n[%s/%s] SKIP: Another source maps to the same replacement name:\n  %s\n' \
                    "$index" "$total" "$target"
                ((skipped++))
                continue
            fi
            replacement_targets[$target_canonical]="$source_canonical"
        elif [[ -e "$target" ]]; then
            printf '\n[%s/%s] SKIP: Output already exists:\n  %s\n' "$index" "$total" "$target"
            ((skipped++))
            continue
        fi

        printf '\n\n[%s/%s] Processing\n  %s\n' "$index" "$total" "$file"

        export _IS_CHILD_PROCESS=1
        if "${BASH:-bash}" "$script_path" "${child_args[@]}" "$file"; then
            ((success++))
        else
            rc=$?
            if (( rc == 3 )); then
                ((unchanged++))
            elif [[ ${HARDCORE_ARCHIVE_NESTED_CHILD:-0} == 1 ]]; then
                ((unchanged++))
                printf 'Nested child video item failed with exit code %s; original preserved and recursion continues.\n' "$rc" >&2
            else
                ((failed++))
                printf 'Batch item failed with exit code %s; continuing.\n' "$rc" >&2
            fi
        fi
    done

    printf '\nBatch summary\n'
    printf '%s\n' '════════════════════════════════════════════════════════════'
    printf 'Found:              %s\n' "$total"
    printf 'Completed:          %s\n' "$success"
    printf 'Unchanged:          %s\n' "$unchanged"
    printf 'Skipped:            %s\n' "$skipped"
    printf 'Failed:             %s\n' "$failed"
    printf '%s\n' '════════════════════════════════════════════════════════════'

    (( failed == 0 ))
}

if [[ "$batch_mode" == true ]]; then
    run_batch "$batch_root"
    exit $?
fi

determine_encoder "$input"

printf '\nAnalysing:\n  %s\n\n' "$input"

width=$(ffprobe -v error -select_streams V:0 -show_entries stream=width -of default=nw=1:nk=1 "$input" | head -n1)
height=$(ffprobe -v error -select_streams V:0 -show_entries stream=height -of default=nw=1:nk=1 "$input" | head -n1)
source_video_codec=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name -of default=nw=1:nk=1 "$input" | head -n1)
pixel_format=$(ffprobe -v error -select_streams V:0 -show_entries stream=pix_fmt -of default=nw=1:nk=1 "$input" | head -n1)
frame_rate=$(ffprobe -v error -select_streams V:0 -show_entries stream=avg_frame_rate -of default=nw=1:nk=1 "$input" | head -n1)
duration=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$input" | head -n1)
format_bitrate=$(ffprobe -v error -show_entries format=bit_rate -of default=nw=1:nk=1 "$input" | head -n1)
format_name=$(ffprobe -v error -show_entries format=format_long_name -of default=nw=1:nk=1 "$input" | head -n1)
color_transfer=$(ffprobe -v error -select_streams V:0 -show_entries stream=color_transfer -of default=nw=1:nk=1 "$input" | head -n1)
color_primaries=$(ffprobe -v error -select_streams V:0 -show_entries stream=color_primaries -of default=nw=1:nk=1 "$input" | head -n1)

[[ "$width" =~ ^[0-9]+$ ]] || die 'Could not determine source width.'
[[ "$height" =~ ^[0-9]+$ ]] || die 'Could not determine source height.'
original_size=$(stat -Lc '%s' -- "$input") || die 'Could not determine source size.'
video_stream_count=$(stream_count V)
all_video_stream_count=$(stream_count v)
audio_count=$(stream_count a)
subtitle_count=$(stream_count s)
attachment_count=$(stream_count t)
data_stream_count=$(stream_count d)

if (( video_stream_count < 1 )); then
    printf 'No primary video stream is available for conversion; original preserved unchanged.\n'
    exit 3
fi

hdr_detected=false
case "$color_transfer" in smpte2084|arib-std-b67) hdr_detected=true;; esac
[[ "$color_primaries" == bt2020 ]] && hdr_detected=true

bitrate_display='Unknown'
if [[ "$format_bitrate" =~ ^[0-9]+$ ]]; then
    bitrate_display=$(LC_NUMERIC=C awk -v bitrate="$format_bitrate" 'BEGIN {printf "%.2f Mbit/s", bitrate/1000000}')
fi

printf 'Source analysis\n'
printf '%s\n' '────────────────────────────────────────────────────────────'
printf 'File size:         %s\n' "$(human_size "$original_size")"
printf 'Container:         %s\n' "${format_name:-Unknown}"
printf 'Duration:          %s\n' "$(format_duration "$duration")"
printf 'Video codec:       %s\n' "${source_video_codec:-Unknown}"
printf 'Resolution:        %sx%s\n' "$width" "$height"
printf 'Pixel format:      %s\n' "${pixel_format:-Unknown}"
printf 'Frame rate:        %s\n' "${frame_rate:-Unknown}"
printf 'Total bitrate:     %s\n' "$bitrate_display"
printf 'Video streams:     %s\n' "$video_stream_count"
printf 'All video streams: %s\n' "$all_video_stream_count"
printf 'Audio streams:     %s\n' "$audio_count"
printf 'Subtitle streams:  %s\n' "$subtitle_count"
printf 'Attachments:       %s\n' "$attachment_count"
printf 'HDR detected:      %s\n' "$hdr_detected"

apply_scaling=false
output_width="$width"
output_height="$height"
scaling_reason="Keep ${width}x${height}"

if [[ "$allow_scaling" == true && "$height" -gt "$TARGET_HEIGHT" ]]; then
    proposed_width=$(calculate_scaled_width "$width" "$height")
    should_offer_scaling=false
    if (( original_size >= 2*1024*1024*1024 )); then
        should_offer_scaling=true
    elif (( original_size >= 500*1024*1024 && height > 1440 )); then
        should_offer_scaling=true
    fi

    if [[ "$should_offer_scaling" == true ]]; then
        printf '\nResolution recommendation\n'
        printf '%s\n' '────────────────────────────────────────────────────────────'
        printf 'Current:            %sx%s\n' "$width" "$height"
        printf 'Proposed:           %sx%s\n' "$proposed_width" "$TARGET_HEIGHT"
        if [[ "$assume_yes" == true ]] || ask_yes_no "Reduce ${width}x${height} to ${proposed_width}x${TARGET_HEIGHT}?" y; then
            apply_scaling=true
            output_width="$proposed_width"
            output_height="$TARGET_HEIGHT"
            scaling_reason="${width}x${height} → ${proposed_width}x${TARGET_HEIGHT}"
        fi
    fi
fi

apply_denoise=false
offer_denoise=false
denoise_reason='Disabled'
if [[ "$allow_denoise" == true ]] && has_filter hqdn3d; then
    case "$source_video_codec" in
        mpeg1video|mpeg2video|mpeg4|wmv1|wmv2) offer_denoise=true;;
    esac
    if [[ "$format_bitrate" =~ ^[0-9]+$ ]] && (( height <= 720 && format_bitrate >= 12000000 )); then
        offer_denoise=true
    fi
fi

if [[ "$offer_denoise" == true ]]; then
    printf '\nDenoising recommendation\n'
    printf '%s\n' '────────────────────────────────────────────────────────────'
    if [[ "$assume_yes" == true ]] || ask_yes_no 'Apply mild denoising?' n; then
        apply_denoise=true
        denoise_reason='Mild HQDN3D'
    fi
fi

audio_args=()
audio_plan=()
audio_stream_number=0
estimated_output_audio_bps=0
opus_available=false
has_encoder libopus && opus_available=true

if (( audio_count > 0 )); then
    while IFS='|' read -r codec channels bitrate; do
        [[ -n "$codec" ]] || continue
        [[ "$channels" =~ ^[0-9]+$ ]] || channels=2
        [[ "$bitrate" =~ ^[0-9]+$ ]] || bitrate=0
        convert_audio=false
        case "$channels" in
            1) target_bitrate='80k'; target_bps=80000;;
            2) target_bitrate='128k'; target_bps=128000;;
            3|4) target_bitrate='192k'; target_bps=192000;;
            5|6) target_bitrate='256k'; target_bps=256000;;
            *) target_bitrate='320k'; target_bps=320000;;
        esac

        if [[ "$automatic_audio" == true && "$opus_available" == true ]]; then
            case "$codec" in
                opus) convert_audio=false;;
                pcm_*|flac|truehd|dts) convert_audio=true;;
                aac) (( bitrate == 0 || bitrate > target_bps*5/4 )) && convert_audio=true;;
                *) (( bitrate > target_bps*3/2 )) && convert_audio=true;;
            esac
        fi

        if [[ "$convert_audio" == true ]]; then
            audio_args+=("-c:a:${audio_stream_number}" libopus "-b:a:${audio_stream_number}" "$target_bitrate" "-vbr:a:${audio_stream_number}" on)
            audio_plan+=("Track $((audio_stream_number+1)): ${codec} → Opus ${target_bitrate}")
            estimated_output_audio_bps=$((estimated_output_audio_bps + target_bps))
        else
            audio_args+=("-c:a:${audio_stream_number}" copy)
            audio_plan+=("Track $((audio_stream_number+1)): copy ${codec}")
            if (( bitrate > 0 )); then
                estimated_output_audio_bps=$((estimated_output_audio_bps + bitrate))
            else
                estimated_output_audio_bps=$((estimated_output_audio_bps + 192000))
            fi
        fi
        ((audio_stream_number++))
    done < <(ffprobe -v error -select_streams a -show_entries stream=codec_name,channels,bit_rate -of compact=p=0:nk=1 "$input")
fi

input_dir=$(dirname -- "$input")
input_filename=$(basename -- "$input")
input_stem="$input_filename"
if [[ "$input_filename" == *.* && "$input_filename" != .* ]]; then
    input_stem="${input_filename%.*}"
fi

if [[ "$replace_original" == true ]]; then
    if [[ "${input_filename,,}" == *.mkv ]]; then output="$input"; else output="${input_dir}/${input_stem}.mkv"; fi
elif [[ -n "$requested_output" ]]; then
    output="$requested_output"
else
    output="${input_dir}/${input_stem}-compressed-${output_suffix}.mkv"
fi

input_canonical=$(realpath -e -- "$input") || die 'Could not resolve the input path.'
output_canonical=$(realpath -m -- "$output") || die 'Could not resolve the output path.'
same_output_as_input=false
[[ "$input_canonical" == "$output_canonical" ]] && same_output_as_input=true

output_dir=$(dirname -- "$output")
output_name=$(basename -- "$output")
mkdir -p -- "$output_dir" || die "Could not create output directory: $output_dir"

cleanup_orphaned_partials "$output_dir" false
temporary="${output_dir}/.${output_name}.partial.$$.mkv"

# --- Advanced VA-API Hybrid Filtering ---
# Software processing must happen before uploading to the GPU space.
# Scaling on VA-API handles the format conversions seamlessly.
video_filters=()
if [[ "$video_encoder" == *_vaapi ]]; then
    [[ "$apply_denoise" == true ]] && video_filters+=("$DENOISE_FILTER")
    if [[ "$apply_scaling" == true ]]; then
        video_filters+=("scale=-2:${TARGET_HEIGHT}:flags=lanczos")
    fi
    video_filters+=("format=nv12" "hwupload")
else
    # Regular software/NVENC filtering path
    [[ "$apply_denoise" == true ]] && video_filters+=("$DENOISE_FILTER")
    [[ "$apply_scaling" == true ]] && video_filters+=("scale=-2:${TARGET_HEIGHT}:flags=lanczos")
fi

filter_chain=''
((${#video_filters[@]} > 0)) && filter_chain=$(IFS=,; printf '%s' "${video_filters[*]}")

MEASURED_QUALITY_KIND=''
MEASURED_QUALITY_SCORE=''
QUALITY_WORKER_THREADS=''
QUALITY_VMAF_AVAILABLE=''

quality_worker_threads() {
    local requested=${HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS:-auto} available
    if [[ $requested != auto && ! $requested =~ ^([1-9]|[1-5][0-9]|6[0-4])$ ]]; then
        printf 'Error: VIDEO_QUALITY_THREADS must be auto or an integer from 1 to 64.\n' >&2
        return 1
    fi
    available=$(nproc 2>/dev/null || getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)
    [[ $available =~ ^[1-9][0-9]{0,5}$ ]] || available=1
    if [[ $requested == auto ]]; then
        requested=$available
        (( requested > 8 )) && requested=8
    fi
    (( requested > available )) && requested=$available
    printf '%s' "$requested"
}

measure_preflight_quality() {
    local start=$1 length=$2 encoded=$3 width height dimensions log_file score started
    MEASURED_QUALITY_KIND=''
    MEASURED_QUALITY_SCORE=''
    [[ $quality_check != off ]] || return 1

    dimensions=$(ffprobe -v error -select_streams V:0 -show_entries stream=width,height \
        -of csv=p=0:s=x "$encoded" 2>/dev/null | head -n1)
    IFS=x read -r width height <<< "$dimensions"
    [[ $width =~ ^[0-9]+$ && $height =~ ^[0-9]+$ ]] || return 1

    if [[ -z $QUALITY_WORKER_THREADS ]]; then
        QUALITY_WORKER_THREADS=$(quality_worker_threads) || return 1
    fi
    if [[ -z $QUALITY_VMAF_AVAILABLE ]]; then
        if has_filter libvmaf; then QUALITY_VMAF_AVAILABLE=true; else QUALITY_VMAF_AVAILABLE=false; fi
    fi
    if [[ $QUALITY_VMAF_AVAILABLE == true ]]; then
        log_file="${encoded}.vmaf.json"
        preflight_files+=("$log_file")
        # Drop stale scores before a retry; only this FFmpeg invocation can pass.
        rm -f -- "$log_file"
        printf '\nVMAF scoring: %sx%s, %s CPU worker(s), every sample frame...\n' \
            "$width" "$height" "$QUALITY_WORKER_THREADS"
        started=$SECONDS
        # Matroska rounds sample timestamps to milliseconds. Framesync's
        # default floor matching can then compare a frame to its predecessor
        # in the MP4 reference. Nearest timestamp matching keeps frame content
        # aligned without discarding timestamps or changing the frame rate.
        if ffmpeg -hide_banner -v error -nostdin \
            -ss "$start" -t "$length" -i "$input" -i "$encoded" \
            -filter_complex "[0:v:0]settb=AVTB,setpts=PTS-STARTPTS,scale=${width}:${height}:flags=lanczos:out_range=tv,format=yuv420p[ref];[1:v:0]settb=AVTB,setpts=PTS-STARTPTS,scale=${width}:${height}:flags=bilinear:out_range=tv,format=yuv420p[dist];[dist][ref]libvmaf=log_fmt=json:log_path=${log_file}:n_threads=${QUALITY_WORKER_THREADS}:n_subsample=1:ts_sync_mode=nearest" \
            -an -f null - >/dev/null 2>&1; then
            printf 'VMAF scoring finished in %ss.\n' "$((SECONDS - started))"
            score=$(python3 - "$log_file" <<'PYVMAF'
import json, math, sys
try:
    with open(sys.argv[1], 'r', encoding='utf-8') as handle:
        value = float(json.load(handle)['pooled_metrics']['vmaf']['mean'])
    if math.isfinite(value) and 0.0 <= value <= 100.0:
        print(f'{value:.6f}')
except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError):
    pass
PYVMAF
)
            if [[ $score =~ ^[0-9]+([.][0-9]+)?$ ]]; then
                MEASURED_QUALITY_KIND=VMAF
                MEASURED_QUALITY_SCORE=$score
                return 0
            fi
        else
            printf 'VMAF scoring failed after %ss.\n' "$((SECONDS - started))"
        fi
    fi

    # Strict quality policy: VMAF failure is a preflight failure; SSIM is not a fallback.
    return 1
}


HARDCORE_AUTO_CODEC_MODE=${HARDCORE_ARCHIVE_VIDEO_CODEC_AUTO:-0}
HARDCORE_AUTO_AV1_ENCODER=${HARDCORE_ARCHIVE_AUTO_AV1_ENCODER:-}
HARDCORE_AUTO_HEVC_ENCODER=${HARDCORE_ARCHIVE_AUTO_HEVC_ENCODER:-}
CAL_MIN_VMAF=''
CAL_AVG_VIDEO_BPS=''
CAL_WORST_POSITION=''
CAL_BEST_QUALITY=''
CAL_PREDICTED_SAVINGS=''
CAL_REQUIRED_SAVINGS=''
CAL_REASON=''
CAL_QUALITY_LABEL=''
CAL_SELECTED_VALIDATED=false
CAL_CACHE_FILE=''
CAL_FILE_CACHE_FILE=''

# Cache entries are hints, never evidence that a different file meets VMAF.
# Version this key when sampling, VMAF normalization or encoder policy changes.
calibration_cache_profile() {
    # Camera average rates vary with clip duration (e.g. 59.9386 vs 60.0053).
    # Group nearby nominal rates, keeping average and declared rates separate
    # and retaining every other profile field. Actual encode timing is untouched.
    python3 - "$1" <<'PYCALPROFILE'
from fractions import Fraction
import re
import sys

fields = []
try:
    for field in sys.argv[1].split("|"):
        name, separator, value = field.partition("=")
        if name in ("avg_frame_rate", "r_frame_rate"):
            if not separator or not re.fullmatch(r"[0-9]{1,12}(?:/[0-9]{1,12})?", value):
                raise ValueError("invalid frame rate")
            rate = Fraction(value)
            if not 0 < rate <= 1000:
                raise ValueError("invalid frame rate")
            nominal = (2 * rate.numerator + rate.denominator) // (2 * rate.denominator)
            if nominal and abs(rate - nominal) <= Fraction(nominal, 100):
                value = f"nominal-{nominal}"
            else:
                value = f"exact-{rate}"
            field = f"{name}={value}"
        fields.append(field)
except (ValueError, ZeroDivisionError):
    # Bad probe data disables reuse, not the current file's full calibration.
    sys.exit(1)
print("|".join(fields))
PYCALPROFILE
}

calibration_cache_prepare() {
    local codec=$1 encoder=$2 directory profile raw_profile ffmpeg_build key identity file_key
    local CAL_FILTER_CHAIN=''
    CAL_CACHE_FILE=''
    CAL_FILE_CACHE_FILE=''
    [[ ${HARDCORE_ARCHIVE_CALIBRATION_CACHE:-true} == true ]] || return 0
    directory=${HARDCORE_ARCHIVE_CALIBRATION_CACHE_DIR:-}
    [[ -n $directory ]] || return 0
    profile=$(ffprobe -v error -select_streams V:0 -show_entries \
        stream=codec_name,profile,width,height,pix_fmt,bits_per_raw_sample,avg_frame_rate,r_frame_rate,field_order,sample_aspect_ratio,color_range,color_space,color_transfer,color_primaries \
        -of compact=p=0:nk=0 "$input" 2>/dev/null) || return 0
    [[ -n $profile ]] || return 0
    raw_profile=$profile
    profile=$(calibration_cache_profile "$profile") || return 0
    ffmpeg_build=$(ffmpeg -version 2>/dev/null) || return 0
    [[ -n $ffmpeg_build ]] || return 0
    calibration_build_filter_chain "$encoder"
    key=$(printf '%s\0' 'calibration-v3-nominal-fps-nearest-timestamps-center-validation' \
        "$codec" "$encoder" "${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" \
        "$profile" "$ffmpeg_build" "$CAL_FILTER_CHAIN" \
        "$quality_vmaf_threshold" "$(hardcore_video_accel_signature "$encoder")" | sha256sum | awk '{print $1}') || return 0
    [[ $key =~ ^[a-f0-9]{64}$ ]] || return 0
    (umask 077; mkdir -p -- "$directory") 2>/dev/null || return 0
    [[ -d $directory && ! -L $directory && -O $directory && -w $directory ]] || return 0
    CAL_CACHE_FILE="$directory/$key"
    identity=$(hardcore_calibration_identity "$input" 2>/dev/null) || return 0
    [[ $identity =~ ^[a-f0-9]{64}$ ]] || return 0
    file_key=$(printf '%s\0' 'per-video-calibration-v1' "$key" "$raw_profile" "$identity" |
        sha256sum | awk '{print $1}') || return 0
    [[ $file_key =~ ^[a-f0-9]{64}$ ]] || return 0
    CAL_FILE_CACHE_FILE="$directory/video-$file_key"
}

calibration_cache_read() {
    local low=$1 high=$2 version quality timestamp extra now size
    local CAL_CACHE_FILE=${3-$CAL_CACHE_FILE}
    [[ -n $CAL_CACHE_FILE && -f $CAL_CACHE_FILE && ! -L $CAL_CACHE_FILE && -O $CAL_CACHE_FILE ]] || return 1
    size=$(stat -c '%s' -- "$CAL_CACHE_FILE" 2>/dev/null) || return 1
    (( size > 0 && size <= 128 )) || return 1
    IFS=$'\t' read -r version quality timestamp extra < "$CAL_CACHE_FILE" || return 1
    [[ $version == v1 && -z $extra && $quality =~ ^[1-9][0-9]{0,2}$ && $timestamp =~ ^[1-9][0-9]{0,10}$ ]] || return 1
    (( quality >= low && quality <= high )) || return 1
    now=$(date +%s) || return 1
    # Expire after 30 days; future timestamps and malformed entries are misses.
    (( timestamp <= now && now - timestamp <= 2592000 )) || return 1
    printf '%s' "$quality"
}

calibration_cache_write() {
    local quality=$1 temporary_cache timestamp
    local CAL_CACHE_FILE=${2-$CAL_CACHE_FILE}
    [[ -n $CAL_CACHE_FILE ]] || return 0
    timestamp=$(date +%s) || return 0
    temporary_cache=$(mktemp "${CAL_CACHE_FILE}.XXXXXX" 2>/dev/null) || return 0
    if ! printf 'v1\t%s\t%s\n' "$quality" "$timestamp" > "$temporary_cache" || \
       ! mv -fT -- "$temporary_cache" "$CAL_CACHE_FILE" 2>/dev/null; then
        rm -f -- "$temporary_cache"
    fi
    return 0
}

# Only v2 per-video records certify that a boundary was searched for this file.
# Legacy v1 records remain useful starting hints, including pinned group hits.
calibration_video_cache_read() {
    local low=$1 high=$2 version kind quality timestamp position bps extra size now
    [[ -n $CAL_FILE_CACHE_FILE && -f $CAL_FILE_CACHE_FILE && ! -L $CAL_FILE_CACHE_FILE && -O $CAL_FILE_CACHE_FILE ]] || return 1
    size=$(stat -c '%s' -- "$CAL_FILE_CACHE_FILE" 2>/dev/null) || return 1
    (( size > 0 && size <= 128 )) || return 1
    IFS=$'\t' read -r version kind quality timestamp position bps extra < "$CAL_FILE_CACHE_FILE" || return 1
    [[ $version == v2 && -z $extra && $kind =~ ^(boundary|rejected)$ &&
       $quality =~ ^[1-9][0-9]{0,2}$ && $timestamp =~ ^[1-9][0-9]{0,10}$ &&
       $position =~ ^0\.(10|50|90)$ && $bps =~ ^[1-9][0-9]{0,14}$ ]] || return 1
    (( quality >= low && quality <= high )) || return 1
    # Rejection must have been witnessed at the encoder's highest quality.
    [[ $kind != rejected ]] || (( quality == low )) || return 1
    now=$(date +%s) || return 1
    (( timestamp <= now && now - timestamp <= 2592000 )) || return 1
    printf '%s\t%s\t%s\t%s' "$kind" "$quality" "$position" "$bps"
}

calibration_video_cache_write() {
    local kind=$1 quality=$2 position=$3 bps=$4 temporary_cache timestamp
    [[ -n $CAL_FILE_CACHE_FILE ]] || return 0
    timestamp=$(date +%s) || return 0
    temporary_cache=$(mktemp "${CAL_FILE_CACHE_FILE}.XXXXXX" 2>/dev/null) || return 0
    if ! printf 'v2\t%s\t%s\t%s\t%s\t%s\n' "$kind" "$quality" "$timestamp" "$position" "$bps" > "$temporary_cache" || \
       ! mv -fT -- "$temporary_cache" "$CAL_FILE_CACHE_FILE" 2>/dev/null; then
        rm -f -- "$temporary_cache"
    fi
    return 0
}

calibration_predict_savings() {
    local video_bps=$1 source_bps=$2 predicted_bps
    predicted_bps=$(LC_NUMERIC=C awk -v video="$video_bps" -v audio="$estimated_output_audio_bps" \
        'BEGIN {printf "%.0f",(video+audio)*1.015}')
    CAL_PREDICTED_SAVINGS=$(LC_NUMERIC=C awk -v source="$source_bps" -v output="$predicted_bps" \
        'BEGIN {if(source<=0){print 0; exit} printf "%.2f",(source-output)*100/source}')
}

calibration_score_passes() {
    LC_NUMERIC=C awk -v v="$CAL_MIN_VMAF" -v threshold="$quality_vmaf_threshold" \
        'BEGIN {exit !(v>=threshold)}'
}

calibration_savings_pass() {
    LC_NUMERIC=C awk -v saving="$CAL_PREDICTED_SAVINGS" -v required="$CAL_REQUIRED_SAVINGS" \
        'BEGIN {exit !(saving>=required)}'
}

# Heuristic: three failed trials spanning at least four quality steps, with
# <=0.25 total VMAF variation and still >=5 points below the requested floor.
# It only rejects a candidate (preserving the original); it never accepts one.
calibration_has_plateau() {
    [[ ${HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT:-true} == true ]] || return 1
    LC_NUMERIC=C awk -v q1="$1" -v q2="$2" -v q3="$3" \
        -v v1="$4" -v v2="$5" -v v3="$6" -v target="$quality_vmaf_threshold" 'BEGIN {
        maximum=v1; if(v2>maximum)maximum=v2; if(v3>maximum)maximum=v3;
        minimum=v1; if(v2<minimum)minimum=v2; if(v3<minimum)minimum=v3;
        exit !(q1>q2 && q2>q3 && q1-q3>=4 && maximum<=target-5 && maximum-minimum<=0.25)
    }'
}

calibration_encoder_supported() {
    case "$1" in
        av1_vaapi|hevc_vaapi|av1_nvenc|hevc_nvenc|av1_qsv|hevc_qsv) return 0 ;;
        *) return 1 ;;
    esac
}

calibration_quality_range() {
    case "$1" in
        av1_vaapi) printf '1 255 q_idx' ;;
        hevc_vaapi) printf '1 51 QP' ;;
        av1_nvenc|hevc_nvenc) printf '1 51 CQ' ;;
        av1_qsv|hevc_qsv) printf '1 51 ICQ' ;;
        *) return 1 ;;
    esac
}

calibration_apply_quality() {
    local encoder=$1 quality=$2
    case "$encoder" in
        av1_vaapi|hevc_vaapi)
            encoder_args=("-rc_mode" "CQP" "-global_quality:v" "$quality") ;;
        av1_nvenc|hevc_nvenc)
            encoder_args=("-cq:v" "$quality" "-preset:v" "p4") ;;
        av1_qsv|hevc_qsv)
            encoder_args=("-global_quality:v" "$quality" "-preset:v" "balanced") ;;
        *) return 1 ;;
    esac
}

calibration_build_filter_chain() {
    hardcore_video_accel_filter "$1"
}

calibration_candidate_command() {
    local encoder=$1 quality=$2 start=$3 sample_length=$4 sample_file=$5
    local CAL_FILTER_CHAIN=''
    calibration_build_filter_chain "$encoder"
    hardcore_video_accel_arguments "$encoder"
    CAL_COMMAND=(ffmpeg -hide_banner -v error -nostdin -y)
    CAL_COMMAND+=("${HARDCORE_VIDEO_DEVICE_ARGS[@]}")
    CAL_COMMAND+=(
        -ss "$start" "${HARDCORE_VIDEO_INPUT_ARGS[@]}" -i "$input" -t "$sample_length"
        -map '0:V:0' -an -sn -dn
        -c:v "$encoder"
    )
    case "$encoder" in
        av1_vaapi|hevc_vaapi) CAL_COMMAND+=(-rc_mode CQP -global_quality:v "$quality") ;;
        av1_nvenc|hevc_nvenc) CAL_COMMAND+=(-cq:v "$quality" -preset:v p4) ;;
        av1_qsv|hevc_qsv) CAL_COMMAND+=(-global_quality:v "$quality" -preset:v balanced) ;;
        *) return 1 ;;
    esac
    [[ -n "$CAL_FILTER_CHAIN" ]] && CAL_COMMAND+=(-vf "$CAL_FILTER_CHAIN")
    CAL_COMMAND+=("${HARDCORE_VIDEO_OUTPUT_ARGS[@]}")
    CAL_COMMAND+=(-f matroska "$sample_file")
}

evaluate_hardware_quality() {
    local codec=$1 encoder=$2 quality=$3 mode=${4:-full}
    local sample_length=3
    local -a positions=(0.10 0.50 0.90)
    local position start sample_file actual_length sample_size sample_bps encode_started
    local total_bps=0 sample_count=0 minimum_vmaf=101
    local -a CAL_COMMAND=()
    CAL_MIN_VMAF=''
    CAL_AVG_VIDEO_BPS=''
    CAL_WORST_POSITION=''

    if [[ $mode == one-shot ]]; then
        [[ ${5:-0.50} =~ ^0\.(10|50|90)$ ]] || return 1
        positions=("${5:-0.50}")
    fi

    if LC_NUMERIC=C awk -v d="$duration" 'BEGIN {exit !(d<9)}'; then
        positions=(0.50)
        sample_length=$(LC_NUMERIC=C awk -v d="$duration" 'BEGIN {
            v=d; if(v>3)v=3; if(v<1)v=1; printf "%.3f",v
        }')
    fi

    for position in "${positions[@]}"; do
        start=$(LC_NUMERIC=C awk -v d="$duration" -v l="$sample_length" -v p="$position" 'BEGIN {
            room=d-l; if(room<0)room=0; s=room*p; if(s<0)s=0; printf "%.3f",s
        }')
        sample_file="${output_dir}/.${output_name}.calibrate-${codec}-${quality}.$$.${sample_count}.mkv"
        preflight_files+=("$sample_file" "${sample_file}.vmaf.json")
        rm -f -- "$sample_file" "${sample_file}.vmaf.json"

        calibration_candidate_command "$encoder" "$quality" "$start" "$sample_length" "$sample_file" || return 1
        printf 'Encoding calibration sample %s/%s at %ss (%s %s)...\n' \
            "$((sample_count + 1))" "${#positions[@]}" "$start" "$encoder" "$quality"
        encode_started=$SECONDS
        if ! "${CAL_COMMAND[@]}"; then
            printf '%s via %s quality %s: sample encode failed.\n' "${codec^^}" "$encoder" "$quality"
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi
        printf 'Sample encoding finished in %ss.\n' "$((SECONDS - encode_started))"

        actual_length=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 "$sample_file" 2>/dev/null | head -n1)
        sample_size=$(stat -c '%s' -- "$sample_file" 2>/dev/null || printf 0)
        if [[ ! $actual_length =~ ^[0-9]+([.][0-9]+)?$ ]] || (( sample_size <= 0 )) || \
           ! LC_NUMERIC=C awk -v d="$actual_length" 'BEGIN {exit !(d>0)}'; then
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi
        sample_bps=$(LC_NUMERIC=C awk -v bytes="$sample_size" -v seconds="$actual_length" \
            'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
        (( sample_bps > 0 )) || { rm -f -- "$sample_file" "${sample_file}.vmaf.json"; return 1; }
        total_bps=$((total_bps + sample_bps))
        sample_count=$((sample_count + 1))

        if ! measure_preflight_quality "$start" "$actual_length" "$sample_file" || \
           [[ $MEASURED_QUALITY_KIND != VMAF || ! $MEASURED_QUALITY_SCORE =~ ^[0-9]+([.][0-9]+)?$ ]] || \
           ! LC_NUMERIC=C awk -v v="$MEASURED_QUALITY_SCORE" 'BEGIN {exit !(v>=0 && v<=100)}'; then
            rm -f -- "$sample_file" "${sample_file}.vmaf.json"
            return 1
        fi
        if LC_NUMERIC=C awk -v a="$MEASURED_QUALITY_SCORE" -v b="$minimum_vmaf" \
            'BEGIN {exit !(a<b)}'; then
            minimum_vmaf=$MEASURED_QUALITY_SCORE
            CAL_WORST_POSITION=$position
        fi
        rm -f -- "$sample_file" "${sample_file}.vmaf.json"
    done

    (( sample_count > 0 )) || return 1
    CAL_MIN_VMAF=$minimum_vmaf
    CAL_AVG_VIDEO_BPS=$((total_bps / sample_count))
    return 0
}

calibrate_hardware_candidate() {
    hardcore_timed video_calibration calibrate_hardware_candidate_accelerated "$@"
}

calibrate_hardware_candidate_accelerated() {
    local codec=$1 encoder=$2 rc=1 mode start_mode selection kind record range low high label
    local best='' best_bps=0 all_rejected=true cacheable=true fastest='' fastest_ns=0
    local CAL_PIPELINE_HINT='' CAL_ENDPOINT_HINT=''
    local -a modes=() finalists=()
    local -A results=() qualities=()
    hardcore_video_accel_prepare "$encoder"
    start_mode=${HARDCORE_VIDEO_START_MODES[$encoder]:-cpu}
    if [[ $start_mode == cpu ]]; then
        HARDCORE_VIDEO_PIPELINES[$encoder]=cpu
        calibrate_hardware_candidate_impl "$codec" "$encoder"
        return $?
    fi
    case "$start_mode" in
        gpu) modes=(gpu hybrid cpu) ;;
        hybrid) modes=(hybrid cpu) ;;
    esac
    hardcore_video_selection_prepare "$codec" "$encoder" "$start_mode"
    if selection=$(hardcore_video_selection_read); then
        IFS=$'\t' read -r kind mode <<< "$selection"
        if [[ $start_mode == gpu || $mode != gpu ]]; then
            HARDCORE_VIDEO_PIPELINES[$encoder]=$mode
            calibration_cache_prepare "$codec" "$encoder"
            range=$(calibration_quality_range "$encoder") || return 4
            IFS=' ' read -r low high label <<< "$range"
            # A routing record alone never certifies a quality boundary.
            if record=$(calibration_video_cache_read "$low" "$high") && [[ $record == "$kind"$'\t'* ]]; then
                printf 'Reusing per-video preprocessing decision: %s (%s); validating its quality record.\n' "$mode" "$kind"
                if calibrate_hardware_candidate_impl "$codec" "$encoder"; then rc=0; else rc=$?; fi
                if [[ $kind == boundary && $rc == 0 && $CAL_REASON == cache-validated ]] ||
                   [[ $kind == rejected && $rc == 2 && $CAL_REASON == cached-quality-rejection-confirmed ]]; then
                    hardcore_video_accel_describe "$encoder"
                    return "$rc"
                fi
            fi
        fi
        printf 'Preprocessing decision needs fresh comparison; reopening available paths.\n'
        hardcore_video_selection_forget
    fi

    for mode in "${modes[@]}"; do
        HARDCORE_VIDEO_PIPELINES[$encoder]=$mode
        hardcore_video_accel_describe "$encoder"
        if [[ $mode == hybrid && $start_mode == gpu && $apply_scaling == true ]]; then
            printf 'Comparing GPU scaling against CPU Lanczos for quality and compression.\n'
        fi
        if calibrate_hardware_candidate_impl "$codec" "$encoder"; then rc=0; else rc=$?; fi
        if (( rc == 0 )); then
            all_rejected=false
            qualities[$mode]=$CAL_BEST_QUALITY
            results[$mode]="$CAL_BEST_QUALITY|$CAL_PREDICTED_SAVINGS|$CAL_REQUIRED_SAVINGS|$CAL_REASON|$CAL_QUALITY_LABEL|$CAL_MIN_VMAF|$CAL_AVG_VIDEO_BPS|$CAL_WORST_POSITION|$CAL_RESULT_VIDEO_BPS"
            if [[ -z $best ]] || (( CAL_RESULT_VIDEO_BPS < best_bps )); then
                best=$mode; best_bps=$CAL_RESULT_VIDEO_BPS; finalists=("$mode")
            elif (( CAL_RESULT_VIDEO_BPS == best_bps )); then
                finalists+=("$mode")
            fi
            CAL_PIPELINE_HINT=$CAL_BEST_QUALITY
            CAL_ENDPOINT_HINT=''
            # No resizing/denoising: preserve the direct GPU path. Comparisons
            # are needed when software filters introduce a transfer round trip.
            [[ $mode != gpu || $apply_scaling == true ]] || break
        else
            (( rc == 2 )) || all_rejected=false
            (( rc == 1 )) && cacheable=false
            CAL_PIPELINE_HINT=''
            CAL_ENDPOINT_HINT=''
            # Probe an alternative at the known failing position/endpoint before
            # spending another binary search on a pipeline-level quality limit.
            (( rc != 2 )) || CAL_ENDPOINT_HINT=$CAL_WORST_POSITION
            [[ $mode == cpu ]] || printf 'Preprocessing attempt failed; checking the next compatible path.\n'
        fi
    done
    if [[ -z $best ]]; then
        [[ $all_rejected != true ]] || hardcore_video_selection_write rejected cpu
        return "$rc"
    fi

    if (( ${#finalists[@]} > 1 )); then
        printf 'Accepted paths predict identical video bitrate; comparing bounded encode speed.\n'
        for mode in "${finalists[@]}"; do
            HARDCORE_VIDEO_PIPELINES[$encoder]=$mode
            if hardcore_video_speed_probe "$codec" "$encoder" "${qualities[$mode]}"; then
                if [[ -z $fastest ]] || (( HARDCORE_VIDEO_PROBE_NS < fastest_ns )); then
                    fastest=$mode; fastest_ns=$HARDCORE_VIDEO_PROBE_NS
                fi
            else
                cacheable=false
                printf 'Speed probe failed for %s; not caching this selection.\n' "$mode"
            fi
        done
        [[ -z $fastest ]] || best=$fastest
    fi
    HARDCORE_VIDEO_PIPELINES[$encoder]=$best
    IFS='|' read -r CAL_BEST_QUALITY CAL_PREDICTED_SAVINGS CAL_REQUIRED_SAVINGS CAL_REASON CAL_QUALITY_LABEL \
        CAL_MIN_VMAF CAL_AVG_VIDEO_BPS CAL_WORST_POSITION CAL_RESULT_VIDEO_BPS <<< "${results[$best]}"
    printf 'Selected preprocessing: %s; best accepted compression, speed used only to break equal-bitrate ties.\n' "$best"
    [[ $cacheable != true ]] || hardcore_video_selection_write boundary "$best"
    return 0
}

calibrate_hardware_candidate_impl() {
    local codec=$1 encoder=$2
    local range low high endpoint quality_label mid best_quality=0 best_video_bps=0 best_position=''
    local source_average_bps required_savings cached_quality='' cache_source=group count next_quality=''
    local record='' cache_kind cached_position cached_bps plateau_checked=false
    local -a failed_qualities=() failed_scores=()

    CAL_BEST_QUALITY=''
    CAL_PREDICTED_SAVINGS=''
    CAL_REQUIRED_SAVINGS=''
    CAL_REASON=''
    CAL_QUALITY_LABEL=''
    CAL_RESULT_VIDEO_BPS=''

    calibration_encoder_supported "$encoder" || {
        CAL_REASON='encoder-family-not-calibrated'
        return 4
    }
    range=$(calibration_quality_range "$encoder") || return 4
    IFS=' ' read -r low high quality_label <<< "$range"
    endpoint=$low
    CAL_QUALITY_LABEL=$quality_label

    source_average_bps=$(LC_NUMERIC=C awk -v bytes="$original_size" -v seconds="$duration" \
        'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
    [[ $source_average_bps =~ ^[0-9]+$ ]] && (( source_average_bps > 0 )) || {
        CAL_REASON='source-bitrate-unavailable'; return 1;
    }

    required_savings="$min_savings_percent"
    if [[ "$source_video_codec" == "$codec" && "$apply_scaling" != true && "$apply_denoise" != true ]]; then
        required_savings=$(LC_NUMERIC=C awk -v minimum="$min_savings_percent" 'BEGIN {
            candidate=minimum+5; if(candidate<10) candidate=10; printf "%.3f",candidate
        }')
    fi
    CAL_REQUIRED_SAVINGS=$required_savings

    printf '\n%s hardware quality calibration\n' "${codec^^}"
    printf '%s\n' '────────────────────────────────────────────────────────────'
    printf 'Encoder: %s | searching %s %s..%s for worst-sample VMAF >= %s.\n' \
        "$encoder" "$quality_label" "$low" "$high" "$quality_vmaf_threshold"

    calibration_cache_prepare "$codec" "$encoder"
    record=$(calibration_video_cache_read "$low" "$high") || record=''
    if [[ -z $record && ${CAL_ENDPOINT_HINT:-} =~ ^0\.(10|50|90)$ ]]; then
        printf 'Another preprocessing path failed quality; testing this path at its highest-quality endpoint first.\n'
        if ! evaluate_hardware_quality "$codec" "$encoder" "$endpoint" one-shot "$CAL_ENDPOINT_HINT"; then
            CAL_REASON="sample-probe-failed-at-${endpoint}"
            return 1
        fi
        if ! calibration_score_passes; then
            CAL_REASON='quality-endpoint-below-floor'
            calibration_video_cache_write rejected "$endpoint" "$CAL_WORST_POSITION" "$CAL_AVG_VIDEO_BPS"
            return 2
        fi
        printf 'Alternative endpoint passes; searching its compression boundary.\n'
    fi
    if [[ -n $record ]]; then
        IFS=$'\t' read -r cache_kind cached_quality cached_position cached_bps <<< "$record"
        printf 'Calibration cache source: video (%s).\n' "$cache_kind"
        printf 'Cached %s %s: validating one 3s segment at the previously worst position %s.\n' \
            "$quality_label" "$cached_quality" "$cached_position"
        if evaluate_hardware_quality "$codec" "$encoder" "$cached_quality" one-shot "$cached_position"; then
            if [[ $cache_kind == rejected ]] && ! calibration_score_passes; then
                CAL_REASON='cached-quality-rejection-confirmed'
                printf 'Highest-quality setting still fails VMAF (%s < %s); skipping repeated codec search.\n' \
                    "$CAL_MIN_VMAF" "$quality_vmaf_threshold"
                calibration_video_cache_write rejected "$cached_quality" "$CAL_WORST_POSITION" "$CAL_AVG_VIDEO_BPS"
                return 2
            fi
            if [[ $cache_kind == boundary ]] && calibration_score_passes; then
                calibration_predict_savings "$CAL_AVG_VIDEO_BPS" "$source_average_bps"
                if calibration_savings_pass; then
                    # Keep the three-segment bitrate estimate for fair codec
                    # competition; one difficult scene is not representative.
                    calibration_predict_savings "$cached_bps" "$source_average_bps"
                    if calibration_savings_pass; then
                        CAL_BEST_QUALITY=$cached_quality
                        CAL_RESULT_VIDEO_BPS=$cached_bps
                        CAL_REASON='cache-validated'
                        printf 'Cached setting passed: VMAF %s >= %s; predicted saving %s%% (required %s%%).\n' \
                            "$CAL_MIN_VMAF" "$quality_vmaf_threshold" "$CAL_PREDICTED_SAVINGS" "$required_savings"
                        calibration_video_cache_write boundary "$cached_quality" "$cached_position" "$cached_bps"
                        return 0
                    fi
                fi
            fi
        fi
        printf 'Cached result needs a fresh search; running full calibration.\n'
        CAL_PREDICTED_SAVINGS=''
    else
        if cached_quality=$(calibration_cache_read "$low" "$high" "$CAL_FILE_CACHE_FILE"); then
            cache_source=legacy-video
        else
            cached_quality=$(calibration_cache_read "$low" "$high") || cached_quality=''
        fi
        if [[ -z $cached_quality && ${CAL_PIPELINE_HINT:-} =~ ^[1-9][0-9]{0,2}$ ]] &&
           (( CAL_PIPELINE_HINT >= low && CAL_PIPELINE_HINT <= high )); then
            cached_quality=$CAL_PIPELINE_HINT
            cache_source=other-pipeline
        fi
        if [[ -n $cached_quality ]]; then
            printf 'Calibration cache source: %s.\n' "$cache_source"
            printf 'Using cached %s %s as a search hint; checking all segments and seeking the compression boundary.\n' \
                "$quality_label" "$cached_quality"
            if evaluate_hardware_quality "$codec" "$encoder" "$cached_quality"; then
                if calibration_score_passes; then
                    best_quality=$cached_quality
                    best_video_bps=$CAL_AVG_VIDEO_BPS
                    best_position=$CAL_WORST_POSITION
                    low=$((cached_quality + 1))
                    # Usually the group hint is already near the boundary.
                    # Check its neighbor before bisecting the remaining range.
                    next_quality=$low
                else
                    high=$((cached_quality - 1))
                fi
            else
                printf 'Cached hint measurement unavailable; running full calibration.\n'
            fi
        fi
    fi

    while (( low <= high )); do
        if [[ -n $next_quality ]]; then mid=$next_quality; next_quality=''
        else mid=$(((low + high) / 2)); fi
        if ! evaluate_hardware_quality "$codec" "$encoder" "$mid"; then
            CAL_REASON="sample-probe-failed-at-${mid}"
            return 1
        fi
        printf '%s %s: worst VMAF %s.\n' "$quality_label" "$mid" "$CAL_MIN_VMAF"
        if calibration_score_passes; then
            best_quality=$mid
            best_video_bps=$CAL_AVG_VIDEO_BPS
            best_position=$CAL_WORST_POSITION
            low=$((mid + 1))
        else
            if (( best_quality == 0 )); then
                failed_qualities+=("$mid")
                failed_scores+=("$CAL_MIN_VMAF")
                count=${#failed_qualities[@]}
                if [[ $plateau_checked == false ]] && (( count >= 3 )) && calibration_has_plateau \
                    "${failed_qualities[count-3]}" "${failed_qualities[count-2]}" "${failed_qualities[count-1]}" \
                    "${failed_scores[count-3]}" "${failed_scores[count-2]}" "${failed_scores[count-1]}"; then
                    plateau_checked=true
                    printf 'VMAF plateau detected; checking highest-quality %s %s at the failing position before rejecting.\n' \
                        "$quality_label" "$endpoint"
                    if ! evaluate_hardware_quality "$codec" "$encoder" "$endpoint" one-shot "$CAL_WORST_POSITION"; then
                        CAL_REASON="sample-probe-failed-at-${endpoint}"
                        return 1
                    fi
                    if ! calibration_score_passes; then
                        CAL_REASON='quality-endpoint-below-floor'
                        printf 'Highest-quality setting fails VMAF (%s < %s); another codec may still qualify.\n' \
                            "$CAL_MIN_VMAF" "$quality_vmaf_threshold"
                        calibration_video_cache_write rejected "$endpoint" "$CAL_WORST_POSITION" "$CAL_AVG_VIDEO_BPS"
                        return 2
                    fi
                    printf 'Highest-quality sample recovered; continuing the boundary search.\n'
                fi
            fi
            high=$((mid - 1))
        fi
    done

    if (( best_quality <= 0 )); then
        CAL_REASON='quality-floor-not-met'
        if ! calibration_score_passes; then
            calibration_video_cache_write rejected "$endpoint" "$CAL_WORST_POSITION" "$CAL_AVG_VIDEO_BPS"
        fi
        return 2
    fi

    calibration_predict_savings "$best_video_bps" "$source_average_bps"
    CAL_BEST_QUALITY=$best_quality
    CAL_RESULT_VIDEO_BPS=$best_video_bps
    printf '%s quality-valid boundary: %s %s; predicted saving %s%%; required %s%%.\n' \
        "${codec^^}" "$quality_label" "$best_quality" "$CAL_PREDICTED_SAVINGS" "$required_savings"

    if ! calibration_savings_pass; then
        CAL_REASON='minimum-saving-not-met'
        return 3
    fi
    calibration_cache_write "$best_quality"
    calibration_video_cache_write boundary "$best_quality" "$best_position" "$best_video_bps"
    CAL_REASON='candidate-valid'
    return 0
}

apply_calibrated_candidate() {
    local codec=$1 encoder=$2 quality=$3 label=$4
    local CAL_FILTER_CHAIN=''
    apply_encoder "$encoder"
    calibration_apply_quality "$encoder" "$quality" || return 1
    calibration_build_filter_chain "$encoder"
    filter_chain=$CAL_FILTER_CHAIN
    CAL_SELECTED_VALIDATED=true
    case "$encoder" in
        av1_vaapi) video_crf="CQP q_idx ${quality} (calibrated)" ;;
        hevc_vaapi) video_crf="CQP QP ${quality} (calibrated)" ;;
        av1_nvenc|hevc_nvenc) video_crf="CQ ${quality} (calibrated)" ;;
        av1_qsv|hevc_qsv) video_crf="ICQ ${quality} (calibrated)" ;;
    esac
    printf 'Selected %s via %s at %s %s.\n' "${codec^^}" "$encoder" "$label" "$quality"
}

calibrate_and_choose_video_codec() {
    CAL_SELECTED_VALIDATED=false
    [[ "$quality_check" != off ]] || {
        if [[ $HARDCORE_AUTO_CODEC_MODE == 1 ]]; then
            printf 'Automatic AV1/HEVC comparison requires VMAF; original preserved unchanged.\n'
            return 3
        fi
        return 0
    }
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || {
        printf 'Video quality calibration could not determine duration. Original preserved unchanged.\n'
        return 3
    }

    local av1_encoder='' hevc_encoder='' av1_rc=9 hevc_rc=9
    local av1_quality='' hevc_quality='' av1_saving='' hevc_saving=''
    local av1_reason='unavailable' hevc_reason='unavailable'
    local av1_label='' hevc_label=''

    if [[ $HARDCORE_AUTO_CODEC_MODE == 1 ]]; then
        av1_encoder=$HARDCORE_AUTO_AV1_ENCODER
        hevc_encoder=$HARDCORE_AUTO_HEVC_ENCODER
    else
        case "$expected_codec" in
            av1) av1_encoder=$video_encoder ;;
            hevc) hevc_encoder=$video_encoder ;;
        esac
    fi

    if [[ -n $av1_encoder ]]; then
        if calibrate_hardware_candidate av1 "$av1_encoder"; then av1_rc=0; else av1_rc=$?; fi
        av1_quality=$CAL_BEST_QUALITY; av1_saving=$CAL_PREDICTED_SAVINGS; av1_reason=$CAL_REASON; av1_label=$CAL_QUALITY_LABEL
    fi
    if [[ -n $hevc_encoder ]]; then
        if calibrate_hardware_candidate hevc "$hevc_encoder"; then hevc_rc=0; else hevc_rc=$?; fi
        hevc_quality=$CAL_BEST_QUALITY; hevc_saving=$CAL_PREDICTED_SAVINGS; hevc_reason=$CAL_REASON; hevc_label=$CAL_QUALITY_LABEL
    fi

    if [[ $HARDCORE_AUTO_CODEC_MODE != 1 ]]; then
        local rc quality saving reason label codec encoder
        if [[ -n $av1_encoder ]]; then rc=$av1_rc; quality=$av1_quality; saving=$av1_saving; reason=$av1_reason; label=$av1_label; codec=av1; encoder=$av1_encoder
        else rc=$hevc_rc; quality=$hevc_quality; saving=$hevc_saving; reason=$hevc_reason; label=$hevc_label; codec=hevc; encoder=$hevc_encoder; fi
        if (( rc == 4 )); then
            printf '%s encoder %s has no calibrated search policy; using its existing validated settings.\n' "${codec^^}" "$encoder"
            return 0
        fi
        if (( rc != 0 )); then
            printf '%s calibration rejected this file (%s). Original preserved unchanged.\n' "${codec^^}" "$reason"
            return 3
        fi
        apply_calibrated_candidate "$codec" "$encoder" "$quality" "$label"
        return $?
    fi

    printf '\nAutomatic codec competition\n'
    printf '%s\n' '════════════════════════════════════════════════════════════'
    printf 'AV1:  encoder=%s | result=%s | quality=%s %s | predicted saving=%s%%\n' \
        "${av1_encoder:-unavailable}" "$av1_reason" "${av1_label:-n/a}" "${av1_quality:-n/a}" "${av1_saving:-n/a}"
    printf 'HEVC: encoder=%s | result=%s | quality=%s %s | predicted saving=%s%%\n' \
        "${hevc_encoder:-unavailable}" "$hevc_reason" "${hevc_label:-n/a}" "${hevc_quality:-n/a}" "${hevc_saving:-n/a}"

    if (( av1_rc == 4 )) && [[ -n $av1_encoder && -z $hevc_encoder ]]; then
        printf 'Only AV1 is available and its encoder family has no calibrated competition policy; keeping existing AV1 settings.\n'
        return 0
    fi
    if (( hevc_rc == 4 )) && [[ -n $hevc_encoder && -z $av1_encoder ]]; then
        printf 'Only HEVC is available and its encoder family has no calibrated competition policy; keeping existing HEVC settings.\n'
        return 0
    fi

    if (( av1_rc == 0 && hevc_rc == 0 )); then
        if LC_NUMERIC=C awk -v a="$av1_saving" -v h="$hevc_saving" 'BEGIN {exit !(a>=h)}'; then
            printf 'Winner: AV1, because its quality-valid candidate is predicted smaller.\n'
            apply_calibrated_candidate av1 "$av1_encoder" "$av1_quality" "$av1_label"
        else
            printf 'Winner: HEVC, because its quality-valid candidate is predicted smaller.\n'
            apply_calibrated_candidate hevc "$hevc_encoder" "$hevc_quality" "$hevc_label"
        fi
        return $?
    elif (( av1_rc == 0 )); then
        printf 'Winner: AV1; HEVC did not produce an accepted quality/size candidate.\n'
        apply_calibrated_candidate av1 "$av1_encoder" "$av1_quality" "$av1_label"
        return $?
    elif (( hevc_rc == 0 )); then
        printf 'Winner: HEVC; AV1 did not produce an accepted quality/size candidate.\n'
        apply_calibrated_candidate hevc "$hevc_encoder" "$hevc_quality" "$hevc_label"
        return $?
    fi

    printf 'Neither AV1 nor HEVC produced a candidate meeting both VMAF and minimum-savings requirements. Original preserved unchanged.\n'
    return 3
}

run_video_preflight() {
    if [[ $CAL_SELECTED_VALIDATED == true && $quality_check != off ]]; then
        printf "\nVideo preflight: reusing this file's calibrated quality and size measurements.\n"
        return 0
    fi
    [[ "$video_preflight" == true ]] || return 0
    [[ "$duration" =~ ^[0-9]+([.][0-9]+)?$ ]] || return 0

    local duration_is_long=false
    if LC_NUMERIC=C awk -v d="$duration" -v minimum="$preflight_min_duration" \
        'BEGIN {exit !(d >= minimum)}'; then
        duration_is_long=true
    fi
    if [[ "$quality_check" == off && "$duration_is_long" != true ]] && (( original_size < preflight_min_size )); then
        printf '\nVideo preflight: skipped for this short, small file; direct encoding is cheaper.\n'
        return 0
    fi

    local required_savings="$min_savings_percent"
    if [[ "$source_video_codec" == "$expected_codec" && "$apply_scaling" != true && "$apply_denoise" != true ]]; then
        required_savings=$(LC_NUMERIC=C awk -v minimum="$min_savings_percent" 'BEGIN {
            candidate=minimum+5; if(candidate<10) candidate=10; printf "%.3f",candidate
        }')
    fi

    local -a positions=(0.10 0.50 0.90)
    local position start sample_length sample_file sample_size actual_length sample_bps
    local successful=0 total_bps=0 min_bps=0 max_bps=0 index=0
    local quality_samples=0 minimum_vmaf=101 minimum_ssim=2 quality_failed=false
    local -a sample_command=()

    printf '\nVideo compression preflight\n'
    printf '%s\n' '────────────────────────────────────────────────────────────'
    printf 'Testing three representative %ss segments with the final encoder settings.\n' \
        "$preflight_sample_seconds"

    for position in "${positions[@]}"; do
        ((index++))
        start=$(LC_NUMERIC=C awk -v d="$duration" -v p="$position" -v seglen="$preflight_sample_seconds" 'BEGIN {
            start=d*p-seglen/2; if(start<0)start=0; if(start+seglen>d)start=d-seglen; if(start<0)start=0;
            printf "%.3f",start
        }')
        sample_length=$(LC_NUMERIC=C awk -v d="$duration" -v start="$start" -v maximum="$preflight_sample_seconds" 'BEGIN {
            remaining=d-start; if(remaining>maximum)remaining=maximum; if(remaining<1)remaining=1; printf "%.3f",remaining
        }')
        sample_file="${output_dir}/.${output_name}.preflight.$$.${index}.mkv"
        preflight_files+=("$sample_file")
        rm -f -- "$sample_file"

        sample_command=(ffmpeg -hide_banner -v error -nostdin -y)
        if [[ "$video_encoder" == *_vaapi ]]; then
            sample_command+=(-init_hw_device "vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" -filter_hw_device va)
        fi
        sample_command+=(
            -ss "$start" -i "$input" -t "$sample_length"
            -map '0:V:0' -an -sn -dn -map_metadata -1 -map_chapters -1
            -c:v "$video_encoder" "${encoder_args[@]}"
        )
        if [[ "$video_encoder" != *_vaapi ]]; then
            sample_command+=(-pix_fmt:v "$video_pix_fmt")
        fi
        if [[ "$video_encoder" == *_nvenc ]]; then
            sample_command+=(-gpu:v "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}")
        fi
        [[ -n "$filter_chain" ]] && sample_command+=(-vf "$filter_chain")
        sample_command+=("$sample_file")

        printf 'Sample %s/3 at %ss: ' "$index" "$start"
        if ! "${sample_command[@]}"; then
            printf 'failed.\n'
            [[ $quality_check != off ]] && quality_failed=true
            rm -f -- "$sample_file"
            continue
        fi

        sample_size=$(stat -c '%s' -- "$sample_file" 2>/dev/null || printf '0')
        actual_length=$(ffprobe -v error -show_entries format=duration -of default=nw=1:nk=1 \
            "$sample_file" 2>/dev/null | head -n1)
        if (( sample_size <= 0 )) || ! [[ "$actual_length" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
            printf 'invalid.\n'
            [[ $quality_check != off ]] && quality_failed=true
            rm -f -- "$sample_file"
            continue
        fi

        sample_bps=$(LC_NUMERIC=C awk -v bytes="$sample_size" -v seconds="$actual_length" \
            'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
        if (( sample_bps <= 0 )); then
            [[ $quality_check != off ]] && quality_failed=true
            continue
        fi
        successful=$((successful + 1))
        total_bps=$((total_bps + sample_bps))
        if (( min_bps == 0 || sample_bps < min_bps )); then min_bps=$sample_bps; fi
        if (( sample_bps > max_bps )); then max_bps=$sample_bps; fi
        printf '%s video bitrate' "$(LC_NUMERIC=C awk -v b="$sample_bps" 'BEGIN {printf "%.2f Mbit/s",b/1000000}')"
        if measure_preflight_quality "$start" "$actual_length" "$sample_file"; then
            quality_samples=$((quality_samples + 1))
            printf '; %s %s' "$MEASURED_QUALITY_KIND" "$MEASURED_QUALITY_SCORE"
            if [[ $MEASURED_QUALITY_KIND == VMAF ]] && \
               LC_NUMERIC=C awk -v a="$MEASURED_QUALITY_SCORE" -v b="$minimum_vmaf" 'BEGIN {exit !(a<b)}'; then
                minimum_vmaf=$MEASURED_QUALITY_SCORE
            elif [[ $MEASURED_QUALITY_KIND == SSIM ]] && \
                 LC_NUMERIC=C awk -v a="$MEASURED_QUALITY_SCORE" -v b="$minimum_ssim" 'BEGIN {exit !(a<b)}'; then
                minimum_ssim=$MEASURED_QUALITY_SCORE
            fi
        elif [[ $quality_check != off ]]; then
            printf '; quality measurement failed'
            quality_failed=true
        fi
        printf '.\n'
        rm -f -- "$sample_file"
    done

    if [[ $quality_check != off ]] && (( quality_samples == 0 )); then
        quality_failed=true
    fi
    if [[ $quality_failed == true ]]; then
        printf 'Sample VMAF quality validation was unavailable. Original preserved unchanged.\n'
        exit 3
    fi
    if (( quality_samples > 0 )); then
        if LC_NUMERIC=C awk -v value="$minimum_vmaf" -v threshold="$quality_vmaf_threshold" \
            'BEGIN {exit !(value<=100 && value<threshold)}'; then
            printf 'Sample VMAF %s is below the %s threshold. Original preserved unchanged.\n' \
                "$minimum_vmaf" "$quality_vmaf_threshold"
            exit 3
        fi
        if LC_NUMERIC=C awk -v value="$minimum_ssim" -v threshold="$quality_ssim_threshold" \
            'BEGIN {exit !(value<=1 && value<threshold)}'; then
            printf 'Sample SSIM %s is below the %s threshold. Original preserved unchanged.\n' \
                "$minimum_ssim" "$quality_ssim_threshold"
            exit 3
        fi
    fi

    if (( successful < 2 )); then
        printf 'Preflight was inconclusive; proceeding with the full encode.\n'
        return 0
    fi

    local average_video_bps source_average_bps predicted_output_bps predicted_savings variation safety_margin=2
    average_video_bps=$((total_bps / successful))
    source_average_bps=$(LC_NUMERIC=C awk -v bytes="$original_size" -v seconds="$duration" \
        'BEGIN {if(seconds<=0)print 0; else printf "%.0f",bytes*8/seconds}')
    predicted_output_bps=$(LC_NUMERIC=C awk -v video="$average_video_bps" -v audio="$estimated_output_audio_bps" \
        'BEGIN {printf "%.0f",(video+audio)*1.015}')
    predicted_savings=$(LC_NUMERIC=C awk -v source="$source_average_bps" -v output="$predicted_output_bps" 'BEGIN {
        if(source<=0){print 0; exit} printf "%.2f",(source-output)*100/source
    }')
    variation=$(LC_NUMERIC=C awk -v minimum="$min_bps" -v maximum="$max_bps" -v average="$average_video_bps" 'BEGIN {
        if(average<=0){print 100; exit} printf "%.2f",(maximum-minimum)*100/average
    }')

    printf 'Predicted output rate: %s\n' \
        "$(LC_NUMERIC=C awk -v b="$predicted_output_bps" 'BEGIN {printf "%.2f Mbit/s",b/1000000}')"
    printf 'Predicted size saving: %s%%\n' "$predicted_savings"
    printf 'Sample variation:      %s%%\n' "$variation"
    printf 'Required saving:       %s%%\n' "$required_savings"

    if LC_NUMERIC=C awk -v predicted="$predicted_savings" 'BEGIN {exit !(predicted<=-20)}'; then
        printf 'Preflight predicts severe expansion (%s%% saving). Original preserved unchanged.\n' "$predicted_savings"
        exit 3
    fi

    if LC_NUMERIC=C awk -v predicted="$predicted_savings" -v required="$required_savings" \
        -v margin="$safety_margin" -v variation="$variation" \
        'BEGIN {exit !((predicted+margin)<required && variation<=35)}'; then
        printf 'Preflight predicts insufficient savings. Original preserved unchanged.\n'
        exit 3
    fi

    printf 'Preflight supports a full encode, or is uncertain enough that skipping would be unsafe.\n'
}

calibrate_and_choose_video_codec
calibration_rc=$?
if (( calibration_rc == 3 )); then
    exit 3
elif (( calibration_rc != 0 )); then
    die "Video codec calibration/selection failed with exit code $calibration_rc."
fi

run_video_preflight

printf '\nRecommended encoding plan\n'
printf '%s\n' '════════════════════════════════════════════════════════════'
printf 'Input:              %s\n' "$input"
printf 'Output:             %s\n' "$output"
printf 'Video:              %s\n' "$video_codec_label"
printf 'Quality:            %s\n' "$video_crf"
printf 'Resolution:         %s\n' "$scaling_reason"
printf 'Denoising:          %s\n' "$denoise_reason"
if ((${#audio_plan[@]} == 0)); then
    printf 'Audio:              No audio streams\n'
else
    printf 'Audio:              %s\n' "${audio_plan[0]}"
    for ((i=1; i<${#audio_plan[@]}; i++)); do printf '                    %s\n' "${audio_plan[$i]}"; done
fi
printf 'Validation:         Codec, duration and full decode\n'
printf '%s\n' '════════════════════════════════════════════════════════════'

if [[ -e "$output" && "$same_output_as_input" != true && "$assume_yes" != true ]]; then
    ask_yes_no 'Replace the existing destination?' n || { printf 'Cancelled.\n'; exit 0; }
fi
if [[ "$assume_yes" != true ]]; then
    printf '\n'
    ask_yes_no 'Start compression?' y || { printf 'Cancelled.\n'; exit 0; }
fi

if ! hardcore_video_encode_full; then
    rm -f -- "$temporary"
    temporary=''
    die 'Video encoding or validation failed after compatible preprocessing retries.'
fi

output_video_stream_count=$(stream_count_file v "$temporary")
output_audio_count=$(stream_count_file a "$temporary")
output_subtitle_count=$(stream_count_file s "$temporary")
output_attachment_count=$(stream_count_file t "$temporary")
output_data_count=$(stream_count_file d "$temporary")
if (( output_video_stream_count != all_video_stream_count || output_audio_count != audio_count ||
      output_subtitle_count != subtitle_count || output_attachment_count != attachment_count ||
      output_data_count != data_stream_count )); then
    rm -f -- "$temporary"
    printf 'Stream-preservation validation failed. Original preserved unchanged.\n'
    exit 3
fi
if ! python3 "$HARDCORE_ARCHIVE_MEDIA_HELPER" validate "$input" "$temporary"; then
    rm -f -- "$temporary"
    printf 'Semantic media-preservation validation failed. Original preserved unchanged.\n'
    exit 3
fi

compressed_size=$(stat -c '%s' -- "$temporary")
printf '\nResult\n'
printf '%s\n' '────────────────────────────────────────────────────────────'
printf 'Original:           %s\n' "$(human_size "$original_size")"
printf 'Compressed:         %s\n' "$(human_size "$compressed_size")"

savings_percent=$(LC_NUMERIC=C awk -v original="$original_size" -v compressed="$compressed_size" 'BEGIN {
    if (original <= 0) { print "0.000"; exit }
    printf "%.3f", (original-compressed)*100/original
}')
printf 'Size reduction:     %s%%\n' "$savings_percent"

meets_savings=false
if LC_NUMERIC=C awk -v saved="$savings_percent" -v minimum="$min_savings_percent"     'BEGIN {exit !(saved >= minimum && saved > 0)}'; then
    meets_savings=true
fi

if [[ "$meets_savings" != true ]]; then
    retain=false
    [[ "$keep_larger" == true ]] && retain=true
    if [[ "$assume_yes" != true && "$retain" != true ]] &&        ask_yes_no "Keep result despite not meeting ${min_savings_percent}% minimum savings?" n; then
        retain=true
    fi
    if [[ "$retain" != true ]]; then
        rm -f -- "$temporary"
        if (( compressed_size >= original_size )); then
            printf 'The larger result was removed.\n'
        else
            printf 'Minimum savings not reached. Original preserved unchanged.\n'
        fi
        exit 3
    fi
fi

chmod --reference="$input" -- "$temporary" 2>/dev/null || true
touch --reference="$input" -- "$temporary" 2>/dev/null || true
mv -f -- "$temporary" "$output" || die 'Could not finalize output.'
temporary=''

if [[ "$replace_original" == true && "$same_output_as_input" != true ]]; then rm -f -- "$input"; fi
printf '\nCompleted successfully:\n  %s\n' "$output"
__HARDCORE_ARCHIVE_VIDEO_HELPER__
    chmod 700 -- "$destination"
}

image_progress_summary() {
    (( IMAGE_COUNT > 0 )) || return 0
    local done_count=0
    if [[ -n ${IMAGE_RESULT_MANIFEST:-} && -e $IMAGE_RESULT_MANIFEST ]]; then
        done_count=$(awk 'NF {c++} END {print c+0}' "$IMAGE_RESULT_MANIFEST" 2>/dev/null || printf 0)
    fi
    if [[ -n ${IMAGE_PIPELINE_PID:-} ]] && kill -0 "$IMAGE_PIPELINE_PID" 2>/dev/null; then
        printf 'images %s/%s handled' "$done_count" "$IMAGE_COUNT"
    elif (( done_count > 0 )); then
        printf 'images %s/%s handled' "$done_count" "$IMAGE_COUNT"
    fi
}

write_embedded_image_helper() {
    local destination=$1
    cat > "$destination" <<'__HARDCORE_ARCHIVE_IMAGE_HELPER__'
#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

has() { command -v "$1" >/dev/null 2>&1; }

jpeg_pixel_hash() {
    djpeg "$1" 2>/dev/null | sha256sum | awk '{print $1}'
}

png_pixel_hash() {
    if has ffmpeg; then
        ffmpeg -hide_banner -v error -nostdin -i "$1" -map 0:v:0 -f framemd5 - 2>/dev/null |
            sha256sum | awk '{print $1}'
    elif has pngcheck; then
        pngcheck -q "$1" >/dev/null 2>&1 || return 1
        # pngcheck proves structural validity. Without a decoder, Oxipng's
        # lossless contract is used as the pixel-preservation guarantee.
        printf 'validated-by-pngcheck\n'
    else
        return 1
    fi
}

optimize_one() {
    local source_parent=$1 stage_parent=$2 result_file=$3 log_file=$4 mode=$5 relative=$6
    local input output output_dir temp_dir original_size lower source_hash candidate_hash
    local baseline progressive candidate candidate_size best='' best_size=0 tool='unavailable'

    input="$source_parent/$relative"
    output="$stage_parent/$relative"
    output_dir=$(dirname -- "$output")
    mkdir -p -- "$output_dir"
    original_size=$(stat -c '%s' -- "$input")
    lower=${relative,,}
    temp_dir=$(mktemp -d "$output_dir/.image-opt.XXXXXX")

    if [[ $lower == *.jpg || $lower == *.jpeg || $lower == *.jpe || $lower == *.jfif ]]; then
        if has jpegtran && has djpeg; then
            tool=jpegtran
            source_hash=$(jpeg_pixel_hash "$input" || true)
            baseline="$temp_dir/baseline.jpg"
            progressive="$temp_dir/progressive.jpg"

            if [[ -n $source_hash ]] && jpegtran -copy all -optimize "$input" >"$baseline" 2>>"$log_file" && [[ -s $baseline ]]; then
                candidate_hash=$(jpeg_pixel_hash "$baseline" || true)
                if [[ $candidate_hash == "$source_hash" ]]; then
                    best=$baseline
                    best_size=$(stat -c '%s' -- "$baseline")
                    tool=jpegtran-optimize
                fi
            fi

            if [[ -n $source_hash ]] && jpegtran -copy all -optimize -progressive "$input" >"$progressive" 2>>"$log_file" && [[ -s $progressive ]]; then
                candidate_hash=$(jpeg_pixel_hash "$progressive" || true)
                if [[ $candidate_hash == "$source_hash" ]]; then
                    candidate_size=$(stat -c '%s' -- "$progressive")
                    if (( best_size == 0 || candidate_size < best_size )); then
                        best=$progressive
                        best_size=$candidate_size
                        tool=jpegtran-progressive
                    fi
                fi
            fi
        fi
    elif [[ $lower == *.png ]]; then
        candidate="$temp_dir/optimized.png"
        cp --reflink=auto --preserve=all -- "$input" "$candidate"
        if has oxipng; then
            tool=oxipng
            case "$mode" in
                maximum) RAYON_NUM_THREADS=2 oxipng -q -o 6 -z --preserve "$candidate" >>"$log_file" 2>&1 || true ;;
                balanced) RAYON_NUM_THREADS=2 oxipng -q -o 4 --preserve "$candidate" >>"$log_file" 2>&1 || true ;;
                fast) RAYON_NUM_THREADS=2 oxipng -q -o 2 --preserve "$candidate" >>"$log_file" 2>&1 || true ;;
            esac
        elif has optipng; then
            tool=optipng
            case "$mode" in
                maximum) optipng -quiet -preserve -o7 "$candidate" >>"$log_file" 2>&1 || true ;;
                balanced) optipng -quiet -preserve -o5 "$candidate" >>"$log_file" 2>&1 || true ;;
                fast) optipng -quiet -preserve -o2 "$candidate" >>"$log_file" 2>&1 || true ;;
            esac
        fi

        if [[ $tool != unavailable && -s $candidate ]]; then
            source_hash=$(png_pixel_hash "$input" || true)
            candidate_hash=$(png_pixel_hash "$candidate" || true)
            if [[ -n $source_hash && $candidate_hash == "$source_hash" ]]; then
                best=$candidate
                best_size=$(stat -c '%s' -- "$candidate")
            fi
        fi
    fi

    if [[ -n $best && $best_size -lt $original_size ]]; then
        cp --reflink=auto -- "$best" "$output"
        chmod --reference="$input" -- "$output" 2>/dev/null || true
        touch --reference="$input" -- "$output" 2>/dev/null || true
        line=$(printf 'optimized\t%s\t%s\t%s\t%s\t%s\n' \
            "$relative" "$relative" "$original_size" "$best_size" "$tool")
    else
        line=$(printf 'original\t%s\t%s\t%s\t%s\t%s\n' \
            "$relative" "$relative" "$original_size" "$original_size" "$tool")
    fi

    rm -rf -- "$temp_dir"
    if has flock; then
        { flock 9; printf '%s\n' "$line" >>"$result_file"; } 9>"${result_file}.lock"
    else
        printf '%s\n' "$line" >>"$result_file"
    fi
}

if [[ ${1:-} == --worker ]]; then
    shift
    optimize_one "$@"
    exit 0
fi

source_parent=''
stage_parent=''
list_file=''
result_file=''
log_file=''
mode=maximum
jobs=1
while (( $# > 0 )); do
    case "$1" in
        --source-parent) source_parent=$2; shift 2 ;;
        --stage-parent) stage_parent=$2; shift 2 ;;
        --list) list_file=$2; shift 2 ;;
        --result) result_file=$2; shift 2 ;;
        --log) log_file=$2; shift 2 ;;
        --mode) mode=$2; shift 2 ;;
        --jobs) jobs=$2; shift 2 ;;
        *) printf 'Unknown image-helper option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

: >"$result_file"
: >"$log_file"
xargs -r -d '\n' -P "$jobs" -I '{}' \
    bash "$0" --worker "$source_parent" "$stage_parent" "$result_file" "$log_file" "$mode" '{}' \
    <"$list_file"
__HARDCORE_ARCHIVE_IMAGE_HELPER__
    chmod 700 -- "$destination"
}



is_nested_archive_path() {
    local lower=${1,,}
    case "$lower" in
        *.7z|*.zip|*.rar|*.cab|*.tar.gz|*.tgz|*.tar.xz|*.txz|*.tar.bz2|*.tbz2|*.tar.zst|*.tzst) return 0 ;;
        *) return 1 ;;
    esac
}


# HARDCORE_COPY_LANE_PATCH_V1
# HARDCORE_CONTAINER_REPACK_PATCH_V1
CONTAINER_REPACK=${HARDCORE_ARCHIVE_CONTAINER_REPACK:-true}
CONTAINER_HELPER=${HARDCORE_ARCHIVE_CONTAINER_HELPER:-}
is_format_preserving_container_path() {
    local lower=${1,,}
    case "$lower" in
        *.docx|*.xlsx|*.pptx|*.odt|*.ods|*.odp|*.epub|*.npz|*.whl|*.jar|*.war) return 0 ;;
        *) return 1 ;;
    esac
}
# HARDCORE_COPY_LANE_PATCH_V2
# Generic Copy/LZMA routing is content-aware. Transform lanes are still
# classified first; ordinary files are sampled once in a batch and only
# content-confirmed incompressible files enter the Copy lane. Uncertain and
# small files remain in solid LZMA2 so a filename can never suppress useful
# compression.
declare -A CONTENT_COPY_PATHS=()
is_already_compressed_path() {
    [[ ${CONTENT_COPY_PATHS[$1]+present} == present ]]
}

archive_replacement_path() {
    local path=$1 base
    case "${path,,}" in
        *.tar.gz) base=${path:0:${#path}-7} ;;
        *.tar.xz|*.tar.zst|*.tar.bz2) base=${path:0:${#path}-7} ;;
        *.tgz|*.txz|*.tzst|*.tbz2) base=${path%.*} ;;
        *) base=${path%.*} ;;
    esac
    printf '%s.7z' "$base"
}


validate_transformed_path_collisions() {
    python3 - "$INVENTORY_RAW" "$VIDEO_LIST" "$NESTED_LIST" <<'PYCOLLIDE'
import os,sys
raw,video_list,nested_list=sys.argv[1:]
data=open(raw,'rb').read().split(b'\0')
original={os.fsdecode(data[i+1]) for i in range(0,len(data)-1,2) if data[i+1]}
transforms=[]
def lines(path):
    try:
        with open(path,'r',encoding='utf-8',errors='surrogateescape') as f:
            return [x.rstrip('\n') for x in f if x.rstrip('\n')]
    except OSError: return []
for src in lines(video_list):
    dst=src if src.lower().endswith('.mkv') else os.path.splitext(src)[0]+'.mkv'
    transforms.append((src,dst,'video'))
for src in lines(nested_list):
    low=src.lower()
    for suffix in ('.tar.gz','.tar.xz','.tar.zst','.tar.bz2'):
        if low.endswith(suffix):
            dst=src[:-len(suffix)]+'.7z'; break
    else:
        dst=os.path.splitext(src)[0]+'.7z'
    transforms.append((src,dst,'nested archive'))
seen={}
errors=[]
transform_sources={src for src,_,_ in transforms}
for src,dst,kind in transforms:
    if dst in seen and seen[dst]!=src:
        errors.append(f"{kind} outputs collide: {seen[dst]!r} and {src!r} -> {dst!r}")
    seen[dst]=src
    if dst in original and dst!=src and dst not in transform_sources:
        errors.append(f"{kind} output would overwrite an existing archived path: {src!r} -> {dst!r}")
if errors:
    print('Transformed-path collisions detected:',file=sys.stderr)
    for e in errors: print('  '+e,file=sys.stderr)
    sys.exit(1)
PYCOLLIDE
}

archive_manifest_extract() {
    local archive=$1 path=$2
    "$SEVEN_ZIP" x -so -y -spd "$archive" -- "$path" 2>/dev/null || true
}

inspect_existing_archive() {
    local archive_input=${POSITIONAL[0]} archive size files dirs method manifest version created
    [[ -f $archive_input ]] || die "Archive does not exist: $archive_input"
    archive=$(realpath -e -- "$archive_input")
    printf 'Inspecting archive:\n  %s\n\n' "$archive"
    "$SEVEN_ZIP" t "$archive" -bsp1 || die "Archive integrity testing failed."
    size=$(stat -c '%s' -- "$archive")
    files=$("$SEVEN_ZIP" l -slt "$archive" 2>/dev/null | awk '/^Folder = -/{n++} END{print n+0}')
    dirs=$("$SEVEN_ZIP" l -slt "$archive" 2>/dev/null | awk '/^Folder = \+/{n++} END{print n+0}')
    method=$("$SEVEN_ZIP" l -slt "$archive" 2>/dev/null | awk -F' = ' '/^Method = /{print $2; exit}')
    printf 'Integrity:             passed\n'
    printf 'Archive size:          %s\n' "$(human_bytes "$size")"
    printf 'File entries:          %s\n' "$files"
    printf 'Directory entries:     %s\n' "$dirs"
    printf 'First method reported: %s\n' "${method:-unknown}"
    manifest=$(archive_manifest_extract "$archive" '.hardcore-archive-metadata/archive-info.txt')
    if [[ -n $manifest ]]; then
        printf '\n===== Archive information =====\n%s\n' "$manifest"
    fi
    for path in '.hardcore-archive-video-manifest.txt' '.hardcore-archive-image-manifest.txt' '.hardcore-archive-container-manifest.txt' '.hardcore-archive-nested-manifest.txt' '.hardcore-archive-metadata/sparse.tsv'; do
        if "$SEVEN_ZIP" l -ba "$archive" "$path" 2>/dev/null | grep -Fq "$path"; then
            printf '%-28s present\n' "$path:"
        fi
    done
    if "$SEVEN_ZIP" l -ba "$archive" '.hardcore-archive-sha256.txt' 2>/dev/null | grep -Fq '.hardcore-archive-sha256.txt'; then
        printf '\nEmbedded SHA-256 manifest: present\n'
    else
        printf '\nEmbedded SHA-256 manifest: absent\n'
    fi
}

apply_sparse_manifest() {
    local root=$1 manifest
    manifest="$root/.hardcore-archive-metadata/sparse.tsv"
    [[ -s $manifest ]] || return 0
    command -v python3 >/dev/null 2>&1 || \
        die "Critical dependency disappeared after preflight: python3"
    python3 - "$root" "$manifest" <<'PYSPARSERESTORE'
import os, shutil, sys, tempfile
root=os.path.realpath(sys.argv[1]); manifest=sys.argv[2]
entries={}
with open(manifest,'r',encoding='utf-8',errors='surrogateescape') as f:
    header=f.readline().rstrip('\n')
    if header != 'path\tlogical_size\tstart\tlength':
        raise ValueError('invalid sparse metadata header')
    for line_number,line in enumerate(f,2):
        line=line.rstrip('\n')
        if not line: continue
        try:
            rel, logical, start, length=line.split('\t',3)
            logical=int(logical); start=int(start); length=int(length)
        except Exception as exc:
            raise ValueError(f'invalid sparse metadata row {line_number}') from exc
        if logical < 0 or start < 0 or length <= 0 or start + length > logical:
            raise ValueError(f'invalid sparse range on row {line_number}')
        entries.setdefault((rel,logical),[]).append((start,start+length))

def copy_range(src,dst,start,end):
    src.seek(start); dst.seek(start); remaining=end-start
    while remaining:
        block=src.read(min(8*1024*1024,remaining))
        if not block: raise IOError('unexpected end of sparse source')
        dst.write(block); remaining-=len(block)

for (rel,logical),holes in entries.items():
    path=os.path.realpath(os.path.join(root,rel))
    if not (path == root or path.startswith(root+os.sep)) or not os.path.isfile(path):
        raise ValueError(f'unsafe or missing sparse metadata path: {rel!r}')
    holes=sorted((max(0,a),min(logical,b)) for a,b in holes if b>a)
    merged=[]
    for a,b in holes:
        if merged and a <= merged[-1][1]: merged[-1]=(merged[-1][0],max(merged[-1][1],b))
        else: merged.append((a,b))
    directory=os.path.dirname(path)
    fd,tmp=tempfile.mkstemp(prefix='.hardcore-sparse-',dir=directory)
    try:
        with open(path,'rb',buffering=0) as src, os.fdopen(fd,'w+b',buffering=0) as dst:
            os.ftruncate(dst.fileno(),logical)
            pos=0
            for a,b in merged:
                if a>pos: copy_range(src,dst,pos,a)
                pos=max(pos,b)
            if pos<logical: copy_range(src,dst,pos,logical)
            dst.flush(); os.fsync(dst.fileno())
        shutil.copystat(path,tmp,follow_symlinks=False)
        os.replace(tmp,path)
    except Exception as exc:
        try: os.unlink(tmp)
        except OSError: pass
        raise RuntimeError(f'could not restore sparse layout for {rel}: {exc}') from exc
PYSPARSERESTORE
}

cleanup_restore() {
    local exit_status=$?
    if [[ -n ${RESTORE_TEMP:-} && -d $RESTORE_TEMP && ${RESTORE_COMMITTED:-false} != true ]]; then
        rm -rf --one-file-system -- "$RESTORE_TEMP" 2>/dev/null || true
    fi
    if [[ -n ${RESTORE_LOCK_FD:-} ]]; then
        flock -u "$RESTORE_LOCK_FD" 2>/dev/null || true
        eval "exec ${RESTORE_LOCK_FD}>&-" 2>/dev/null || true
    fi
    [[ -z ${RESTORE_LOCK_FILE:-} ]] || rm -f -- "$RESTORE_LOCK_FILE" 2>/dev/null || true
    return "$exit_status"
}

hardcore_archive_internal_root_name() {
    case $1 in
        .hardcore-archive-metadata|\
        .hardcore-archive-sha256.txt|\
        .hardcore-archive-video-manifest.txt|\
        .hardcore-archive-image-manifest.txt|\
        .hardcore-archive-container-manifest.txt|\
        .hardcore-archive-nested-manifest.txt) return 0 ;;
        *) return 1 ;;
    esac
}

remove_hardcore_archive_internal_entries() {
    local root=$1 name
    [[ -n $root && -d $root && $root != / ]] || \
        die "Refusing to clean internal entries from an unsafe directory: ${root:-empty}"
    for name in \
        .hardcore-archive-metadata \
        .hardcore-archive-sha256.txt \
        .hardcore-archive-video-manifest.txt \
        .hardcore-archive-image-manifest.txt \
        .hardcore-archive-container-manifest.txt \
        .hardcore-archive-nested-manifest.txt
    do
        rm -rf --one-file-system -- "$root/$name"
    done
}

restore_existing_archive() {
    local archive_input=${POSITIONAL[0]} destination_input=${POSITIONAL[1]:-} archive stem destination parent temp hashfile top_count top_name
    local listed_size free required lockfile
    [[ -f $archive_input ]] || die "Archive does not exist: $archive_input"
    archive=$(realpath -e -- "$archive_input")
    stem=$(basename -- "$archive")
    stem=${stem%.7z}
    if [[ -n $destination_input ]]; then
        destination=$(realpath -m -- "$destination_input")
    else
        destination=$(realpath -m -- "$(dirname -- "$archive")/$stem")
    fi
    [[ ! -e $destination ]] || die "Restore destination already exists: $destination"
    parent=$(dirname -- "$destination")
    mkdir -p -- "$parent"

    RESTORE_TEMP=""
    RESTORE_LOCK_FILE=""
    RESTORE_COMMITTED=false
    trap cleanup_restore EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    trap 'exit 129' HUP
    lockfile="${destination}.restore.lock"
    # Do not truncate or remove a lock belonging to another restore process.
    exec {RESTORE_LOCK_FD}>>"$lockfile"
    flock -n "$RESTORE_LOCK_FD" || die "Another restore process is already targeting: $destination"
    RESTORE_LOCK_FILE=$lockfile
    printf 'PID=%s\nStarted=%s\nArchive=%s\n' "$$" "$(date --iso-8601=seconds)" "$archive" > "$RESTORE_LOCK_FILE"

    printf 'Testing archive before restore...\n'
    "$SEVEN_ZIP" t "$archive" -bsp1 || die "Archive integrity testing failed; nothing was restored."

    # -ba omits the archive header (whose Path is the absolute archive filename).
    # Validate every member, including the first; use this same listing for the
    # space estimate. A failed/partial listing must never authorize extraction.
    if ! listed_size=$("$SEVEN_ZIP" l -slt -ba "$archive" | python3 -c '
import sys
bad=[]
size=0
for line in sys.stdin:
    if line.startswith("Size = "):
        value=line[7:].rstrip("\r\n")
        if not value.isascii() or not value.isdecimal():
            sys.exit("Invalid archive member size")
        size+=int(value)
    if not line.startswith("Path = "): continue
    path=line[7:].rstrip("\r\n")
    norm=path.replace("\\","/")
    if not path or norm.startswith("/") or (len(norm)>=2 and norm[1]==":") or any(p==".." for p in norm.split("/")):
        bad.append(path)
if bad:
    print("Unsafe archive paths detected:", file=sys.stderr)
    for p in bad[:20]: print("  "+p, file=sys.stderr)
    sys.exit(1)
print(size)
'); then
        die "Restore refused because the archive listing failed or contains unsafe paths or sizes."
    fi

    free=$(df -PB1 -- "$parent" | awk 'NR==2 {print $4}')
    required=$((listed_size + listed_size / 20 + 256 * MIB))
    (( free >= required )) || die "Insufficient restore space: need approximately $(human_bytes "$required"), but only $(human_bytes "$free") is free."

    temp=$(mktemp -d -p "$parent" ".${stem}.restore.XXXXXX")
    RESTORE_TEMP=$temp
    RESTORE_COMMITTED=false
    printf 'Extracting into temporary destination...\n'
    "$SEVEN_ZIP" x -y -spd -o"$temp" "$archive" || die "Archive extraction failed."

    hashfile="$temp/.hardcore-archive-sha256.txt"
    if [[ -s $hashfile ]]; then
        printf 'Verifying extracted file hashes...\n'
        (cd -- "$temp" && sha256sum -c --quiet '.hardcore-archive-sha256.txt') || die "Restored content hash verification failed."
    fi

    apply_sparse_manifest "$temp"

    # Apply metadata with installed, trusted code. ACL paths are sanitized
    # before setfacl sees them; no code or path from the archive is trusted.
    [[ -n $METADATA_HELPER && -f $METADATA_HELPER ]] || \
        die "Trusted metadata restore helper is missing: ${METADATA_HELPER:-unset}"
    python3 "$METADATA_HELPER" \
        --root "$temp" \
        --metadata-dir "$temp/.hardcore-archive-metadata" || \
        die "Safe metadata restoration failed. Nothing was committed."

    # Sparse reconstruction changes allocation only, not content; verify again.
    if [[ -s $hashfile ]]; then
        printf 'Verifying hashes after sparse and metadata restoration...\n'
        (cd -- "$temp" && sha256sum -c --quiet '.hardcore-archive-sha256.txt') || die "Final restored content verification failed."
    fi

    # Remove only the exact private entries created by Hardcore Archive. A
    # blanket prefix filter would silently discard legitimate user content such
    # as a top-level directory named .hardcore-archive-photos.
    remove_hardcore_archive_internal_entries "$temp"
    top_count=$(find "$temp" -mindepth 1 -maxdepth 1 -printf '.' | wc -c)
    if (( top_count == 1 )); then
        top_name=$(find "$temp" -mindepth 1 -maxdepth 1 -printf '%f' | head -n1)
        if [[ -d $temp/$top_name ]]; then
            mv -- "$temp/$top_name" "$destination"
        else
            mkdir -- "$destination"
            mv -- "$temp/$top_name" "$destination/"
        fi
    else
        mkdir -- "$destination"
        find "$temp" -mindepth 1 -maxdepth 1 -exec mv -t "$destination" -- {} +
    fi
    sync "$destination" 2>/dev/null || true
    RESTORE_COMMITTED=true
    rm -rf --one-file-system -- "$temp"
    RESTORE_TEMP=""
    flock -u "$RESTORE_LOCK_FD" 2>/dev/null || true
    eval "exec ${RESTORE_LOCK_FD}>&-" 2>/dev/null || true
    RESTORE_LOCK_FD=""
    rm -f -- "$RESTORE_LOCK_FILE"
    RESTORE_LOCK_FILE=""
    printf '\nRestore completed successfully:\n  %s\n' "$destination"
}

# Resolve configuration before normal argument parsing. Command-line options
# always override the config values loaded here.
PRE_CONFIG_FILE="$CONFIG_FILE"
for ((i=1; i<=$#; i++)); do
    arg=${!i}
    case $arg in
        --no-config) CONFIG_ENABLED=false ;;
        --config)
            next=$((i + 1))
            (( next <= $# )) || die "--config requires a file path."
            PRE_CONFIG_FILE=${!next}
            ;;
        --config=*) PRE_CONFIG_FILE=${arg#*=} ;;
    esac
done
if $CONFIG_ENABLED; then
    CONFIG_FILE=$PRE_CONFIG_FILE
    load_config_file "$CONFIG_FILE"
fi

# Children may read a different config; keep the parent's resolved calibration
# policy and shared directory, including explicit false overrides.
export HARDCORE_ARCHIVE_CALIBRATION_CACHE=${HARDCORE_ARCHIVE_CALIBRATION_CACHE:-true}
export HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT=${HARDCORE_ARCHIVE_CALIBRATION_EARLY_ABORT:-true}
export HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS=${HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS:-auto}
export HARDCORE_ARCHIVE_VIDEO_ACCELERATION=${HARDCORE_ARCHIVE_VIDEO_ACCELERATION:-auto}
export HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS=${HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS:-auto}
export HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE=${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}
[[ $HARDCORE_ARCHIVE_VIDEO_ACCELERATION == auto || $HARDCORE_ARCHIVE_VIDEO_ACCELERATION == cpu ]] || die 'VIDEO_ACCELERATION must be auto or cpu.'
[[ $HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS == auto || $HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS == off ]] || die 'VIDEO_GPU_FILTERS must be auto or off.'
[[ $HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE =~ ^(0|[1-9][0-9]{0,2})$ ]] || die 'VIDEO_CUDA_DEVICE must be a GPU index from 0 to 999.'
export HARDCORE_ARCHIVE_CALIBRATION_POLICY_INHERITED=1

# Read enough flags before argument parsing to decide whether an inhibitor is
# useful. Help and analysis-only runs do not need sleep protection.
PRE_ALLOW_SLEEP=false
PRE_NO_WORK=false
for arg in "$@"; do
    case "$arg" in
        --allow-sleep) PRE_ALLOW_SLEEP=true ;;
        --analyze-only|-h|--help|--version) PRE_NO_WORK=true ;;
    esac
done

if ! $PRE_ALLOW_SLEEP && ! $PRE_NO_WORK && \
   [[ ${HARDCORE_ARCHIVE_INHIBITED:-0} != 1 ]]; then
    SCRIPT_SOURCE=${BASH_SOURCE[0]}
    if [[ $SCRIPT_SOURCE == */* || -e $SCRIPT_SOURCE ]]; then
        SCRIPT_PATH=$(realpath -e -- "$SCRIPT_SOURCE" 2>/dev/null || true)
    else
        SCRIPT_PATH=$(command -v -- "$SCRIPT_SOURCE" 2>/dev/null || true)
    fi

    if [[ -n ${SCRIPT_PATH:-} ]] && platform_sleep_tool_available; then
        if [[ $PLATFORM_ID == macos ]]; then
            exec caffeinate -i -m env HARDCORE_ARCHIVE_INHIBITED=1 bash "$SCRIPT_PATH" "$@"
        else
            exec systemd-inhibit \
                --what=sleep:idle:handle-lid-switch \
                --who="$PROGRAM_NAME" \
                --why="Creating and verifying a high-compression archive" \
                --mode=block \
                env HARDCORE_ARCHIVE_INHIBITED=1 bash "$SCRIPT_PATH" "$@"
        fi
    else
        SLEEP_INHIBITOR_UNAVAILABLE=true
    fi
fi

[[ ${HARDCORE_ARCHIVE_INHIBITED:-0} == 1 ]] && SLEEP_PROTECTION_ACTIVE=true

while (( $# > 0 )); do
    case "$1" in
        --config)
            (( $# >= 2 )) || die "--config requires a file path."
            CONFIG_FILE=$2
            shift 2
            ;;
        --config=*)
            CONFIG_FILE=${1#*=}
            shift
            ;;
        --no-config)
            CONFIG_ENABLED=false
            shift
            ;;
        --batch)
            BATCH_MODE=true
            shift
            ;;
        --inspect)
            COMMAND_MODE="inspect"
            shift
            ;;
        --restore)
            COMMAND_MODE="restore"
            shift
            ;;
        --no-nested-repack)
            NESTED_REPACK=false
            shift
            ;;
        --nested-max-depth)
            (( $# >= 2 )) || die "--nested-max-depth requires a non-negative integer."
            NESTED_MAX_DEPTH=$2
            shift 2
            ;;
        --nested-max-depth=*)
            NESTED_MAX_DEPTH=${1#*=}
            shift
            ;;
        --remove-source)
            REMOVE_SOURCE=true
            shift
            ;;
        --allow-sleep)
            ALLOW_SLEEP=true
            shift
            ;;
        --analyze-only)
            ANALYZE_ONLY=true
            shift
            ;;
        --force)
            FORCE=true
            shift
            ;;
        -y|--yes)
            ASSUME_YES=true
            shift
            ;;
        --dictionary)
            (( $# >= 2 )) || die "--dictionary requires a value."
            DICTIONARY_OVERRIDE=$2
            shift 2
            ;;
        --dictionary=*)
            DICTIONARY_OVERRIDE=${1#*=}
            shift
            ;;
        --threads)
            (( $# >= 2 )) || die "--threads requires a value."
            THREADS_OVERRIDE=$2
            shift 2
            ;;
        --threads=*)
            THREADS_OVERRIDE=${1#*=}
            shift
            ;;
        --effort)
            (( $# >= 2 )) || die "--effort requires practical, extreme, or insane."
            EFFORT=${2,,}
            EFFORT_EXPLICIT=true
            shift 2
            ;;
        --effort=*)
            EFFORT=${1#*=}
            EFFORT=${EFFORT,,}
            EFFORT_EXPLICIT=true
            shift
            ;;
        --search-cycles)
            (( $# >= 2 )) || die "--search-cycles requires a value."
            SEARCH_CYCLES=$2
            SEARCH_CYCLES_EXPLICIT=true
            shift 2
            ;;
        --search-cycles=*)
            SEARCH_CYCLES=${1#*=}
            SEARCH_CYCLES_EXPLICIT=true
            shift
            ;;
        --mc-auto)
            MC_AUTO=true
            MC_AUTO_EXPLICIT=true
            shift
            ;;
        --no-mc-auto)
            MC_AUTO=false
            MC_AUTO_EXPLICIT=true
            shift
            ;;
        --progress-interval)
            (( $# >= 2 )) || die "--progress-interval requires a value."
            PROGRESS_INTERVAL=$2
            shift 2
            ;;
        --progress-interval=*)
            PROGRESS_INTERVAL=${1#*=}
            shift
            ;;
        --no-video-transcode)
            VIDEO_TRANSCODE=false
            shift
            ;;
        --video-codec)
            (( $# >= 2 )) || die "--video-codec requires av1 or hevc."
            VIDEO_CODEC=${2,,}
            shift 2
            ;;
        --video-codec=*)
            VIDEO_CODEC=${1#*=}
            VIDEO_CODEC=${VIDEO_CODEC,,}
            shift
            ;;
        --video-encoder)
            (( $# >= 2 )) || die "--video-encoder requires an FFmpeg encoder name."
            VIDEO_ENCODER=$2
            shift 2
            ;;
        --video-encoder=*)
            VIDEO_ENCODER=${1#*=}
            shift
            ;;
        --video-sequential)
            VIDEO_PARALLEL=false
            VIDEO_PARALLEL_EXPLICIT=true
            shift
            ;;
        --video-no-scale)
            VIDEO_NO_SCALE=true
            shift
            ;;
        --video-no-denoise)
            VIDEO_NO_DENOISE=true
            shift
            ;;
        --video-copy-audio)
            VIDEO_COPY_AUDIO=true
            shift
            ;;
        --video-special-policy)
            (( $# >= 2 )) || die "--video-special-policy requires ask, preserve, convert, or omit."
            VIDEO_SPECIAL_POLICY=${2,,}
            shift 2
            ;;
        --video-special-policy=*)
            VIDEO_SPECIAL_POLICY=${1#*=}
            VIDEO_SPECIAL_POLICY=${VIDEO_SPECIAL_POLICY,,}
            shift
            ;;
        --video-min-vmaf)
            (( $# >= 2 )) || die "--video-min-vmaf requires a VMAF score."
            VIDEO_MIN_VMAF=$2
            shift 2
            ;;
        --video-min-vmaf=*)
            VIDEO_MIN_VMAF=${1#*=}
            shift
            ;;
        --video-min-savings)
            (( $# >= 2 )) || die "--video-min-savings requires a percentage."
            VIDEO_MIN_SAVINGS_PERCENT=$2
            shift 2
            ;;
        --video-min-savings=*)
            VIDEO_MIN_SAVINGS_PERCENT=${1#*=}
            shift
            ;;
        --video-no-preflight)
            VIDEO_PREFLIGHT=false
            shift
            ;;
        --no-video-manifest)
            VIDEO_WRITE_MANIFEST=false
            shift
            ;;
        --no-image-optimize)
            IMAGE_OPTIMIZE=false
            shift
            ;;
        --image-mode)
            (( $# >= 2 )) || die "--image-mode requires maximum, balanced, or fast."
            IMAGE_MODE=${2,,}
            shift 2
            ;;
        --image-mode=*)
            IMAGE_MODE=${1#*=}
            IMAGE_MODE=${IMAGE_MODE,,}
            shift
            ;;
        --image-jobs)
            (( $# >= 2 )) || die "--image-jobs requires auto or a positive integer."
            IMAGE_JOBS=${2,,}
            shift 2
            ;;
        --image-jobs=*)
            IMAGE_JOBS=${1#*=}
            IMAGE_JOBS=${IMAGE_JOBS,,}
            shift
            ;;
        --verify)
            (( $# >= 2 )) || die "--verify requires auto, integrity, hashes, or extract."
            VERIFY_MODE=${2,,}
            shift 2
            ;;
        --verify=*)
            VERIFY_MODE=${1#*=}
            VERIFY_MODE=${VERIFY_MODE,,}
            shift
            ;;
        --work-dir)
            (( $# >= 2 )) || die "--work-dir requires a directory."
            WORK_DIR_OVERRIDE=$2
            shift 2
            ;;
        --work-dir=*)
            WORK_DIR_OVERRIDE=${1#*=}
            shift
            ;;
        --resume)
            RESUME_ENABLED=true
            shift
            ;;
        --no-resume)
            RESUME_ENABLED=false
            shift
            ;;
        --keep-work)
            KEEP_WORK=true
            shift
            ;;
        --cross-filesystems)
            CROSS_FILESYSTEMS=true
            ONE_FILE_SYSTEM=false
            shift
            ;;
        --one-file-system)
            CROSS_FILESYSTEMS=false
            ONE_FILE_SYSTEM=true
            shift
            ;;
        --batch-root-files)
            (( $# >= 2 )) || die "--batch-root-files requires archive, ignore, or error."
            BATCH_ROOT_FILES=${2,,}
            shift 2
            ;;
        --batch-root-files=*)
            BATCH_ROOT_FILES=${1#*=}
            BATCH_ROOT_FILES=${BATCH_ROOT_FILES,,}
            shift
            ;;
        --batch-jobs)
            (( $# >= 2 )) || die "--batch-jobs requires auto or a positive integer."
            BATCH_JOBS=${2,,}
            shift 2
            ;;
        --batch-jobs=*)
            BATCH_JOBS=${1#*=}
            BATCH_JOBS=${BATCH_JOBS,,}
            shift
            ;;
        --retry-failed)
            RETRY_FAILED=true
            shift
            ;;
        --no-retry-failed)
            RETRY_FAILED=false
            shift
            ;;
        --report)
            WRITE_REPORT=true
            shift
            ;;
        --no-report)
            WRITE_REPORT=false
            shift
            ;;
        --video-mode)
            (( $# >= 2 )) || die "--video-mode requires maximum, balanced, or fast."
            VIDEO_MODE=${2,,}
            shift 2
            ;;
        --video-mode=*)
            VIDEO_MODE=${1#*=}
            VIDEO_MODE=${VIDEO_MODE,,}
            shift
            ;;
        --video-parallel)
            VIDEO_PARALLEL=true
            VIDEO_PARALLEL_EXPLICIT=true
            shift
            ;;
        --quality-check)
            (( $# >= 2 )) || die "--quality-check requires auto, off, or required."
            QUALITY_CHECK=${2,,}
            shift 2
            ;;
        --quality-check=*)
            QUALITY_CHECK=${1#*=}
            QUALITY_CHECK=${QUALITY_CHECK,,}
            shift
            ;;
        --version)
            printf '%s %s\n' "$PROGRAM_NAME" "$SCRIPT_VERSION"
            exit 0
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        --)
            shift
            POSITIONAL+=("$@")
            break
            ;;
        -*)
            die "Unknown option: $1"
            ;;
        *)
            POSITIONAL+=("$1")
            shift
            ;;
    esac
done

(( ${#POSITIONAL[@]} >= 1 && ${#POSITIONAL[@]} <= 2 )) || {
    usage >&2
    exit 1
}

# Read-only archive modes do not encode video. In particular, the public
# default VIDEO_CODEC=auto need not resolve to a hardware codec for restoration.
if [[ $COMMAND_MODE == inspect ]]; then
    dependency_preflight_inspect
    inspect_existing_archive
    exit 0
elif [[ $COMMAND_MODE == restore ]]; then
    dependency_preflight_restore "${POSITIONAL[0]}"
    restore_existing_archive
    exit 0
fi

case "$EFFORT" in
    practical|extreme|insane) ;;
    *) die "Effort must be practical, extreme, or insane." ;;
esac

case "$VIDEO_CODEC" in
    av1|hevc) ;;
    *) die "Video codec must be av1 or hevc." ;;
esac
case "$VIDEO_MODE" in
    maximum|balanced|fast) ;;
    *) die "Video mode must be maximum, balanced, or fast." ;;
esac
case "$VIDEO_SPECIAL_POLICY" in
    ask|preserve|convert|omit) ;;
    *) die "Special-video policy must be ask, preserve, convert, or omit." ;;
esac
case "$IMAGE_MODE" in
    maximum|balanced|fast) ;;
    *) die "Image mode must be maximum, balanced, or fast." ;;
esac
if [[ $IMAGE_JOBS != auto ]]; then
    [[ $IMAGE_JOBS =~ ^[1-9][0-9]*$ ]] || die "Image jobs must be auto or a positive integer."
fi
case "$VERIFY_MODE" in
    auto|integrity|hashes|extract) ;;
    *) die "Verification mode must be auto, integrity, hashes, or extract." ;;
esac
case "$BATCH_ROOT_FILES" in
    archive|ignore|error) ;;
    *) die "Batch root-file policy must be archive, ignore, or error." ;;
esac
case "$QUALITY_CHECK" in
    auto|off|required) ;;
    *) die "Quality check must be auto, off, or required." ;;
esac
if [[ $BATCH_JOBS != auto ]]; then
    [[ $BATCH_JOBS =~ ^[1-9][0-9]*$ ]] || die "Batch jobs must be auto or a positive integer."
fi
[[ $NESTED_MAX_DEPTH =~ ^[0-9]+$ ]] || die "Nested maximum depth must be a non-negative integer."

if [[ $VERIFY_MODE == auto ]]; then
    VERIFY_MODE_EFFECTIVE=hashes
else
    VERIFY_MODE_EFFECTIVE=$VERIFY_MODE
fi
if $REMOVE_SOURCE && [[ $VERIFY_MODE_EFFECTIVE != hashes && $VERIFY_MODE_EFFECTIVE != extract ]]; then
    die "--remove-source requires --verify hashes or --verify extract; integrity-only verification is not sufficient for deletion."
fi

# Exact match-cycle requests always take precedence. An explicit effort preset
# disables sample tuning unless --mc-auto was explicitly requested as well.
if $SEARCH_CYCLES_EXPLICIT; then
    MC_AUTO=false
elif $EFFORT_EXPLICIT && ! $MC_AUTO_EXPLICIT; then
    MC_AUTO=false
fi

if ! $SEARCH_CYCLES_EXPLICIT; then
    case "$EFFORT" in
        practical) SEARCH_CYCLES=0 ;;
        extreme)   SEARCH_CYCLES=500 ;;
        insane)    SEARCH_CYCLES=1000 ;;
    esac
fi

[[ $SEARCH_CYCLES =~ ^[0-9]+$ ]] || die "Search cycles must be an integer."
(( SEARCH_CYCLES >= 0 && SEARCH_CYCLES <= 1000000000 )) || \
    die "Search cycles must be between 0 and 1000000000."
[[ $PROGRESS_INTERVAL =~ ^[0-9]+$ ]] || die "Progress interval must be a non-negative integer."
(( PROGRESS_INTERVAL <= 86400 )) || die "Progress interval is unreasonably large."
[[ $VIDEO_MIN_SAVINGS_PERCENT =~ ^[0-9]+([.][0-9]+)?$ ]] ||     die "Video minimum savings must be a non-negative number."
LC_NUMERIC=C awk -v p="$VIDEO_MIN_SAVINGS_PERCENT" 'BEGIN {exit !(p >= 0 && p <= 100)}' ||     die "Video minimum savings must be between 0 and 100."
[[ $VIDEO_MIN_VMAF =~ ^[0-9]+([.][0-9]+)?$ ]] || die "Video minimum VMAF must be numeric."
LC_NUMERIC=C awk -v v="$VIDEO_MIN_VMAF" 'BEGIN {exit !(v >= 0 && v <= 100)}' || die "Video minimum VMAF must be between 0 and 100."

dependency_preflight_create_critical

resolve_current_script() {
    local source_path=${BASH_SOURCE[0]} resolved=''

    if [[ $source_path == */* || -e $source_path ]]; then
        resolved=$(realpath -e -- "$source_path" 2>/dev/null || true)
    else
        resolved=$(command -v -- "$source_path" 2>/dev/null || true)
    fi

    [[ -n $resolved ]] || return 1
    printf '%s\n' "$resolved"
}

build_batch_child_arguments() {
    BATCH_CHILD_ARGS=()

    $REMOVE_SOURCE && BATCH_CHILD_ARGS+=(--remove-source)
    $ALLOW_SLEEP && BATCH_CHILD_ARGS+=(--allow-sleep)
    $ANALYZE_ONLY && BATCH_CHILD_ARGS+=(--analyze-only)
    $FORCE && BATCH_CHILD_ARGS+=(--force)
    $ASSUME_YES && BATCH_CHILD_ARGS+=(--yes)

    [[ -n $DICTIONARY_OVERRIDE ]] && BATCH_CHILD_ARGS+=(--dictionary "$DICTIONARY_OVERRIDE")
    [[ -n $THREADS_OVERRIDE ]] && BATCH_CHILD_ARGS+=(--threads "$THREADS_OVERRIDE")

    if $SEARCH_CYCLES_EXPLICIT; then
        BATCH_CHILD_ARGS+=(--search-cycles "$SEARCH_CYCLES")
    else
        BATCH_CHILD_ARGS+=(--effort "$EFFORT")
        if $MC_AUTO; then
            BATCH_CHILD_ARGS+=(--mc-auto)
        else
            BATCH_CHILD_ARGS+=(--no-mc-auto)
        fi
    fi

    BATCH_CHILD_ARGS+=(--progress-interval "$PROGRESS_INTERVAL")

    $VIDEO_TRANSCODE || BATCH_CHILD_ARGS+=(--no-video-transcode)
    BATCH_CHILD_ARGS+=(--video-codec "$VIDEO_CODEC")
    [[ -n $VIDEO_ENCODER ]] && BATCH_CHILD_ARGS+=(--video-encoder "$VIDEO_ENCODER")
    $VIDEO_PARALLEL || BATCH_CHILD_ARGS+=(--video-sequential)
    $VIDEO_NO_SCALE && BATCH_CHILD_ARGS+=(--video-no-scale)
    $VIDEO_NO_DENOISE && BATCH_CHILD_ARGS+=(--video-no-denoise)
    $VIDEO_COPY_AUDIO && BATCH_CHILD_ARGS+=(--video-copy-audio)
    BATCH_CHILD_ARGS+=(--video-special-policy "${VIDEO_SPECIAL_POLICY:-ask}")
    BATCH_CHILD_ARGS+=(--video-min-savings "$VIDEO_MIN_SAVINGS_PERCENT")
    BATCH_CHILD_ARGS+=(--video-min-vmaf "$VIDEO_MIN_VMAF")
    $VIDEO_PREFLIGHT || BATCH_CHILD_ARGS+=(--video-no-preflight)
    $VIDEO_WRITE_MANIFEST || BATCH_CHILD_ARGS+=(--no-video-manifest)
    $IMAGE_OPTIMIZE || BATCH_CHILD_ARGS+=(--no-image-optimize)
    $NESTED_REPACK || BATCH_CHILD_ARGS+=(--no-nested-repack)
    BATCH_CHILD_ARGS+=(--nested-max-depth "$NESTED_MAX_DEPTH")
    BATCH_CHILD_ARGS+=(--image-mode "$IMAGE_MODE" --image-jobs "$IMAGE_JOBS")
    BATCH_CHILD_ARGS+=(--verify "$VERIFY_MODE_EFFECTIVE")
    [[ -n $WORK_DIR_OVERRIDE ]] && BATCH_CHILD_ARGS+=(--work-dir "$WORK_DIR_OVERRIDE")
    $RESUME_ENABLED && BATCH_CHILD_ARGS+=(--resume) || BATCH_CHILD_ARGS+=(--no-resume)
    $KEEP_WORK && BATCH_CHILD_ARGS+=(--keep-work)
    $CROSS_FILESYSTEMS && BATCH_CHILD_ARGS+=(--cross-filesystems) || BATCH_CHILD_ARGS+=(--one-file-system)
    $WRITE_REPORT && BATCH_CHILD_ARGS+=(--report) || BATCH_CHILD_ARGS+=(--no-report)
    BATCH_CHILD_ARGS+=(--video-mode "$VIDEO_MODE" --quality-check "$QUALITY_CHECK")
    if $VIDEO_PARALLEL_EXPLICIT; then
        $VIDEO_PARALLEL && BATCH_CHILD_ARGS+=(--video-parallel) || BATCH_CHILD_ARGS+=(--video-sequential)
    fi
    $CONFIG_ENABLED || BATCH_CHILD_ARGS+=(--no-config)
}

run_batch_mode() {
    local parent_input=${POSITIONAL[0]} output_input=${POSITIONAL[1]:-}
    local parent output_dir script_path child child_name archive rc
    local loose_files=0 total=0 succeeded=0 failed=0 skipped=0 analyzed=0
    local started=$SECONDS batch_elapsed parent_name root_stage_parent='' root_stage='' root_snapshot_before='' root_snapshot_after=''
    local jobs=1 active=0 batch_lock_file batch_lock_fd state_status
    local -a children=() sources=() names=() archives=() kinds=() item_args=()
    local -a plan_dict=() plan_ram=() plan_cpu=() plan_gpu=() plan_image_jobs=() plan_video_parallel=() plan_source_dev=() plan_output_dev=()
    local -a failed_names=() skipped_names=() pids=() pid_names=() pid_sources=() pid_archives=() pid_kinds=() pid_logs=() pid_indexes=()
    local logs_dir='' item_log='' item_diagnostics='' item_slug='' index total_index

    [[ -d $parent_input ]] || die "Batch parent is not a directory: $parent_input"
    parent=$(realpath -e -- "$parent_input")
    parent_name=$(basename -- "$parent")
    if [[ -n $output_input ]]; then
        output_dir=$(realpath -m -- "$output_input")
    else
        output_dir=$(realpath -m -- "$(dirname -- "$parent")/${parent_name}-archives")
        OUTPUT_WAS_AUTOMATIC=true
    fi

    [[ ! -e $output_dir || -d $output_dir ]] || \
        die "Batch output path is not a directory: $output_dir"
    if [[ $output_dir == "$parent" || $output_dir == "$parent/"* ]]; then
        die "Batch output directory must be outside the parent folder to prevent self-inclusion."
    fi

    mkdir -p -- "$output_dir"
    logs_dir="${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-$output_dir/hardcore-archive-logs}/batch"
    mkdir -p -- "$logs_dir"
    script_path=$(resolve_current_script) || \
        die "Could not locate the running script for batch child jobs."

    if command -v flock >/dev/null 2>&1; then
        batch_lock_file="$output_dir/.hardcore-batch.lock"
        exec {batch_lock_fd}>"$batch_lock_file"
        flock -n "$batch_lock_fd" || die "Another batch process is already using: $output_dir"
        printf 'PID=%s\nStarted=%s\nParent=%s\n' "$$" "$(date --iso-8601=seconds)" "$parent" > "$batch_lock_file"
        BATCH_LOCK_FILE_GLOBAL=$batch_lock_file
        BATCH_LOCK_FD_GLOBAL=$batch_lock_fd
    fi

    BATCH_STATE_FILE="$output_dir/.hardcore-batch-state.tsv"
    touch -- "$BATCH_STATE_FILE"

    snapshot_root_files() {
        local destination=$1 entry target
        : > "$destination"
        while IFS= read -r -d '' entry; do
            if [[ -L $entry ]]; then
                target=$(readlink -- "$entry" || true)
                printf 'l	%s	%s
' "$(basename -- "$entry")" "$target"
            else
                printf 'f	%s	%s	' "$(basename -- "$entry")" "$(stat -c '%s:%Y' -- "$entry")"
                sha256sum -- "$entry" | awk '{print $1}'
            fi
        done < <(find "$parent" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0 | LC_ALL=C sort -z)
    }

    while IFS= read -r -d '' child; do
        child_name=$(basename -- "$child")
        children+=("$child")
        sources+=("$child")
        names+=("$child_name")
        archives+=("$output_dir/${child_name}.7z")
        kinds+=(subfolder)
    done < <(find "$parent" -mindepth 1 -maxdepth 1 -type d -print0 | LC_ALL=C sort -z)

    loose_files=$(find "$parent" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -printf '.' | wc -c)
    if (( loose_files > 0 )); then
        case $BATCH_ROOT_FILES in
            error)
                die "$loose_files loose root file(s) exist. Use --batch-root-files archive or ignore."
                ;;
            ignore)
                warn "$loose_files loose root file(s) will be ignored by explicit policy."
                ;;
            archive)
                root_snapshot_before=$(mktemp)
                root_snapshot_after=$(mktemp)
                snapshot_root_files "$root_snapshot_before"
                if root_stage_parent=$(mktemp -d "$(dirname -- "$parent")/.${parent_name}-root-stage.XXXXXX" 2>/dev/null); then
                    :
                else
                    mkdir -p -- "$PLATFORM_CACHE_HOME"
                    root_stage_parent=$(mktemp -d "$PLATFORM_CACHE_HOME/hardcore-archive-batch-root.XXXXXX")
                fi
                root_stage="$root_stage_parent/${parent_name}-root-files"
                mkdir -p -- "$root_stage"
                while IFS= read -r -d '' child; do
                    if [[ -L $child ]]; then
                        cp -a -- "$child" "$root_stage/"
                    elif ! ln -- "$child" "$root_stage/$(basename -- "$child")" 2>/dev/null; then
                        cp --reflink=auto --preserve=all -- "$child" "$root_stage/"
                    fi
                done < <(find "$parent" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0)
                sources+=("$root_stage")
                names+=("${parent_name}-root-files")
                archives+=("$output_dir/${parent_name}-root-files.7z")
                kinds+=(root-files)
                ;;
        esac
    fi

    total=${#sources[@]}
    (( total > 0 )) || die "No immediate subfolders or archivable root files were found in: $parent"

    # Aggregate only the dependency-relevant media/container types once so the
    # parent can present a single optional-dependency decision before any child
    # analysis or parallel work starts.
    local dependency_video_count=0 dependency_jpeg_count=0 dependency_png_count=0 dependency_nested_count=0 dependency_path
    local -a dependency_find_boundary=()
    $ONE_FILE_SYSTEM && dependency_find_boundary=(-xdev)
    for child in "${sources[@]}"; do
        while IFS= read -r -d '' dependency_path; do
            if is_video_path "$dependency_path"; then
                dependency_video_count=$((dependency_video_count + 1))
            elif $NESTED_REPACK && is_nested_archive_path "$dependency_path"; then
                dependency_nested_count=$((dependency_nested_count + 1))
            else
                case ${dependency_path,,} in
                    *.jpg|*.jpeg|*.jpe|*.jfif) dependency_jpeg_count=$((dependency_jpeg_count + 1)) ;;
                    *.png) dependency_png_count=$((dependency_png_count + 1)) ;;
                esac
            fi
        done < <(find "$child" "${dependency_find_boundary[@]}" -type f -print0)
    done
    dependency_preflight_create_optional "$dependency_video_count" "$dependency_jpeg_count"         "$dependency_png_count" "$dependency_nested_count" true

    build_batch_child_arguments

    # Pre-plan every child while the machine is idle. The selected dictionary
    # and image-worker count are then pinned for the real run, so concurrent
    # jobs never lower compression quality merely because another job started.
    local available_mib cpu_count ram_capacity_mib cpu_capacity max_parallel
    local plan_log plan_rc dict ram threads video_count image_count image_workers video_execution image_execution video_encoder
    local video_reserve image_reserve image_cpu cpu_cost gpu_cost src_dev dst_dev
    IFS=$'\t' read -r _batch_mem_total _batch_available_kib _batch_swap_total _batch_swap_free < <(platform_memory_kib)
    available_mib=$((_batch_available_kib / 1024))
    cpu_count=$(platform_cpu_threads)
    local quality_cpu=${HARDCORE_ARCHIVE_VIDEO_QUALITY_THREADS:-auto}
    if [[ $quality_cpu == auto ]]; then
        quality_cpu=$cpu_count
        (( quality_cpu > 8 )) && quality_cpu=8
    fi
    [[ $quality_cpu =~ ^([1-9]|[1-5][0-9]|6[0-4])$ ]] || die 'Invalid VIDEO_QUALITY_THREADS.'
    (( quality_cpu > cpu_count )) && quality_cpu=$cpu_count
    [[ $QUALITY_CHECK == off ]] && quality_cpu=0
    ram_capacity_mib=$((available_mib * 70 / 100))
    cpu_capacity=$((cpu_count - 2))
    (( cpu_capacity < 1 )) && cpu_capacity=1

    printf '\nPre-planning batch resources and pinning full-quality settings...\n'
    for ((index=0; index<total; index++)); do
        child=${sources[index]}
        archive=${archives[index]}
        item_slug=$(safe_slug "${names[index]}")
        item_diagnostics="$logs_dir/$((index + 1))-${item_slug:0:80}"
        mkdir -p -- "$item_diagnostics/planning"
        plan_log="$item_diagnostics/planning/run.log"
        plan_rc=0
        env HARDCORE_ARCHIVE_INHIBITED=1 HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1 LC_ALL=C \
            HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$item_diagnostics/planning" \
            HARDCORE_ARCHIVE_LIVE_LOG="$plan_log" \
            bash "$script_path" "${BATCH_CHILD_ARGS[@]}" --analyze-only --force --yes \
            "$child" "$archive" >"$plan_log" 2>&1 || plan_rc=$?
        printf '\nExit status: %s\n' "$plan_rc" >> "$plan_log"

        if (( plan_rc == 0 )); then
            dict=$(awk -F: '/^Dictionary:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$plan_log")
            ram=$(awk -F: '/^Estimated compression RAM:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$plan_log")
            threads=$(awk -F: '/^Compression threads:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$plan_log")
            video_count=$(awk -F: '/^Video files detected:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$plan_log")
            image_count=$(awk -F: '/^Image files detected:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$plan_log")
            image_workers=$(awk -F/ '/^Image mode\/workers:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$plan_log")
            video_execution=$(awk -F: '/^Video execution:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$plan_log")
            image_execution=$(awk -F: '/^Image execution:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$plan_log")
            video_encoder=$(awk -F: '/^Video encoder:/ {gsub(/^[[:space:]]+/,"",$2); print $2; exit}' "$plan_log")
            video_reserve=$(awk -F: '/^RAM reserved for video:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$plan_log")
            image_reserve=$(awk -F: '/^RAM reserved for images:/ {gsub(/[^0-9]/,"",$2); print $2; exit}' "$plan_log")
            [[ $dict =~ ^[0-9]+$ ]] || dict=4
            [[ $ram =~ ^[0-9]+$ ]] || ram=$ram_capacity_mib
            [[ $threads =~ ^[0-9]+$ ]] || threads=2
            [[ $video_count =~ ^[0-9]+$ ]] || video_count=0
            [[ $image_count =~ ^[0-9]+$ ]] || image_count=0
            [[ $image_workers =~ ^[0-9]+$ ]] || image_workers=0
            [[ $video_reserve =~ ^[0-9]+$ ]] || video_reserve=0
            [[ $image_reserve =~ ^[0-9]+$ ]] || image_reserve=0
            ram=$((ram + video_reserve + image_reserve))

            image_cpu=$((image_workers * 2))
            if [[ $image_execution == Parallel* ]]; then
                cpu_cost=$((threads + image_cpu))
            else
                cpu_cost=$threads
                (( image_cpu > cpu_cost )) && cpu_cost=$image_cpu
            fi
            gpu_cost=0
            if (( video_count > 0 )); then
                if [[ $video_execution == Parallel* ]]; then
                    if [[ $video_encoder == lib* ]]; then
                        # Forced software-video parallelism is CPU intensive.
                        cpu_cost=$cpu_capacity
                    else
                        # Hardware encoding still needs CPU VMAF workers plus
                        # decode/control capacity during quality calibration.
                        cpu_cost=$((cpu_cost + quality_cpu + 2))
                        gpu_cost=1
                    fi
                else
                    # A sequential software encoder can consume the complete
                    # CPU during its video phase, so it gets an exclusive lane.
                    cpu_cost=$cpu_capacity
                    (( ram < 2048 )) && ram=2048
                fi
            fi
            (( cpu_cost < 1 )) && cpu_cost=1
            (( cpu_cost > cpu_capacity )) && cpu_cost=$cpu_capacity
        else
            warn "Could not pre-plan ${names[index]}; it will run alone and choose its own full-quality dictionary."
            dict=0
            ram=$ram_capacity_mib
            cpu_cost=$cpu_capacity
            gpu_cost=1
            image_workers=1
            video_execution=Sequential
        fi

        src_dev=$(storage_lane_key "$child")
        dst_dev=$(storage_lane_key "$output_dir")
        plan_dict[index]=$dict
        plan_ram[index]=$ram
        plan_cpu[index]=$cpu_cost
        plan_gpu[index]=$gpu_cost
        plan_image_jobs[index]=$image_workers
        [[ $video_execution == Parallel* ]] && plan_video_parallel[index]=true || plan_video_parallel[index]=false
        plan_source_dev[index]=$src_dev
        plan_output_dev[index]=$dst_dev

        printf '  %-30s dict=%4s MiB  RAM=%5s MiB  CPU=%2s  GPU=%s  image-workers=%s\n' \
            "${names[index]}" "$dict" "$ram" "$cpu_cost" "$gpu_cost" "$image_workers"
    done

    if [[ $BATCH_JOBS == auto ]]; then
        max_parallel=$total
        (( max_parallel > 4 )) && max_parallel=4
    else
        max_parallel=$BATCH_JOBS
        (( max_parallel > total )) && max_parallel=$total
        (( max_parallel > 8 )) && warn "More than eight requested batch jobs are capped by the resource scheduler."
        (( max_parallel > 8 )) && max_parallel=8
    fi
    (( max_parallel < 1 )) && max_parallel=1
    jobs=$max_parallel
    printf '\nBatch archive plan\n'
    printf '════════════════════════════════════════════════════════════════\n'
    printf 'Parent folder:           %s\n' "$parent"
    printf 'Output directory:        %s%s\n' "$output_dir" "$($OUTPUT_WAS_AUTOMATIC && printf ' (automatic)' || true)"
    printf 'Immediate subfolders:    %s\n' "${#children[@]}"
    printf 'Loose root files:        %s (%s)\n' "$loose_files" "$BATCH_ROOT_FILES"
    printf 'Batch jobs:              %s\n' "$jobs"
    printf 'RAM scheduling budget:   %s MiB
' "$ram_capacity_mib"
    printf 'CPU scheduling budget:   %s logical threads
' "$cpu_capacity"
    printf 'GPU-video lanes:         1
'
    printf 'Same-device job limit:   2
'
    printf 'Retry failed items:      %s\n' "$RETRY_FAILED"
printf 'Dependency preflight:    %s\n' "$DEPENDENCY_PREFLIGHT_SUMMARY"
    if $REMOVE_SOURCE; then
        printf 'After verification:      Remove each successful source item\n'
    else
        printf 'After verification:      Keep every source item\n'
    fi
    printf '════════════════════════════════════════════════════════════════\n'

    record_state() {
        local status=$1 name=$2 source=$3 destination=$4 result=${5:-}
        printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$(date --iso-8601=seconds)" "$status" "$name" "$source" "$destination" "$result" \
            >> "$BATCH_STATE_FILE"
    }

    last_state() {
        local name=$1
        awk -F '\t' -v n="$name" '$3==n {s=$2} END{print s}' "$BATCH_STATE_FILE"
    }

    finish_item() {
        local item_rc=$1 name=$2 source=$3 destination=$4 kind=$5 log=${6:-}
        if (( item_rc == 0 )) && [[ $kind == root-files ]]; then
            snapshot_root_files "$root_snapshot_after"
            if ! cmp -s -- "$root_snapshot_before" "$root_snapshot_after"; then
                warn "Loose root files changed while their staged archive was being created."
                if [[ -e $destination ]]; then
                    changed_name="${destination%.7z}.source-changed-$(date '+%Y%m%d-%H%M%S').7z"
                    mv -- "$destination" "$changed_name" 2>/dev/null || true
                fi
                item_rc=4
            fi
        fi
        if (( item_rc == 0 )); then
            if $ANALYZE_ONLY; then
                analyzed=$((analyzed + 1))
                record_state analyzed "$name" "$source" "$destination"
            else
                succeeded=$((succeeded + 1))
                record_state success "$name" "$source" "$destination"
                if [[ $kind == root-files && $REMOVE_SOURCE == true ]]; then
                    while IFS= read -r -d '' child; do
                        rm -f -- "$child"
                    done < <(find "$parent" -mindepth 1 -maxdepth 1 \( -type f -o -type l \) -print0)
                fi
            fi
        else
            failed=$((failed + 1))
            failed_names+=("$name (exit $item_rc${log:+; log $log})")
            record_state failed "$name" "$source" "$destination" "exit=$item_rc${log:+;log=$log}"
            warn "Batch item failed with exit code $item_rc; continuing with the next item."
        fi
    }

    local active_ram=0 active_cpu=0 active_gpu=0
    declare -A active_device_count=()

    can_launch_index() {
        local idx=$1 src dst src_count dst_count
        src=${plan_source_dev[idx]}
        dst=${plan_output_dev[idx]}
        src_count=${active_device_count[$src]:-0}
        dst_count=${active_device_count[$dst]:-0}
        (( active < jobs )) || return 1
        (( active == 0 )) && return 0
        (( active_ram + plan_ram[idx] <= ram_capacity_mib )) || return 1
        (( active_cpu + plan_cpu[idx] <= cpu_capacity )) || return 1
        (( active_gpu + plan_gpu[idx] <= 1 )) || return 1
        (( src_count < 2 )) || return 1
        if [[ $dst != "$src" ]]; then
            (( dst_count < 2 )) || return 1
        fi
        return 0
    }

    reserve_index_resources() {
        local idx=$1 src dst
        src=${plan_source_dev[idx]}
        dst=${plan_output_dev[idx]}
        active_ram=$((active_ram + plan_ram[idx]))
        active_cpu=$((active_cpu + plan_cpu[idx]))
        active_gpu=$((active_gpu + plan_gpu[idx]))
        active_device_count[$src]=$(( ${active_device_count[$src]:-0} + 1 ))
        if [[ $dst != "$src" ]]; then
            active_device_count[$dst]=$(( ${active_device_count[$dst]:-0} + 1 ))
        fi
    }

    release_index_resources() {
        local idx=$1 src dst
        src=${plan_source_dev[idx]}
        dst=${plan_output_dev[idx]}
        active_ram=$((active_ram - plan_ram[idx]))
        active_cpu=$((active_cpu - plan_cpu[idx]))
        active_gpu=$((active_gpu - plan_gpu[idx]))
        active_device_count[$src]=$(( ${active_device_count[$src]:-1} - 1 ))
        if [[ $dst != "$src" ]]; then
            active_device_count[$dst]=$(( ${active_device_count[$dst]:-1} - 1 ))
        fi
    }

    wait_one_parallel() {
        local chosen=-1 i pid item_rc=0 idx
        # Reap whichever child finishes first instead of waiting for the oldest
        # job. This keeps the resource scheduler busy when workloads differ.
        while (( chosen < 0 )); do
            for i in "${!pids[@]}"; do
                pid=${pids[i]}
                if ! kill -0 "$pid" 2>/dev/null; then
                    chosen=$i
                    break
                fi
            done
            (( chosen >= 0 )) || sleep 0.25
        done

        pid=${pids[chosen]}
        idx=${pid_indexes[chosen]}
        set +e
        wait "$pid"
        item_rc=$?
        set -e
        printf '\nExit status: %s\n' "$item_rc" >> "${pid_logs[chosen]}"
        finish_item "$item_rc" "${pid_names[chosen]}" "${pid_sources[chosen]}"             "${pid_archives[chosen]}" "${pid_kinds[chosen]}" "${pid_logs[chosen]}"
        release_index_resources "$idx"

        unset 'pids[chosen]' 'pid_names[chosen]' 'pid_sources[chosen]'             'pid_archives[chosen]' 'pid_kinds[chosen]' 'pid_logs[chosen]' 'pid_indexes[chosen]'
        pids=("${pids[@]}")
        pid_names=("${pid_names[@]}")
        pid_sources=("${pid_sources[@]}")
        pid_archives=("${pid_archives[@]}")
        pid_kinds=("${pid_kinds[@]}")
        pid_logs=("${pid_logs[@]}")
        pid_indexes=("${pid_indexes[@]}")
        active=$((active - 1))
    }


    for ((index=0; index<total; index++)); do
        child=${sources[index]}
        child_name=${names[index]}
        archive=${archives[index]}
        kind=${kinds[index]}
        total_index=$((index + 1))

        [[ $child_name != *$'\n'* ]] || {
            warn "Skipping an item whose name contains a newline: $child"
            skipped=$((skipped + 1))
            skipped_names+=("$child_name")
            record_state skipped "$child_name" "$child" "$archive" newline-name
            continue
        }

        state_status=$(last_state "$child_name")
        if [[ $state_status == failed && $RETRY_FAILED != true ]]; then
            warn "Skipping previously failed item because --no-retry-failed is active: $child_name"
            skipped=$((skipped + 1))
            skipped_names+=("$child_name")
            continue
        fi

        printf '\n\nBatch item %s/%s\n' "$total_index" "$total"
        printf '════════════════════════════════════════════════════════════════\n'
        printf 'Source:  %s\n' "$child"
        printf 'Archive: %s\n' "$archive"
        printf '════════════════════════════════════════════════════════════════\n'

        if [[ -e $archive && $FORCE != true ]]; then
            warn "Skipping because the output already exists; use --force to replace it after validation: $archive"
            skipped=$((skipped + 1))
            skipped_names+=("$child_name")
            record_state skipped "$child_name" "$child" "$archive" output-exists
            continue
        fi

        item_args=("${BATCH_CHILD_ARGS[@]}" --yes)
        (( plan_dict[index] > 0 )) && item_args+=(--dictionary "${plan_dict[index]}m")
        (( plan_image_jobs[index] > 0 )) && item_args+=(--image-jobs "${plan_image_jobs[index]}")
        if [[ ${plan_video_parallel[index]} == true ]]; then
            item_args+=(--video-parallel)
        else
            item_args+=(--video-sequential)
        fi

        item_slug=$(safe_slug "$child_name")
        item_diagnostics="$logs_dir/$((index + 1))-${item_slug:0:80}"
        item_log="$item_diagnostics/run.log"
        printf 'Batch item log: %s\n' "$item_log"
        if (( jobs == 1 )); then
            rc=0
            env HARDCORE_ARCHIVE_INHIBITED="${HARDCORE_ARCHIVE_INHIBITED:-0}" HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1 \
                HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$item_diagnostics" HARDCORE_ARCHIVE_LIVE_LOG="$item_log" \
                bash "$script_path" "${item_args[@]}" "$child" "$archive" 2>&1 | tee "$item_log" || rc=$?
            printf '\nExit status: %s\n' "$rc" >> "$item_log"
            finish_item "$rc" "$child_name" "$child" "$archive" "$kind" "$item_log"
        else
            while ! can_launch_index "$index"; do
                wait_one_parallel
            done
            printf 'Launching with pinned resources: dictionary=%s MiB, RAM=%s MiB, CPU=%s, GPU=%s\n' \
                "${plan_dict[index]}" "${plan_ram[index]}" "${plan_cpu[index]}" "${plan_gpu[index]}"
            env HARDCORE_ARCHIVE_INHIBITED="${HARDCORE_ARCHIVE_INHIBITED:-0}" HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1 \
                HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$item_diagnostics" HARDCORE_ARCHIVE_LIVE_LOG="$item_log" \
                bash "$script_path" "${item_args[@]}" "$child" "$archive" >"$item_log" 2>&1 &
            pids+=("$!")
            BATCH_CHILD_PIDS+=("$!")
            pid_names+=("$child_name")
            pid_sources+=("$child")
            pid_archives+=("$archive")
            pid_kinds+=("$kind")
            pid_logs+=("$item_log")
            pid_indexes+=("$index")
            reserve_index_resources "$index"
            active=$((active + 1))
        fi
    done

    while (( active > 0 )); do wait_one_parallel; done

    [[ -n $root_stage_parent && -d $root_stage_parent ]] && rm -rf --one-file-system -- "$root_stage_parent"
    rm -f -- "$root_snapshot_before" "$root_snapshot_after"
    batch_elapsed=$((SECONDS - started))
    printf '\n\nBatch summary\n'
    printf '════════════════════════════════════════════════════════════════\n'
    printf 'Items found:             %s\n' "$total"
    if $ANALYZE_ONLY; then
        printf 'Analyzed successfully:   %s\n' "$analyzed"
    else
        printf 'Archives completed:      %s\n' "$succeeded"
    fi
    printf 'Skipped:                 %s\n' "$skipped"
    printf 'Failed:                  %s\n' "$failed"
    printf 'Elapsed:                 %s\n' "$(format_duration "$batch_elapsed")"
    printf 'State file:              %s\n' "$BATCH_STATE_FILE"
    printf '════════════════════════════════════════════════════════════════\n'

    (( skipped == 0 )) || { printf '\nSkipped items:\n'; printf '  %s\n' "${skipped_names[@]}"; }
    (( failed == 0 )) || { printf '\nFailed items:\n' >&2; printf '  %s\n' "${failed_names[@]}" >&2; }

    [[ -n ${batch_lock_fd:-} ]] && flock -u "$batch_lock_fd" 2>/dev/null || true
    [[ -n ${batch_lock_file:-} ]] && rm -f -- "$batch_lock_file" 2>/dev/null || true
    BATCH_LOCK_FILE_GLOBAL=""; BATCH_LOCK_FD_GLOBAL=""; BATCH_ROOT_STAGE_PARENT=""; BATCH_CHILD_PIDS=()

    (( failed == 0 && skipped == 0 ))
}

if $BATCH_MODE; then
    run_batch_mode
    exit $?
fi

SOURCE_INPUT=${POSITIONAL[0]}
OUTPUT_INPUT=${POSITIONAL[1]:-}
[[ -d $SOURCE_INPUT ]] || die "Source is not a directory: $SOURCE_INPUT"

SOURCE=$(realpath -e -- "$SOURCE_INPUT")
export HARDCORE_ARCHIVE_CALIBRATION_SOURCE_ROOT="$SOURCE"
SOURCE_PARENT=$(dirname -- "$SOURCE")
SOURCE_NAME=$(basename -- "$SOURCE")
hardcore_archive_internal_root_name "$SOURCE_NAME" && \
    die "The source name is reserved for internal archive metadata: $SOURCE_NAME"
if [[ -z $OUTPUT_INPUT ]]; then
    OUTPUT_INPUT="$SOURCE_PARENT/${SOURCE_NAME}.7z"
    OUTPUT_WAS_AUTOMATIC=true
fi
[[ $OUTPUT_INPUT == *.7z ]] || OUTPUT_INPUT="${OUTPUT_INPUT}.7z"
ARCHIVE=$(realpath -m -- "$OUTPUT_INPUT")
ARCHIVE_PARENT=$(dirname -- "$ARCHIVE")

[[ $ARCHIVE != "$SOURCE" && $ARCHIVE != "$SOURCE/"* ]] || \
    die "The output archive cannot be inside the source folder."

if $REMOVE_SOURCE; then
    [[ $SOURCE != / ]] || die "Refusing to remove the filesystem root."
    [[ $SOURCE != "$HOME" ]] || die "Refusing to remove your complete home directory."
fi

mkdir -p -- "$ARCHIVE_PARENT"

[[ ! -d $ARCHIVE ]] || die "The output path is a directory: $ARCHIVE"

if $OUTPUT_WAS_AUTOMATIC && [[ -e $ARCHIVE ]] && ! $FORCE; then
    auto_stem=${ARCHIVE%.7z}
    auto_stamp=$(date '+%Y%m%d-%H%M%S')
    candidate="${auto_stem}-${auto_stamp}.7z"
    suffix=1
    while [[ -e $candidate ]]; do
        candidate="${auto_stem}-${auto_stamp}-${suffix}.7z"
        suffix=$((suffix + 1))
    done
    ARCHIVE=$candidate
    ARCHIVE_PARENT=$(dirname -- "$ARCHIVE")
    warn "The automatic default already existed; using: $ARCHIVE"
fi

if [[ -e $ARCHIVE ]] && ! $FORCE; then
    die "Output already exists. Use --force to replace it after successful testing: $ARCHIVE"
fi

acquire_output_lock
REPORT_PATH=$(archive_report_path)

VIDEO_LIST=$(mktemp)
IMAGE_LIST=$(mktemp)
NESTED_LIST=$(mktemp)
CONTAINER_LIST=$(mktemp)
CONTAINER_RESULT_MANIFEST=$(mktemp)
CONTAINER_REPACKED_LIST=$(mktemp)
CONTAINER_FALLBACK_LIST=$(mktemp)
COPY_LIST=$(mktemp)
COMPRESSIBILITY_CANDIDATES=$(mktemp)
COMPRESSIBILITY_RESULT_MANIFEST=$(mktemp)
SNAPSHOT_BEFORE=$(mktemp)
SNAPSHOT_AFTER=$(mktemp)
SEVEN_ZIP_LOG=$(component_log_path 7zip.log)
INVENTORY_RAW=$(mktemp)
VIDEO_LOG=$(component_log_path video.log)
IMAGE_LOG=$(component_log_path image.log)
VIDEO_COMPRESSED_LIST=$(mktemp)
VIDEO_FALLBACK_LIST=$(mktemp)
VIDEO_RESULT_MANIFEST=$(mktemp)
VIDEO_SPECIAL_LIST=$(mktemp)
VIDEO_SPECIAL_PRESERVE_LIST=$(mktemp)
VIDEO_SPECIAL_OMIT_LIST=$(mktemp)
IMAGE_RESULT_MANIFEST=$(mktemp)
IMAGE_OPTIMIZED_LIST=$(mktemp)
IMAGE_FALLBACK_LIST=$(mktemp)
NESTED_RESULT_MANIFEST=$(mktemp)
NESTED_REPACKED_LIST=$(mktemp)
NESTED_FALLBACK_LIST=$(mktemp)
MC_TUNING_LOG=$(component_log_path match-cycle.log)
EXPECTED_PATHS=$(mktemp)
ARCHIVE_PATHS=$(mktemp)
HASH_MANIFEST=$(mktemp)
HASH_VERIFY_LOG=$(component_log_path hash-verification.log)
SPECIAL_FILES_LIST=$(mktemp)
NESTED_MOUNTS_LIST=$(mktemp)
RESUME_MAP=$(mktemp)
ARCHIVE_MANIFEST_STAGE=$(mktemp -d -p "$ARCHIVE_PARENT" ".hardcore-manifest-stage.XXXXXX")
ARCHIVE_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-video-manifest.txt"
IMAGE_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-image-manifest.txt"
NESTED_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-nested-manifest.txt"
CONTAINER_MANIFEST_FILE="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-container-manifest.txt"
METADATA_DIR="$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-metadata"
METADATA_MANIFEST="$METADATA_DIR/files.tsv"
ACL_MANIFEST="$METADATA_DIR/acl.txt"
XATTR_MANIFEST="$METADATA_DIR/xattrs.txt"
RESTORE_HELPER="$METADATA_DIR/RESTORE-NOTES.txt"
SPARSE_MANIFEST="$METADATA_DIR/sparse.tsv"
ARCHIVE_INFO_FILE="$METADATA_DIR/archive-info.txt"
TEMP_ARCHIVE="${ARCHIVE}.partial.$$.7z"

choose_failed_output_paths() {
    local context timestamp stem suffix=0
    context=${FAILURE_CONTEXT:-failed}
    context=${context//[^A-Za-z0-9._-]/-}
    timestamp=$(date '+%Y%m%d-%H%M%S')
    stem=$ARCHIVE
    [[ $stem == *.7z ]] && stem=${stem%.7z}

    while :; do
        if (( suffix == 0 )); then
            FAILED_ARCHIVE_PATH="${stem}.${context}-${timestamp}.7z"
            FAILED_LOG_PATH="${stem}.${context}-${timestamp}.log"
        else
            FAILED_ARCHIVE_PATH="${stem}.${context}-${timestamp}-${suffix}.7z"
            FAILED_LOG_PATH="${stem}.${context}-${timestamp}-${suffix}.log"
        fi

        if [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
            FAILED_LOG_PATH="$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/${FAILED_LOG_PATH##*/}"
        fi
        [[ ! -e $FAILED_ARCHIVE_PATH && ! -e $FAILED_LOG_PATH ]] && break
        ((suffix++))
    done
}

preserve_failed_archive() {
    local exit_status=$1 retained_path original_temp size
    [[ -n ${TEMP_ARCHIVE:-} && -e $TEMP_ARCHIVE ]] || return 0

    original_temp=$TEMP_ARCHIVE
    size=$(stat -c '%s' -- "$TEMP_ARCHIVE" 2>/dev/null || printf '0')
    choose_failed_output_paths

    sync "$TEMP_ARCHIVE" 2>/dev/null || true
    if mv -- "$TEMP_ARCHIVE" "$FAILED_ARCHIVE_PATH"; then
        retained_path=$FAILED_ARCHIVE_PATH
        TEMP_ARCHIVE=""
    else
        retained_path=$original_temp
        warn "Could not rename the failed archive; it remains at: $retained_path"
    fi

    {
        printf 'Hardcore Archive failure report\n'
        printf 'Script version: %s\n' "$SCRIPT_VERSION"
        printf 'Platform: %s\n' "$(platform_os_version)"
        printf 'Exit status: %s\n' "$exit_status"
        printf 'Failure stage: %s\n' "${FAILURE_CONTEXT:-unknown}"
        printf 'Source: %s\n' "$SOURCE"
        printf 'Requested output: %s\n' "$ARCHIVE"
        printf 'Preserved archive: %s\n' "$retained_path"
        printf 'Preserved archive size: %s bytes\n' "$size"

        if [[ -s ${SEVEN_ZIP_LOG:-} ]]; then
            printf '\n===== Last 7-Zip output =====\n'
            cat -- "$SEVEN_ZIP_LOG"
        fi

        if [[ -s ${MC_TUNING_LOG:-} ]]; then
            printf '\n===== Match-cycle tuning output =====\n'
            cat -- "$MC_TUNING_LOG"
        fi

        if [[ -s ${VIDEO_LOG:-} ]]; then
            printf '\n===== Video pipeline output =====\n'
            cat -- "$VIDEO_LOG"
        fi
        if [[ -s ${IMAGE_LOG:-} ]]; then
            printf '\n===== Image pipeline output =====\n'
            cat -- "$IMAGE_LOG"
        fi
        if [[ -s ${HASH_VERIFY_LOG:-} ]]; then
            printf '\n===== Hash verification output =====\n'
            cat -- "$HASH_VERIFY_LOG"
        fi
        if [[ -n ${JOB_WORK_DIR:-} ]]; then
            printf '\nReusable working directory: %s\n' "$JOB_WORK_DIR"
        fi
    } > "$FAILED_LOG_PATH" 2>/dev/null || true

    sync "$retained_path" "$FAILED_LOG_PATH" 2>/dev/null || true

    printf '\nArchive operation failed, but the failed archive was preserved.\n' >&2
    printf 'Preserved archive: %s\n' "$retained_path" >&2
    if [[ -e $FAILED_LOG_PATH ]]; then
        printf 'Diagnostic log:   %s\n' "$FAILED_LOG_PATH" >&2
    fi
    printf 'The source folder was not removed.\n' >&2
}

cleanup() {
    local exit_status=$?
    set +e

    if [[ -n ${VIDEO_PIPELINE_PID:-} ]] && kill -0 "$VIDEO_PIPELINE_PID" 2>/dev/null; then
        if $VIDEO_PIPELINE_GROUP; then
            kill -- "-$VIDEO_PIPELINE_PID" 2>/dev/null || true
        else
            kill "$VIDEO_PIPELINE_PID" 2>/dev/null || true
        fi
        wait "$VIDEO_PIPELINE_PID" 2>/dev/null || true
    fi

    if [[ -n ${IMAGE_PIPELINE_PID:-} ]] && kill -0 "$IMAGE_PIPELINE_PID" 2>/dev/null; then
        if $IMAGE_PIPELINE_GROUP; then
            kill -- "-$IMAGE_PIPELINE_PID" 2>/dev/null || true
        else
            kill "$IMAGE_PIPELINE_PID" 2>/dev/null || true
        fi
        wait "$IMAGE_PIPELINE_PID" 2>/dev/null || true
    fi

    cache_completed_video_results 2>/dev/null || true

    if [[ -n ${NESTED_TIMING_STARTED:-} ]]; then
        hardcore_timing_record nested_processing "$NESTED_TIMING_STARTED" "$exit_status"
    fi

    if [[ -n ${TEMP_ARCHIVE:-} && -e $TEMP_ARCHIVE ]]; then
        if (( exit_status == 0 )); then
            rm -f -- "$TEMP_ARCHIVE"
        else
            preserve_failed_archive "$exit_status"
        fi
    fi


    if [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
        mkdir -p -- "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR" 2>/dev/null || true
        {
            printf 'exit_status=%s\n' "$exit_status"
            printf 'failure_context=%s\n' "${FAILURE_CONTEXT:-unknown}"
            printf 'video_transcode=%s\n' "${VIDEO_TRANSCODE:-unknown}"
            printf 'video_codec=%s\n' "${VIDEO_CODEC:-unknown}"
            printf 'video_encoder=%s\n' "${VIDEO_ENCODER:-unset}"
            printf 'video_vaapi_device=%s\n' "${HARDCORE_ARCHIVE_VAAPI_DEVICE:-auto}"
            printf 'video_acceleration=%s\n' "${HARDCORE_ARCHIVE_VIDEO_ACCELERATION:-auto}"
            printf 'video_gpu_filters=%s\n' "${HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS:-auto}"
            printf 'video_cuda_device=%s\n' "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}"
            printf 'video_pipeline_pid=%s\n' "${VIDEO_PIPELINE_PID:-none}"
            printf 'video_completed=%s\n' "${VIDEO_COMPRESSED_COUNT:-0}"
            printf 'video_preserved=%s\n' "${VIDEO_FALLBACK_COUNT:-0}"
            printf 'nested_repacked=%s\n' "${NESTED_REPACKED_COUNT:-0}"
            printf 'nested_preserved=%s\n' "${NESTED_FALLBACK_COUNT:-0}"
        } > "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/state.txt" 2>/dev/null || true
        hardcore_timing_summary > "$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/timings.txt" 2>/dev/null || true
    fi

    if [[ -z ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
        rm -f -- "$SEVEN_ZIP_LOG" "$VIDEO_LOG" "$IMAGE_LOG" "$MC_TUNING_LOG" "$HASH_VERIFY_LOG"
    fi
    rm -f -- "$VIDEO_LIST" "$IMAGE_LIST" "$NESTED_LIST" "$CONTAINER_LIST" "$COPY_LIST" "$COMPRESSIBILITY_CANDIDATES" "$COMPRESSIBILITY_RESULT_MANIFEST" "$SNAPSHOT_BEFORE" "$SNAPSHOT_AFTER" \
        "$INVENTORY_RAW" "$VIDEO_COMPRESSED_LIST" "$VIDEO_FALLBACK_LIST" \
        "$VIDEO_SPECIAL_LIST" "$VIDEO_SPECIAL_PRESERVE_LIST" "$VIDEO_SPECIAL_OMIT_LIST" \
        "$VIDEO_RESULT_MANIFEST" "$IMAGE_RESULT_MANIFEST" "$IMAGE_OPTIMIZED_LIST" "$IMAGE_FALLBACK_LIST" \
        "$NESTED_RESULT_MANIFEST" "$NESTED_REPACKED_LIST" "$NESTED_FALLBACK_LIST" \
        "$CONTAINER_RESULT_MANIFEST" "$CONTAINER_REPACKED_LIST" "$CONTAINER_FALLBACK_LIST" \
        "$EXPECTED_PATHS" "$ARCHIVE_PATHS" "$HASH_MANIFEST" \
        "$SPECIAL_FILES_LIST" "$NESTED_MOUNTS_LIST" "$RESUME_MAP"


    if [[ -n ${ARCHIVE_MANIFEST_STAGE:-} && -d $ARCHIVE_MANIFEST_STAGE ]]; then
        rm -rf --one-file-system -- "$ARCHIVE_MANIFEST_STAGE"
    fi

    if [[ -n ${VIDEO_STAGE_PARENT:-} && -d $VIDEO_STAGE_PARENT ]]; then
        rm -rf --one-file-system -- "$VIDEO_STAGE_PARENT"
    fi
    if [[ -n ${IMAGE_STAGE_PARENT:-} && -d $IMAGE_STAGE_PARENT ]]; then
        rm -rf --one-file-system -- "$IMAGE_STAGE_PARENT"
    fi
    if [[ -n ${CONTAINER_STAGE_PARENT:-} && -d $CONTAINER_STAGE_PARENT ]]; then
        rm -rf --one-file-system -- "$CONTAINER_STAGE_PARENT"
    fi
    if [[ -n ${NESTED_STAGE_PARENT:-} && -d $NESTED_STAGE_PARENT ]]; then
        rm -rf --one-file-system -- "$NESTED_STAGE_PARENT"
    fi
    if [[ -n ${MC_SAMPLE_DIR:-} && -d $MC_SAMPLE_DIR ]]; then
        rm -rf --one-file-system -- "$MC_SAMPLE_DIR"
    fi

    if (( exit_status == 0 )) && ! $KEEP_WORK && [[ -n ${JOB_WORK_DIR:-} && -d $JOB_WORK_DIR ]]; then
        rm -rf --one-file-system -- "$JOB_WORK_DIR"
    elif (( exit_status != 0 )) && $RESUME_ENABLED && [[ -n ${JOB_WORK_DIR:-} ]]; then
        warn "Reusable work was preserved for automatic resume: $JOB_WORK_DIR"
    fi

    release_output_lock
    return "$exit_status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

source_find() {
    local root=$1
    shift
    local -a boundary=()
    $ONE_FILE_SYSTEM && boundary=(-xdev)
    find "$root" "${boundary[@]}" "$@"
}

create_snapshot() {
    local destination=$1
    (
        cd -- "$SOURCE_PARENT"
        LC_ALL=C source_find "$SOURCE_NAME" \
            -printf '%y\t%s\t%T@\t%C@\t%p\0' | LC_ALL=C sort -z
    ) > "$destination"
}

inspect_source_structure() {
    : > "$SPECIAL_FILES_LIST"
    : > "$NESTED_MOUNTS_LIST"

    (
        cd -- "$SOURCE_PARENT"
        source_find "$SOURCE_NAME" \( -type b -o -type c -o -type p -o -type s \) -print0
    ) > "$SPECIAL_FILES_LIST"
    if [[ -s $SPECIAL_FILES_LIST ]]; then
        printf '\nUnsupported special filesystem objects were found:\n' >&2
        tr '\0' '\n' < "$SPECIAL_FILES_LIST" | sed 's/^/  /' >&2
        die "Sockets, devices, and FIFOs cannot be safely represented by this archive workflow."
    fi

    platform_list_nested_mounts "$SOURCE" "$NESTED_MOUNTS_LIST"
    if [[ -s $NESTED_MOUNTS_LIST ]]; then
        if $ONE_FILE_SYSTEM; then
            warn "Nested mount points were detected and will be excluded by the one-filesystem default."
        else
            warn "Nested mount points were detected and will be included because --cross-filesystems was selected."
        fi
    fi
}

check_destination_capacity() {
    local free existing=0 estimate safety required largest
    free=$(df -PB1 -- "$ARCHIVE_PARENT" | awk 'NR==2{print $4}')
    [[ $free =~ ^[0-9]+$ ]] || die "Could not determine free space at the destination."
    [[ -e $ARCHIVE ]] && existing=$(stat -c '%s' -- "$ARCHIVE" 2>/dev/null || printf 0)
    # Until compression completes, the only safe assumption is that the archive
    # may be roughly as large as all logical source data plus manifests. Sparse
    # holes compress extremely well, but they are deliberately not subtracted
    # from this safety bound.
    estimate=$((TOTAL_BYTES - VIDEO_OMITTED_BYTES))
    safety=$((estimate / 20 + 256 * MIB))
    required=$((estimate + safety))
    if $FORCE && (( existing > 0 )); then
        # The old archive remains until the new verified temporary archive is
        # complete, so it cannot be counted as available space.
        :
    fi
    DESTINATION_REQUIRED_BYTES=$required
    DESTINATION_FREE_BYTES=$free
    (( free >= required )) || die "Insufficient destination space. Need approximately $(human_bytes "$required") free for safe atomic creation; only $(human_bytes "$free") is available."
    printf 'Destination capacity: %s free; conservative requirement %s.\n' "$(human_bytes "$free")" "$(human_bytes "$required")"
}


inspect_source_structure

printf '\nStage 1/8: Capturing the source state...\n'
create_snapshot "$SNAPSHOT_BEFORE"
printf 'Source-state capture complete.\n'

printf '\nStage 2/8: Scanning and classifying files...\n'
TOTAL_FILE_COUNT=0
TOTAL_BYTES=0
VIDEO_COUNT=0
VIDEO_BYTES=0
IMAGE_COUNT=0
IMAGE_BYTES=0
IMAGE_JPEG_COUNT=0
IMAGE_PNG_COUNT=0
LARGEST_IMAGE_BYTES=0
NESTED_COUNT=0
NESTED_BYTES=0
CONTAINER_COUNT=0
CONTAINER_BYTES=0
CONTAINER_REPACKED_COUNT=0
CONTAINER_FALLBACK_COUNT=0
CONTAINER_REPACKED_BYTES=0
CONTAINER_FALLBACK_BYTES=0
CONTAINER_SAVED_BYTES=0
CONTAINER_STAGE_PARENT=''
COPY_COUNT=0
COPY_BYTES=0
GENERIC_CANDIDATE_COUNT=0
NONVIDEO_COUNT=0
NONVIDEO_BYTES=0

# List files relative to SOURCE_PARENT, matching the paths passed to 7-Zip.
(
    cd -- "$SOURCE_PARENT"
    source_find "$SOURCE_NAME" -type f -printf '%s\0%p\0'
) > "$INVENTORY_RAW"

while IFS= read -r -d '' file_size && IFS= read -r -d '' relative_path; do
    [[ $file_size =~ ^[0-9]+$ ]] || die "Could not read file size for: $relative_path"
    [[ $relative_path != *$'\n'* && $relative_path != *$'\t'* ]] || \
        die "A filename contains a tab or newline, which the safe manifest format cannot represent: $relative_path"

    TOTAL_FILE_COUNT=$((TOTAL_FILE_COUNT + 1))
    TOTAL_BYTES=$((TOTAL_BYTES + file_size))

    if is_video_path "$relative_path"; then
        VIDEO_COUNT=$((VIDEO_COUNT + 1))
        VIDEO_BYTES=$((VIDEO_BYTES + file_size))
        if (( file_size > LARGEST_VIDEO_BYTES )); then
            LARGEST_VIDEO_BYTES=$file_size
        fi
        printf '%s\n' "$relative_path" >> "$VIDEO_LIST"
    elif $NESTED_REPACK && is_nested_archive_path "$relative_path"; then
        NESTED_COUNT=$((NESTED_COUNT + 1))
        NESTED_BYTES=$((NESTED_BYTES + file_size))
        printf '%s\n' "$relative_path" >> "$NESTED_LIST"
    elif is_image_path "$relative_path"; then
        IMAGE_COUNT=$((IMAGE_COUNT + 1))
        IMAGE_BYTES=$((IMAGE_BYTES + file_size))
        (( file_size > LARGEST_IMAGE_BYTES )) && LARGEST_IMAGE_BYTES=$file_size
        case "${relative_path,,}" in
            *.png) IMAGE_PNG_COUNT=$((IMAGE_PNG_COUNT + 1)) ;;
            *) IMAGE_JPEG_COUNT=$((IMAGE_JPEG_COUNT + 1)) ;;
        esac
        printf '%s\n' "$relative_path" >> "$IMAGE_LIST"
    elif $CONTAINER_REPACK && is_format_preserving_container_path "$relative_path"; then
        CONTAINER_COUNT=$((CONTAINER_COUNT + 1))
        CONTAINER_BYTES=$((CONTAINER_BYTES + file_size))
        printf '%s\n' "$relative_path" >> "$CONTAINER_LIST"
    else
        GENERIC_CANDIDATE_COUNT=$((GENERIC_CANDIDATE_COUNT + 1))
        printf '%s\0%s\0' "$file_size" "$relative_path" >> "$COMPRESSIBILITY_CANDIDATES"
    fi
done < "$INVENTORY_RAW"

: > "$COMPRESSIBILITY_RESULT_MANIFEST"
if (( GENERIC_CANDIDATE_COUNT > 0 )); then
    COMPRESSIBILITY_HELPER=${HARDCORE_ARCHIVE_COMPRESSIBILITY_HELPER:-"$(dirname -- "${BASH_SOURCE[0]}")/hardcore-archive-compressibility.py"}
    [[ -f $COMPRESSIBILITY_HELPER ]] || \
        die "The content-aware compressibility helper is missing: $COMPRESSIBILITY_HELPER"
    if ! python3 "$COMPRESSIBILITY_HELPER" \
        --source-parent "$SOURCE_PARENT" \
        --inventory "$COMPRESSIBILITY_CANDIDATES" \
        --result "$COMPRESSIBILITY_RESULT_MANIFEST"; then
        die "Content-aware Copy/LZMA classification failed; no extension-only fallback was used."
    fi

    compressibility_accounted=0
    while IFS=$'\t' read -r route classified_size sampled_bytes mean_ratio min_ratio route_reason relative_path; do
        [[ -n $route && -n $relative_path ]] || continue
        [[ $classified_size =~ ^[0-9]+$ && $sampled_bytes =~ ^[0-9]+$ ]] || \
            die "Invalid content-routing result for: $relative_path"
        compressibility_accounted=$((compressibility_accounted + 1))
        case $route in
            copy)
                COPY_COUNT=$((COPY_COUNT + 1))
                COPY_BYTES=$((COPY_BYTES + classified_size))
                CONTENT_COPY_PATHS["$relative_path"]=1
                printf '%s\n' "$relative_path" >> "$COPY_LIST"
                ;;
            lzma)
                NONVIDEO_COUNT=$((NONVIDEO_COUNT + 1))
                NONVIDEO_BYTES=$((NONVIDEO_BYTES + classified_size))
                ;;
            *)
                die "Unknown content-routing action '$route' for: $relative_path"
                ;;
        esac
    done < "$COMPRESSIBILITY_RESULT_MANIFEST"
    (( compressibility_accounted == GENERIC_CANDIDATE_COUNT )) || \
        die "Content routing accounted for $compressibility_accounted of $GENERIC_CANDIDATE_COUNT ordinary files."
fi

printf 'Scan complete: %s files / %s.\n' "$TOTAL_FILE_COUNT" "$(human_bytes "$TOTAL_BYTES")"
printf 'Content routing: %s LZMA2 file(s), %s Copy file(s); filenames do not decide the generic lane.\n' \
    "$NONVIDEO_COUNT" "$COPY_COUNT"

dependency_preflight_create_optional "$VIDEO_COUNT" "$IMAGE_JPEG_COUNT" \
    "$IMAGE_PNG_COUNT" "$NESTED_COUNT" false

if $VIDEO_TRANSCODE && (( VIDEO_COUNT > 0 )); then
    [[ -f $MEDIA_HELPER ]] || die "The trusted special-media helper is missing: $MEDIA_HELPER"
    set +e
    hardcore_media_resolve
    media_policy_rc=$?
    set -e
    case $media_policy_rc in
        0) ;;
        2) die 'Cancelled while choosing how to handle special videos.' ;;
        *) die 'Special-video inspection or policy selection failed.' ;;
    esac

    VIDEO_SPECIAL_COUNT=$(awk 'END {print NR+0}' "$VIDEO_SPECIAL_LIST")
    VIDEO_SPECIAL_PRESERVE_COUNT=$(awk 'END {print NR+0}' "$VIDEO_SPECIAL_PRESERVE_LIST")
    VIDEO_OMITTED_COUNT=$(awk 'END {print NR+0}' "$VIDEO_SPECIAL_OMIT_LIST")
    VIDEO_SPECIAL_CONVERT_COUNT=$((VIDEO_SPECIAL_COUNT - VIDEO_SPECIAL_PRESERVE_COUNT - VIDEO_OMITTED_COUNT))
    (( VIDEO_SPECIAL_CONVERT_COUNT >= 0 )) || die 'Special-video policy accounting is inconsistent.'
    VIDEO_TRANSCODE_COUNT=$((VIDEO_COUNT - VIDEO_SPECIAL_PRESERVE_COUNT - VIDEO_OMITTED_COUNT))
    while IFS= read -r relative_path; do
        [[ -n $relative_path ]] || continue
        file_size=$(stat -c '%s' -- "$SOURCE_PARENT/$relative_path")
        if hardcore_media_list_contains "$VIDEO_SPECIAL_OMIT_LIST" "$relative_path"; then
            VIDEO_OMITTED_BYTES=$((VIDEO_OMITTED_BYTES + file_size))
        elif ! hardcore_media_list_contains "$VIDEO_SPECIAL_PRESERVE_LIST" "$relative_path"; then
            VIDEO_TRANSCODE_BYTES=$((VIDEO_TRANSCODE_BYTES + file_size))
            (( file_size > LARGEST_TRANSCODE_VIDEO_BYTES )) && LARGEST_TRANSCODE_VIDEO_BYTES=$file_size
        fi
    done < "$VIDEO_LIST"
    VIDEO_SELECTED_BYTES=$((VIDEO_BYTES - VIDEO_OMITTED_BYTES))

    if (( VIDEO_OMITTED_COUNT > 0 )); then
        warn "$VIDEO_OMITTED_COUNT explicitly selected video file(s) will be omitted from the archive ($(human_bytes "$VIDEO_OMITTED_BYTES"))."
        $REMOVE_SOURCE && die 'Videos selected for omission cannot be combined with --remove-source; the omitted originals would have no archived copy.'
    fi
else
    VIDEO_TRANSCODE_COUNT=0
    VIDEO_SELECTED_BYTES=$VIDEO_BYTES
fi
check_destination_capacity

if (( IMAGE_COUNT > 0 )); then
    jpeg_tools=false
    png_tool=none
    command -v jpegtran >/dev/null 2>&1 && command -v djpeg >/dev/null 2>&1 && jpeg_tools=true
    if command -v oxipng >/dev/null 2>&1; then
        png_tool=oxipng
    elif command -v optipng >/dev/null 2>&1; then
        png_tool=optipng
    fi
    IMAGE_OPTIMIZER_AVAILABLE=false
    if (( IMAGE_JPEG_COUNT > 0 )) && $jpeg_tools; then IMAGE_OPTIMIZER_AVAILABLE=true; fi
    if (( IMAGE_PNG_COUNT > 0 )) && [[ $png_tool != none ]]; then IMAGE_OPTIMIZER_AVAILABLE=true; fi
    if ! $IMAGE_OPTIMIZE; then
        IMAGE_TOOL_SUMMARY="disabled; originals stored with Copy"
    else
        IMAGE_TOOL_SUMMARY="JPEG=$($jpeg_tools && printf jpegtran || printf fallback), PNG=$png_tool"
    fi
fi


# HARDCORE_HARDWARE_ONLY_VIDEO_V1
# HARDCORE_EXPLICIT_VAAPI_DEVICE_V1
video_encoder_is_hardware() {
    case "$1" in
        av1_vaapi|av1_nvenc|av1_qsv|hevc_videotoolbox|hevc_vaapi|hevc_nvenc|hevc_qsv)
            return 0 ;;
        *)
            return 1 ;;
    esac
}

probe_parent_video_encoder() {
    local relative='' selected='' input probe='' candidate expected actual
    local -a command=() candidates=()
    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        hardcore_media_list_contains "$VIDEO_SPECIAL_PRESERVE_LIST" "$relative" && continue
        hardcore_media_list_contains "$VIDEO_SPECIAL_OMIT_LIST" "$relative" && continue
        selected=$relative
        break
    done < "$VIDEO_LIST"
    [[ -n $selected ]] || return 1
    input="$SOURCE_PARENT/$selected"
    probe=$(mktemp --suffix=.mkv)
    [[ $VIDEO_CODEC == av1 ]] && expected=av1 || expected=hevc

    if [[ $VIDEO_CODEC == av1 ]]; then
        candidates=(av1_vaapi av1_nvenc av1_qsv)
    else
        candidates=(hevc_videotoolbox hevc_vaapi hevc_nvenc hevc_qsv)
    fi
    for candidate in "${candidates[@]}"; do
        ffmpeg -hide_banner -encoders 2>/dev/null | grep -w "$candidate" >/dev/null || continue
        command=(ffmpeg -hide_banner -v error -nostdin -y)
        [[ $candidate == *_vaapi ]] && command+=( -init_hw_device "vaapi=va:${HARDCORE_ARCHIVE_VAAPI_DEVICE:-}" -filter_hw_device va )
        command+=( -t 1 -i "$input" -map '0:V:0' -an -sn -dn )
        case $candidate in
            *_videotoolbox) command+=( -c:v "$candidate" -q:v 65 -pix_fmt nv12 ) ;;
            *_vaapi) command+=( -vf 'format=nv12,hwupload' -c:v "$candidate" -rc_mode CQP -global_quality:v 33 ) ;;
            *_nvenc) command+=( -c:v "$candidate" -gpu:v "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}" -cq:v 33 -preset:v p4 ) ;;
            *_qsv) command+=( -c:v "$candidate" -global_quality:v 33 -preset:v balanced ) ;;
        esac
        command+=( -f matroska "$probe" )
        if "${command[@]}" >/dev/null 2>&1; then
            actual=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name \
                -of default=nw=1:nk=1 "$probe" 2>/dev/null | head -n1)
            rm -f -- "$probe"
            if [[ $actual == "$expected" ]]; then
                VIDEO_ENCODER=$candidate
                return 0
            fi
        fi
        rm -f -- "$probe"
    done
    rm -f -- "$probe"
    return 1
}

# Automatic video policy. Balanced keeps the existing hardware-first behavior
# so video work can overlap the CPU-heavy LZMA process. Maximum prefers the
# strongest available software encoder and runs sequentially unless explicitly
# overridden. Fast keeps hardware-first behavior and parallel execution.
if $VIDEO_TRANSCODE && (( VIDEO_TRANSCODE_COUNT > 0 )); then
    case $VIDEO_MODE in
        maximum)
            if [[ -z $VIDEO_ENCODER ]]; then
                probe_parent_video_encoder || die "Hardware video encoding is mandatory, but no compatible hardware encoder passed the real-file probe."
            fi
            $VIDEO_PARALLEL_EXPLICIT || VIDEO_PARALLEL=true
            [[ $QUALITY_CHECK == auto ]] && QUALITY_CHECK=required
            ;;
        balanced)
            if [[ -z $VIDEO_ENCODER ]]; then
                if probe_parent_video_encoder; then
                    $VIDEO_PARALLEL_EXPLICIT || VIDEO_PARALLEL=true
                else
                    die "Hardware video encoding is mandatory, but the hardware probe failed."
                fi
            elif [[ $VIDEO_ENCODER == lib* ]]; then
                $VIDEO_PARALLEL_EXPLICIT || VIDEO_PARALLEL=false
            fi
            ;;
        fast)
            [[ -z $VIDEO_ENCODER ]] && probe_parent_video_encoder || true
            if [[ -z $VIDEO_ENCODER ]]; then
                die "Hardware video encoding is mandatory, but the hardware probe failed."
            fi
            $VIDEO_PARALLEL_EXPLICIT || VIDEO_PARALLEL=true
            ;;
    esac
    [[ -n $VIDEO_ENCODER ]] || die "Hardware video encoding is mandatory, but no hardware encoder could be selected."
    video_encoder_is_hardware "$VIDEO_ENCODER" || die "Software/non-hardware video encoder '$VIDEO_ENCODER' is forbidden. Hardware encoding is mandatory."
    $VIDEO_PARALLEL_EXPLICIT || VIDEO_PARALLEL=true
    printf 'Hardware video encoder locked: %s\n' "$VIDEO_ENCODER"
fi

# Pick a persistent local working area. It is cleaned after success, but kept
# after interruption/failure so validated video work can be reused.
MINIMUM_STAGING_BYTES=$((256 * MIB))
if $VIDEO_TRANSCODE && (( VIDEO_TRANSCODE_COUNT > 0 )); then
    MINIMUM_STAGING_BYTES=$((MINIMUM_STAGING_BYTES + VIDEO_TRANSCODE_BYTES + LARGEST_TRANSCODE_VIDEO_BYTES))
fi
if (( IMAGE_COUNT > 0 )); then
    MINIMUM_STAGING_BYTES=$((MINIMUM_STAGING_BYTES + IMAGE_BYTES + LARGEST_IMAGE_BYTES))
fi
if $CONTAINER_REPACK && (( CONTAINER_COUNT > 0 )); then
    MINIMUM_STAGING_BYTES=$((MINIMUM_STAGING_BYTES + CONTAINER_BYTES))
fi
choose_work_root
JOB_ID=$(printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
    "$SOURCE" "$VIDEO_CODEC" "$VIDEO_ENCODER" "$VIDEO_MODE" \
    "$VIDEO_MIN_VMAF" "$VIDEO_MIN_SAVINGS_PERCENT" "$VIDEO_NO_SCALE" "$VIDEO_NO_DENOISE" \
    "$IMAGE_OPTIMIZE" "$IMAGE_MODE" | \
    sha256sum | awk '{print substr($1,1,24)}')
JOB_WORK_DIR="$WORK_ROOT/jobs/$JOB_ID"
if ! $RESUME_ENABLED; then
    rm -rf --one-file-system -- "$JOB_WORK_DIR"
fi
mkdir -p -- "$JOB_WORK_DIR"
VIDEO_CACHE_DIR="$JOB_WORK_DIR/video-cache"
mkdir -p -- "$VIDEO_CACHE_DIR"

IFS=$'\t' read -r MEM_TOTAL_KIB MEM_AVAILABLE_KIB SWAP_TOTAL_KIB SWAP_FREE_KIB < <(platform_memory_kib)
[[ ${MEM_TOTAL_KIB:-0} =~ ^[0-9]+$ ]] || die "Could not determine total memory on $PLATFORM_NAME."
[[ ${MEM_AVAILABLE_KIB:-0} =~ ^[0-9]+$ ]] || die "Could not determine available memory on $PLATFORM_NAME."
MEM_TOTAL_MIB=$((MEM_TOTAL_KIB / 1024))
MEM_AVAILABLE_MIB=$((MEM_AVAILABLE_KIB / 1024))
SWAP_TOTAL_MIB=$((${SWAP_TOTAL_KIB:-0} / 1024))
SWAP_FREE_MIB=$((${SWAP_FREE_KIB:-0} / 1024))

CPU_THREADS=$(platform_cpu_threads)
CPU_MODEL=$(platform_cpu_model)
[[ -n ${CPU_MODEL:-} ]] || CPU_MODEL="Unknown CPU"

SEVEN_ZIP_BANNER=$($SEVEN_ZIP 2>&1 | head -n 3 || true)
SEVEN_ZIP_VERSION=$(grep -Eo '[0-9]{2}\.[0-9]{2}' <<< "$SEVEN_ZIP_BANNER" | head -n 1 || true)

MAX_FORMAT_DICTIONARY_MIB=1536
if [[ $SEVEN_ZIP_VERSION =~ ^([0-9]+)\.([0-9]+)$ ]]; then
    VERSION_MAJOR=${BASH_REMATCH[1]}
    VERSION_MINOR=${BASH_REMATCH[2]}
    if (( VERSION_MAJOR > 21 || (VERSION_MAJOR == 21 && VERSION_MINOR >= 3) )); then
        MAX_FORMAT_DICTIONARY_MIB=4096
    fi
fi

# Reserve memory for the desktop, filesystem cache, 7-Zip overhead, and other
# applications. Swap is intentionally not counted as usable compression RAM.
if (( MEM_TOTAL_MIB < 4096 )); then
    OS_RESERVE_MIB=768
elif (( MEM_TOTAL_MIB < 8192 )); then
    OS_RESERVE_MIB=1536
else
    OS_RESERVE_MIB=$((MEM_TOTAL_MIB / 10))
    (( OS_RESERVE_MIB < 2048 )) && OS_RESERVE_MIB=2048
    (( OS_RESERVE_MIB > 8192 )) && OS_RESERVE_MIB=8192
fi

# Image workers run beside LZMA. Automatic mode leaves at least four logical
# CPUs for the desktop/LZMA/video control work and caps concurrent workers.
if (( IMAGE_COUNT > 0 )) && $IMAGE_OPTIMIZE && $IMAGE_OPTIMIZER_AVAILABLE; then
    # Coordinate outer image workers with OxiPNG's internal Rayon pool.
    # Reserve four logical CPUs for LZMA2, orchestration and the desktop,
    # then divide the remaining CPU budget across active image workers.
    spare_image_threads=$((CPU_THREADS - 4))
    (( spare_image_threads < 1 )) && spare_image_threads=1
    if [[ $IMAGE_JOBS == auto ]]; then
        IMAGE_JOBS_EFFECTIVE=$((spare_image_threads / 2))
        (( IMAGE_JOBS_EFFECTIVE < 1 )) && IMAGE_JOBS_EFFECTIVE=1
        (( IMAGE_JOBS_EFFECTIVE > 4 )) && IMAGE_JOBS_EFFECTIVE=4
        (( IMAGE_JOBS_EFFECTIVE > IMAGE_COUNT )) && IMAGE_JOBS_EFFECTIVE=$IMAGE_COUNT
    else
        IMAGE_JOBS_EFFECTIVE=$IMAGE_JOBS
        (( IMAGE_JOBS_EFFECTIVE > CPU_THREADS )) && IMAGE_JOBS_EFFECTIVE=$CPU_THREADS
        (( IMAGE_JOBS_EFFECTIVE > IMAGE_COUNT )) && IMAGE_JOBS_EFFECTIVE=$IMAGE_COUNT
    fi
    IMAGE_THREADS_PER_WORKER=$((spare_image_threads / IMAGE_JOBS_EFFECTIVE))
    (( IMAGE_THREADS_PER_WORKER < 1 )) && IMAGE_THREADS_PER_WORKER=1
else
    IMAGE_JOBS_EFFECTIVE=0
    IMAGE_THREADS_PER_WORKER=1
    IMAGE_PARALLEL=false
fi

VIDEO_PARALLEL_RESERVE_MIB=0
if $VIDEO_TRANSCODE && $VIDEO_PARALLEL && (( VIDEO_TRANSCODE_COUNT > 0 )); then
    VIDEO_PARALLEL_RESERVE_MIB=2048
fi
IMAGE_PARALLEL_RESERVE_MIB=0
if (( IMAGE_JOBS_EFFECTIVE > 0 )); then
    IMAGE_PARALLEL_RESERVE_MIB=$((IMAGE_JOBS_EFFECTIVE * 256))
fi

MEMORY_BUDGET_MIB=$((MEM_AVAILABLE_MIB - OS_RESERVE_MIB))
TOTAL_MEMORY_CAP_MIB=$((MEM_TOTAL_MIB * 85 / 100))
(( MEMORY_BUDGET_MIB > TOTAL_MEMORY_CAP_MIB )) && MEMORY_BUDGET_MIB=$TOTAL_MEMORY_CAP_MIB
(( MEMORY_BUDGET_MIB < 256 )) && MEMORY_BUDGET_MIB=256

# BT4 needs roughly 10.5-11.5 times the dictionary size for compression.
# An additional 512 MiB is reserved for 7-Zip buffers and process overhead.
if (( MEMORY_BUDGET_MIB > 512 )); then
    MAX_DICTIONARY_BY_RAM_MIB=$(((MEMORY_BUDGET_MIB - 512) * 2 / 23))
else
    MAX_DICTIONARY_BY_RAM_MIB=4
fi

NONVIDEO_MIB=$(((NONVIDEO_BYTES + MIB - 1) / MIB))
(( NONVIDEO_MIB < 4 )) && NONVIDEO_MIB=4

DICTIONARY_CANDIDATES=(4096 3072 2048 1536 1024 768 512 384 256 192 128 96 64 48 32 24 16 12 8 4)

AUTO_DICTIONARY_LIMIT_MIB=$MAX_FORMAT_DICTIONARY_MIB
(( AUTO_DICTIONARY_LIMIT_MIB > MAX_DICTIONARY_BY_RAM_MIB )) && \
    AUTO_DICTIONARY_LIMIT_MIB=$MAX_DICTIONARY_BY_RAM_MIB
(( AUTO_DICTIONARY_LIMIT_MIB > NONVIDEO_MIB )) && \
    AUTO_DICTIONARY_LIMIT_MIB=$NONVIDEO_MIB

AUTO_DICTIONARY_MIB=4
for candidate in "${DICTIONARY_CANDIDATES[@]}"; do
    if (( candidate <= AUTO_DICTIONARY_LIMIT_MIB )); then
        AUTO_DICTIONARY_MIB=$candidate
        break
    fi
done

DICTIONARY_WAS_OVERRIDDEN=false
if [[ -n $DICTIONARY_OVERRIDE ]]; then
    DICTIONARY_WAS_OVERRIDDEN=true
    DICTIONARY_MIB=$(parse_size_mib "$DICTIONARY_OVERRIDE") || \
        die "Invalid dictionary size: $DICTIONARY_OVERRIDE"
    (( DICTIONARY_MIB >= 4 )) || die "Dictionary must be at least 4 MiB."

    # This is a format/encoder limit, not merely a safety recommendation, so it
    # cannot be bypassed by confirmation.
    (( DICTIONARY_MIB <= MAX_FORMAT_DICTIONARY_MIB )) || \
        die "This 7-Zip version supports at most ${MAX_FORMAT_DICTIONARY_MIB} MiB."

    ESTIMATED_OVERRIDE_RAM_MIB=$((DICTIONARY_MIB * 23 / 2 + 512))

    if (( ESTIMATED_OVERRIDE_RAM_MIB > MEMORY_BUDGET_MIB )); then
        printf '\nUnsafe manual dictionary override\n' >&2
        printf '════════════════════════════════════════════════════════════════\n' >&2
        printf 'Requested dictionary:       %s MiB\n' "$DICTIONARY_MIB" >&2
        printf 'Estimated compression RAM:  %s MiB\n' "$ESTIMATED_OVERRIDE_RAM_MIB" >&2
        printf 'Currently available RAM:    %s MiB\n' "$MEM_AVAILABLE_MIB" >&2
        printf 'Script safety budget:       %s MiB\n' "$MEMORY_BUDGET_MIB" >&2
        printf 'Automatic safe dictionary:  %s MiB\n' "$AUTO_DICTIONARY_MIB" >&2
        printf '════════════════════════════════════════════════════════════════\n' >&2
        warn "This can cause heavy swapping, an out-of-memory kill, or a failed archive run."

        if $ANALYZE_ONLY; then
            warn "Analysis only: a real run will ask for confirmation unless --yes is used."
        elif $ASSUME_YES; then
            warn "Continuing because --yes was supplied."
        else
            answer=""
            if [[ -r /dev/tty ]]; then
                printf 'Try the requested dictionary anyway? [y/N]: ' >&2
                IFS= read -r answer </dev/tty || true
            else
                die "Cannot ask for confirmation without a terminal. Re-run with --yes to force this dictionary."
            fi

            case ${answer,,} in
                y|yes)
                    warn "Proceeding with the requested dictionary."
                    ;;
                *)
                    die "Cancelled. Remove --dictionary to use ${AUTO_DICTIONARY_MIB} MiB automatically."
                    ;;
            esac
        fi
    fi
else
    DICTIONARY_MIB=$AUTO_DICTIONARY_MIB
fi

if [[ -n $THREADS_OVERRIDE ]]; then
    [[ $THREADS_OVERRIDE =~ ^[0-9]+$ ]] || die "Threads must be an integer."
    (( THREADS_OVERRIDE >= 1 )) || die "Threads must be at least 1."
    THREADS=$THREADS_OVERRIDE
    (( THREADS <= CPU_THREADS )) || {
        warn "Requested $THREADS threads, but only $CPU_THREADS are online; using $CPU_THREADS."
        THREADS=$CPU_THREADS
    }
else
    if (( CPU_THREADS >= 2 )); then
        THREADS=2
    else
        THREADS=1
    fi
fi

if (( THREADS > 2 )); then
    warn "More than 2 LZMA2 threads can split the stream and slightly reduce compression ratio."
fi

build_mc_sample() {
    local target_bytes=$((MC_AUTO_SAMPLE_MIB * MIB))
    local per_file_cap remaining take source_path file_size relative_path
    local first middle last middle_offset end_offset

    MC_SAMPLE_DIR=$(mktemp -d -p "$JOB_WORK_DIR" ".hardcore-mc-sample.XXXXXX")
    MC_SAMPLE_FILE="$MC_SAMPLE_DIR/representative-sample.bin"
    : > "$MC_SAMPLE_FILE"

    if (( NONVIDEO_COUNT > 0 )); then
        per_file_cap=$((target_bytes / NONVIDEO_COUNT))
    else
        per_file_cap=$target_bytes
    fi
    (( per_file_cap < 1 * MIB )) && per_file_cap=$((1 * MIB))
    (( per_file_cap > 16 * MIB )) && per_file_cap=$((16 * MIB))

    while IFS= read -r -d '' file_size && IFS= read -r -d '' relative_path; do
        is_video_path "$relative_path" && continue
        is_image_path "$relative_path" && continue
        $NESTED_REPACK && is_nested_archive_path "$relative_path" && continue
        $CONTAINER_REPACK && is_format_preserving_container_path "$relative_path" && continue
        is_already_compressed_path "$relative_path" && continue
        remaining=$((target_bytes - $(stat -c '%s' -- "$MC_SAMPLE_FILE")))
        (( remaining > 0 )) || break

        take=$file_size
        (( take > per_file_cap )) && take=$per_file_cap
        (( take > remaining )) && take=$remaining
        (( take > 0 )) || continue
        source_path="$SOURCE_PARENT/$relative_path"

        if (( file_size <= take || take < 3 * MIB )); then
            head -c "$take" -- "$source_path" >> "$MC_SAMPLE_FILE"
        else
            first=$((take / 3))
            middle=$((take / 3))
            last=$((take - first - middle))
            middle_offset=$(((file_size - middle) / 2))
            end_offset=$((file_size - last))

            head -c "$first" -- "$source_path" >> "$MC_SAMPLE_FILE"
            dd if="$source_path" of="$MC_SAMPLE_FILE" iflag=skip_bytes,count_bytes \
                oflag=append conv=notrunc skip="$middle_offset" count="$middle" status=none
            dd if="$source_path" of="$MC_SAMPLE_FILE" iflag=skip_bytes,count_bytes \
                oflag=append conv=notrunc skip="$end_offset" count="$last" status=none
        fi
    done < "$INVENTORY_RAW"
}

auto_tune_match_cycles() {
    local sample_bytes sample_mib sample_dictionary=4 candidate archive rc
    local started_ns ended_ns elapsed_ms archive_size best_size=0 tolerance selected
    local successful=0 free_bytes tuning_space_needed=$((MC_AUTO_SAMPLE_MIB * MIB * 6))
    local -a candidates=(0 250 500 1000)
    local -a dictionary_candidates=(64 48 32 24 16 12 8 4)
    local -A result_size=() result_time=() result_status=()

    free_bytes=$(df -PB1 -- "$JOB_WORK_DIR" | awk 'NR==2 {print $4}')
    if (( free_bytes < tuning_space_needed )); then
        MC_AUTO_RESULT="skipped; insufficient temporary space for bounded tuning"
        warn "Skipping match-cycle tuning because it may need up to $(human_bytes "$tuning_space_needed") temporarily."
        return 0
    fi

    build_mc_sample
    sample_bytes=$(stat -c '%s' -- "$MC_SAMPLE_FILE" 2>/dev/null || printf '0')
    if (( sample_bytes < 8 * MIB )); then
        MC_AUTO_RESULT="skipped; less than 8 MiB of representative data"
        rm -rf --one-file-system -- "$MC_SAMPLE_DIR"
        MC_SAMPLE_DIR=""
        MC_SAMPLE_FILE=""
        return 0
    fi

    sample_mib=$(((sample_bytes + MIB - 1) / MIB))
    for candidate in "${dictionary_candidates[@]}"; do
        if (( candidate <= sample_mib && candidate <= DICTIONARY_MIB )); then
            sample_dictionary=$candidate
            break
        fi
    done

    : > "$MC_TUNING_LOG"
    printf '\nTuning LZMA match cycles on a bounded representative sample...\n'
    printf 'Sample: %s | dictionary: %s MiB | timeout: %ss per candidate\n' \
        "$(human_bytes "$sample_bytes")" "$sample_dictionary" "$MC_AUTO_TIMEOUT_SECONDS"
    printf '%-10s %-12s %-14s %-12s\n' 'mc' 'size' 'exact bytes' 'elapsed'

    for candidate in "${candidates[@]}"; do
        archive="$MC_SAMPLE_DIR/mc-${candidate}.7z"
        rm -f -- "$archive"
        printf '%-10s ' "$candidate"
        started_ns=$(date +%s%N)
        set +e
        timeout --signal=TERM --kill-after=5s "$MC_AUTO_TIMEOUT_SECONDS" \
            "$SEVEN_ZIP" a "$archive" "$MC_SAMPLE_FILE" \
                -t7z -mx=9 \
                "-m0=LZMA2:d=${sample_dictionary}m:fb=273:mf=bt4:mc=${candidate}:a=1" \
                -mmt=2 -myx=9 -ms=on -mhc=off -bso0 -bsp0 -bse0 -y \
                >>"$MC_TUNING_LOG" 2>&1
        rc=$?
        set -e
        ended_ns=$(date +%s%N)
        elapsed_ms=$(((ended_ns - started_ns) / 1000000))

        if (( rc == 0 )) && [[ -s $archive ]]; then
            archive_size=$(stat -c '%s' -- "$archive")
            result_size[$candidate]=$archive_size
            result_time[$candidate]=$elapsed_ms
            result_status[$candidate]=ok
            successful=$((successful + 1))
            if (( best_size == 0 || archive_size < best_size )); then
                best_size=$archive_size
            fi
            printf '%-12s %-14s %s\n' "$(human_bytes "$archive_size")" "$archive_size" \
                "$(LC_NUMERIC=C awk -v ms="$elapsed_ms" 'BEGIN {printf "%.1fs",ms/1000}')"
        elif (( rc == 124 || rc == 137 )); then
            result_status[$candidate]=timeout
            printf '%-12s %-14s %s\n' 'timed out' '-' \
                "${MC_AUTO_TIMEOUT_SECONDS}s cap"
        else
            result_status[$candidate]=failed
            printf '%-12s %-14s %s\n' "failed ($rc)" '-' '-'
        fi
    done

    if (( successful >= 2 && best_size > 0 )); then
        tolerance=$((best_size / 5000))
        (( tolerance < 256 )) && tolerance=256
        selected=""
        for candidate in "${candidates[@]}"; do
            [[ ${result_status[$candidate]:-} == ok ]] || continue
            if (( result_size[$candidate] <= best_size + tolerance )); then
                selected=$candidate
                break
            fi
        done
        if [[ -n $selected ]]; then
            SEARCH_CYCLES=$selected
            MC_SAMPLE_RATIO=$(LC_NUMERIC=C awk -v packed="${result_size[$selected]}" -v source="$sample_bytes" 'BEGIN {if(source>0) printf "%.8f", packed/source}')
            MC_SAMPLE_SECONDS_PER_MIB=$(LC_NUMERIC=C awk -v ms="${result_time[$selected]}" -v mib="$sample_mib" 'BEGIN {if(mib>0) printf "%.6f", (ms/1000)/mib}')
            if (( selected == 0 )); then
                MC_AUTO_RESULT="selected mc=0 (7-Zip default, about 152 cycles); on the measured compression plateau"
                printf 'Selected mc=0 (7-Zip default, about 152 cycles): the lowest search cost within 0.02%% (or 256 bytes) of the smallest sample.\n'
            else
                MC_AUTO_RESULT="selected mc=${selected}; on the measured compression plateau"
                printf 'Selected mc=%s: the lowest search cost within 0.02%% (or 256 bytes) of the smallest sample.\n' \
                    "$SEARCH_CYCLES"
            fi
        fi
    else
        MC_AUTO_RESULT="inconclusive; kept preset mc=${SEARCH_CYCLES}"
        warn "Match-cycle tuning was inconclusive; keeping mc=${SEARCH_CYCLES}."
    fi

    rm -rf --one-file-system -- "$MC_SAMPLE_DIR"
    MC_SAMPLE_DIR=""
    MC_SAMPLE_FILE=""
}

if $MC_AUTO && ! $SEARCH_CYCLES_EXPLICIT; then
    if $ANALYZE_ONLY; then
        MC_AUTO_RESULT="enabled; bounded sample runs during a real archive"
    elif (( NONVIDEO_BYTES >= 8 * MIB )); then
        auto_tune_match_cycles
    else
        MC_AUTO_RESULT="skipped; too little non-video data"
    fi
else
    MC_AUTO_RESULT="disabled; using requested preset/value"
fi

ESTIMATED_COMPRESSION_RAM_MIB=$((DICTIONARY_MIB * 23 / 2 + 512))

# Preserve compression quality first. The dictionary above is selected exactly
# as if LZMA2 were running alone. Media jobs may overlap only when the memory
# left after that full-quality plan can safely accommodate them.
PARALLEL_SPARE_MIB=$((MEMORY_BUDGET_MIB - ESTIMATED_COMPRESSION_RAM_MIB))
(( PARALLEL_SPARE_MIB < 0 )) && PARALLEL_SPARE_MIB=0

if $VIDEO_TRANSCODE && (( VIDEO_TRANSCODE_COUNT > 0 )) && $VIDEO_PARALLEL; then
    if (( VIDEO_PARALLEL_RESERVE_MIB > PARALLEL_SPARE_MIB )); then
        if $VIDEO_PARALLEL_EXPLICIT; then
            warn "Forced parallel video work exceeds the spare-RAM plan; compression settings remain pinned, but memory pressure may increase."
        else
            VIDEO_PARALLEL=false
            VIDEO_PARALLEL_RESERVE_MIB=0
            warn "Video work will run sequentially so the full LZMA2 dictionary is preserved without memory pressure."
        fi
    fi
fi

MEDIA_SPARE_MIB=$((PARALLEL_SPARE_MIB - VIDEO_PARALLEL_RESERVE_MIB))
(( MEDIA_SPARE_MIB < 0 )) && MEDIA_SPARE_MIB=0
if (( IMAGE_COUNT > 0 && IMAGE_JOBS_EFFECTIVE > 0 )); then
    while (( IMAGE_JOBS_EFFECTIVE > 1 && IMAGE_JOBS_EFFECTIVE * 256 > MEDIA_SPARE_MIB )); do
        IMAGE_JOBS_EFFECTIVE=$((IMAGE_JOBS_EFFECTIVE - 1))
    done
    IMAGE_PARALLEL_RESERVE_MIB=$((IMAGE_JOBS_EFFECTIVE * 256))
    if (( IMAGE_PARALLEL_RESERVE_MIB > MEDIA_SPARE_MIB )); then
        IMAGE_PARALLEL=false
        IMAGE_PARALLEL_RESERVE_MIB=0
        warn "Lossless image optimization will run sequentially so it cannot reduce the LZMA2 dictionary or force swapping."
    fi
fi

FREE_DESTINATION_BYTES=$(df -PB1 -- "$ARCHIVE_PARENT" | awk 'NR==2 {print $4}')
FREE_WORK_BYTES=$(df -PB1 -- "$JOB_WORK_DIR" | awk 'NR==2 {print $4}')
DESTINATION_REQUIRED_BYTES=$((TOTAL_BYTES - VIDEO_OMITTED_BYTES + 128 * MIB))
WORK_REQUIRED_BYTES=$((256 * MIB))
if $VIDEO_TRANSCODE && (( VIDEO_TRANSCODE_COUNT > 0 )); then
    WORK_REQUIRED_BYTES=$((WORK_REQUIRED_BYTES + VIDEO_TRANSCODE_BYTES + LARGEST_TRANSCODE_VIDEO_BYTES))
fi
if (( IMAGE_COUNT > 0 )); then
    WORK_REQUIRED_BYTES=$((WORK_REQUIRED_BYTES + IMAGE_BYTES + LARGEST_IMAGE_BYTES))
fi
if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
    WORK_REQUIRED_BYTES=$((WORK_REQUIRED_BYTES + TOTAL_BYTES - VIDEO_OMITTED_BYTES + 128 * MIB))
fi
if same_filesystem "$ARCHIVE_PARENT" "$JOB_WORK_DIR"; then
    SHARED_FILESYSTEM=true
    SHARED_REQUIRED_BYTES=$((DESTINATION_REQUIRED_BYTES + WORK_REQUIRED_BYTES))
else
    SHARED_FILESYSTEM=false
    SHARED_REQUIRED_BYTES=0
fi

if [[ -n $MC_SAMPLE_RATIO ]]; then
    ESTIMATED_ARCHIVE_BYTES=$(LC_NUMERIC=C awk -v nonvideo="$NONVIDEO_BYTES" -v ratio="$MC_SAMPLE_RATIO" -v copy="$COPY_BYTES" -v container="$CONTAINER_BYTES" -v video="$VIDEO_SELECTED_BYTES" -v image="$IMAGE_BYTES" -v nested="$NESTED_BYTES" 'BEGIN {printf "%.0f", nonvideo*ratio+copy+container+video+image+nested}')
fi
if [[ -n $MC_SAMPLE_SECONDS_PER_MIB ]]; then
    ESTIMATED_SECONDS=$(LC_NUMERIC=C awk -v mib="$NONVIDEO_MIB" -v rate="$MC_SAMPLE_SECONDS_PER_MIB" 'BEGIN {printf "%.0f", mib*rate}')
fi

printf '\nSystem-adaptive archive plan\n'
printf '════════════════════════════════════════════════════════════════\n'
printf 'Script version:          %s\n' "$SCRIPT_VERSION"
printf 'Platform:                %s\n' "$(platform_os_version)"
printf 'Dependency preflight:    %s\n' "$DEPENDENCY_PREFLIGHT_SUMMARY"
printf 'Source:                  %s\n' "$SOURCE"
printf 'Output:                  %s%s\n' "$ARCHIVE" "$($OUTPUT_WAS_AUTOMATIC && printf ' (automatic)' || true)"
printf '7-Zip executable:        %s\n' "$SEVEN_ZIP"
printf '7-Zip version:           %s\n' "${SEVEN_ZIP_VERSION:-Unknown}"
printf 'CPU:                     %s\n' "$CPU_MODEL"
printf 'Logical CPU threads:     %s\n' "$CPU_THREADS"
printf 'Compression threads:     %s\n' "$THREADS"
printf 'RAM total:               %s MiB\n' "$MEM_TOTAL_MIB"
printf 'RAM currently available: %s MiB\n' "$MEM_AVAILABLE_MIB"
printf 'RAM kept free:           %s MiB\n' "$OS_RESERVE_MIB"
if (( VIDEO_PARALLEL_RESERVE_MIB > 0 )); then
    printf 'RAM reserved for video:  %s MiB\n' "$VIDEO_PARALLEL_RESERVE_MIB"
fi
if (( IMAGE_PARALLEL_RESERVE_MIB > 0 )); then
    printf 'RAM reserved for images: %s MiB\n' "$IMAGE_PARALLEL_RESERVE_MIB"
fi
printf 'Swap:                    %s MiB total / %s MiB free (not used for sizing)\n' \
    "$SWAP_TOTAL_MIB" "$SWAP_FREE_MIB"
printf 'Files:                   %s\n' "$TOTAL_FILE_COUNT"
printf 'Source file data:        %s\n' "$(human_bytes "$TOTAL_BYTES")"
printf 'Video files detected:    %s files / %s\n' \
    "$VIDEO_COUNT" "$(human_bytes "$VIDEO_BYTES")"
if (( VIDEO_COUNT > 0 )); then
    if $VIDEO_TRANSCODE; then
        printf 'Video handling:          Transcode smaller validated results; Copy fallback\n'
        printf 'Special video policy:   %s (%s detected, %s preserved, %s conversion candidates, %s omitted)\n' \
            "$VIDEO_SPECIAL_POLICY" "$VIDEO_SPECIAL_COUNT" "$VIDEO_SPECIAL_PRESERVE_COUNT" \
            "$VIDEO_SPECIAL_CONVERT_COUNT" "$VIDEO_OMITTED_COUNT"
        printf 'Video codec:             %s\n' "${VIDEO_CODEC^^}"
        printf 'Video encoder:           %s\n' "${VIDEO_ENCODER:-Automatic hardware-first selection}"
        printf 'Video execution:         %s separate process\n' "$($VIDEO_PARALLEL && printf 'Parallel' || printf 'Sequential')"
        printf 'Video scaling:           %s\n' "$($VIDEO_NO_SCALE && printf 'Disabled' || printf 'Automatic recommendation')"
        printf 'Video denoising:         %s\n' "$($VIDEO_NO_DENOISE && printf 'Disabled' || printf 'Automatic recommendation')"
        printf 'Video audio:             %s\n' "$($VIDEO_COPY_AUDIO && printf 'Copy unchanged' || printf 'Automatic Opus optimization')"
        printf 'Minimum video saving:    %s%%\n' "$VIDEO_MIN_SAVINGS_PERCENT"
        printf 'Minimum video VMAF:      %s\n' "$VIDEO_MIN_VMAF"
printf 'Video preflight:         %s\n' "$($VIDEO_PREFLIGHT && printf 'Three representative segments' || printf 'Disabled')"
        printf 'Video manifest:          %s\n' "$($VIDEO_WRITE_MANIFEST && printf 'Included' || printf 'Disabled')"
    else
        printf 'Video handling:          Store originals without compression\n'
    fi
fi
printf 'Image files detected:    %s files / %s (JPEG %s, PNG %s)\n' \
    "$IMAGE_COUNT" "$(human_bytes "$IMAGE_BYTES")" "$IMAGE_JPEG_COUNT" "$IMAGE_PNG_COUNT"
if (( IMAGE_COUNT > 0 )); then
    printf 'Image handling:          %s\n' "$($IMAGE_OPTIMIZE && $IMAGE_OPTIMIZER_AVAILABLE && printf 'Lossless optimize, validate, Copy fallback' || printf 'Store originals with Copy')"
    printf 'Image optimizer tools:   %s\n' "$IMAGE_TOOL_SUMMARY"
    printf 'Image mode/workers:      %s / %s\n' "$IMAGE_MODE" "$IMAGE_JOBS_EFFECTIVE"
    if ! $IMAGE_OPTIMIZER_AVAILABLE || ! $IMAGE_OPTIMIZE; then
        printf 'Image execution:         No optimizer process; originals use Copy\n'
    else
        printf 'Image execution:         %s\n' "$($IMAGE_PARALLEL && printf 'Parallel with LZMA2' || printf 'Sequential before LZMA2')"
    fi
fi
printf 'LZMA2 lane:              %s files / %s\n' \
    "$NONVIDEO_COUNT" "$(human_bytes "$NONVIDEO_BYTES")"
printf 'Container repack lane:   %s files / %s\n' \
    "$CONTAINER_COUNT" "$(human_bytes "$CONTAINER_BYTES")"
printf 'Copy lane:               %s files / %s\n' \
    "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"
printf 'Dictionary:              %s MiB\n' "$DICTIONARY_MIB"
printf 'Estimated compression RAM: %s MiB\n' "$ESTIMATED_COMPRESSION_RAM_MIB"
printf 'Match finder:            BT4\n'
printf 'Fast bytes:              273 (maximum)\n'
printf 'Compression effort:      %s\n' "$EFFORT"
printf 'MC sample tuning:        %s\n' "$($MC_AUTO && printf 'Enabled (%s)' "$MC_AUTO_RESULT" || printf 'Disabled')"
if (( SEARCH_CYCLES == 0 )); then
    printf 'Match cycles:            0 (7-Zip default, about 152 at fb=273)\n'
    printf 'Match-cycle intensity:   7-Zip calculated default\n'
else
    printf 'Match cycles:            %s\n' "$SEARCH_CYCLES"
    awk -v mc="$SEARCH_CYCLES" 'BEGIN {
        printf "Match-cycle intensity:   about %.1fx the BT4 default at fb=273\n", mc / 152
    }' 
fi
printf 'File analysis:           Level 9\n'
printf 'Solid sorting:           By file type across all subfolders\n'
printf 'Sleep protection:        %s\n' "$($ALLOW_SLEEP && printf 'Disabled' || { $SLEEP_PROTECTION_ACTIVE && printf 'Active' || printf 'Unavailable'; })"
printf 'After verification:      %s\n' "$($REMOVE_SOURCE && printf 'DELETE SOURCE' || printf 'Keep source')"
printf 'Destination free space:  %s\n' "$(human_bytes "$FREE_DESTINATION_BYTES")"
printf 'Working free space:      %s\n' "$(human_bytes "$FREE_WORK_BYTES")"
printf 'Output filesystem:       %s (%s)\n' "$(filesystem_type "$ARCHIVE_PARENT")" "$(filesystem_source "$ARCHIVE_PARENT")"
printf 'Working directory:       %s\n' "$JOB_WORK_DIR"
printf 'Working filesystem:      %s (%s)\n' "$(filesystem_type "$JOB_WORK_DIR")" "$(filesystem_source "$JOB_WORK_DIR")"
printf 'Resume cache:            %s\n' "$($RESUME_ENABLED && printf 'Enabled' || printf 'Disabled')"
printf 'Verification:            %s\n' "$VERIFY_MODE_EFFECTIVE"
printf 'Filesystem boundary:     %s\n' "$($ONE_FILE_SYSTEM && printf 'One source filesystem' || printf 'Cross nested mounts')"
printf 'Quality preflight:       %s\n' "$QUALITY_CHECK"
printf 'Video policy:            %s\n' "$VIDEO_MODE"
if (( ESTIMATED_ARCHIVE_BYTES > 0 )); then
    printf 'Estimated archive size:  approximately %s before transform savings\n' "$(human_bytes "$ESTIMATED_ARCHIVE_BYTES")"
fi
if (( ESTIMATED_SECONDS > 0 )); then
    printf 'Estimated LZMA time:     approximately %s (sample-derived)\n' "$(format_duration "$ESTIMATED_SECONDS")"
fi
if [[ -s $NESTED_MOUNTS_LIST ]]; then
    printf 'Nested mounts detected:  %s\n' "$(wc -l < "$NESTED_MOUNTS_LIST")"
fi
printf '════════════════════════════════════════════════════════════════\n\n'

if (( SEARCH_CYCLES > 1000 )); then
    warn "This manual match-cycle value exceeds the script's maximum sensible preset."
    warn "Values above 1000 usually add substantial runtime for only a very small possible ratio gain."
fi

if $SHARED_FILESYSTEM; then
    if (( FREE_DESTINATION_BYTES < SHARED_REQUIRED_BYTES )); then
        die "The shared output/work filesystem needs approximately $(human_bytes "$SHARED_REQUIRED_BYTES") free in the conservative worst case."
    fi
else
    (( FREE_DESTINATION_BYTES >= DESTINATION_REQUIRED_BYTES )) ||         die "The destination needs approximately $(human_bytes "$DESTINATION_REQUIRED_BYTES") free in the conservative worst case."
    (( FREE_WORK_BYTES >= WORK_REQUIRED_BYTES )) ||         die "The working filesystem needs approximately $(human_bytes "$WORK_REQUIRED_BYTES") free for staging and resume data."
fi

if $REMOVE_SOURCE && $VIDEO_TRANSCODE && (( VIDEO_COUNT > 0 )); then
    warn "--remove-source explicitly authorizes deletion after verified lossy video replacement."
    warn "Use --no-video-transcode when original video bitstreams must be preserved."
fi

if $ANALYZE_ONLY; then
    printf 'Analysis completed; no files were changed.\n'
    exit 0
fi

if [[ ${HARDCORE_ARCHIVE_INHIBITED:-0} == 1 ]]; then
    printf 'Sleep protection is active for the complete archive operation.\n\n'
fi


# HARDCORE_VISUAL_MODE_V1
HARDCORE_VISUAL_ENABLED=false
if [[ ${HARDCORE_ARCHIVE_VISUAL:-0} == 1 && ${HARDCORE_ARCHIVE_NESTED_CHILD:-0} != 1 ]]; then
    HARDCORE_VISUAL_ENABLED=true
fi
HARDCORE_VISUAL_TERMINAL=''
HARDCORE_VISUAL_VIEWER_SCRIPT=''
declare -A HARDCORE_VISUAL_OPENED=()

hardcore_visual_detect_terminal() {
    $HARDCORE_VISUAL_ENABLED || return 0
    [[ -n $HARDCORE_VISUAL_TERMINAL ]] && return 0

    if [[ ${PLATFORM:-} == Linux && -z ${DISPLAY:-} && -z ${WAYLAND_DISPLAY:-} ]]; then
        die '--visual requires a graphical Linux session (DISPLAY or WAYLAND_DISPLAY).'
    fi

    local requested=${HARDCORE_ARCHIVE_VISUAL_TERMINAL:-} candidate
    if [[ -n $requested && $requested != *[[:space:]]* ]]; then
        candidate=${requested##*/}
        case $candidate in
            konsole|kitty|gnome-terminal|alacritty|wezterm|foot|xterm)
                command -v -- "$requested" >/dev/null 2>&1 || die "--visual terminal was requested but is unavailable: $requested"
                HARDCORE_VISUAL_TERMINAL=$candidate
                HARDCORE_VISUAL_TERMINAL_COMMAND=$requested
                return 0
                ;;
        esac
    fi

    for candidate in konsole kitty gnome-terminal alacritty wezterm foot xterm; do
        if command -v "$candidate" >/dev/null 2>&1; then
            HARDCORE_VISUAL_TERMINAL=$candidate
            HARDCORE_VISUAL_TERMINAL_COMMAND=$(command -v "$candidate")
            return 0
        fi
    done

    die '--visual needs a supported terminal emulator: konsole, kitty, gnome-terminal, alacritty, wezterm, foot, or xterm.'
}

hardcore_visual_prepare_viewer() {
    $HARDCORE_VISUAL_ENABLED || return 0
    [[ -n $HARDCORE_VISUAL_VIEWER_SCRIPT && -x $HARDCORE_VISUAL_VIEWER_SCRIPT ]] && return 0
    HARDCORE_VISUAL_VIEWER_SCRIPT="$JOB_WORK_DIR/.hardcore-visual-viewer.sh"
    cat > "$HARDCORE_VISUAL_VIEWER_SCRIPT" <<'__HARDCORE_VISUAL_VIEWER__'
#!/usr/bin/env bash
set -u
IFS=$'\n\t'
title=$1
mode=$2
target=$3
hold=${4:-8}
shift 4
files=("$@")

printf '%s\n' "$title"
printf '%s\n' '════════════════════════════════════════════════════════════'
printf 'Live log viewer. Closing this window does NOT stop the archive worker.\n'
printf 'Files:\n'
for file in "${files[@]}"; do
    printf '  %s\n' "$file"
    touch -- "$file" 2>/dev/null || true
done
printf '%s\n\n' '════════════════════════════════════════════════════════════'

tail -n +1 -F -- "${files[@]}" &
tail_pid=$!
cleanup() {
    kill "$tail_pid" 2>/dev/null || true
    wait "$tail_pid" 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

case $mode in
    pid)
        while kill -0 "$target" 2>/dev/null; do sleep 1; done
        ;;
    pattern)
        while true; do
            [[ -f ${files[0]} ]] && grep -Fq -- "$target" "${files[0]}" 2>/dev/null && break
            sleep 1
        done
        ;;
    *)
        while true; do sleep 3600; done
        ;;
esac

sleep 1
cleanup
trap - EXIT HUP INT TERM
printf '\nProcess/log stream finished. This viewer closes in %s seconds.\n' "$hold"
[[ $hold =~ ^[0-9]+$ ]] || hold=8
sleep "$hold"
__HARDCORE_VISUAL_VIEWER__
    chmod 700 -- "$HARDCORE_VISUAL_VIEWER_SCRIPT"
}

hardcore_visual_launch_terminal() {
    local title=$1 mode=$2 target=$3
    shift 3
    local hold=${HARDCORE_ARCHIVE_VISUAL_HOLD_SECONDS:-8}
    hardcore_visual_detect_terminal
    hardcore_visual_prepare_viewer

    case $HARDCORE_VISUAL_TERMINAL in
        konsole)
            "$HARDCORE_VISUAL_TERMINAL_COMMAND" --separate -p "tabtitle=$title" -e \
                "$HARDCORE_VISUAL_VIEWER_SCRIPT" "$title" "$mode" "$target" "$hold" "$@" >/dev/null 2>&1 &
            ;;
        kitty)
            "$HARDCORE_VISUAL_TERMINAL_COMMAND" --title "$title" \
                "$HARDCORE_VISUAL_VIEWER_SCRIPT" "$title" "$mode" "$target" "$hold" "$@" >/dev/null 2>&1 &
            ;;
        gnome-terminal)
            "$HARDCORE_VISUAL_TERMINAL_COMMAND" --title="$title" -- \
                "$HARDCORE_VISUAL_VIEWER_SCRIPT" "$title" "$mode" "$target" "$hold" "$@" >/dev/null 2>&1 &
            ;;
        alacritty)
            "$HARDCORE_VISUAL_TERMINAL_COMMAND" --title "$title" -e \
                "$HARDCORE_VISUAL_VIEWER_SCRIPT" "$title" "$mode" "$target" "$hold" "$@" >/dev/null 2>&1 &
            ;;
        wezterm)
            "$HARDCORE_VISUAL_TERMINAL_COMMAND" start --always-new-process -- \
                "$HARDCORE_VISUAL_VIEWER_SCRIPT" "$title" "$mode" "$target" "$hold" "$@" >/dev/null 2>&1 &
            ;;
        foot)
            "$HARDCORE_VISUAL_TERMINAL_COMMAND" --title="$title" \
                "$HARDCORE_VISUAL_VIEWER_SCRIPT" "$title" "$mode" "$target" "$hold" "$@" >/dev/null 2>&1 &
            ;;
        xterm)
            "$HARDCORE_VISUAL_TERMINAL_COMMAND" -T "$title" -e \
                "$HARDCORE_VISUAL_VIEWER_SCRIPT" "$title" "$mode" "$target" "$hold" "$@" >/dev/null 2>&1 &
            ;;
    esac
}

hardcore_visual_open_log() {
    $HARDCORE_VISUAL_ENABLED || return 0
    local title=$1 log=$2 mode=$3 target=$4 key extra
    shift 4
    key="$title|$log"
    [[ -n ${HARDCORE_VISUAL_OPENED[$key]:-} ]] && return 0
    HARDCORE_VISUAL_OPENED[$key]=1

    mkdir -p -- "$(dirname -- "$log")"
    touch -- "$log"
    for extra in "$@"; do
        mkdir -p -- "$(dirname -- "$extra")"
        touch -- "$extra"
    done
    hardcore_visual_launch_terminal "$title" "$mode" "$target" "$log" "$@"
}

hardcore_visual_validate() {
    $HARDCORE_VISUAL_ENABLED || return 0
    hardcore_visual_detect_terminal
    hardcore_visual_prepare_viewer
    printf 'Visual mode: enabled; live worker windows use %s.\n' "$HARDCORE_VISUAL_TERMINAL"
    printf 'Visual windows are viewers only; the main process still owns worker PIDs, cancellation, and exit status.\n\n'
}

hardcore_visual_validate

compress_nonvideo_with_fallback() {
    local initial_dictionary=$1
    local candidate rc
    local attempts=("$initial_dictionary")

    # Automatic mode may step down after a real allocation failure. An explicit
    # --dictionary request is attempted exactly as requested instead of being
    # silently replaced with a smaller value.
    if ! $DICTIONARY_WAS_OVERRIDDEN; then
        for candidate in "${DICTIONARY_CANDIDATES[@]}"; do
            (( candidate < initial_dictionary )) || continue
            attempts+=("$candidate")
        done
    fi

    for candidate in "${attempts[@]}"; do
        (( candidate <= MAX_FORMAT_DICTIONARY_MIB )) || continue
        (( candidate <= NONVIDEO_MIB )) || continue

        rm -f -- "$TEMP_ARCHIVE"
        : > "$SEVEN_ZIP_LOG"
        hardcore_visual_open_log "Hardcore Archive - 7-Zip / archive" "$SEVEN_ZIP_LOG" pid "$$"

        FAILURE_CONTEXT="lzma-compression"
        printf '\nStage 4/8: Compressing the LZMA2 lane with a %s MiB dictionary...\n' "$candidate"
        printf '7-Zip percentage output is enabled. A status line will also appear every %s seconds.\n\n' "$PROGRESS_INTERVAL"

        set +e
        run_logged_stage "LZMA2 compression" "$SEVEN_ZIP_LOG" \
            "$SEVEN_ZIP" a "$TEMP_ARCHIVE" "$SOURCE_NAME" \
                -t7z \
                -mx=9 \
                "-m0=LZMA2:d=${candidate}m:fb=273:mf=bt4:mc=${SEARCH_CYCLES}:a=1" \
                "-mmt=${THREADS}" \
                -myx=9 \
                -ms=on \
                -mqs=on \
                -mhc=on \
                -snl \
                -snh \
                -spd \
                -scsUTF-8 \
                -bsp1 \
                -y \
                "-x@${VIDEO_LIST}" \
                "-x@${IMAGE_LIST}" \
                "-x@${NESTED_LIST}" \
                "-x@${CONTAINER_LIST}" \
                "-x@${COPY_LIST}"
        rc=$?
        set -e

        if (( rc == 0 )); then
            DICTIONARY_MIB=$candidate
            ESTIMATED_COMPRESSION_RAM_MIB=$((candidate * 23 / 2 + 512))
            return 0
        fi

        if (( rc == 8 )) || grep -Eqi \
            'not enough memory|out of memory|cannot allocate memory|memory allocation' \
            "$SEVEN_ZIP_LOG"; then
            if $DICTIONARY_WAS_OVERRIDDEN; then
                die "7-Zip could not allocate the explicitly requested ${candidate} MiB dictionary. The script did not substitute a smaller value."
            fi
            warn "The ${candidate} MiB dictionary could not be allocated. Retrying with a smaller dictionary."
            continue
        fi

        printf '\n7-Zip failed with exit code %s. The source was not removed.\n' "$rc" >&2
        return "$rc"
    done

    die "No usable LZMA2 dictionary could be allocated."
}




process_format_preserving_containers() {
    (( CONTAINER_COUNT > 0 )) || return 0
    $CONTAINER_REPACK || return 0
    [[ -n $CONTAINER_HELPER && -f $CONTAINER_HELPER ]] || \
        die "Format-preserving container repack is enabled, but its helper is missing: ${CONTAINER_HELPER:-unset}"

    FAILURE_CONTEXT="container-repack"
    printf '\nStage 6/8: Repacking format-preserving application containers...\n'
    printf 'Container candidates: %s files / %s\n' "$CONTAINER_COUNT" "$(human_bytes "$CONTAINER_BYTES")"
    CONTAINER_STAGE_PARENT=$(mktemp -d -p "$WORK_ROOT" containers.XXXXXX)
    : > "$CONTAINER_RESULT_MANIFEST"
    : > "$CONTAINER_REPACKED_LIST"
    : > "$CONTAINER_FALLBACK_LIST"

    if ! python3 "$CONTAINER_HELPER" \
        --source-parent "$SOURCE_PARENT" \
        --stage-parent "$CONTAINER_STAGE_PARENT" \
        --list "$CONTAINER_LIST" \
        --result "$CONTAINER_RESULT_MANIFEST"; then
        die "The format-preserving container helper reported an internal processing failure. Originals were not silently substituted."
    fi

    local action original archived original_size candidate_size archived_size reason
    local actual candidate_display accounted=0
    while IFS=$'\t' read -r action original archived original_size candidate_size archived_size reason; do
        [[ -n $original ]] || continue
        accounted=$((accounted + 1))
        [[ $original_size =~ ^[0-9]+$ && $candidate_size =~ ^[0-9]+$ && $archived_size =~ ^[0-9]+$ ]] || \
            die "Invalid container-repack result row for: $original"
        case $action in
            repacked)
                [[ $archived == "$original" ]] || die "Container repack changed the restored path: $original -> $archived"
                [[ -f $CONTAINER_STAGE_PARENT/$archived ]] || die "Validated container candidate disappeared: $archived"
                actual=$(stat -c '%s' -- "$CONTAINER_STAGE_PARENT/$archived")
                (( actual == candidate_size && actual == archived_size && actual < original_size )) || \
                    die "Container candidate size/accounting changed after validation: $original"
                printf '%s\n' "$archived" >> "$CONTAINER_REPACKED_LIST"
                CONTAINER_REPACKED_COUNT=$((CONTAINER_REPACKED_COUNT + 1))
                CONTAINER_REPACKED_BYTES=$((CONTAINER_REPACKED_BYTES + actual))
                CONTAINER_SAVED_BYTES=$((CONTAINER_SAVED_BYTES + original_size - actual))
                ;;
            original)
                [[ $archived == "$original" && $archived_size == "$original_size" ]] || \
                    die "Invalid original-container fallback accounting: $original"
                actual=$(stat -c '%s' -- "$SOURCE_PARENT/$original")
                (( actual == original_size )) || die "Source container changed during repack: $original"
                printf '%s\n' "$original" >> "$CONTAINER_FALLBACK_LIST"
                CONTAINER_FALLBACK_COUNT=$((CONTAINER_FALLBACK_COUNT + 1))
                CONTAINER_FALLBACK_BYTES=$((CONTAINER_FALLBACK_BYTES + original_size))
                ;;
            *) die "Unknown container-repack action '$action' for: $original" ;;
        esac
        if (( candidate_size > 0 )); then candidate_display=$(human_bytes "$candidate_size"); else candidate_display='not produced'; fi
        printf 'Container decision: %s | original %s | candidate %s | %s (%s)\n' \
            "$original" "$(human_bytes "$original_size")" "$candidate_display" \
            "$([[ $action == repacked ]] && printf 'REPACKED' || printf 'PRESERVED')" "$reason"
    done < "$CONTAINER_RESULT_MANIFEST"

    (( accounted == CONTAINER_COUNT )) || \
        die "Container repack accounted for $accounted of $CONTAINER_COUNT candidate files."

    if [[ -s $CONTAINER_REPACKED_LIST ]]; then
        ( cd -- "$CONTAINER_STAGE_PARENT" && \
            run_logged_stage "repacked-container storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -snl -snh -spd -scsUTF-8 -bsp1 -y "@${CONTAINER_REPACKED_LIST}" )
    fi
    if [[ -s $CONTAINER_FALLBACK_LIST ]]; then
        ( cd -- "$SOURCE_PARENT" && \
            run_logged_stage "original-container storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -snl -snh -spd -scsUTF-8 -bsp1 -y "@${CONTAINER_FALLBACK_LIST}" )
    fi

    {
        printf 'Hardcore Archive format-preserving container manifest\n'
        printf 'Script version: %s\n' "$SCRIPT_VERSION"
        printf 'Original container bytes: %s\n' "$CONTAINER_BYTES"
        printf 'Saved container bytes: %s\n' "$CONTAINER_SAVED_BYTES"
        printf '\nColumns: action<TAB>original path<TAB>archived path<TAB>original bytes<TAB>candidate bytes<TAB>archived bytes<TAB>reason\n'
        cat -- "$CONTAINER_RESULT_MANIFEST"
    } > "$CONTAINER_MANIFEST_FILE"
}

add_copy_lane_to_archive() {
    (( COPY_COUNT > 0 )) || return 0
    FAILURE_CONTEXT="copy-lane-storage"
    printf '\nStage 6/8: Storing content-confirmed incompressible files with Copy mode...\n'
    printf 'Copy lane: %s files / %s\n\n' "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"
    (
        cd -- "$SOURCE_PARENT"
        run_logged_stage "content-incompressible Copy storage" "$SEVEN_ZIP_LOG" \
            "$SEVEN_ZIP" a "$TEMP_ARCHIVE" \
                -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                -snl -snh -spd -scsUTF-8 -bsp1 -y \
                "@${COPY_LIST}"
    )
}

video_archived_relative() {
    local relative=$1 lower=${1,,}
    if [[ $lower == *.mkv ]]; then
        printf '%s' "$relative"
    else
        printf '%s.mkv' "${relative%.*}"
    fi
}

video_cache_key() {
    local relative=$1 source_path stat_value source_hash ffmpeg_version stream_signature
    source_path="$SOURCE_PARENT/$relative"
    stat_value=$(stat -c '%s:%Y:%Z:%i' -- "$source_path" 2>/dev/null || return 1)
    source_hash=$(sha256sum -- "$source_path" 2>/dev/null | awk '{print $1}') || return 1
    ffmpeg_version=$(ffmpeg -version 2>/dev/null | head -n1 || true)
    stream_signature=$(ffprobe -v error -show_entries stream=index,codec_type,codec_name,profile,width,height,pix_fmt,channels,sample_rate -of compact=p=0:nk=1 -- "$source_path" 2>/dev/null | sha256sum | awk '{print $1}')
    printf '%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0%s\0' \
        "$SCRIPT_VERSION" "$relative" "$stat_value" "$source_hash" "$stream_signature" \
        "$VIDEO_CODEC" "$VIDEO_ENCODER" "$VIDEO_MODE" "$VIDEO_MIN_VMAF" "$VIDEO_MIN_SAVINGS_PERCENT" \
        "$VIDEO_NO_SCALE" "$VIDEO_NO_DENOISE" "$VIDEO_AUDIO_COPY" "$QUALITY_CHECK" "$ffmpeg_version" \
        "video-preprocessing-v2-selection" "${HARDCORE_ARCHIVE_VIDEO_ACCELERATION:-auto}" \
        "${HARDCORE_ARCHIVE_VIDEO_GPU_FILTERS:-auto}" "${HARDCORE_ARCHIVE_VIDEO_CUDA_DEVICE:-0}" | \
        sha256sum | awk '{print $1}'
}

cache_completed_video_results() {
    [[ -n ${VIDEO_STAGE_PARENT:-} && -d $VIDEO_STAGE_PARENT && -d ${VIDEO_CACHE_DIR:-} ]] || return 0
    local relative staged_original staged_result archived_relative key cache_file temp
    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        if grep -Fq -- "$relative"$'\t' "$RESUME_MAP" 2>/dev/null; then
            continue
        fi
        staged_original="$VIDEO_STAGE_PARENT/$relative"
        archived_relative=$(video_archived_relative "$relative")
        staged_result="$VIDEO_STAGE_PARENT/$archived_relative"
        [[ -f $staged_result && ! -L $staged_result ]] || continue
        key=$(video_cache_key "$relative") || continue
        cache_file="$VIDEO_CACHE_DIR/${key}.mkv"
        [[ -s $cache_file ]] && continue
        temp="${cache_file}.partial.$$"
        if ln -- "$staged_result" "$temp" 2>/dev/null || cp --reflink=auto -- "$staged_result" "$temp" 2>/dev/null; then
            chmod 600 -- "$temp" 2>/dev/null || true
            mv -f -- "$temp" "$cache_file"
            printf '%s\t%s\t%s\n' "$relative" "$archived_relative" "$(stat -c '%s' -- "$cache_file")" \
                > "$VIDEO_CACHE_DIR/${key}.meta"
        else
            rm -f -- "$temp"
        fi
    done < "$VIDEO_LIST"
}

materialize_video_cache_hits() {
    local relative cache_file archived_relative destination
    while IFS=$'\t' read -r relative cache_file archived_relative; do
        [[ -n $relative && -s $cache_file ]] || continue
        destination="$VIDEO_STAGE_PARENT/$archived_relative"
        mkdir -p -- "$(dirname -- "$destination")"
        if ! ln -- "$cache_file" "$destination" 2>/dev/null; then
            cp --reflink=auto -- "$cache_file" "$destination"
        fi
        touch --reference="$SOURCE_PARENT/$relative" -- "$destination" 2>/dev/null || true
        chmod --reference="$SOURCE_PARENT/$relative" -- "$destination" 2>/dev/null || true
    done < "$RESUME_MAP"
}

prepare_video_stage() {
    VIDEO_STAGE_PARENT=$(mktemp -d -p "$JOB_WORK_DIR" ".hardcore-video-stage.XXXXXX")
    VIDEO_STAGE_ROOT="$VIDEO_STAGE_PARENT/$SOURCE_NAME"
    VIDEO_HELPER="$VIDEO_STAGE_PARENT/.compress-video-helper.sh"
    mkdir -p -- "$VIDEO_STAGE_ROOT"
    write_embedded_video_helper "$VIDEO_HELPER"

    local relative_path source_path staged_path archived_relative key cache_file actual_codec expected_codec
    : > "$RESUME_MAP"
    VIDEO_CACHE_HITS=0
    VIDEO_CACHE_MISSES=0
    [[ $VIDEO_CODEC == av1 ]] && expected_codec=av1 || expected_codec=hevc

    while IFS= read -r relative_path; do
        [[ -n $relative_path ]] || continue
        if hardcore_media_list_contains "$VIDEO_SPECIAL_PRESERVE_LIST" "$relative_path" ||
           hardcore_media_list_contains "$VIDEO_SPECIAL_OMIT_LIST" "$relative_path"; then
            continue
        fi
        source_path="$SOURCE_PARENT/$relative_path"
        archived_relative=$(video_archived_relative "$relative_path")
        key=$(video_cache_key "$relative_path") || key=''
        cache_file="$VIDEO_CACHE_DIR/${key}.mkv"
        if $RESUME_ENABLED && [[ -n $key && -s $cache_file ]]; then
            actual_codec=$(ffprobe -v error -select_streams V:0 -show_entries stream=codec_name                 -of default=nw=1:nk=1 "$cache_file" 2>/dev/null | head -n1)
            if [[ $actual_codec == "$expected_codec" ]]; then
                printf '%s	%s	%s
' "$relative_path" "$cache_file" "$archived_relative" >> "$RESUME_MAP"
                VIDEO_CACHE_HITS=$((VIDEO_CACHE_HITS + 1))
                continue
            fi
            rm -f -- "$cache_file" "$VIDEO_CACHE_DIR/${key}.meta"
        fi

        staged_path="$VIDEO_STAGE_PARENT/$relative_path"
        mkdir -p -- "$(dirname -- "$staged_path")"
        ln -s -- "$source_path" "$staged_path"
        VIDEO_CACHE_MISSES=$((VIDEO_CACHE_MISSES + 1))
    done < "$VIDEO_LIST"
}

video_helper_arguments() {
    VIDEO_HELPER_ARGS=(--batch --yes --replace)
    case "$VIDEO_CODEC" in
        av1) VIDEO_HELPER_ARGS+=(--av1) ;;
        hevc) VIDEO_HELPER_ARGS+=(--hevc) ;;
    esac
    [[ -n $VIDEO_ENCODER ]] && VIDEO_HELPER_ARGS+=(--encoder "$VIDEO_ENCODER")
    $VIDEO_NO_SCALE && VIDEO_HELPER_ARGS+=(--no-scale)
    $VIDEO_NO_DENOISE && VIDEO_HELPER_ARGS+=(--no-denoise)
    $VIDEO_COPY_AUDIO && VIDEO_HELPER_ARGS+=(--no-audio)
    $VIDEO_PREFLIGHT || VIDEO_HELPER_ARGS+=(--no-preflight)
    VIDEO_HELPER_ARGS+=(--quality-check "$QUALITY_CHECK")
    VIDEO_HELPER_ARGS+=(--quality-vmaf "$VIDEO_MIN_VMAF")
    VIDEO_HELPER_ARGS+=(--min-savings "$VIDEO_MIN_SAVINGS_PERCENT")
    VIDEO_HELPER_ARGS+=("$VIDEO_STAGE_ROOT")
}

start_video_pipeline() {
    prepare_video_stage
    video_helper_arguments
    : > "$VIDEO_LOG"

    printf 'Resume cache: %s hit(s), %s video(s) still require work.\n' \
        "$VIDEO_CACHE_HITS" "$VIDEO_CACHE_MISSES"
    if (( VIDEO_CACHE_MISSES == 0 )); then
        printf 'All validated video transcodes were recovered from the resume cache.\n'
        VIDEO_PIPELINE_PID=""
        return 0
    fi

    printf '\nStage 3/8: Starting integrated video compression in a separate process...\n'
    printf 'The original videos remain untouched. Valid smaller outputs are written only to temporary staging.\n'
    printf 'Detailed FFmpeg output is captured; combined status appears every %s seconds.\n\n' "$PROGRESS_INTERVAL"

    if command -v setsid >/dev/null 2>&1; then
        setsid env _IS_CHILD_PROCESS=1 bash "$VIDEO_HELPER" "${VIDEO_HELPER_ARGS[@]}" \
            >"$VIDEO_LOG" 2>&1 &
        VIDEO_PIPELINE_GROUP=true
    else
        env _IS_CHILD_PROCESS=1 bash "$VIDEO_HELPER" "${VIDEO_HELPER_ARGS[@]}" \
            >"$VIDEO_LOG" 2>&1 &
        VIDEO_PIPELINE_GROUP=false
    fi
    VIDEO_PIPELINE_PID=$!
    hardcore_visual_open_log "Hardcore Archive - Video / FFmpeg" "$VIDEO_LOG" pid "$VIDEO_PIPELINE_PID"
}

wait_for_video_pipeline() {
    if [[ -z ${VIDEO_PIPELINE_PID:-} ]]; then
        materialize_video_cache_hits
        return 0
    fi
    local started=$SECONDS heartbeat_pid='' rc

    if kill -0 "$VIDEO_PIPELINE_PID" 2>/dev/null; then
        printf '\nStage 5/8: Waiting for the video process to finish...\n'
        if (( PROGRESS_INTERVAL > 0 )); then
            heartbeat "video transcoding" "$VIDEO_PIPELINE_PID" "$started" &
            heartbeat_pid=$!
        fi
    else
        printf '\nStage 5/8: Video process has already finished.\n'
    fi

    set +e
    wait "$VIDEO_PIPELINE_PID"
    rc=$?
    set -e
    VIDEO_PIPELINE_PID=""

    if [[ -n $heartbeat_pid ]]; then
        kill "$heartbeat_pid" 2>/dev/null || true
        wait "$heartbeat_pid" 2>/dev/null || true
    fi

    if (( rc != 0 )); then
        warn "The integrated video batch returned exit code $rc."
        warn "Any validated smaller outputs will still be used; all remaining videos fall back to their originals."
        printf '\nLast video-compressor messages:\n' >&2
        tail -n 30 "$VIDEO_LOG" >&2 || true
    else
        awk '
            /^Batch summary$/ {show=1}
            show {print}
        ' "$VIDEO_LOG" | tail -n 8 || true
    fi
    cache_completed_video_results
    materialize_video_cache_hits

}

prepare_image_stage() {
    local helper_source
    IMAGE_STAGE_PARENT="$JOB_WORK_DIR/image-stage"
    IMAGE_STAGE_ROOT="$IMAGE_STAGE_PARENT/$SOURCE_NAME"
    rm -rf --one-file-system -- "$IMAGE_STAGE_PARENT"
    mkdir -p -- "$IMAGE_STAGE_ROOT"
    IMAGE_HELPER="$JOB_WORK_DIR/integrated-image-helper.sh"
    helper_source=${HARDCORE_ARCHIVE_IMAGE_HELPER_SOURCE:-"$(dirname -- "${BASH_SOURCE[0]}")/hardcore-archive-image-helper.sh"}
    [[ -f $helper_source ]] || die "Trusted image helper is missing: $helper_source"
    cp -- "$helper_source" "$IMAGE_HELPER"
    chmod 700 -- "$IMAGE_HELPER"
}

write_original_image_results() {
    : >"$IMAGE_RESULT_MANIFEST"
    local relative size
    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        size=$(stat -c '%s' -- "$SOURCE_PARENT/$relative")
        printf 'original\t%s\t%s\t%s\t%s\tdisabled-or-unavailable\n' \
            "$relative" "$relative" "$size" "$size" >>"$IMAGE_RESULT_MANIFEST"
    done <"$IMAGE_LIST"
}

start_image_pipeline() {
    (( IMAGE_COUNT > 0 )) || return 0
    prepare_image_stage

    if ! $IMAGE_OPTIMIZE || ! $IMAGE_OPTIMIZER_AVAILABLE; then
        write_original_image_results
        IMAGE_PIPELINE_PID=""
        return 0
    fi

    printf '\nStage 3/8: Starting lossless image optimization in a separate process...\n'
    printf 'JPEG/PNG originals remain untouched; only validated smaller outputs are staged.\n'
    printf 'Image workers: %s | OxiPNG threads/worker: %s | policy: %s\n\n' \
        "$IMAGE_JOBS_EFFECTIVE" "$IMAGE_THREADS_PER_WORKER" "$IMAGE_MODE"

    if command -v setsid >/dev/null 2>&1; then
        setsid env _IS_CHILD_PROCESS=1 bash "$IMAGE_HELPER" \
            --source-parent "$SOURCE_PARENT" \
            --stage-parent "$IMAGE_STAGE_PARENT" \
            --list "$IMAGE_LIST" \
            --result "$IMAGE_RESULT_MANIFEST" \
            --log "$IMAGE_LOG" \
            --mode "$IMAGE_MODE" \
            --jobs "$IMAGE_JOBS_EFFECTIVE" \
            --threads-per-worker "$IMAGE_THREADS_PER_WORKER" &
        IMAGE_PIPELINE_GROUP=true
    else
        env _IS_CHILD_PROCESS=1 bash "$IMAGE_HELPER" \
            --source-parent "$SOURCE_PARENT" \
            --stage-parent "$IMAGE_STAGE_PARENT" \
            --list "$IMAGE_LIST" \
            --result "$IMAGE_RESULT_MANIFEST" \
            --log "$IMAGE_LOG" \
            --mode "$IMAGE_MODE" \
            --jobs "$IMAGE_JOBS_EFFECTIVE" \
            --threads-per-worker "$IMAGE_THREADS_PER_WORKER" &
        IMAGE_PIPELINE_GROUP=false
    fi
    IMAGE_PIPELINE_PID=$!
    hardcore_visual_open_log "Hardcore Archive - Images" "$IMAGE_LOG" pid "$IMAGE_PIPELINE_PID" "$IMAGE_RESULT_MANIFEST"
}

wait_for_image_pipeline() {
    [[ -n ${IMAGE_PIPELINE_PID:-} ]] || return 0
    local started=$SECONDS heartbeat_pid='' rc
    printf '\nStage 5/8: Waiting for the lossless image process to finish...\n'
    if (( PROGRESS_INTERVAL > 0 )); then
        heartbeat "lossless image optimization" "$IMAGE_PIPELINE_PID" "$started" &
        heartbeat_pid=$!
    fi
    set +e
    wait "$IMAGE_PIPELINE_PID"
    rc=$?
    set -e
    IMAGE_PIPELINE_PID=""
    if [[ -n $heartbeat_pid ]]; then
        kill "$heartbeat_pid" 2>/dev/null || true
        wait "$heartbeat_pid" 2>/dev/null || true
    fi
    if (( rc != 0 )); then
        warn "The image optimizer returned exit code $rc. Missing results will fall back to originals."
    fi
}

classify_image_results() {
    : >"$IMAGE_OPTIMIZED_LIST"
    : >"$IMAGE_FALLBACK_LIST"
    local normalized=$(mktemp) action original archived original_size archived_size tool relative size
    declare -A seen=()

    IMAGE_OPTIMIZED_COUNT=0
    IMAGE_FALLBACK_COUNT=0
    IMAGE_OPTIMIZED_BYTES=0
    IMAGE_FALLBACK_BYTES=0
    : >"$normalized"

    while IFS=$'\t' read -r action original archived original_size archived_size tool; do
        [[ -n $original ]] || continue
        [[ -n ${seen[$original]:-} ]] && continue
        seen[$original]=1
        if [[ $action == optimized && -f $IMAGE_STAGE_PARENT/$archived ]]; then
            actual=$(stat -c '%s' -- "$IMAGE_STAGE_PARENT/$archived")
            if [[ $actual == "$archived_size" && $actual -lt $original_size ]]; then
                printf '%s\n' "$archived" >>"$IMAGE_OPTIMIZED_LIST"
                IMAGE_OPTIMIZED_COUNT=$((IMAGE_OPTIMIZED_COUNT + 1))
                IMAGE_OPTIMIZED_BYTES=$((IMAGE_OPTIMIZED_BYTES + actual))
                printf 'optimized\t%s\t%s\t%s\t%s\t%s\n' \
                    "$original" "$archived" "$original_size" "$actual" "$tool" >>"$normalized"
                continue
            fi
        fi
        size=$(stat -c '%s' -- "$SOURCE_PARENT/$original")
        printf '%s\n' "$original" >>"$IMAGE_FALLBACK_LIST"
        IMAGE_FALLBACK_COUNT=$((IMAGE_FALLBACK_COUNT + 1))
        IMAGE_FALLBACK_BYTES=$((IMAGE_FALLBACK_BYTES + size))
        printf 'original\t%s\t%s\t%s\t%s\t%s\n' \
            "$original" "$original" "$size" "$size" "${tool:-fallback}" >>"$normalized"
    done <"$IMAGE_RESULT_MANIFEST"

    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        [[ -n ${seen[$relative]:-} ]] && continue
        size=$(stat -c '%s' -- "$SOURCE_PARENT/$relative")
        printf '%s\n' "$relative" >>"$IMAGE_FALLBACK_LIST"
        IMAGE_FALLBACK_COUNT=$((IMAGE_FALLBACK_COUNT + 1))
        IMAGE_FALLBACK_BYTES=$((IMAGE_FALLBACK_BYTES + size))
        printf 'original\t%s\t%s\t%s\t%s\tmissing-result-fallback\n' \
            "$relative" "$relative" "$size" "$size" >>"$normalized"
    done <"$IMAGE_LIST"

    mv -- "$normalized" "$IMAGE_RESULT_MANIFEST"
    IMAGE_SAVED_BYTES=$((IMAGE_BYTES - IMAGE_OPTIMIZED_BYTES - IMAGE_FALLBACK_BYTES))
    (( IMAGE_SAVED_BYTES < 0 )) && IMAGE_SAVED_BYTES=0

    accounted=$((IMAGE_OPTIMIZED_COUNT + IMAGE_FALLBACK_COUNT))
    (( accounted == IMAGE_COUNT )) || die "Image accounting mismatch: detected $IMAGE_COUNT but accounted for $accounted."
}

write_image_manifest() {
    (( IMAGE_COUNT > 0 )) || return 0
    {
        printf 'Hardcore Archive lossless image transformation manifest\n'
        printf 'Script version: %s\n' "$SCRIPT_VERSION"
        printf 'Policy: %s\n' "$IMAGE_MODE"
        printf 'Original image bytes: %s\n' "$IMAGE_BYTES"
        printf 'Archived image bytes: %s\n' "$((IMAGE_OPTIMIZED_BYTES + IMAGE_FALLBACK_BYTES))"
        printf 'Saved image bytes: %s\n' "$IMAGE_SAVED_BYTES"
        printf '\nColumns: action<TAB>original path<TAB>archived path<TAB>original bytes<TAB>archived bytes<TAB>tool\n'
        cat -- "$IMAGE_RESULT_MANIFEST"
    } >"$IMAGE_MANIFEST_FILE"
}

add_image_results_to_archive() {
    (( IMAGE_COUNT > 0 )) || return 0
    FAILURE_CONTEXT="image-storage"
    printf '\nStage 6/8: Adding lossless image results without further compression...\n'
    printf 'Optimized images: %s files / %s\n' "$IMAGE_OPTIMIZED_COUNT" "$(human_bytes "$IMAGE_OPTIMIZED_BYTES")"
    printf 'Original fallbacks: %s files / %s\n\n' "$IMAGE_FALLBACK_COUNT" "$(human_bytes "$IMAGE_FALLBACK_BYTES")"

    if [[ -s $IMAGE_OPTIMIZED_LIST ]]; then
        (
            cd -- "$IMAGE_STAGE_PARENT"
            run_logged_stage "optimized-image storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -snl -snh -spd -scsUTF-8 -bsp1 -y "@${IMAGE_OPTIMIZED_LIST}"
        )
    fi
    if [[ -s $IMAGE_FALLBACK_LIST ]]; then
        (
            cd -- "$SOURCE_PARENT"
            run_logged_stage "original-image fallback storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -snl -snh -spd -scsUTF-8 -bsp1 -y "@${IMAGE_FALLBACK_LIST}"
        )
    fi
    write_image_manifest
}

classify_video_stage_results() {
    : > "$VIDEO_COMPRESSED_LIST"
    : > "$VIDEO_FALLBACK_LIST"
    : > "$VIDEO_RESULT_MANIFEST"

    local relative staged_original staged_result archived_relative original_size archived_size
    local lower stem action accounted
    declare -A used_archive_paths=()

    VIDEO_COMPRESSED_COUNT=0
    VIDEO_FALLBACK_COUNT=0
    VIDEO_OMITTED_COUNT=0
    VIDEO_COMPRESSED_BYTES=0
    VIDEO_FALLBACK_BYTES=0
    VIDEO_OMITTED_BYTES=0

    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        staged_original="$VIDEO_STAGE_PARENT/$relative"
        original_size=$(stat -c '%s' -- "$SOURCE_PARENT/$relative")

        if hardcore_media_list_contains "$VIDEO_SPECIAL_OMIT_LIST" "$relative"; then
            action='omitted'
            archived_relative=''
            archived_size=0
            VIDEO_OMITTED_COUNT=$((VIDEO_OMITTED_COUNT + 1))
            VIDEO_OMITTED_BYTES=$((VIDEO_OMITTED_BYTES + original_size))
        elif hardcore_media_list_contains "$VIDEO_SPECIAL_PRESERVE_LIST" "$relative"; then
            action='original'
            archived_relative=$relative
            archived_size=$original_size
            printf '%s\n' "$relative" >> "$VIDEO_FALLBACK_LIST"
            VIDEO_FALLBACK_COUNT=$((VIDEO_FALLBACK_COUNT + 1))
            VIDEO_FALLBACK_BYTES=$((VIDEO_FALLBACK_BYTES + original_size))
        elif [[ -L $staged_original ]]; then
            action='original'
            archived_relative=$relative
            archived_size=$original_size
            printf '%s\n' "$relative" >> "$VIDEO_FALLBACK_LIST"
            VIDEO_FALLBACK_COUNT=$((VIDEO_FALLBACK_COUNT + 1))
            VIDEO_FALLBACK_BYTES=$((VIDEO_FALLBACK_BYTES + original_size))
        else
            lower=${relative,,}
            if [[ $lower == *.mkv ]]; then
                staged_result=$staged_original
                archived_relative=$relative
            else
                stem=${relative%.*}
                staged_result="$VIDEO_STAGE_PARENT/${stem}.mkv"
                archived_relative="${stem}.mkv"
            fi

            if [[ -f $staged_result && -z ${used_archive_paths[$archived_relative]:-} ]]; then
                action='transcoded'
                archived_size=$(stat -c '%s' -- "$staged_result")
                printf '%s\n' "$archived_relative" >> "$VIDEO_COMPRESSED_LIST"
                used_archive_paths[$archived_relative]=1
                VIDEO_COMPRESSED_COUNT=$((VIDEO_COMPRESSED_COUNT + 1))
                VIDEO_COMPRESSED_BYTES=$((VIDEO_COMPRESSED_BYTES + archived_size))
            else
                warn "No unique validated staged result was found for: $relative"
                action='original'
                archived_relative=$relative
                archived_size=$original_size
                printf '%s\n' "$relative" >> "$VIDEO_FALLBACK_LIST"
                VIDEO_FALLBACK_COUNT=$((VIDEO_FALLBACK_COUNT + 1))
                VIDEO_FALLBACK_BYTES=$((VIDEO_FALLBACK_BYTES + original_size))
            fi
        fi

        printf '%s\t%s\t%s\t%s\t%s\n'             "$action" "$relative" "$archived_relative" "$original_size" "$archived_size"             >> "$VIDEO_RESULT_MANIFEST"
    done < "$VIDEO_LIST"

    accounted=$((VIDEO_COMPRESSED_COUNT + VIDEO_FALLBACK_COUNT + VIDEO_OMITTED_COUNT))
    (( accounted == VIDEO_COUNT )) ||         die "Video staging accounted for $accounted of $VIDEO_COUNT source videos."

    VIDEO_SAVED_BYTES=$((VIDEO_BYTES - VIDEO_OMITTED_BYTES - VIDEO_COMPRESSED_BYTES - VIDEO_FALLBACK_BYTES))
    if (( VIDEO_SAVED_BYTES < 0 )); then
        VIDEO_SAVED_BYTES=0
    fi
}

write_video_manifest() {
    $VIDEO_WRITE_MANIFEST || return 0
    (( VIDEO_COUNT > 0 )) || return 0

    {
        printf 'Hardcore Archive video transformation manifest\n'
        printf 'Script version: %s\n' "$SCRIPT_VERSION"
        printf 'Source root: %s\n' "$SOURCE_NAME"
        printf 'Video codec target: %s\n' "${VIDEO_CODEC^^}"
        printf 'Special-video policy: %s\n' "$VIDEO_SPECIAL_POLICY"
        printf 'Special videos detected: %s\n' "$VIDEO_SPECIAL_COUNT"
        printf 'Special videos preserved: %s\n' "$VIDEO_SPECIAL_PRESERVE_COUNT"
        printf 'Special videos offered to FFmpeg: %s\n' "$VIDEO_SPECIAL_CONVERT_COUNT"
        printf 'Videos omitted by explicit choice: %s\n' "$VIDEO_OMITTED_COUNT"
        printf 'Bytes omitted by explicit choice: %s\n' "$VIDEO_OMITTED_BYTES"
        printf 'Minimum accepted VMAF: %s\n' "$VIDEO_MIN_VMAF"
        printf 'Minimum accepted saving: %s%%\n' "$VIDEO_MIN_SAVINGS_PERCENT"
        printf 'Preflight sampling: %s\n' "$($VIDEO_PREFLIGHT && printf 'enabled' || printf 'disabled')"
        printf 'Original video bytes: %s\n' "$VIDEO_BYTES"
        printf 'Archived video bytes: %s\n' "$((VIDEO_COMPRESSED_BYTES + VIDEO_FALLBACK_BYTES))"
        printf 'Saved video bytes: %s\n' "$VIDEO_SAVED_BYTES"
        printf '\nColumns: action<TAB>original path<TAB>archived path<TAB>original bytes<TAB>archived bytes\n'
        cat -- "$VIDEO_RESULT_MANIFEST"
    } > "$ARCHIVE_MANIFEST_FILE"
}

add_video_results_to_archive() {
    FAILURE_CONTEXT="video-storage"
    printf '\nStage 6/8: Adding video results to the archive without further compression...\n'
    printf 'Smaller validated transcodes: %s files / %s\n' \
        "$VIDEO_COMPRESSED_COUNT" "$(human_bytes "$VIDEO_COMPRESSED_BYTES")"
    printf 'Original-video fallbacks:     %s files / %s\n\n' \
        "$VIDEO_FALLBACK_COUNT" "$(human_bytes "$VIDEO_FALLBACK_BYTES")"
    if (( ${VIDEO_OMITTED_COUNT:-0} > 0 )); then
        printf 'Explicitly omitted videos:    %s files / %s\n\n' \
            "${VIDEO_OMITTED_COUNT:-0}" "$(human_bytes "${VIDEO_OMITTED_BYTES:-0}")"
    fi

    if [[ -s $VIDEO_COMPRESSED_LIST ]]; then
        (
            cd -- "$VIDEO_STAGE_PARENT"
            run_logged_stage "compressed-video storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" \
                    -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -snl -snh -spd -scsUTF-8 -bsp1 -y \
                    "@${VIDEO_COMPRESSED_LIST}"
        )
    fi

    if [[ -s $VIDEO_FALLBACK_LIST ]]; then
        (
            cd -- "$SOURCE_PARENT"
            run_logged_stage "original-video fallback storage" "$SEVEN_ZIP_LOG" \
                "$SEVEN_ZIP" a "$TEMP_ARCHIVE" \
                    -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                    -snl -snh -spd -scsUTF-8 -bsp1 -y \
                    "@${VIDEO_FALLBACK_LIST}"
        )
    fi


    write_video_manifest
}


# HARDCORE_NESTED_CHILD_DIAGNOSTICS_V1
choose_nested_work_root() {
    # Nested work can hold an extraction, staged media, and a child archive at
    # once. The ordinary work-root probe only reserves a small staging minimum.
    # Compare free space again here, after the parent media work has finished.
    local candidate free fs probe best_free=-1
    local -a candidates=("$WORK_ROOT")
    NESTED_WORK_ROOT=""
    [[ -n $WORK_DIR_OVERRIDE ]] || candidates+=("$ARCHIVE_PARENT/.hardcore-archive-work")
    for candidate in "${candidates[@]}"; do
        candidate=$(realpath -m -- "$candidate")
        if [[ $candidate == "$SOURCE" || $candidate == "$SOURCE/"* || $SOURCE == "$candidate/"* ]]; then
            continue
        fi
        (umask 077; mkdir -p -- "$candidate") 2>/dev/null || continue
        fs=$(filesystem_type "$candidate")
        case $fs in
            ext2|ext3|ext4|btrfs|xfs|f2fs|zfs|tmpfs|overlay|reiserfs|jfs|apfs|hfs|hfsplus) ;;
            *) [[ -n $WORK_DIR_OVERRIDE ]] || continue ;;
        esac
        free=$(df -PB1 -- "$candidate" 2>/dev/null | awk 'NR==2 {print $4}') || continue
        [[ $free =~ ^[0-9]+$ ]] || continue
        (( free > best_free )) || continue
        # Test actual writability, including ACLs, before selecting the path.
        probe=$(mktemp -d -p "$candidate" .nested-probe.XXXXXX) 2>/dev/null || continue
        rmdir -- "$probe"
        NESTED_WORK_ROOT=$candidate
        best_free=$free
    done
    [[ -n $NESTED_WORK_ROOT ]] || die "No suitable nested working directory is writable. Use --work-dir PATH."
    printf 'Nested working directory: %s | free %s\n' "$NESTED_WORK_ROOT" "$(human_bytes "$best_free")"
}

nested_child_failure_reason() {
    local rc=$1 child_log=$2
    if (( rc == 1 )) && grep -Eq '^Error: (The shared output/work filesystem needs|The destination needs|The working filesystem needs|Insufficient destination space\.|No suitable working directory has enough free space\.)' "$child_log"; then
        printf 'insufficient-child-work-space'
    else
        printf 'recursive-archive-failed-rc-%s' "$rc"
    fi
}

prepare_and_add_nested_archives() {
    (( NESTED_COUNT > 0 )) || return 0
    printf '\nProcessing %s nested archive(s) through bounded recursive content-aware repacking...\n' "$NESTED_COUNT"
    choose_nested_work_root
    NESTED_STAGE_PARENT=$(mktemp -d -p "$NESTED_WORK_ROOT" nested-archives.XXXXXX)
    : > "$NESTED_RESULT_MANIFEST"; : > "$NESTED_REPACKED_LIST"; : > "$NESTED_FALLBACK_LIST"
    local relative input extracted child_archive normalized output_rel full_output original_size output_size candidate_size depth rc reason child_log
    local expanded files encrypted free max_expanded candidate_display
    local -a inherited=()
    depth=${HARDCORE_ARCHIVE_NESTED_DEPTH:-0}
    inherited+=(--force --yes --no-report --allow-sleep --nested-max-depth "$NESTED_MAX_DEPTH")
    # A sibling of extract.XXXXXX cannot overlap the child source. Keep child
    # staging on the selected filesystem instead of reselecting the home cache.
    inherited+=(--work-dir "$NESTED_STAGE_PARENT/child-work")
    $VIDEO_TRANSCODE || inherited+=(--no-video-transcode)
    inherited+=(--video-codec "$VIDEO_CODEC" --video-mode "$VIDEO_MODE" --video-special-policy "${VIDEO_SPECIAL_POLICY:-ask}" --quality-check "$QUALITY_CHECK" --video-min-vmaf "$VIDEO_MIN_VMAF")
    [[ -n $VIDEO_ENCODER ]] && inherited+=(--video-encoder "$VIDEO_ENCODER")
    $IMAGE_OPTIMIZE || inherited+=(--no-image-optimize)
    inherited+=(--image-mode "$IMAGE_MODE" --verify "$VERIFY_MODE_EFFECTIVE" --effort "$EFFORT")
    $MC_AUTO && inherited+=(--mc-auto) || inherited+=(--no-mc-auto)

    while IFS= read -r relative; do
        [[ -n $relative ]] || continue
        input="$SOURCE_PARENT/$relative"; original_size=$(stat -c '%s' -- "$input")
        output_rel=$(archive_replacement_path "$relative")
        extracted=$(mktemp -d -p "$NESTED_STAGE_PARENT" extract.XXXXXX)
        child_archive="$NESTED_STAGE_PARENT/.child-$RANDOM-$$.7z"
        normalized=$(mktemp -d -p "$NESTED_STAGE_PARENT" normalize.XXXXXX)
        full_output="$NESTED_STAGE_PARENT/$output_rel"; mkdir -p -- "$(dirname -- "$full_output")"
        rc=0
        if (( depth >= NESTED_MAX_DEPTH )); then rc=90
        else
            expanded=$("$SEVEN_ZIP" l -slt "$input" 2>/dev/null | awk -F' = ' '/^Size = [0-9]+$/ {s+=$2} END{printf "%.0f",s+0}')
            files=$("$SEVEN_ZIP" l -slt "$input" 2>/dev/null | awk '/^Path = /{n++} END{print n+0}')
            encrypted=$("$SEVEN_ZIP" l -slt "$input" 2>/dev/null | awk -F' = ' '/^Encrypted = \+/{print 1; exit}')
            free=$(df -PB1 -- "$NESTED_STAGE_PARENT" | awk 'NR==2{print $4}')
            max_expanded=$((free > 512*MIB ? free-512*MIB : 0))
            if [[ $encrypted == 1 ]] || (( files > 100000 )) || (( expanded > max_expanded )) || (( original_size > 0 && expanded/original_size > 1000 )); then
                warn "Preserving nested archive unchanged because its declared expansion is unsafe or unsupported: $relative"
                rc=92
            elif ! "$SEVEN_ZIP" x -y -spd -o"$extracted" "$input" >>"$SEVEN_ZIP_LOG" 2>&1; then rc=91
            else
                if [[ -n ${HARDCORE_ARCHIVE_DIAGNOSTIC_DIR:-} ]]; then
                    child_log="$HARDCORE_ARCHIVE_DIAGNOSTIC_DIR/nested/depth-$((depth + 1))/${relative}/run.log"
                    mkdir -p -- "$(dirname -- "$child_log")"
                else
                    child_log="$NESTED_STAGE_PARENT/.child-$RANDOM-$$.log"
                fi
                {
                    printf 'Nested archive: %s\n' "$relative"
                    printf 'Depth: %s\n' "$((depth + 1))"
                    printf 'Started: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')"
                    printf 'Hardware encoder inherited: %s\n\n' "${VIDEO_ENCODER:-none}"
                } > "$child_log"
                hardcore_visual_open_log "Hardcore Archive - Nested: ${relative}" "$child_log" pattern 'Exit status:'
                env HARDCORE_ARCHIVE_INHIBITED=1 \
                    HARDCORE_ARCHIVE_DEPENDENCIES_APPROVED=1 \
                    HARDCORE_ARCHIVE_NESTED_CHILD=1 \
                    HARDCORE_ARCHIVE_CALIBRATION_NAMESPACE="$(hardcore_calibration_identity "$input" || true)" \
                    HARDCORE_ARCHIVE_DIAGNOSTIC_DIR="$(dirname -- "$child_log")" \
                    HARDCORE_ARCHIVE_LIVE_LOG="$child_log" \
                    HARDCORE_ARCHIVE_HARDWARE_ENCODER_LOCKED="${VIDEO_ENCODER:-}" \
                    HARDCORE_ARCHIVE_NESTED_DEPTH=$((depth + 1)) \
                    bash "$(resolve_current_script)" "${inherited[@]}" "$extracted" "$child_archive" >>"$child_log" 2>&1 || rc=$?
                printf '\nFinished: %s\nExit status: %s\n' "$(date '+%Y-%m-%d %H:%M:%S %z')" "$rc" >> "$child_log" 2>/dev/null || true
                cat -- "$child_log" >> "$SEVEN_ZIP_LOG" 2>/dev/null || true
                printf 'Nested child log: %s\n' "$child_log"
                if (( rc == 0 )); then
                    "$SEVEN_ZIP" x -y -spd -o"$normalized" "$child_archive" >>"$SEVEN_ZIP_LOG" 2>&1 || rc=93
                fi
                if (( rc == 0 )); then
                    # Remove the child's random extraction-root directory while retaining
                    # all transformed payload. Child manifests must not become user data
                    # in the normalized nested archive.
                    local root_count root_entry content_root
                    remove_hardcore_archive_internal_entries "$normalized"
                    root_count=$(find "$normalized" -mindepth 1 -maxdepth 1 -printf '.' | wc -c)
                    content_root="$normalized"
                    if (( root_count == 1 )); then
                        root_entry=$(find "$normalized" -mindepth 1 -maxdepth 1 -printf '%f' | head -n1)
                        [[ -d $normalized/$root_entry ]] && content_root="$normalized/$root_entry"
                    fi
                    (cd -- "$content_root" && "$SEVEN_ZIP" a "$full_output" -t7z -m0=lzma2 -mx=9 -ms=on -mmt=on -spd -scsUTF-8 -bsp1 -y .) >>"$SEVEN_ZIP_LOG" 2>&1 || rc=94
                    "$SEVEN_ZIP" t "$full_output" >>"$SEVEN_ZIP_LOG" 2>&1 || rc=95
                fi
            fi
        fi
        if [[ -s $full_output ]]; then candidate_size=$(stat -c '%s' -- "$full_output"); else candidate_size=0; fi
        output_size=$original_size
        case $rc in
            0)  if (( candidate_size < original_size )); then reason='candidate-smaller'; else reason='candidate-not-smaller'; fi ;;
            90) reason='max-depth-reached' ;;
            91) reason='source-extraction-failed' ;;
            92)
                if [[ ${encrypted:-0} == 1 ]]; then reason='encrypted-archive'
                elif (( ${files:-0} > 100000 )); then reason='entry-count-limit'
                elif (( ${expanded:-0} > ${max_expanded:-0} )); then reason='insufficient-safe-extraction-space'
                elif (( original_size > 0 && ${expanded:-0}/original_size > 1000 )); then reason='unsafe-expansion-ratio'
                else reason='unsafe-or-unsupported'; fi ;;
            93) reason='child-extraction-failed' ;;
            94) reason='candidate-build-failed' ;;
            95) reason='candidate-integrity-failed' ;;
            *)  reason=$(nested_child_failure_reason "$rc" "$child_log") ;;
        esac
        if (( rc == 0 && candidate_size < original_size )); then
            output_size=$candidate_size
            printf '%s\n' "$output_rel" >> "$NESTED_REPACKED_LIST"
            printf 'repacked\t%s\t%s\t%s\t%s\t%s\t%s\n' "$relative" "$output_rel" "$original_size" "$candidate_size" "$output_size" "$reason" >> "$NESTED_RESULT_MANIFEST"
            ((NESTED_REPACKED_COUNT+=1)); NESTED_SAVED_BYTES=$((NESTED_SAVED_BYTES+original_size-output_size))
        else
            rm -f -- "$full_output"; printf '%s\n' "$relative" >> "$NESTED_FALLBACK_LIST"
            printf 'original\t%s\t%s\t%s\t%s\t%s\t%s\n' "$relative" "$relative" "$original_size" "$candidate_size" "$original_size" "$reason" >> "$NESTED_RESULT_MANIFEST"
            ((NESTED_FALLBACK_COUNT+=1))
        fi
        if (( candidate_size > 0 )); then candidate_display=$(human_bytes "$candidate_size"); else candidate_display='not produced'; fi
        printf 'Nested decision: %s | original %s | candidate %s | %s (%s)\n' \
            "$relative" "$(human_bytes "$original_size")" "$candidate_display" \
            "$([[ $reason == candidate-smaller ]] && printf 'REPACKED' || printf 'PRESERVED')" "$reason"
        rm -rf --one-file-system -- "$extracted" "$normalized"; rm -f -- "$child_archive"
    done < "$NESTED_LIST"
    if [[ -s $NESTED_REPACKED_LIST ]]; then
        (cd -- "$NESTED_STAGE_PARENT" && run_logged_stage "nested-archive replacement storage" "$SEVEN_ZIP_LOG" "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 -spd -scsUTF-8 -bsp1 -y "@${NESTED_REPACKED_LIST}")
    fi
    if [[ -s $NESTED_FALLBACK_LIST ]]; then
        (cd -- "$SOURCE_PARENT" && run_logged_stage "nested-archive original fallback storage" "$SEVEN_ZIP_LOG" "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 -spd -scsUTF-8 -bsp1 -y "@${NESTED_FALLBACK_LIST}")
    fi
    if [[ -s $NESTED_RESULT_MANIFEST ]]; then
        { printf 'action\toriginal path\tarchived path\toriginal bytes\tcandidate bytes\tarchived bytes\treason\n'; cat "$NESTED_RESULT_MANIFEST"; } > "$NESTED_MANIFEST_FILE"
    fi
}

build_sparse_manifest() {
    mkdir -p -- "$METADATA_DIR"
    printf 'path\tlogical_size\thole_start\thole_length\n' > "$SPARSE_MANIFEST"
    command -v python3 >/dev/null 2>&1 || return 0
    python3 - "$SOURCE_PARENT" "$INVENTORY_RAW" >> "$SPARSE_MANIFEST" <<'PYSPARSE'
import os,sys
parent=sys.argv[1]; raw=sys.argv[2]
data=open(raw,'rb').read().split(b'\0')
for i in range(0,len(data)-1,2):
    if not data[i+1]: continue
    rel=os.fsdecode(data[i+1]); path=os.path.join(parent,rel)
    try:
        size=os.stat(path,follow_symlinks=False).st_size
        fd=os.open(path,os.O_RDONLY)
    except OSError: continue
    pos=0
    try:
        while pos<size:
            try:
                d=os.lseek(fd,pos,os.SEEK_DATA)
            except OSError as exc:
                import errno
                if exc.errno == errno.ENXIO:
                    d=size
                elif exc.errno in (errno.EINVAL, getattr(errno,'ENOTSUP',95), getattr(errno,'EOPNOTSUPP',95)):
                    # The filesystem cannot report sparse extents. Record no holes;
                    # treating unsupported probing as a hole would corrupt restore.
                    break
                else:
                    break
            if d>pos:
                print(f"{rel}\t{size}\t{pos}\t{d-pos}")
            if d>=size: break
            try: h=os.lseek(fd,d,os.SEEK_HOLE)
            except OSError: break
            pos=max(h,d+1)
    finally: os.close(fd)
PYSPARSE
    SPARSE_FILE_COUNT=$(awk -F '\t' 'NR>1{seen[$1]=1} END{print length(seen)}' "$SPARSE_MANIFEST")
    SPARSE_HOLE_BYTES=$(awk -F '\t' 'NR>1{s+=$4} END{printf "%.0f",s+0}' "$SPARSE_MANIFEST")
}


build_metadata_bundle() {
    mkdir -p -- "$METADATA_DIR"
    build_sparse_manifest
    cat > "$ARCHIVE_INFO_FILE" <<EOF
Script version: $SCRIPT_VERSION
Platform: $PLATFORM_NAME
Operating system: $(platform_os_version)
Created: $(date --iso-8601=seconds)
Source name: $SOURCE_NAME
Source bytes: $TOTAL_BYTES
Source bytes selected for archive: $((TOTAL_BYTES - VIDEO_OMITTED_BYTES))
Videos omitted by explicit choice: $VIDEO_OMITTED_COUNT
Video bytes omitted by explicit choice: $VIDEO_OMITTED_BYTES
Verification: $VERIFY_MODE_EFFECTIVE
Sparse files: $SPARSE_FILE_COUNT
Sparse hole bytes: $SPARSE_HOLE_BYTES
LZMA2 files: $NONVIDEO_COUNT
LZMA2 source bytes: $NONVIDEO_BYTES
Copy-lane files: $COPY_COUNT
Copy-lane bytes: $COPY_BYTES
Format-preserving containers: $CONTAINER_COUNT
Containers repacked: $CONTAINER_REPACKED_COUNT
Container bytes saved: $CONTAINER_SAVED_BYTES
Nested archives repacked: $NESTED_REPACKED_COUNT
EOF
    [[ -n $METADATA_HELPER && -f $METADATA_HELPER ]] || \
        die "Trusted metadata capture helper is missing: ${METADATA_HELPER:-unset}"
    (
        cd -- "$SOURCE_PARENT"
        source_find "$SOURCE_NAME" -print0
    ) | python3 "$METADATA_HELPER" --capture-files \
        --root "$SOURCE_PARENT" --metadata-dir "$METADATA_DIR"

    if [[ $PLATFORM_ID == macos ]]; then
        python3 "$METADATA_HELPER" --capture-acl \
            --root "$SOURCE_PARENT" --metadata-dir "$METADATA_DIR" || die 'Native macOS ACL capture failed.'
    else
        (cd -- "$SOURCE_PARENT" && getfacl -R -p -n -- "$SOURCE_NAME") > "$ACL_MANIFEST" || \
            die 'POSIX ACL capture failed; refusing to create an archive with missing permissions.'
    fi
    SOURCE_XATTR_ROOT="$SOURCE_PARENT" SOURCE_XATTR_NAME="$SOURCE_NAME" \
        python3 - "$XATTR_MANIFEST" <<'PYXATTRSAVE'
import base64, json, os, sys
root=os.path.realpath(os.environ['SOURCE_XATTR_ROOT'])
name=os.environ['SOURCE_XATTR_NAME']; output=sys.argv[1]
start=os.path.join(root,name)
with open(output,'w',encoding='utf-8') as out:
    out.write('# hardcore-archive xattrs-and-flags jsonl v1\n')
    for current,dirs,files in os.walk(start,topdown=True,followlinks=False):
        paths=[current]+[os.path.join(current,n) for n in files]
        paths += [os.path.join(current,n) for n in dirs if os.path.islink(os.path.join(current,n))]
        for path in paths:
            rel=os.path.relpath(path,root)
            record={'path':rel,'xattrs':{}}
            try:
                flags=getattr(os.lstat(path),'st_flags',0)
                if flags: record['flags']=flags
            except OSError: pass
            if hasattr(os,'listxattr'):
                try:
                    for attr in os.listxattr(path,follow_symlinks=False):
                        try:
                            value=os.getxattr(path,attr,follow_symlinks=False)
                            record['xattrs'][attr]=base64.b64encode(value).decode('ascii')
                        except OSError: pass
                except OSError: pass
            if record.get('flags') or record['xattrs']:
                out.write(json.dumps(record,ensure_ascii=True,separators=(',',':'))+'\n')
PYXATTRSAVE

    cat > "$RESTORE_HELPER" <<'RESTORE_NOTES'
Metadata in this directory is data only. Do not execute files from an archive.
Use `hardcore-archive --restore ARCHIVE.7z` so the installed, trusted program
can validate paths, restore sparse allocation, and apply supported metadata.
RESTORE_NOTES
    chmod 600 -- "$RESTORE_HELPER"
}

build_expected_paths_and_hashes() {
    : > "$EXPECTED_PATHS"
    : > "$HASH_MANIFEST"
    local file_size relative source_path action original archived original_size candidate_size archived_size reason data_path hash

    while IFS= read -r -d '' file_size && IFS= read -r -d '' relative; do
        is_video_path "$relative" && continue
        is_image_path "$relative" && continue
        $NESTED_REPACK && is_nested_archive_path "$relative" && continue
        $CONTAINER_REPACK && is_format_preserving_container_path "$relative" && continue
        printf '%s\n' "$relative" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            source_path="$SOURCE_PARENT/$relative"
            hash=$(sha256sum -- "$source_path" | awk '{print $1}')
            printf '%s  %s\n' "$hash" "$relative" >> "$HASH_MANIFEST"
        fi
    done < "$INVENTORY_RAW"

    while IFS=$'\t' read -r action original archived original_size archived_size; do
        [[ -n $archived ]] || continue
        printf '%s\n' "$archived" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            if [[ $action == transcoded ]]; then
                data_path="$VIDEO_STAGE_PARENT/$archived"
            else
                data_path="$SOURCE_PARENT/$original"
            fi
            hash=$(sha256sum -- "$data_path" | awk '{print $1}')
            printf '%s  %s\n' "$hash" "$archived" >> "$HASH_MANIFEST"
        fi
    done < "$VIDEO_RESULT_MANIFEST"

    while IFS=$'	' read -r action original archived original_size archived_size tool; do
        [[ -n $archived ]] || continue
        printf '%s\n' "$archived" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            if [[ $action == optimized ]]; then
                data_path="$IMAGE_STAGE_PARENT/$archived"
            else
                data_path="$SOURCE_PARENT/$original"
            fi
            hash=$(sha256sum -- "$data_path" | awk '{print $1}')
            printf '%s  %s\n' "$hash" "$archived" >> "$HASH_MANIFEST"
        fi
    done < "$IMAGE_RESULT_MANIFEST"




    while IFS=$'\t' read -r action original archived original_size candidate_size archived_size reason; do
        [[ -n $archived ]] || continue
        printf '%s\n' "$archived" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            if [[ $action == repacked ]]; then data_path="$CONTAINER_STAGE_PARENT/$archived"; else data_path="$SOURCE_PARENT/$original"; fi
            hash=$(sha256sum -- "$data_path" | awk '{print $1}')
            printf '%s  %s\n' "$hash" "$archived" >> "$HASH_MANIFEST"
        fi
    done < "$CONTAINER_RESULT_MANIFEST"

    while IFS=$'\t' read -r action original archived original_size candidate_size archived_size reason; do
        [[ -n $archived ]] || continue
        printf '%s\n' "$archived" >> "$EXPECTED_PATHS"
        if [[ $VERIFY_MODE_EFFECTIVE == hashes || $VERIFY_MODE_EFFECTIVE == extract ]]; then
            if [[ $action == repacked ]]; then data_path="$NESTED_STAGE_PARENT/$archived"; else data_path="$SOURCE_PARENT/$original"; fi
            hash=$(sha256sum -- "$data_path" | awk '{print $1}')
            printf '%s  %s\n' "$hash" "$archived" >> "$HASH_MANIFEST"
        fi
    done < "$NESTED_RESULT_MANIFEST"

    (
        cd -- "$SOURCE_PARENT"
        source_find "$SOURCE_NAME" \( -type d -o -type l \) -print
    ) >> "$EXPECTED_PATHS"

    printf '%s\n' '.hardcore-archive-metadata' \
        '.hardcore-archive-metadata/files.tsv' \
        '.hardcore-archive-metadata/acl.txt' \
        '.hardcore-archive-metadata/xattrs.txt' \
        '.hardcore-archive-metadata/RESTORE-NOTES.txt' \
        '.hardcore-archive-metadata/sparse.tsv' \
        '.hardcore-archive-metadata/archive-info.txt' >> "$EXPECTED_PATHS"
    $VIDEO_WRITE_MANIFEST && (( VIDEO_COUNT > 0 )) && \
        printf '%s\n' '.hardcore-archive-video-manifest.txt' >> "$EXPECTED_PATHS"
    (( IMAGE_COUNT > 0 )) && \
        printf '%s\n' '.hardcore-archive-image-manifest.txt' >> "$EXPECTED_PATHS"
    (( CONTAINER_COUNT > 0 )) && \
        printf '%s\n' '.hardcore-archive-container-manifest.txt' >> "$EXPECTED_PATHS"
    (( NESTED_COUNT > 0 )) && \
        printf '%s\n' '.hardcore-archive-nested-manifest.txt' >> "$EXPECTED_PATHS"
    if [[ -s $HASH_MANIFEST ]]; then
        cp -- "$HASH_MANIFEST" "$ARCHIVE_MANIFEST_STAGE/.hardcore-archive-sha256.txt"
        printf '%s\n' '.hardcore-archive-sha256.txt' >> "$EXPECTED_PATHS"
    fi
    LC_ALL=C sort -u -o "$EXPECTED_PATHS" "$EXPECTED_PATHS"
}

add_safety_manifests_to_archive() {
    build_metadata_bundle
    build_expected_paths_and_hashes
    local -a manifest_items=(.hardcore-archive-metadata)
    # All lanes have finished writing their manifests. Store them together so
    # each tiny manifest does not trigger another copy of the existing archive.
    # Match the expected-path conditions, including --no-video-manifest.
    $VIDEO_WRITE_MANIFEST && (( VIDEO_COUNT > 0 )) && \
        manifest_items+=(.hardcore-archive-video-manifest.txt)
    (( IMAGE_COUNT > 0 )) && manifest_items+=(.hardcore-archive-image-manifest.txt)
    (( CONTAINER_COUNT > 0 )) && manifest_items+=(.hardcore-archive-container-manifest.txt)
    (( NESTED_COUNT > 0 )) && manifest_items+=(.hardcore-archive-nested-manifest.txt)
    [[ -s $ARCHIVE_MANIFEST_STAGE/.hardcore-archive-sha256.txt ]] && \
        manifest_items+=(.hardcore-archive-sha256.txt)
    (
        cd -- "$ARCHIVE_MANIFEST_STAGE"
        run_logged_stage "safety-manifest storage" "$SEVEN_ZIP_LOG" \
            "$SEVEN_ZIP" a "$TEMP_ARCHIVE" -t7z -mx=0 -m0=Copy -ms=off -mmt=1 \
                -spd -scsUTF-8 -bsp1 -y "${manifest_items[@]}"
    )
}

list_archive_file_paths() {
    "$SEVEN_ZIP" l -slt "$TEMP_ARCHIVE" 2>/dev/null | awk '
        /^----------$/ {in_items=1; next}
        !in_items {next}
        /^Path = / {if (have) print path; path=substr($0,8); have=1; next}
        END {if (have) print path}
    ' | sed '/^$/d' | LC_ALL=C sort -u > "$ARCHIVE_PATHS"
}

verify_archive_completeness() {
    local missing unexpected
    list_archive_file_paths
    missing=$(comm -23 "$EXPECTED_PATHS" "$ARCHIVE_PATHS" || true)
    unexpected=$(comm -13 "$EXPECTED_PATHS" "$ARCHIVE_PATHS" || true)
    if [[ -n $missing ]]; then
        printf '\nExpected archive paths are missing:\n%s\n' "$missing" >&2
        return 1
    fi
    if [[ -n $unexpected ]]; then
        printf '\nUnexpected paths were added to the archive:\n%s\n' "$unexpected" >&2
        return 1
    fi
    printf 'Archive completeness check passed: expected and archived entries match exactly.\n'
}

verify_archive_hashes_single_pass() {
    local extract_dir="$JOB_WORK_DIR/hash-verification"
    : > "$HASH_VERIFY_LOG"
    rm -rf --one-file-system -- "$extract_dir"
    mkdir -p -- "$extract_dir"
    run_logged_stage "single-pass hash extraction" "$HASH_VERIFY_LOG" \
        "$SEVEN_ZIP" x -y -spd -o"$extract_dir" "$TEMP_ARCHIVE" || return 1
    if [[ -s $HASH_MANIFEST ]]; then
        (cd -- "$extract_dir" && sha256sum -c --quiet "$HASH_MANIFEST") >>"$HASH_VERIFY_LOG" 2>&1 || return 1
    fi
    rm -rf --one-file-system -- "$extract_dir"
    printf 'Single-pass extraction and SHA-256 content verification passed.\n'
}

verify_archive_by_extraction() {
    verify_archive_hashes_single_pass
}

write_success_report() {
    $WRITE_REPORT || return 0
    local archive_size elapsed ratio report_temp archived_source_bytes
    archive_size=$(stat -c '%s' -- "$ARCHIVE")
    elapsed=$((SECONDS - SCRIPT_START_SECONDS))
    archived_source_bytes=$((TOTAL_BYTES - VIDEO_OMITTED_BYTES))
    ratio=$(LC_NUMERIC=C awk -v a="$archive_size" -v s="$archived_source_bytes" 'BEGIN {if(s>0) printf "%.2f",a*100/s; else print "0"}')
    report_temp="${REPORT_PATH}.partial.$$"
    if ! {
        printf 'Hardcore Archive success report\n'
        printf 'Script version: %s\n' "$SCRIPT_VERSION"
        printf 'Platform: %s\n' "$(platform_os_version)"
        printf 'Dependency preflight: %s\n' "$DEPENDENCY_PREFLIGHT_SUMMARY"
        printf 'Completed: %s\n' "$(date --iso-8601=seconds)"
        printf 'Source: %s\n' "$SOURCE"
        printf 'Archive: %s\n' "$ARCHIVE"
        printf 'Source bytes: %s\n' "$TOTAL_BYTES"
        printf 'Source bytes selected for archive: %s\n' "$archived_source_bytes"
        printf 'Videos omitted by explicit choice: %s\n' "$VIDEO_OMITTED_COUNT"
        printf 'Video bytes omitted by explicit choice: %s\n' "$VIDEO_OMITTED_BYTES"
        printf 'Archive bytes: %s\n' "$archive_size"
        printf 'Archive/source ratio: %s%%\n' "$ratio"
        printf 'Elapsed: %s\n' "$(format_duration "$elapsed")"
        printf 'Dictionary MiB: %s\n' "$DICTIONARY_MIB"
        printf 'Match cycles: %s\n' "$SEARCH_CYCLES"
        printf 'Verification: %s\n' "$VERIFY_MODE_EFFECTIVE"
        printf 'Completeness: passed\n'
        printf 'LZMA2 files: %s\n' "$NONVIDEO_COUNT"
        printf 'LZMA2 source bytes: %s\n' "$NONVIDEO_BYTES"
        printf 'Copy-lane files: %s\n' "$COPY_COUNT"
        printf 'Copy-lane bytes: %s\n' "$COPY_BYTES"
        printf 'Containers repacked: %s\n' "$CONTAINER_REPACKED_COUNT"
        printf 'Containers preserved: %s\n' "$CONTAINER_FALLBACK_COUNT"
        printf 'Container bytes saved: %s\n' "$CONTAINER_SAVED_BYTES"
        printf 'Videos transcoded: %s\n' "$VIDEO_COMPRESSED_COUNT"
        printf 'Videos preserved: %s\n' "$VIDEO_FALLBACK_COUNT"
        printf 'Videos omitted by explicit choice: %s\n' "$VIDEO_OMITTED_COUNT"
        printf 'Video bytes saved: %s\n' "$VIDEO_SAVED_BYTES"
        printf 'Resume-cache hits: %s\n' "$VIDEO_CACHE_HITS"
        printf 'Images optimized: %s\n' "$IMAGE_OPTIMIZED_COUNT"
        printf 'Images preserved: %s\n' "$IMAGE_FALLBACK_COUNT"
        printf 'Image bytes saved: %s\n' "$IMAGE_SAVED_BYTES"
        printf 'Image mode/workers: %s / %s\n' "$IMAGE_MODE" "$IMAGE_JOBS_EFFECTIVE"
        printf 'Nested archives repacked: %s\n' "$NESTED_REPACKED_COUNT"
        printf 'Nested archives preserved: %s\n' "$NESTED_FALLBACK_COUNT"
        printf 'Nested archive bytes saved: %s\n' "$NESTED_SAVED_BYTES"
        printf 'Sparse files detected: %s\n' "$SPARSE_FILE_COUNT"
        printf 'Sparse hole bytes: %s\n' "$SPARSE_HOLE_BYTES"
        printf 'Destination free at start: %s\n' "$DESTINATION_FREE_BYTES"
        printf 'Destination conservative requirement: %s\n' "$DESTINATION_REQUIRED_BYTES"
        printf 'Working filesystem: %s\n' "$(filesystem_type "$WORK_ROOT")"
        printf '\n===== Phase timings =====\n'
        hardcore_timing_summary
        if [[ -s $VIDEO_RESULT_MANIFEST ]]; then
            printf '\n===== Video decisions =====\n'
            printf 'action\toriginal path\tarchived path\toriginal bytes\tarchived bytes\n'
            cat -- "$VIDEO_RESULT_MANIFEST"
        fi
        if [[ -s $VIDEO_LOG ]]; then
            printf '\n===== Video pipeline log =====\n'
            cat -- "$VIDEO_LOG"
        fi
        if [[ -s $IMAGE_RESULT_MANIFEST ]]; then
            printf '\n===== Image decisions =====\n'
            printf 'action\toriginal path\tarchived path\toriginal bytes\tarchived bytes\ttool\n'
            cat -- "$IMAGE_RESULT_MANIFEST"
        fi
        if [[ -s $CONTAINER_RESULT_MANIFEST ]]; then
            printf '\n===== Container repack decisions =====\n'
            printf 'action\toriginal path\tarchived path\toriginal bytes\tcandidate bytes\tarchived bytes\treason\n'
            cat -- "$CONTAINER_RESULT_MANIFEST"
        fi
        if [[ -s $NESTED_RESULT_MANIFEST ]]; then
            printf '\n===== Nested archive decisions =====\n'
            printf 'action\toriginal path\tarchived path\toriginal bytes\tcandidate bytes\tarchived bytes\treason\n'
            cat -- "$NESTED_RESULT_MANIFEST"
        fi
        if [[ -s $IMAGE_LOG ]]; then
            printf '\n===== Image pipeline log =====\n'
            cat -- "$IMAGE_LOG"
        fi
        if [[ -s $MC_TUNING_LOG ]]; then
            printf '\n===== Match-cycle tuning log =====\n'
            cat -- "$MC_TUNING_LOG"
        fi
    } > "$report_temp"; then
        warn "Could not write the optional success report: $REPORT_PATH"
        rm -f -- "$report_temp"
        return 0
    fi
    mv -f -- "$report_temp" "$REPORT_PATH" || {
        warn "Could not finalize the optional success report: $REPORT_PATH"
        rm -f -- "$report_temp"
        return 0
    }
    sync "$REPORT_PATH" 2>/dev/null || true
}

cd -- "$SOURCE_PARENT"

if (( VIDEO_COUNT > 0 )) && $VIDEO_TRANSCODE; then
    if $VIDEO_PARALLEL; then
        start_video_pipeline
        if $IMAGE_PARALLEL; then
            start_image_pipeline
        fi
        compress_nonvideo_with_fallback "$DICTIONARY_MIB"
        if $IMAGE_PARALLEL; then
            wait_for_image_pipeline
        else
            start_image_pipeline
            wait_for_image_pipeline
        fi
        wait_for_video_pipeline
    else
        # CPU-heavy software video encoding is completed first. Lossless image
        # work overlaps LZMA only when spare resources remain after preserving
        # the full dictionary selected for the archive.
        start_video_pipeline
        wait_for_video_pipeline
        if $IMAGE_PARALLEL; then
            start_image_pipeline
            compress_nonvideo_with_fallback "$DICTIONARY_MIB"
            wait_for_image_pipeline
        else
            start_image_pipeline
            wait_for_image_pipeline
            compress_nonvideo_with_fallback "$DICTIONARY_MIB"
        fi
    fi

    classify_video_stage_results
    add_video_results_to_archive
else
    printf '\nStage 3/8: Video transcoding is not needed.\n'
    if $IMAGE_PARALLEL; then
        start_image_pipeline
        compress_nonvideo_with_fallback "$DICTIONARY_MIB"
        wait_for_image_pipeline
    else
        start_image_pipeline
        wait_for_image_pipeline
        compress_nonvideo_with_fallback "$DICTIONARY_MIB"
    fi

    printf '\nStage 5/8: No video process needs to be awaited.\n'
    if [[ -s $VIDEO_LIST ]]; then
        cp -- "$VIDEO_LIST" "$VIDEO_FALLBACK_LIST"
        : > "$VIDEO_RESULT_MANIFEST"
        while IFS= read -r relative; do
            [[ -n $relative ]] || continue
            size=$(stat -c '%s' -- "$SOURCE_PARENT/$relative")
            printf 'original\t%s\t%s\t%s\t%s\n' \
                "$relative" "$relative" "$size" "$size" >> "$VIDEO_RESULT_MANIFEST"
        done < "$VIDEO_LIST"
        VIDEO_FALLBACK_COUNT=$VIDEO_COUNT
        VIDEO_FALLBACK_BYTES=$VIDEO_BYTES
        add_video_results_to_archive
    else
        printf '\nStage 6/8: No video files need to be added.\n'
    fi
fi

process_format_preserving_containers
add_copy_lane_to_archive

if (( IMAGE_COUNT > 0 )); then
    classify_image_results
    add_image_results_to_archive
else
    printf '\nStage 6/8: No JPEG or PNG files need separate handling.\n'
fi

# This function can terminate the process on a fatal archive error, so keep
# its existing errexit behavior instead of invoking it inside an if-wrapper.
NESTED_TIMING_STARTED=$(hardcore_timing_now 2>/dev/null) || NESTED_TIMING_STARTED=0
prepare_and_add_nested_archives
hardcore_timing_record nested_processing "$NESTED_TIMING_STARTED" 0
NESTED_TIMING_STARTED=''

printf '\nAdding completeness, hash, and Linux metadata manifests...\n'
add_safety_manifests_to_archive

printf '\nStage 7/8: Testing every stream in the completed archive...\n\n'
if [[ $VERIFY_MODE_EFFECTIVE == integrity ]]; then
    FAILURE_CONTEXT="integrity-test"
    INTEGRITY_TEST_RC=0
    run_logged_stage "archive integrity test" "$SEVEN_ZIP_LOG" \
        "$SEVEN_ZIP" t "$TEMP_ARCHIVE" -t7z -bsp1 || INTEGRITY_TEST_RC=$?

    if (( INTEGRITY_TEST_RC != 0 )) || \
       grep -Eq '^(Sub items Errors|Archives with Errors):[[:space:]]*[1-9][0-9]*' "$SEVEN_ZIP_LOG"; then
        die "Archive integrity testing failed. The failed archive and diagnostic log will be preserved."
    fi
else
    printf 'The single strong-verification extraction below also checks every archive stream.\n'
fi

FAILURE_CONTEXT="completeness-test"
hardcore_timed archive_verification verify_archive_completeness || \
    die "Archive completeness verification failed. The archive is intact but does not contain every expected path."

case "$VERIFY_MODE_EFFECTIVE" in
    hashes)
        FAILURE_CONTEXT="hash-verification"
        hardcore_timed archive_verification verify_archive_hashes_single_pass || \
            die "Archive hash verification failed. The failed archive and diagnostic log will be preserved."
        ;;
    extract)
        FAILURE_CONTEXT="full-extraction-verification"
        hardcore_timed archive_verification verify_archive_by_extraction || \
            die "Full extraction verification failed. The failed archive and diagnostic log will be preserved."
        ;;
esac

printf '\nStage 8/8: Checking that the source did not change while it was archived...\n'
FAILURE_CONTEXT="source-changed"
create_snapshot "$SNAPSHOT_AFTER"
if ! cmp -s -- "$SNAPSHOT_BEFORE" "$SNAPSHOT_AFTER"; then
    die "The source changed during processing. The tested archive will be preserved with a source-changed filename, and the source will not be removed."
fi

FAILURE_CONTEXT="finalization"
sync "$TEMP_ARCHIVE" 2>/dev/null || sync

mv -f -- "$TEMP_ARCHIVE" "$ARCHIVE"
TEMP_ARCHIVE=""
sync "$ARCHIVE" 2>/dev/null || sync

printf 'Archive integrity test passed.\n'
printf 'Final dictionary used: %s MiB\n' "$DICTIONARY_MIB"
printf 'LZMA2 lane: %s files / %s\n' "$NONVIDEO_COUNT" "$(human_bytes "$NONVIDEO_BYTES")"
printf 'Container lane: %s files / %s; repacked %s; saved %s\n' \
    "$CONTAINER_COUNT" "$(human_bytes "$CONTAINER_BYTES")" "$CONTAINER_REPACKED_COUNT" "$(human_bytes "$CONTAINER_SAVED_BYTES")"
printf 'Copy lane:  %s files / %s\n' "$COPY_COUNT" "$(human_bytes "$COPY_BYTES")"
if (( VIDEO_COUNT > 0 )); then
    printf 'Videos transcoded smaller: %s\n' "$VIDEO_COMPRESSED_COUNT"
    printf 'Videos stored original:    %s\n' "$VIDEO_FALLBACK_COUNT"
    printf 'Videos omitted explicitly: %s\n' "$VIDEO_OMITTED_COUNT"
    printf 'Video bytes saved:         %s\n' "$(human_bytes "$VIDEO_SAVED_BYTES")"
fi
if (( IMAGE_COUNT > 0 )); then
    printf 'Images optimized smaller: %s\n' "$IMAGE_OPTIMIZED_COUNT"
    printf 'Images stored original:   %s\n' "$IMAGE_FALLBACK_COUNT"
    printf 'Image bytes saved:        %s\n' "$(human_bytes "$IMAGE_SAVED_BYTES")"
fi
if (( NESTED_COUNT > 0 )); then
    printf 'Nested archives repacked: %s\n' "$NESTED_REPACKED_COUNT"
    printf 'Nested archives preserved: %s\n' "$NESTED_FALLBACK_COUNT"
    printf 'Nested bytes saved: %s\n' "$(human_bytes "$NESTED_SAVED_BYTES")"
fi
if (( SPARSE_FILE_COUNT > 0 )); then
    printf 'Sparse files recorded: %s (%s holes)\n' "$SPARSE_FILE_COUNT" "$(human_bytes "$SPARSE_HOLE_BYTES")"
fi
printf 'Archive size: %s\n' "$(human_bytes "$(stat -c '%s' -- "$ARCHIVE")")"
write_success_report
$WRITE_REPORT && printf 'Success report: %s\n' "$REPORT_PATH"

if $REMOVE_SOURCE; then
    warn "The archive may contain lossy video transcodes instead of the original video bitstreams."
    warn "7z also is not a complete POSIX metadata backup for ownership, ACLs, or extended attributes."
    printf '\nDeleting verified source folder:\n  %s\n\n' "$SOURCE"
    rm -rf --one-file-system -- "$SOURCE"

    if [[ -e $SOURCE ]]; then
        warn "Some source content remains, possibly because of permissions or a nested mounted filesystem."
        exit 1
    fi

    printf 'Source folder removed successfully.\n'
fi

printf '\nCompleted successfully:\n  %s\n' "$ARCHIVE"
