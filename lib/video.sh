#!/usr/bin/env bash

# Production video-helper staging boundary.
#
# Initialization / dependency contract:
#   * Safe to source before the core initializes per-job state; this module only
#     resolves the checked-in helper path and defines staging functions.
#   * hardcore_video_stage_helper requires one destination path, a readable
#     checked-in helper, cat, and chmod. It returns non-zero on any staging
#     failure and never changes quality, codec, retry, or selection policy.
#   * The staged helper remains a separate process exactly as before. Its own
#     EXIT/INT/TERM/HUP traps, exported video functions, nested batch execution,
#     and return codes are therefore preserved.
#   * This module owns no long-lived temporary resources. The core owns and
#     removes VIDEO_STAGE_PARENT/VIDEO_HELPER through its existing cleanup path.
[[ ${HARDCORE_VIDEO_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_VIDEO_SH_LOADED=1

HARDCORE_VIDEO_MODULE_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
HARDCORE_VIDEO_HELPER_SOURCE=${HARDCORE_ARCHIVE_VIDEO_HELPER_SOURCE:-"$HARDCORE_VIDEO_MODULE_DIR/hardcore-archive-video-helper.sh"}

hardcore_video_stage_helper() {
    local destination=${1:-}
    [[ -n $destination ]] || {
        printf 'Error: video helper staging requires a destination path.\n' >&2
        return 2
    }
    [[ -r $HARDCORE_VIDEO_HELPER_SOURCE ]] || {
        printf 'Error: checked-in video helper is missing or unreadable: %s\n' "$HARDCORE_VIDEO_HELPER_SOURCE" >&2
        return 1
    }
    cat -- "$HARDCORE_VIDEO_HELPER_SOURCE" > "$destination" || return 1
    chmod 700 -- "$destination"
}
