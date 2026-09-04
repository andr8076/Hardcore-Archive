#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-video-routing.XXXXXX")
cleanup() { rm -rf -- "$TMP"; }
trap cleanup EXIT
mkdir -p "$TMP/not-video" "$TMP/video"
printf 'const answer: number = 42;\n' > "$TMP/not-video/app.ts"
printf 'this is not a movie\n' > "$TMP/not-video/fake.mp4"
printf '\x00\x01\x02ordinary binary payload\n' > "$TMP/not-video/blob.unknown"
printf '\x00\x00\x00\x18ftypisom\x00\x00\x02\x00isomiso2avc1mp41' > "$TMP/video/movie.mp4"

# shellcheck source=/dev/null
source "$ROOT/lib/hardcore-archive-doctor-checks.sh"

is_video_path() {
    case ${1,,} in
        *.mp4|*.mkv|*.webm|*.mov|*.m4v|*.avi|*.wmv|*.flv|*.mpg|*.mpeg|\
        *.m2ts|*.mts|*.ts|*.vob|*.ogv|*.3gp|*.3g2|*.mxf|*.dvr-ms|\
        *.rm|*.rmvb|*.asf|*.divx|*.f4v) return 0 ;;
        *) return 1 ;;
    esac
}

# Keep the test deterministic: emulate libmagic's content result rather than
# depending on the host runner's exact MIME database version.
file() {
    local path=${!#}
    case $path in
        */video/movie.mp4) printf 'video/mp4\n' ;;
        *) printf 'text/plain\n' ;;
    esac
}

add_info() { :; }
check_core_command_set() { return 0; }
check_7zip() { SEVEN_ZIP=''; return 0; }
inspect_nested_relevance() { return 0; }
check_version_command() { return 0; }
check_command() { return 0; }
check_acl_capability() { return 0; }
check_image_capabilities() { return 0; }
check_video_capability() { return 0; }

runtime_prepare_calls=0
hardcore_runtime_prepare_video_toolchain() { runtime_prepare_calls=$((runtime_prepare_calls + 1)); }

PLATFORM=Other
MC_AUTO_ENABLED=false
ANALYZE_ONLY=false
ALLOW_SLEEP=true
BATCH_MODE=false
IMAGE_ENABLED=false
IMAGE_RELEVANT=false
NESTED_RELEVANT=false
NESTED_JPEG_COUNT=0
NESTED_PNG_COUNT=0
NESTED_DEEP_ARCHIVE_COUNT=0
SEVEN_ZIP=''
ONE_FILE_SYSTEM=true
VIDEO_ENABLED=true
VIDEO_STATE=auto
VIDEO_PREFLIGHT_ENABLED=false
QUALITY_CHECK_EFFECTIVE=off
REQUESTED_VIDEO_ENCODER=''
EFFECTIVE_VIDEO_CODEC=av1
FIRST_VIDEO=''

# A directory can contain arbitrary regular file types, including misleading
# video-looking suffixes, without ever touching FFmpeg.
SOURCE="$TMP/not-video"
VIDEO_COUNT=2
VIDEO_RELEVANT=true
check_strict_runtime_capabilities
[[ $VIDEO_RELEVANT == false ]] || { printf 'False video candidates remained video-relevant.\n' >&2; exit 1; }
(( VIDEO_COUNT == 0 )) || { printf 'False video candidates were still counted as video.\n' >&2; exit 1; }
(( runtime_prepare_calls == 0 )) || { printf 'FFmpeg runtime was prepared for non-video files.\n' >&2; exit 1; }

# Content-confirmed video still activates the media runtime normally.
SOURCE="$TMP/video"
VIDEO_COUNT=1
VIDEO_RELEVANT=true
FIRST_VIDEO="$TMP/video/movie.mp4"
check_strict_runtime_capabilities
[[ $VIDEO_RELEVANT == true ]] || { printf 'Real video was incorrectly routed as a generic file.\n' >&2; exit 1; }
(( VIDEO_COUNT == 1 )) || { printf 'Confirmed video count changed unexpectedly.\n' >&2; exit 1; }
(( runtime_prepare_calls == 1 )) || { printf 'Confirmed video did not prepare the FFmpeg runtime exactly once.\n' >&2; exit 1; }

printf 'Content-aware video routing tests passed.\n'
