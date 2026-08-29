#!/usr/bin/env bash
# Sourced by hardcore-archive.sh after source inventory/policy resolution.

# --------------------------- strict doctor ---------------------------------
declare -a FAIL_TYPES=() FAIL_CAPS=() FAIL_DETAILS=() FAIL_REPAIR_KEYS=() FAIL_REPAIR_CMDS=()
declare -a READY_LINES=() INFO_LINES=()
declare -A REPAIR_KEY_SEEN=()

add_ready() { READY_LINES+=("$1"); }
add_info() { INFO_LINES+=("$1"); }
add_failure() {
    FAIL_TYPES+=("$1"); FAIL_CAPS+=("$2"); FAIL_DETAILS+=("$3"); FAIL_REPAIR_KEYS+=("${4:-}"); FAIL_REPAIR_CMDS+=("${5:-}")
    [[ -n ${4:-} ]] && REPAIR_KEY_SEEN["$4"]=1
}

check_command() {
    local cap=$1 cmd=$2 key=$3 detail=$4
    if ! command -v "$cmd" >/dev/null 2>&1; then add_failure MISSING "$cap" "$detail" "$key"; return 1; fi
    return 0
}

check_version_command() {
    local cap=$1 cmd=$2 key=$3 detail=$4; shift 4
    check_command "$cap" "$cmd" "$key" "$detail" || return 1
    if ! "$cmd" "$@" >/dev/null 2>&1; then add_failure BROKEN "$cap" "$cmd is installed but failed its startup/version self-test." "$key"; return 1; fi
    return 0
}

check_core_command_set() {
    local item cmd key missing=0
    local -a required=(
        'awk:gawk' 'grep:grep' 'sed:sed' 'find:findutils' 'sort:coreutils' 'comm:coreutils' 'cmp:coreutils'
        'stat:coreutils' 'realpath:coreutils' 'numfmt:coreutils' 'mktemp:coreutils' 'date:coreutils' 'df:coreutils' 'du:coreutils'
        'sha256sum:coreutils' 'head:coreutils' 'tail:coreutils' 'cut:coreutils' 'tr:coreutils' 'wc:coreutils'
        'xargs:findutils' 'chmod:coreutils' 'cp:coreutils' 'mv:coreutils' 'rm:coreutils' 'mkdir:coreutils'
        'touch:coreutils' 'readlink:coreutils' 'sync:coreutils' 'nproc:coreutils' 'sleep:coreutils' 'tee:coreutils'
        'ln:coreutils' 'env:coreutils' 'basename:coreutils' 'dirname:coreutils' 'flock:util-linux'
    )
    for item in "${required[@]}"; do
        cmd=${item%%:*}; key=${item#*:}
        if ! command -v "$cmd" >/dev/null 2>&1; then add_failure MISSING "core command: $cmd" "The archive engine uses $cmd in this create workflow." "$key"; missing=1; fi
    done
    (( missing == 0 )) || return 1
    stat -c '%s' -- /dev/null >/dev/null 2>&1 || add_failure UNSUPPORTED 'GNU stat contract' 'stat exists but does not support GNU -c semantics required by the engine.' coreutils
    realpath -m -- . >/dev/null 2>&1 || add_failure UNSUPPORTED 'GNU realpath contract' 'realpath exists but does not support -m semantics required by the engine.' coreutils
    numfmt --to=iec-i 1024 >/dev/null 2>&1 || add_failure UNSUPPORTED 'GNU numfmt contract' 'numfmt is missing or incompatible with the GNU interface.' coreutils
    printf 'b\0a\0' | sort -z >/dev/null 2>&1 || add_failure UNSUPPORTED 'GNU sort contract' 'sort exists but does not support NUL-delimited -z sorting.' coreutils
    find . -maxdepth 0 -printf '%p\0' >/dev/null 2>&1 || add_failure UNSUPPORTED 'GNU find contract' 'find exists but does not support GNU -printf semantics.' findutils
    flock --version >/dev/null 2>&1 || add_failure BROKEN 'flock' 'flock is installed but cannot start correctly.' util-linux
    add_ready 'Core archive command set'
}

SEVEN_ZIP=''
check_7zip() {
    local c
    for c in 7zz 7z 7za; do command -v "$c" >/dev/null 2>&1 && { SEVEN_ZIP=$(command -v "$c"); break; }; done
    if [[ -z $SEVEN_ZIP ]]; then add_failure MISSING '7-Zip' 'Final archive creation, listing, extraction, and verification require 7-Zip.' 7zip; return 1; fi
    if ! "$SEVEN_ZIP" i >/dev/null 2>&1; then add_failure BROKEN '7-Zip' "$SEVEN_ZIP exists but cannot report supported formats." 7zip; return 1; fi
    add_ready "7-Zip ($SEVEN_ZIP)"
}

NESTED_VIDEO_COUNT=0
NESTED_JPEG_COUNT=0
NESTED_PNG_COUNT=0
NESTED_DEEP_ARCHIVE_COUNT=0
inspect_nested_relevance() {
    $NESTED_RELEVANT || return 0
    [[ -n $SEVEN_ZIP ]] || return 0
    local archive line entry rc=0
    for archive in "${NESTED_PATHS[@]}"; do
        while IFS= read -r line; do
            [[ $line == 'Path = '* ]] || continue
            entry=${line#Path = }
            [[ $entry == "$archive" ]] && continue
            if is_video_path "$entry"; then NESTED_VIDEO_COUNT=$((NESTED_VIDEO_COUNT + 1))
            elif is_jpeg_path "$entry"; then NESTED_JPEG_COUNT=$((NESTED_JPEG_COUNT + 1))
            elif is_png_path "$entry"; then NESTED_PNG_COUNT=$((NESTED_PNG_COUNT + 1))
            elif is_nested_path "$entry"; then NESTED_DEEP_ARCHIVE_COUNT=$((NESTED_DEEP_ARCHIVE_COUNT + 1))
            fi
        done < <("$SEVEN_ZIP" l -slt -- "$archive" 2>/dev/null) || rc=$?
        if (( rc != 0 )); then
            add_failure BROKEN 'Nested archive inspection' "7-Zip cannot list $archive, so required recursive capabilities cannot be determined safely." 7zip
            return 1
        fi
    done
    if (( NESTED_VIDEO_COUNT > 0 )); then VIDEO_RELEVANT=true; fi
    if (( NESTED_JPEG_COUNT > 0 || NESTED_PNG_COUNT > 0 )); then IMAGE_RELEVANT=true; fi
    if (( NESTED_DEEP_ARCHIVE_COUNT > 0 )); then
        # We do not extract nested-within-nested data during the lightweight
        # doctor. Deeper archives may reveal media, so enabled media transforms
        # remain relevant only in this genuinely unknown recursive case.
        $VIDEO_ENABLED && VIDEO_RELEVANT=true
        $IMAGE_ENABLED && IMAGE_RELEVANT=true
    fi
    add_info "Nested inspection: $NESTED_VIDEO_COUNT video, $NESTED_JPEG_COUNT JPEG, $NESTED_PNG_COUNT PNG, $NESTED_DEEP_ARCHIVE_COUNT deeper archive entries."
}

# Do not use grep -q in an ffmpeg | ... pipeline here. With `set -o pipefail`,
# an early grep exit can SIGPIPE ffmpeg/awk and turn a successful match into a
# false failure. AWK consumes the complete table and decides only at EOF.
ffmpeg_table_has_name() {
    local table=$1 wanted=$2
    command -v ffmpeg >/dev/null 2>&1 || return 1
    ffmpeg -hide_banner "$table" 2>/dev/null |
        awk -v wanted="$wanted" 'NF >= 2 && $2 == wanted {found=1} END {exit(found ? 0 : 1)}'
}
encoder_available() {
    ffmpeg_table_has_name -encoders "$1"
}
filter_available() {
    ffmpeg_table_has_name -filters "$1"
}
linux_has_drm_vendor() {
    local wanted=${1,,} node vendor
    for node in /sys/class/drm/renderD*/device/vendor; do [[ -r $node ]] || continue; vendor=$(<"$node"); [[ ${vendor,,} == "$wanted" ]] && return 0; done
    return 1
}
vaapi_device_for_vendor() {
    local wanted=${1,,} node vendor render
    for node in /sys/class/drm/renderD*/device/vendor; do
        [[ -r $node ]] || continue; vendor=$(<"$node"); [[ ${vendor,,} == "$wanted" ]] || continue
        render=/dev/dri/$(basename "$(dirname "$(dirname "$node")")")
        [[ -e $render ]] && { printf '%s' "$render"; return 0; }
    done
    for render in /dev/dri/renderD*; do [[ -e $render ]] && { printf '%s' "$render"; return 0; }; done
    return 1
}
encoder_matches_codec() {
    case "$2:$1" in av1:av1_vaapi|av1:av1_nvenc|av1:av1_qsv|hevc:hevc_videotoolbox|hevc:hevc_vaapi|hevc:hevc_nvenc|hevc:hevc_qsv) return 0;; *) return 1;; esac
}
select_hardware_encoder() {
    local codec=$1 candidate
    local -a preferred=() fallback=()
    case $codec in
        av1)
            [[ $PLATFORM == Linux ]] && { linux_has_drm_vendor 0x1002 && preferred+=(av1_vaapi); linux_has_drm_vendor 0x10de && preferred+=(av1_nvenc); linux_has_drm_vendor 0x8086 && preferred+=(av1_qsv av1_vaapi); }
            fallback=(av1_vaapi av1_nvenc av1_qsv) ;;
        hevc)
            [[ $PLATFORM == Darwin ]] && preferred+=(hevc_videotoolbox)
            [[ $PLATFORM == Linux ]] && { linux_has_drm_vendor 0x1002 && preferred+=(hevc_vaapi); linux_has_drm_vendor 0x10de && preferred+=(hevc_nvenc); linux_has_drm_vendor 0x8086 && preferred+=(hevc_qsv hevc_vaapi); }
            fallback=(hevc_videotoolbox hevc_vaapi hevc_nvenc hevc_qsv) ;;
    esac
    for candidate in "${preferred[@]}" "${fallback[@]}"; do [[ -n $candidate ]] && encoder_available "$candidate" && { printf '%s' "$candidate"; return 0; }; done
    return 1
}

VIDEO_PROBE_ERROR=''
