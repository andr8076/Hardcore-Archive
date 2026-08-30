#!/usr/bin/env bash

# Archive-engine assembly boundary. This is the transitional home of the legacy
# core patch chain; sections are migrated out of hardcore-archive-core.sh one at
# a time without changing runtime behavior.
[[ ${HARDCORE_ARCHIVE_MODULE_SH_LOADED:-0} == 1 ]] && return 0
HARDCORE_ARCHIVE_MODULE_SH_LOADED=1

hardcore_archive_prepare_runtime_dir() {
    HARDCORE_RUNTIME_DIR=$(mktemp -d "${TMPDIR:-/tmp}/hardcore-archive-runtime.XXXXXX")
    mkdir -p -- "$HARDCORE_RUNTIME_DIR/lib"
}

hardcore_archive_patch_policy() {
    local base_policy="$HARDCORE_RUNTIME_DIR/.hardcore-archive-policy.base.sh"
    HARDCORE_RUNTIME_POLICY="$HARDCORE_RUNTIME_DIR/hardcore-archive-runner-policy.sh"
    python3 "$HARDCORE_POLICY_PATCHER" "$HARDCORE_POLICY_RUNNER" "$base_policy" || {
        rm -f -- "$base_policy"
        printf 'Error: refusing to start with stale archive policy.\n' >&2
        return 3
    }
    python3 "$HARDCORE_VIDEO_AUTO_POLICY_PATCHER" "$base_policy" "$HARDCORE_RUNTIME_POLICY" || {
        rm -f -- "$base_policy" "$HARDCORE_RUNTIME_POLICY"
        printf 'Error: refusing to start with stale automatic video-codec policy.\n' >&2
        return 3
    }
    rm -f -- "$base_policy"
}

hardcore_archive_link_stable_core() {
    ln -s -- "$HARDCORE_CORE_SOURCE" "$HARDCORE_RUNTIME_DIR/lib/hardcore-archive-core.sh"
}

hardcore_archive_build_runtime_core() {
    local copy_core="$HARDCORE_RUNTIME_DIR/lib/.hardcore-archive-core.copy-lane.sh"
    local media_core="$HARDCORE_RUNTIME_DIR/lib/.hardcore-archive-core.media.sh"
    local video_core="$HARDCORE_RUNTIME_DIR/lib/.hardcore-archive-core.video.sh"
    local nested_core="$HARDCORE_RUNTIME_DIR/lib/.hardcore-archive-core.nested.sh"
    local final_core="$HARDCORE_RUNTIME_DIR/lib/hardcore-archive-core.sh"

    python3 "$HARDCORE_COPY_LANE_PATCHER" "$HARDCORE_CORE_SOURCE" "$copy_core" || {
        printf 'Error: refusing to start with an unpatched archive engine.\n' >&2
        return 3
    }
    hardcore_nested_apply_runtime_patch "$copy_core" "$media_core" || return $?
    hardcore_video_apply_runtime_patch "$media_core" "$video_core" || return $?
    hardcore_nested_apply_diagnostics_patch "$video_core" "$nested_core" || return $?
    hardcore_containers_apply_runtime_patch "$nested_core" "$final_core" || return $?
    rm -f -- "$copy_core" "$media_core" "$video_core" "$nested_core"
}

hardcore_archive_cleanup_runtime_dir() {
    [[ -n ${HARDCORE_RUNTIME_DIR:-} && -d ${HARDCORE_RUNTIME_DIR:-} ]] && \
        rm -rf -- "$HARDCORE_RUNTIME_DIR" 2>/dev/null || true
}
