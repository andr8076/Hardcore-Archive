#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)

VISUAL_MODULE="$ROOT/lib/visual.sh"
CORE="$ROOT/lib/hardcore-archive-core.sh"
for required in "$VISUAL_MODULE" "$CORE"; do
    [[ -f $required ]] || { printf 'Missing visual production dependency: %s\n' "$required" >&2; exit 1; }
    bash -n "$required"
done

# Launcher behavior: --visual is consumed before the policy frontend sees it,
# and normal invocations explicitly export visual=0 rather than inheriting stale state.
source "$VISUAL_MODULE"
CAPTURED_ARGS=()
hardcore_config_main() {
    CAPTURED_ARGS=("$@")
    return 0
}
hardcore_visual_launcher_main --visual source-dir output.7z
[[ ${HARDCORE_ARCHIVE_VISUAL:-0} == 1 ]]
[[ ${#CAPTURED_ARGS[@]} == 2 ]]
[[ ${CAPTURED_ARGS[0]} == source-dir ]]
[[ ${CAPTURED_ARGS[1]} == output.7z ]]
hardcore_visual_launcher_main source-dir output.7z
[[ ${HARDCORE_ARCHIVE_VISUAL:-1} == 0 ]]

# Visual worker ownership is part of the checked-in static engine.  Test those
# production interfaces directly rather than rebuilding a patched copy of core.
assert_core_has() {
    local text=$1
    grep -Fq -- "$text" "$CORE" || {
        printf 'Missing static visual engine text: %s\n' "$text" >&2
        exit 1
    }
}
assert_module_has() {
    local text=$1
    grep -Fq -- "$text" "$VISUAL_MODULE" || {
        printf 'Missing visual module text: %s\n' "$text" >&2
        exit 1
    }
}

assert_core_has '# HARDCORE_VISUAL_MODE_V1'
assert_core_has 'hardcore_visual_validate'
assert_core_has 'Hardcore Archive - Video / FFmpeg'
assert_core_has 'Hardcore Archive - Images'
assert_core_has 'Hardcore Archive - 7-Zip / archive'
assert_core_has 'Hardcore Archive - Nested: ${relative}'
assert_core_has 'Live log viewer. Closing this window does NOT stop the archive worker.'
assert_core_has 'VIDEO_PIPELINE_PID=$!'
assert_core_has 'IMAGE_PIPELINE_PID=$!'
assert_core_has "pattern 'Exit status:'"
assert_core_has 'konsole|kitty|gnome-terminal|alacritty|wezterm|foot|xterm'
assert_module_has 'HARDCORE_ARCHIVE_VISUAL=$($visual && printf 1 || printf 0)'
assert_module_has 'hardcore_config_main "${forwarded[@]}"'

! grep -Eq 'HARDCORE_VISUAL_PATCHER|hardcore_visual_apply_runtime_patch' \
    "$ROOT/lib/planner.sh" "$ROOT/lib/archive.sh"
grep -Fq 'source "$HARDCORE_ARCHIVE_ROOT/lib/visual.sh"' "$ROOT/hardcore-archive"

printf 'Visual worker-window policy tests passed.\n'
