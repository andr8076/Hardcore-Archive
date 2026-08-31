#!/usr/bin/env python3
"""Add opt-in live terminal log viewers to the generated archive engine."""
from __future__ import annotations

import os
import pathlib
import sys

MARKER = "# HARDCORE_VISUAL_MODE_V1"


def fail(label: str, count: int) -> None:
    print(
        f"Error: visual runtime patch failed: {label}: expected one anchor, found {count}",
        file=sys.stderr,
    )
    raise SystemExit(1)


def repl(text: str, old: str, new: str, label: str) -> str:
    count = text.count(old)
    if count != 1:
        fail(label, count)
    return text.replace(old, new, 1)


def main() -> int:
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} INPUT_CORE OUTPUT_CORE", file=sys.stderr)
        return 2

    src, dst = map(pathlib.Path, sys.argv[1:])
    text = src.read_text(encoding="utf-8")
    if MARKER in text:
        dst.write_text(text, encoding="utf-8")
        os.chmod(dst, 0o700)
        return 0

    runtime = r'''
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
'''

    text = repl(
        text,
        "\ncompress_nonvideo_with_fallback() {",
        "\n" + runtime + "\nhardcore_visual_validate\n\ncompress_nonvideo_with_fallback() {",
        "visual runtime insertion",
    )

    # The Copy-lane patch runs before visual mode and renames the legacy
    # nonvideo-compression failure context to lzma-compression. Anchor against
    # the post-patch runtime text so visual mode follows the same engine that
    # will actually execute.
    text = repl(
        text,
        '''        : > "$SEVEN_ZIP_LOG"

        FAILURE_CONTEXT="lzma-compression"''',
        '''        : > "$SEVEN_ZIP_LOG"
        hardcore_visual_open_log "Hardcore Archive - 7-Zip / archive" "$SEVEN_ZIP_LOG" pid "$$"

        FAILURE_CONTEXT="lzma-compression"''',
        "7-Zip visual viewer",
    )

    text = repl(
        text,
        '''    VIDEO_PIPELINE_PID=$!
}

wait_for_video_pipeline() {''',
        '''    VIDEO_PIPELINE_PID=$!
    hardcore_visual_open_log "Hardcore Archive - Video / FFmpeg" "$VIDEO_LOG" pid "$VIDEO_PIPELINE_PID"
}

wait_for_video_pipeline() {''',
        "video visual viewer",
    )

    text = repl(
        text,
        '''    IMAGE_PIPELINE_PID=$!
}

wait_for_image_pipeline() {''',
        '''    IMAGE_PIPELINE_PID=$!
    hardcore_visual_open_log "Hardcore Archive - Images" "$IMAGE_LOG" pid "$IMAGE_PIPELINE_PID" "$IMAGE_RESULT_MANIFEST"
}

wait_for_image_pipeline() {''',
        "image visual viewer",
    )

    nested_anchor = '''                } > "$child_log"
                env HARDCORE_ARCHIVE_INHIBITED=1 \\
'''
    nested_replacement = '''                } > "$child_log"
                hardcore_visual_open_log "Hardcore Archive - Nested: ${relative}" "$child_log" pattern 'Exit status:'
                env HARDCORE_ARCHIVE_INHIBITED=1 \\
'''
    text = repl(text, nested_anchor, nested_replacement, "nested-child visual viewer")

    dst.write_text(text, encoding="utf-8")
    os.chmod(dst, 0o700)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
