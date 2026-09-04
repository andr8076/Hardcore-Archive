#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
SCHEDULER="$ROOT/lib/scheduler.sh"
DOCTOR_CHECKS="$ROOT/lib/hardcore-archive-doctor-checks.sh"

if grep -Fq 'hardcore_runtime_prepare_video_toolchain' "$SCHEDULER"; then
    printf 'Scheduler still prepares the video runtime before source relevance is known.\n' >&2
    exit 1
fi

# shellcheck source=/dev/null
source "$DOCTOR_CHECKS"

runtime_prepare_calls=0
hardcore_runtime_prepare_video_toolchain() { runtime_prepare_calls=$((runtime_prepare_calls + 1)); }
check_core_command_set() { return 0; }
check_7zip() { SEVEN_ZIP=/bin/true; return 0; }
inspect_nested_relevance() { return 0; }
check_version_command() { return 0; }
check_command() { return 0; }
add_ready() { return 0; }
check_acl_capability() { return 0; }
check_image_capabilities() { return 0; }
check_video_capability() { return 0; }

PLATFORM=Other
MC_AUTO_ENABLED=false
ANALYZE_ONLY=false
ALLOW_SLEEP=true
BATCH_MODE=false
IMAGE_ENABLED=false
IMAGE_RELEVANT=false
NESTED_RELEVANT=false
VIDEO_ENABLED=true
VIDEO_RELEVANT=false
SEVEN_ZIP=''

check_strict_runtime_capabilities
(( runtime_prepare_calls == 0 )) || {
    printf 'Video runtime was prepared for a source with no relevant videos.\n' >&2
    exit 1
}

VIDEO_RELEVANT=true
check_strict_runtime_capabilities
(( runtime_prepare_calls == 1 )) || {
    printf 'Video runtime was not prepared exactly once for a direct video source.\n' >&2
    exit 1
}

runtime_prepare_calls=0
VIDEO_RELEVANT=false
NESTED_RELEVANT=true
inspect_nested_relevance() {
    VIDEO_RELEVANT=true
    return 0
}
check_strict_runtime_capabilities
(( runtime_prepare_calls == 1 )) || {
    printf 'Video runtime was not prepared after nested inspection discovered video content.\n' >&2
    exit 1
}

runtime_prepare_calls=0
VIDEO_ENABLED=false
VIDEO_RELEVANT=true
NESTED_RELEVANT=false
inspect_nested_relevance() { return 0; }
check_strict_runtime_capabilities
(( runtime_prepare_calls == 0 )) || {
    printf 'Video runtime was prepared even though video transcoding was disabled.\n' >&2
    exit 1
}

printf 'Lazy video runtime tests passed.\n'
